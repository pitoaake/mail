#!/usr/bin/env bash
# PMail 自动化安装脚本 (优化版)
# 版本: 2.1.0
# 最后更新: 2023-11-20

# ==================== 初始化配置 ====================
set -eo pipefail
shopt -s inherit_errexit
LC_ALL=C

# ==================== 常量定义 ====================
readonly RED='\033[31m'
readonly GREEN='\033[32m'
readonly YELLOW='\033[33m'
readonly BLUE='\033[36m'
readonly NC='\033[0m'
readonly PMAIL_DIR="${PMAIL_DIR:-$HOME/pmail}"
readonly CONFIG_DIR="$PMAIL_DIR/config"
readonly SSL_DIR="$PMAIL_DIR/ssl"
readonly LOG_FILE="/var/log/pmail_install.log"
readonly DOCKER_COMPOSE_VERSION="2.24.7"
readonly ALIYUN_CLI_VERSION="3.0.277"
readonly REQUIRED_PORTS=(25 80 443 465 993 995)

# ==================== 函数定义 ====================

# 带颜色输出到控制台和日志文件
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO") color=$GREEN ;;
        "WARN") color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "DEBUG") color=$BLUE ;;
        *) color=$NC ;;
    esac
    
    echo -e "${color}[${timestamp}] ${message}${NC}"
    echo "[${timestamp}] [$level] ${message}" >> "$LOG_FILE"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查端口占用
check_port() {
    local port=$1
    if lsof -i :"$port" >/dev/null 2>&1; then
        log "ERROR" "端口 $port 被占用: $(lsof -i :$port | awk 'NR==2{print $1}')"
        return 1
    fi
}

# 清理旧环境
clean_environment() {
    log "INFO" "开始清理旧环境..."
    
    # 停止并删除容器
    if docker ps -a --filter "name=pmail" | grep -q pmail; then
        log "DEBUG" "删除旧容器..."
        docker rm -f pmail >/dev/null || {
            log "WARN" "删除容器失败，尝试强制删除..."
            docker rm -f pmail &>/dev/null || true
        }
    fi

    # 删除网络
    if docker network ls | grep -q pmail_default; then
        log "DEBUG" "删除Docker网络..."
        docker network rm pmail_default >/dev/null || true
    fi

    # 清理数据目录
    if [[ -d "$PMAIL_DIR" ]]; then
        log "DEBUG" "删除数据目录..."
        find "$PMAIL_DIR" -mindepth 1 -delete || {
            log "WARN" "部分文件删除失败，尝试强制删除..."
            rm -rf "${PMAIL_DIR:?}"/* 2>/dev/null || true
        }
    fi
    
    log "INFO" "环境清理完成"
}

# 安装系统依赖
install_dependencies() {
    log "INFO" "开始安装系统依赖..."
    
    local pkgs=(
        "curl" "wget" "jq" "lsof" "git"
        "docker-ce" "docker-ce-cli" "containerd.io"
    )
    
    # 配置Docker源
    if ! command_exists docker; then
        log "DEBUG" "配置Docker官方源..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    fi
    
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null
    
    # 启动Docker服务
    systemctl enable --now docker >/dev/null 2>&1
    
    # 安装Docker Compose
    if ! command_exists docker-compose; then
        log "DEBUG" "安装Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/download/v$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    fi
    
    log "INFO" "系统依赖安装完成"
}

# 配置阿里云CLI
setup_aliyun_cli() {
    log "INFO" "配置阿里云CLI..."
    
    if ! command_exists aliyun; then
        log "DEBUG" "安装阿里云CLI..."
        curl -fsSL "https://aliyuncli.alicdn.com/aliyun-cli-linux-$ALIYUN_CLI_VERSION-amd64.tgz" | \
            tar xz -C /usr/local/bin && chmod +x /usr/local/bin/aliyun
    fi
    
    aliyun configure set \
        --profile PMailInstaller \
        --mode AK \
        --access-key-id "$ACCESS_KEY" \
        --access-key-secret "$ACCESS_SECRET" \
        --region cn-hangzhou >/dev/null 2>&1
    
    log "INFO" "阿里云CLI配置完成"
}

# 部署PMail服务
deploy_pmail() {
    log "INFO" "开始部署PMail服务..."
    
    # 创建目录结构
    mkdir -p "$CONFIG_DIR" "$SSL_DIR"
    cd "$PMAIL_DIR"
    
    # 生成docker-compose.yml
    cat > docker-compose.yml <<-'EOF'
version: '3.9'
services:
  pmail:
    image: ghcr.io/jinnrry/pmail:latest
    container_name: pmail
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 6
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
    log "DEBUG" "拉取PMail镜像..."
    docker pull ghcr.io/jinnrry/pmail:latest >/dev/null 2>&1 || {
        log "ERROR" "镜像拉取失败，尝试使用备用镜像源..."
        docker pull registry.cn-hangzhou.aliyuncs.com/jinnrry/pmail:latest >/dev/null 2>&1 || {
            log "ERROR" "无法获取PMail镜像"
            exit 1
        }
        sed -i 's|ghcr.io/jinnrry/pmail|registry.cn-hangzhou.aliyuncs.com/jinnrry/pmail|' docker-compose.yml
    }

    # 启动服务
    log "DEBUG" "启动PMail容器..."
    docker-compose up -d >/dev/null
    
    # 等待服务就绪
    local timeout=120
    while ! docker inspect --format '{{.State.Health.Status}}' pmail 2>/dev/null | grep -q 'healthy'; do
        sleep 5
        timeout=$((timeout-5))
        if [[ $timeout -le 0 ]]; then
            log "ERROR" "PMail启动超时"
            docker-compose logs
            exit 1
        fi
        log "DEBUG" "等待服务就绪... (剩余${timeout}秒)"
    done
    
    log "INFO" "PMail服务部署完成"
}

# 配置PMail基础设置
configure_pmail() {
    local ip=$1 domain=$2 password=$3
    log "INFO" "配置PMail基础设置..."
    
    # 设置管理员密码
    curl -X POST "http://$ip/api/setup" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"set\",\"step\":\"password\",\"account\":\"admin\",\"password\":\"$password\"}" >/dev/null 2>&1 || {
        log "WARN" "密码设置API调用失败"
    }

    # 配置域名
    curl -X POST "http://$ip/api/setup" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"set\",\"step\":\"domain\",\"web_domain\":\"mail.$domain\",\"smtp_domain\":\"$domain\"}" >/dev/null 2>&1 || {
        log "WARN" "域名设置API调用失败"
    }
}

# 配置DNS记录
configure_dns() {
    log "INFO" "开始配置DNS记录..."
    
    # 获取DNS配置
    local dns_config
    dns_config=$(curl -sS "http://$PMAIL_IP/api/setup" \
        -H "Content-Type: application/json" \
        -d '{"action":"get","step":"dns"}') || {
        log "ERROR" "获取DNS配置失败"
        return 1
    }

    # 处理每条记录
    echo "$dns_config" | jq -r '
        .data | to_entries[] | 
        "\(.key) \(.value | to_entries[] | .value.host) \(.value | to_entries[] | .value.type) \(.value | to_entries[] | .value.value)"
    ' | while read -r domain host type value; do
        local priority=5
        [[ "$type" == "MX" ]] && priority=10
        
        # 删除旧记录
        if ! aliyun alidns DeleteSubDomainRecords \
            --DomainName "$domain" \
            --RR "$host" \
            --Type "$type" \
            --profile PMailInstaller \
            --region cn-hangzhou >/dev/null 2>&1; then
            log "WARN" "删除旧记录失败: $host.$domain $type"
        fi

        # 添加新记录
        if ! aliyun alidns AddDomainRecord \
            --DomainName "$domain" \
            --RR "$host" \
            --Type "$type" \
            --Value "$value" \
            --TTL 600 \
            --Priority "$priority" \
            --profile PMailInstaller \
            --region cn-hangzhou >/dev/null 2>&1; then
            log "ERROR" "添加记录失败: $host.$domain $type"
            continue
        fi
        
        log "DEBUG" "成功设置: $host.$domain $type -> $value"
    done
    
    # 等待DNS传播
    log "INFO" "等待DNS记录生效(60秒)..."
    sleep 60
}

# 验证安装结果
verify_installation() {
    log "INFO" "验证安装结果..."
    
    # 检查容器状态
    if ! docker ps --filter "name=pmail" --format '{{.Status}}' | grep -q 'Up'; then
        log "ERROR" "PMail容器未运行"
        return 1
    fi

    # 检查端口监听
    for port in "${REQUIRED_PORTS[@]}"; do
        if ! lsof -i :"$port" >/dev/null; then
            log "ERROR" "端口 $port 未监听"
            return 1
        fi
    done
    
    log "INFO" "所有服务验证通过"
}

# 显示安装结果
show_result() {
    cat <<EOF

${GREEN}════════════════ PMail 安装完成 ════════════════${NC}
管理面板:   ${BLUE}http://${PMAIL_IP}${NC}
域名配置:   ${YELLOW}mail.${DOMAIN}${NC}
管理员账号: ${YELLOW}admin${NC}
管理员密码: ${YELLOW}${PASSWORD}${NC}

${GREEN}════════════ 必需DNS记录 ════════════${NC}
A记录:      mail.${DOMAIN} → ${PMAIL_IP}
MX记录:     ${DOMAIN} → mail.${DOMAIN} (优先级10)
TXT记录:    ${DOMAIN} → v=spf1 a mx ~all

${GREEN}安装日志已保存到: ${LOG_FILE}${NC}
EOF
}

# ==================== 主执行流程 ====================
main() {
    # 参数验证
    if [[ $# -lt 5 ]]; then
        echo -e "${RED}用法: $0 <IP地址> <域名> <密码> <阿里云AccessKey> <阿里云AccessSecret>${NC}"
        exit 1
    fi

    readonly PMAIL_IP=$1
    readonly DOMAIN=$2
    readonly PASSWORD=$3
    readonly ACCESS_KEY=$4
    readonly ACCESS_SECRET=$5

    # 初始化日志
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== PMail 安装日志 ===" > "$LOG_FILE"
    log "INFO" "开始PMail安装流程 (版本: 2.1.0)"

    # 执行安装步骤
    clean_environment
    install_dependencies
    
    # 检查端口
    log "INFO" "检查端口占用情况..."
    for port in "${REQUIRED_PORTS[@]}"; do
        check_port "$port"
    done
    
    setup_aliyun_cli
    deploy_pmail
    configure_pmail "$PMAIL_IP" "$DOMAIN" "$PASSWORD"
    configure_dns
    verify_installation
    
    # 设置主机名
    hostnamectl set-hostname "mail.$DOMAIN" >/dev/null 2>&1 || {
        log "WARN" "主机名设置失败"
    }

    show_result
    log "INFO" "PMail安装成功完成"
    exit 0
}

main "$@"
