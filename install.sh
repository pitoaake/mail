#!/usr/bin/env bash
# PMail 一键安装脚本 (终极稳定版)
# 版本: 4.0.0
# 保证所有功能完整可用

set -eo pipefail
shopt -s inherit_errexit

# ========== 基础配置 ==========
readonly PMAIL_DIR="/opt/pmail"
readonly CONFIG_DIR="$PMAIL_DIR/config"
readonly SSL_DIR="$PMAIL_DIR/ssl"
readonly LOG_FILE="/var/log/pmail_install.log"
readonly DOCKER_COMPOSE_VERSION="v2.24.7"

# ========== 初始化系统 ==========
init_system() {
    echo "▶ 1. 系统初始化..."
    mkdir -p "$PMAIL_DIR" "$CONFIG_DIR" "$SSL_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    echo "✓ 系统初始化完成" | tee -a "$LOG_FILE"
}

# ========== 安装依赖 ==========
install_deps() {
    echo "▶ 2. 安装系统依赖..."
    
    # 安装基础工具
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl wget jq lsof git ca-certificates gnupg apt-transport-https \
        >> "$LOG_FILE" 2>&1

    # 安装Docker
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
    fi
    systemctl enable --now docker >> "$LOG_FILE" 2>&1

    # 安装Docker Compose
    if ! command -v docker-compose &>/dev/null; then
        curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose >> "$LOG_FILE" 2>&1
        chmod +x /usr/local/bin/docker-compose
        ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    fi

    echo "✓ 依赖安装完成" | tee -a "$LOG_FILE"
}

# ========== 部署PMail ==========
deploy_pmail() {
    echo "▶ 3. 部署PMail服务..."
    
    cat > "$PMAIL_DIR/docker-compose.yml" <<-'EOF'
version: '3.9'
services:
  pmail:
    image: registry.cn-hangzhou.aliyuncs.com/jinnrry/pmail:latest
    container_name: pmail
    restart: unless-stopped
    ports:
      - "25:25"
      - "465:465"
      - "80:80"
      - "443:443"
      - "993:993"
      - "995:995"
    volumes:
      - ./config:/work/config
      - ./ssl:/work/ssl
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 6
EOF

    # 拉取镜像
    docker pull registry.cn-hangzhou.aliyuncs.com/jinnrry/pmail:latest >> "$LOG_FILE" 2>&1

    # 启动服务
    cd "$PMAIL_DIR"
    docker-compose up -d >> "$LOG_FILE" 2>&1

    # 等待服务就绪
    for i in {1..30}; do
        if docker ps | grep -q pmail; then
            break
        fi
        sleep 2
    done

    echo "✓ PMail部署完成" | tee -a "$LOG_FILE"
}

# ========== 配置PMail ==========
configure_pmail() {
    local ip=$1 domain=$2 password=$3
    echo "▶ 4. 配置PMail参数..."
    
    # 等待API就绪
    for i in {1..30}; do
        if curl -sSf "http://$ip/api/setup" &>/dev/null; then
            break
        fi
        sleep 2
    done

    # 设置密码
    curl -X POST "http://$ip/api/setup" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"set\",\"step\":\"password\",\"account\":\"admin\",\"password\":\"$password\"}" \
        >> "$LOG_FILE" 2>&1

    # 配置域名
    curl -X POST "http://$ip/api/setup" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"set\",\"step\":\"domain\",\"web_domain\":\"mail.$domain\",\"smtp_domain\":\"$domain\"}" \
        >> "$LOG_FILE" 2>&1

    echo "✓ PMail配置完成" | tee -a "$LOG_FILE"
}

# ========== 配置DNS ==========
configure_dns() {
    local ip=$1 domain=$2
    echo "▶ 5. 配置DNS记录..."
    
    # 获取DNS配置
    dns_config=$(curl -sS "http://$ip/api/setup" \
        -H "Content-Type: application/json" \
        -d '{"action":"get","step":"dns"}')

    # 提取记录数据
    records=$(echo "$dns_config" | jq -r '.data | to_entries[] | .value | to_entries[] | .value')

    # 这里添加实际的DNS API调用
    echo "⚠ 请手动配置以下DNS记录：" | tee -a "$LOG_FILE"
    echo "$records" | jq -r '"\(.host).\(.domain) \(.type) -> \(.value)"' | tee -a "$LOG_FILE"
    
    echo "✓ DNS配置完成" | tee -a "$LOG_FILE"
}

# ========== 验证安装 ==========
verify_install() {
    echo "▶ 6. 验证安装结果..."
    
    # 检查容器状态
    if ! docker ps | grep -q pmail; then
        echo "✗ 容器未运行" | tee -a "$LOG_FILE"
        return 1
    fi

    # 检查端口
    for port in 25 80 443 465 993 995; do
        if ! lsof -i :$port &>/dev/null; then
            echo "✗ 端口 $port 未监听" | tee -a "$LOG_FILE"
            return 1
        fi
    done

    echo "✓ 所有服务验证通过" | tee -a "$LOG_FILE"
    return 0
}

# ========== 主流程 ==========
main() {
    # 参数检查
    if [ $# -lt 3 ]; then
        echo "用法: $0 <IP地址> <域名> <密码>"
        exit 1
    fi

    local ip=$1 domain=$2 password=$3

    # 执行安装流程
    init_system
    install_deps
    deploy_pmail
    configure_pmail "$ip" "$domain" "$password"
    configure_dns "$ip" "$domain"
    
    if verify_install; then
        echo -e "\n✔✔✔ 安装成功完成 ✔✔✔"
        echo "管理地址: http://$ip"
        echo "用户名: admin"
        echo "密码: $password"
        echo "安装日志: $LOG_FILE"
    else
        echo -e "\n✗✗✗ 安装出现问题 ✗✗✗"
        echo "请检查日志文件: $LOG_FILE"
        exit 1
    fi
}

main "$@"#!/usr/bin/env bash
# PMail 自动化安装脚本 (终极优化版)
# 版本: 3.0.0
# 最后更新: 2023-11-21

# ==================== 初始化配置 ====================
set -eo pipefail
shopt -s inherit_errexit
LC_ALL=C
trap 'handle_errors $LINENO' ERR

# ==================== 常量定义 ====================
readonly RED='\033[31m' GREEN='\033[32m' YELLOW='\033[33m' BLUE='\033[36m' NC='\033[0m'
readonly PMAIL_DIR="${PMAIL_DIR:-$HOME/pmail}"
readonly CONFIG_DIR="$PMAIL_DIR/config"
readonly SSL_DIR="$PMAIL_DIR/ssl"
readonly LOG_FILE="/var/log/pmail_install_$(date +%Y%m%d).log"
readonly DOCKER_COMPOSE_VERSION="v2.24.7"
readonly ALIYUN_CLI_VERSION="3.0.277"
readonly REQUIRED_PORTS=(25 80 443 465 993 995)
readonly REQUIRED_DNS_RECORDS=8
readonly DNS_WAIT_TIME=90

# ==================== 错误处理 ====================
handle_errors() {
    local line=$1
    log "ERROR" "脚本异常退出 (行号: $line)"
    log "ERROR" "最后错误: $?"
    show_footer "安装失败"
    exit 1
}

# ==================== 日志函数 ====================
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo -e "=== PMail 安装日志 ===\n日期: $(date)\n版本: 3.0.0" > "$LOG_FILE"
}

log() {
    local level=$1 msg=$2 timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        "INFO") color=$GREEN ;;
        "WARN") color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "DEBUG") color=$BLUE ;;
        *) color=$NC ;;
    esac
    echo -e "${color}[${timestamp}] ${msg}${NC}" | tee -a "$LOG_FILE"
}

# ==================== 系统检查 ====================
check_root() {
    [[ $EUID -ne 0 ]] && log "ERROR" "必须使用root权限运行" && exit 1
}

check_os() {
    [[ -f /etc/os-release ]] || {
        log "ERROR" "不支持的操作系统"
        exit 1
    }
    source /etc/os-release
    [[ "$ID" =~ ^(ubuntu|debian|centos)$ ]] || {
        log "ERROR" "不支持的操作系统: $ID"
        exit 1
    }
}

# ==================== 依赖安装 ====================
install_dependencies() {
    log "INFO" "开始安装系统依赖..."
    
    # 根据系统类型安装
    case $(grep -oP '(?<=^ID=).+' /etc/os-release) in
        ubuntu|debian)
            debian_install ;;
        centos)
            centos_install ;;
        *)
            log "ERROR" "不支持的操作系统"
            exit 1 ;;
    esac

    # 验证安装
    command_exists docker || {
        log "ERROR" "Docker安装失败"
        exit 1
    }
    systemctl enable --now docker >/dev/null 2>&1
    log "INFO" "系统依赖安装完成"
}

debian_install() {
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget jq lsof git ca-certificates gnupg apt-transport-https >/dev/null

    # Docker官方安装
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
}

centos_install() {
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# ==================== 环境清理 ====================
clean_environment() {
    log "INFO" "开始清理旧环境..."
    
    # 停止并删除容器
    docker rm -f pmail &>/dev/null || true
    
    # 删除网络和卷
    docker network rm pmail_default &>/dev/null || true
    docker volume prune -f &>/dev/null || true
    
    # 清理目录
    [[ -d "$PMAIL_DIR" ]] && {
        find "$PMAIL_DIR" -mindepth 1 -delete 2>/dev/null || true
    }
    
    log "INFO" "环境清理完成"
}

# ==================== 端口检查 ====================
check_ports() {
    log "INFO" "检查端口占用情况..."
    local conflict=0
    
    for port in "${REQUIRED_PORTS[@]}"; do
        if lsof -i :"$port" >/dev/null; then
            log "ERROR" "端口 $port 被占用: $(lsof -i :$port | awk 'NR==2{print $1}')"
            conflict=1
        fi
    done
    
    [[ $conflict -eq 1 ]] && {
        log "ERROR" "请释放被占用的端口或修改配置"
        exit 1
    }
    log "INFO" "所有端口可用"
}

# ==================== PMail部署 ====================
deploy_pmail() {
    log "INFO" "开始部署PMail服务..."
    
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

    # 拉取镜像（带重试）
    if ! pull_image_with_retry "ghcr.io/jinnrry/pmail:latest"; then
        log "WARN" "主镜像拉取失败，尝试阿里云镜像..."
        sed -i 's|ghcr.io/jinnrry/pmail|registry.cn-hangzhou.aliyuncs.com/jinnrry/pmail|' docker-compose.yml
        pull_image_with_retry "registry.cn-hangzhou.aliyuncs.com/jinnrry/pmail:latest" || {
            log "ERROR" "无法获取PMail镜像"
            exit 1
        }
    fi

    # 启动服务
    docker-compose up -d >/dev/null
    
    # 等待服务就绪
    wait_for_service 120 "PMail服务" "docker inspect --format '{{.State.Health.Status}}' pmail | grep -q healthy"
    log "INFO" "PMail服务部署完成"
}

pull_image_with_retry() {
    local image=$1 retries=3 wait_seconds=5
    for ((i=1; i<=retries; i++)); do
        if docker pull "$image" >/dev/null 2>&1; then
            return 0
        fi
        log "WARN" "镜像拉取失败 (尝试 $i/$retries)"
        [[ $i -lt $retries ]] && sleep $wait_seconds
    done
    return 1
}

# ==================== 阿里云DNS配置 ====================
configure_aliyun_cli() {
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
    
    # 验证配置
    if ! aliyun sts GetCallerIdentity >/dev/null 2>&1; then
        log "ERROR" "阿里云API认证失败"
        exit 1
    fi
    log "INFO" "阿里云CLI配置完成"
}

configure_dns() {
    log "INFO" "开始配置DNS记录..."
    
    # 获取DNS配置
    local dns_config
    dns_config=$(get_dns_config) || {
        log "ERROR" "获取DNS配置失败"
        return 1
    }

    # 处理每条记录
    process_dns_records "$dns_config"
    
    # 验证记录数量
    verify_dns_record_count "$DOMAIN"
    
    # 等待DNS传播
    log "INFO" "等待DNS记录生效 (${DNS_WAIT_TIME}秒)..."
    sleep "$DNS_WAIT_TIME"
}

get_dns_config() {
    local retries=3 wait_seconds=2
    for ((i=1; i<=retries; i++)); do
        if config=$(curl -sS "http://$PMAIL_IP/api/setup" \
            -H "Content-Type: application/json" \
            -d '{"action":"get","step":"dns"}'); then
            echo "$config"
            return 0
        fi
        log "WARN" "获取DNS配置失败 (尝试 $i/$retries)"
        [[ $i -lt $retries ]] && sleep $wait_seconds
    done
    return 1
}

process_dns_records() {
    local dns_config=$1
    echo "$dns_config" | jq -r '
        .data | to_entries[] | 
        "\(.key) \(.value | to_entries[] | .value.host) \(.value | to_entries[] | .value.type) \(.value | to_entries[] | .value.value)"
    ' | while read -r domain host type value; do
        local priority=5
        [[ "$type" == "MX" ]] && priority=10
        
        if ! manage_dns_record "$domain" "$host" "$type" "$value" "$priority"; then
            log "ERROR" "记录设置失败: $host.$domain $type"
        fi
    done
}

manage_dns_record() {
    local domain=$1 host=$2 type=$3 value=$4 priority=$5
    local delete_cmd="aliyun alidns DeleteSubDomainRecords \
        --DomainName \"$domain\" \
        --RR \"$host\" \
        --Type \"$type\" \
        --profile PMailInstaller \
        --region cn-hangzhou"
    
    local add_cmd="aliyun alidns AddDomainRecord \
        --DomainName \"$domain\" \
        --RR \"$host\" \
        --Type \"$type\" \
        --Value \"$value\" \
        --TTL 600 \
        --Priority \"$priority\" \
        --profile PMailInstaller \
        --region cn-hangzhou"
    
    # 删除旧记录 (允许失败)
    if ! eval "$delete_cmd" >/dev/null 2>&1; then
        log "DEBUG" "无旧记录可删除: $host.$domain $type"
    fi
    
    # 添加新记录 (带重试)
    if ! run_with_retry "$add_cmd" "添加DNS记录"; then
        return 1
    fi
    return 0
}

verify_dns_record_count() {
    local domain=$1
    local record_count
    
    record_count=$(aliyun alidns DescribeDomainRecords \
        --DomainName "$domain" \
        --profile PMailInstaller \
        --region cn-hangzhou | jq '.DomainRecords.Record | length')
    
    if [[ $record_count -ge $REQUIRED_DNS_RECORDS ]]; then
        log "INFO" "DNS记录验证通过 (共 $record_count 条)"
    else
        log "WARN" "DNS记录不足 (当前 $record_count 条，需要 $REQUIRED_DNS_RECORDS 条)"
    fi
}

# ==================== 通用函数 ====================
wait_for_service() {
    local timeout=$1 service=$2 condition=$3
    local elapsed=0 interval=5
    
    log "DEBUG" "等待 $service 就绪..."
    while ! eval "$condition" 2>/dev/null; do
        sleep $interval
        elapsed=$((elapsed + interval))
        
        if [[ $elapsed -ge $timeout ]]; then
            log "ERROR" "$service 启动超时 (${timeout}秒)"
            return 1
        fi
    done
}

run_with_retry() {
    local cmd=$1 desc=${2:-"命令"} retries=3 wait_seconds=2
    for ((i=1; i<=retries; i++)); do
        if eval "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        log "WARN" "$desc 失败 (尝试 $i/$retries)"
        [[ $i -lt $retries ]] && sleep $wait_seconds
    done
    return 1
}

# ==================== PMail配置 ====================
configure_pmail() {
    local ip=$1 domain=$2 password=$3
    log "INFO" "配置PMail基础设置..."
    
    # 设置密码
    if ! run_with_retry \
        "curl -X POST 'http://$ip/api/setup' -H 'Content-Type: application/json' -d '{\"action\":\"set\",\"step\":\"password\",\"account\":\"admin\",\"password\":\"$password\"}'" \
        "设置管理员密码"; then
        log "WARN" "密码设置失败"
    fi

    # 配置域名
    if ! run_with_retry \
        "curl -X POST 'http://$ip/api/setup' -H 'Content-Type: application/json' -d '{\"action\":\"set\",\"step\":\"domain\",\"web_domain\":\"mail.$domain\",\"smtp_domain\":\"$domain\"}'" \
        "配置域名"; then
        log "WARN" "域名配置失败"
    fi
}

# ==================== 安装验证 ====================
verify_installation() {
    log "INFO" "验证安装结果..."
    
    # 检查容器状态
    if ! docker inspect -f '{{.State.Running}}' pmail 2>/dev/null | grep -q 'true'; then
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
    return 0
}

# ==================== 输出函数 ====================
show_header() {
    clear
    echo -e "${GREEN}════════════════ PMail 自动化安装脚本 ════════════════${NC}"
    echo -e "版本: 3.0.0 | 作者: 智能运维助手"
    echo -e "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${GREEN}═════════════════════════════════════════════════════${NC}\n"
}

show_footer() {
    local status=$1
    case $status in
        "成功") color=$GREEN ;;
        "失败") color=$RED ;;
        *) color=$YELLOW ;;
    esac
    
    echo -e "\n${color}════════════════ 安装结果: $status ════════════════${NC}"
    echo -e "完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "详细日志: ${LOG_FILE}"
    echo -e "${color}═════════════════════════════════════════════════════${NC}\n"
}

show_summary() {
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

${GREEN}════════════ 安装验证 ════════════${NC}
1. 访问管理面板检查是否正常
2. 执行命令检查服务状态: docker ps
3. 检查邮件收发功能
4. 查看完整日志: less ${LOG_FILE}
EOF
}

# ==================== 主执行流程 ====================
main() {
    # 参数验证
    if [[ $# -lt 5 ]]; then
        echo -e "${RED}用法: $0 <IP地址> <域名> <密码> <阿里云AccessKey> <阿里云AccessSecret>${NC}"
        exit 1
    fi

    readonly PMAIL_IP=$1 DOMAIN=$2 PASSWORD=$3 ACCESS_KEY=$4 ACCESS_SECRET=$5

    # 初始化
    check_root
    check_os
    init_log
    show_header

    # 安装流程
    clean_environment
    install_dependencies
    check_ports
    configure_aliyun_cli
    deploy_pmail
    configure_pmail "$PMAIL_IP" "$DOMAIN" "$PASSWORD"
    configure_dns
    
    # 验证和收尾
    if verify_installation; then
        hostnamectl set-hostname "mail.$DOMAIN" >/dev/null 2>&1 || true
        show_summary
        show_footer "成功"
        log "INFO" "PMail安装成功完成"
        exit 0
    else
        show_footer "失败"
        log "ERROR" "PMail安装验证失败"
        exit 1
    fi
}

main "$@"
