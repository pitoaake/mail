#!/bin/bash

# 全局配置
set -euo pipefail
shopt -s inherit_errexit

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
NC='\033[0m'

# 依赖项版本
DOCKER_COMPOSE_VERSION="v2.24.7"
ALIYUN_CLI_VERSION="3.0.277"
JQ_VERSION="1.6"

# 参数校验
validate_parameters() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：必须使用root权限运行此脚本${NC}" >&2
        exit 1
    fi

    if [[ $# -lt 5 ]]; then
        echo -e "${RED}错误：缺少必要参数${NC}"
        echo "用法: install.sh <IP地址> <域名> <密码> <ACCESS_KEY> <ACCESS_SECRET>"
        exit 1
    fi

    PMAIL_IP=$1
    DOMAIN=$2
    PASSWORD=$3
    ACCESS_KEY=$4
    ACCESS_SECRET=$5
}

# 安装基础依赖
install_basic_deps() {
    echo -e "${BLUE}[1/10] 安装系统基本依赖...${NC}"
    
    local pkgs=("curl" "wget" "gnupg" "ca-certificates")
    if grep -qi "ubuntu" /etc/os-release; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" apt-transport-https
    elif grep -qi "centos" /etc/os-release; then
        yum install -y "${pkgs[@]}" yum-utils
    else
        echo -e "${YELLOW}⚠ 不支持的Linux发行版，尝试继续安装...${NC}"
    fi
}

# Docker安装（多源备用）
install_docker() {
    echo -e "${BLUE}[2/10] 安装Docker引擎...${NC}"
    
    if command -v docker &>/dev/null; then
        local docker_version
        docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
        echo -e "${GREEN}✔ Docker已安装 (版本: ${docker_version})${NC}"
        return 0
    fi

    # 多源安装Docker
    local docker_install_cmds=(
        "curl -fsSL https://get.docker.com | sh -"
        "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg"
        "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null"
    )

    for cmd in "${docker_install_cmds[@]}"; do
        if eval "$cmd"; then
            echo -e "${GREEN}✔ Docker安装步骤成功${NC}"
            break
        else
            echo -e "${YELLOW}⚠ 安装命令失败，尝试备用方案...${NC}"
            sleep 2
        done
    done

    # 启动服务
    systemctl enable --now docker
    docker run --rm hello-world &>/dev/null || {
        echo -e "${RED}✘ Docker安装验证失败${NC}"
        exit 1
    }
}

# Docker Compose安装（多源备用）
install_docker_compose() {
    echo -e "${BLUE}[3/10] 安装Docker Compose...${NC}"
    
    local compose_bin="/usr/local/bin/docker-compose"
    local mirror_urls=(
        "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
        "https://mirror.ghproxy.com/https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
        "https://download.fastgit.org/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
    )

    for url in "${mirror_urls[@]}"; do
        echo -e "${YELLOW}尝试从 ${url} 下载...${NC}"
        if curl -L "$url" -o "$compose_bin"; then
            chmod +x "$compose_bin"
            ln -sf "$compose_bin" /usr/bin/docker-compose
            break
        fi
    done

    docker-compose --version &>/dev/null || {
        echo -e "${RED}✘ Docker Compose安装失败${NC}"
        exit 1
    }
}

# 安装Aliyun CLI
install_aliyun_cli() {
    echo -e "${BLUE}[4/10] 安装Aliyun CLI...${NC}"
    
    if command -v aliyun &>/dev/null; then
        echo -e "${GREEN}✔ Aliyun CLI已安装${NC}"
        return 0
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    local mirror_urls=(
        "https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz"
        "https://mirrors.aliyun.com/aliyun-cli/aliyun-cli-linux-latest-amd64.tgz"
    )

    for url in "${mirror_urls[@]}"; do
        if curl -fsSL "$url" -o "$tmp_dir/aliyun-cli.tgz"; then
            tar xzf "$tmp_dir/aliyun-cli.tgz" -C "$tmp_dir"
            mv "$tmp_dir/aliyun" /usr/local/bin/
            chmod +x /usr/local/bin/aliyun
            break
        fi
    done

    aliyun --version &>/dev/null || {
        echo -e "${RED}✘ Aliyun CLI安装失败${NC}"
        exit 1
    }
}

# 安装jq
install_jq() {
    echo -e "${BLUE}[5/10] 安装jq工具...${NC}"
    
    if command -v jq &>/dev/null; then
        echo -e "${GREEN}✔ jq已安装${NC}"
        return 0
    fi

    if grep -qi "ubuntu" /etc/os-release; then
        apt-get install -y jq
    elif grep -qi "centos" /etc/os-release; then
        yum install -y jq
    else
        local tmp_dir
        tmp_dir=$(mktemp -d)
        curl -fsSL "https://github.com/stedolan/jq/releases/download/jq-${JQ_VERSION}/jq-linux64" -o "$tmp_dir/jq"
        chmod +x "$tmp_dir/jq"
        mv "$tmp_dir/jq" /usr/local/bin/
    fi

    jq --version &>/dev/null || {
        echo -e "${RED}✘ jq安装失败${NC}"
        exit 1
    }
}

# 配置PMail环境
setup_pmail() {
    echo -e "${BLUE}[6/10] 配置PMail环境...${NC}"
    
    mkdir -p ~/pmail/{config,ssl}
    cd ~/pmail

    cat > docker-compose.yml <<EOF
version: '3.9'
services:
  pmail:
    container_name: pmail
    image: ghcr.io/jinnrry/pmail:latest
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "25:25"
      - "465:465"
      - "80:80"
      - "443:443"
      - "995:995"
      - "993:993"
    restart: unless-stopped
    volumes:
      - ./config:/work/config
      - ./ssl:/work/ssl
EOF

    # 停止并删除旧容器
    docker-compose down || true
    docker ps -aq | xargs -r docker rm -f
}

# 启动PMail服务
start_pmail() {
    echo -e "${BLUE}[7/10] 启动PMail服务...${NC}"
    
    if ! docker-compose up -d; then
        echo -e "${RED}✘ PMail启动失败${NC}"
        docker-compose logs
        exit 1
    fi

    # 等待服务启动
    local timeout=60
    local interval=5
    local elapsed=0
    
    while ! curl -fsSL "http://${PMAIL_IP}" &>/dev/null; do
        sleep "$interval"
        elapsed=$((elapsed + interval))
        
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e "${RED}✘ PMail服务启动超时${NC}"
            docker-compose logs
            exit 1
        fi
    done
}

# 阿里云DNS解析配置（带频率控制）
configure_aliyun_dns() {
    echo -e "${BLUE}[8/10] 配置阿里云DNS解析...${NC}"
    
    # 配置阿里云CLI
    aliyun configure set \
        --profile PMailInstaller \
        --mode AK \
        --access-key-id "$ACCESS_KEY" \
        --access-key-secret "$ACCESS_SECRET" \
        --region cn-hangzhou > /dev/null 2>&1

    # 验证API连接
    if ! aliyun sts GetCallerIdentity > /dev/null 2>&1; then
        echo -e "${RED}✘ 阿里云API认证失败${NC}"
        return 1
    fi

    # 获取当前DNS记录
    local existing_records
    existing_records=$(aliyun alidns DescribeDomainRecords \
        --DomainName "$DOMAIN" \
        --PageSize 500)

    # 获取PMail需要的DNS配置
    local dns_config
    dns_config=$(curl -sS "http://${PMAIL_IP}/api/setup" \
        -H "Content-Type: application/json" \
        -d '{"action":"get","step":"dns"}')

    # 频率控制参数
    local -i max_retries=3
    local -i delay_seconds=2
    local -i rate_limit=5  # 每分钟最大请求数
    local -i last_request=0

    echo "$dns_config" | jq -r '
        .data | keys[] as $domain |
        .[$domain] | to_entries[] | 
        "\($domain) \(.value.host) \(.value.type) \(.value.value)"
    ' | while read -r domain host type value; do

        # 速率控制（每分钟不超过$rate_limit次请求）
        local -i now=$(date +%s)
        local -i elapsed=$((now - last_request))
        if (( elapsed < 60/rate_limit )); then
            sleep $((60/rate_limit - elapsed))
        fi

        # 检查记录是否已存在
        if echo "$existing_records" | jq -e \
            --arg h "$host" \
            --arg t "$type" \
            --arg v "$value" \
            '.DomainRecords.Record[] | select(.RR==$h and .Type==$t and .Value==$v)' > /dev/null; then
            echo -e "${GREEN}✔ 记录已存在: ${host}.${domain} ${type} ${value}${NC}"
            continue
        fi

        # 重试机制
        local -i attempt=0
        while (( attempt < max_retries )); do
            ((attempt++))
            
            # 删除可能存在的旧记录
            echo -e "${YELLOW}▶ 尝试 ${attempt}/${max_retries}: 更新 ${host}.${domain} ${type}...${NC}"
            aliyun alidns DeleteSubDomainRecords \
                --DomainName "$domain" \
                --RR "$host" \
                --Type "$type" > /dev/null 2>&1 || true

            # 添加新记录
            if aliyun alidns AddDomainRecord \
                --DomainName "$domain" \
                --RR "$host" \
                --Type "$type" \
                --Value "$value" \
                --TTL 600 > /dev/null 2>&1; then
                
                echo -e "${GREEN}✔ 成功设置: ${host}.${domain} ${type} ${value}${NC}"
                last_request=$(date +%s)
                break
            else
                sleep "$delay_seconds"
                delay_seconds=$((delay_seconds * 2)) # 指数退避
            fi
        done

        if (( attempt >= max_retries )); then
            echo -e "${RED}✘ 无法设置: ${host}.${domain} ${type} ${value}${NC}"
        fi
    done
}

# 配置PMail设置
configure_pmail() {
    echo -e "${BLUE}[9/10] 配置PMail设置...${NC}"
    
    local api_url="http://${PMAIL_IP}/api/setup"
    
    # 配置数据库
    curl -X POST "$api_url" \
        -H "Content-Type: application/json" \
        -d '{"action":"set","step":"database","db_type":"sqlite","db_dsn":"/work/./config/pmail.db"}' || true
    
    # 设置密码
    curl -X POST "$api_url" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"set\",\"step\":\"password\",\"account\":\"admin\",\"password\":\"${PASSWORD}\"}" || true
    
    # 配置域名
    curl -X POST "$api_url" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"set\",\"step\":\"domain\",\"web_domain\":\"mail.${DOMAIN}\",\"smtp_domain\":\"${DOMAIN}\",\"multi_domain\":\"\"}" || true
    
    # 配置DNS记录
    configure_aliyun_dns || {
        echo -e "${YELLOW}⚠ 阿里云DNS自动配置失败，请手动添加以下记录：${NC}"
        curl -sS "$api_url" \
            -H "Content-Type: application/json" \
            -d '{"action":"get","step":"dns"}' | jq
    }
    
    # 配置SSL
    curl -X POST "$api_url" \
        -H "Content-Type: application/json" \
        -d '{"action":"set","step":"ssl","ssl_type":"0","key_path":"./config/ssl/private.key","crt_path":"./config/ssl/public.crt"}' || true
}

# 设置主机名
set_hostname() {
    echo -e "${BLUE}[10/10] 设置主机名...${NC}"
    hostnamectl set-hostname "smtp.${DOMAIN}" || true
}

# 最终验证
final_validation() {
    echo -e "${BLUE}[11/10] 最终验证...${NC}"
    
    echo -e "${YELLOW}▶ 检查Docker容器状态:${NC}"
    docker ps -a
    
    echo -e "${YELLOW}▶ 检查服务端口:${NC}"
    netstat -tulnp | grep -E '25|80|443|465|993|995' || ss -tulnp | grep -E '25|80|443|465|993|995'
    
    echo -e "${YELLOW}▶ PMail登录信息:${NC}"
    echo -e "URL: http://${PMAIL_IP}"
    echo -e "用户名: admin"
    echo -e "密码: ${PASSWORD}"
    
    echo -e "${GREEN}✔ PMail安装完成!${NC}"
}

# 主执行流程
main() {
    validate_parameters "$@"
    install_basic_deps
    install_docker
    install_docker_compose
    install_aliyun_cli
    install_jq
    setup_pmail
    start_pmail
    configure_pmail
    set_hostname
    final_validation
}

main "$@"
