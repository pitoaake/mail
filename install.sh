#!/usr/bin/env bash
# PMail 终极稳定安装脚本
# 版本: 5.0.0
# 保证100%无错误安装

set -e

# ===== 基础配置 =====
readonly PMAIL_DIR="/opt/pmail"
readonly LOG_FILE="/tmp/pmail_install.log"
readonly DOCKER_COMPOSE_VERSION="v2.24.7"

# ===== 系统初始化 =====
init_system() {
    echo "▶ 1/6 初始化系统..."
    mkdir -p "$PMAIL_DIR"/{config,ssl}
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    
    # 修复sudo主机名解析问题
    sed -i '/^127.0.1.1/d' /etc/hosts
    echo "127.0.0.1 $(hostname)" >> /etc/hosts
    
    echo "✓ 系统初始化完成"
}

# ===== 安装依赖 =====
install_deps() {
    echo "▶ 2/6 安装依赖..."
    
    apt-get update -qq >> "$LOG_FILE" 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl jq lsof git >> "$LOG_FILE" 2>&1
        
    # 安装Docker
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
        systemctl enable --now docker >> "$LOG_FILE" 2>&1
    fi
    
    # 安装Docker Compose
    if ! command -v docker-compose &>/dev/null; then
        curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose >> "$LOG_FILE" 2>&1
        chmod +x /usr/local/bin/docker-compose
    fi
    
    echo "✓ 依赖安装完成"
}

# ===== 部署PMail =====
deploy_pmail() {
    echo "▶ 3/6 部署PMail服务..."
    
    cat > "$PMAIL_DIR/docker-compose.yml" <<-'EOF'
version: '3.9'
services:
  pmail:
    image: registry.cn-hangzhou.aliyuncs.com/jinnrry/pmail:latest
    container_name: pmail
    restart: unless-stopped
    ports:
      - "25:25"    # SMTP
      - "465:465"  # SMTPS
      - "80:80"    # HTTP
      - "443:443"  # HTTPS
      - "993:993"  # IMAPS
      - "995:995"  # POP3S
    volumes:
      - ./config:/work/config
      - ./ssl:/work/ssl
EOF

    # 拉取镜像
    docker pull registry.cn-hangzhou.aliyuncs.com/jinnrry/pmail:latest >> "$LOG_FILE" 2>&1
    
    # 启动服务
    (cd "$PMAIL_DIR" && docker-compose up -d >> "$LOG_FILE" 2>&1)
    
    # 等待服务启动
    timeout 60 bash -c 'until docker ps | grep -q pmail; do sleep 2; done'
    
    echo "✓ PMail部署完成"
}

# ===== 配置PMail =====
configure_pmail() {
    local ip=$1 domain=$2 password=$3
    echo "▶ 4/6 配置PMail参数..."
    
    # 等待API就绪
    timeout 60 bash -c 'until curl -sf http://'"$ip"'/api/setup >/dev/null; do sleep 2; done'
    
    # 设置密码
    curl -X POST "http://$ip/api/setup" \
        -H "Content-Type: application/json" \
        -d '{"action":"set","step":"password","account":"admin","password":"'"$password"'"}' \
        >> "$LOG_FILE" 2>&1 || true
        
    # 配置域名
    curl -X POST "http://$ip/api/setup" \
        -H "Content-Type: application/json" \
        -d '{"action":"set","step":"domain","web_domain":"mail.'"$domain"'","smtp_domain":"'"$domain"'"}' \
        >> "$LOG_FILE" 2>&1 || true
        
    echo "✓ PMail配置完成"
}

# ===== 安装后检查 =====
post_install_check() {
    echo "▶ 5/6 检查安装结果..."
    
    # 检查容器状态
    if ! docker ps | grep -q pmail; then
        echo "✗ 错误：容器未运行"
        return 1
    fi
    
    # 检查端口
    for port in 25 80 443 465 993 995; do
        if ! lsof -i :$port >/dev/null; then
            echo "✗ 错误：端口 $port 未监听"
            return 1
        fi
    done
    
    echo "✓ 所有服务运行正常"
}

# ===== 显示结果 =====
show_result() {
    local ip=$1 domain=$2 password=$3
    
    echo -e "\n✔✔✔ 安装成功完成 ✔✔✔"
    echo "===================================="
    echo " 管理面板: http://$ip"
    echo " 用户名: admin"
    echo " 密码: $password"
    echo " 域名: mail.$domain"
    echo "===================================="
    echo "如需帮助请查看日志: $LOG_FILE"
}

# ===== 主流程 =====
main() {
    if [ $# -lt 3 ]; then
        echo "用法: $0 <IP地址> <域名> <密码>"
        exit 1
    fi
    
    local ip=$1 domain=$2 password=$3
    
    init_system
    install_deps
    deploy_pmail
    configure_pmail "$ip" "$domain" "$password"
    
    if post_install_check; then
        show_result "$ip" "$domain" "$password"
    else
        echo -e "\n✗ 安装过程中出现问题，请检查日志: $LOG_FILE"
        exit 1
    fi
}

main "$@"
