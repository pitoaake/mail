#!/bin/bash

# ==================== 初始化配置 ====================
set -euo pipefail
shopt -s inherit_errexit

# 颜色定义
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[36m'; NC='\033[0m'

# 阿里云API配置
ALIYUN_PROFILE="PMailInstaller"
ALIYUN_REGION="cn-hangzhou"
ALIYUN_API_DELAY=1  # 每次API调用间隔1秒
MAX_DNS_RETRIES=5    # 最大重试次数
BASE_RETRY_DELAY=2   # 基础重试延迟(秒)

# ==================== 参数验证 ====================
validate_parameters() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用root权限运行${NC}" >&2 && exit 1
    [[ $# -lt 5 ]] && {
        echo -e "${RED}错误：缺少必要参数${NC}"
        echo "用法: $0 <IP地址> <域名> <密码> <ACCESS_KEY> <ACCESS_SECRET>"
        exit 1
    }

    PMAIL_IP=$1
    DOMAIN=$2
    PASSWORD=$3
    ACCESS_KEY=$4
    ACCESS_SECRET=$5
}

# ==================== 速率控制 ====================
rate_limit() {
    local now last elapsed sleep_time
    now=$(date +%s)
    last=${last_api_call_time:-0}
    elapsed=$((now - last))
    
    if [[ $elapsed -lt $ALIYUN_API_DELAY ]]; then
        sleep_time=$((ALIYUN_API_DELAY - elapsed))
        echo -e "${YELLOW}[速率控制] 等待${sleep_time}秒...${NC}" >&2
        sleep $sleep_time
    fi
    last_api_call_time=$(date +%s)
}

# ==================== 阿里云DNS操作 ====================
aliyun_dns_wrapper() {
    local cmd="$1" attempt=1 last_exit
    local retry_delay=$BASE_RETRY_DELAY
    
    until [[ $attempt -gt $MAX_DNS_RETRIES ]]; do
        rate_limit
        echo -e "${BLUE}[尝试 $attempt/$MAX_DNS_RETRIES] 执行: ${cmd:0:60}...${NC}" >&2
        
        if eval "$cmd"; then
            return 0
        else
            last_exit=$?
            case $last_exit in
                94)  # Throttling.User
                    echo -e "${YELLOW}⚠ 阿里云API限流，${retry_delay}秒后重试...${NC}" >&2
                    ;;
                95)  # InvalidDomainName.NoExist
                    echo -e "${RED}✖ 域名不存在，无法继续${NC}" >&2
                    return $last_exit
                    ;;
                96)  # InvalidRR.AlreadyExist
                    echo -e "${YELLOW}⚠ 记录已存在，跳过${NC}" >&2
                    return 0
                    ;;
                *)
                    echo -e "${YELLOW}⚠ 未知错误[CODE:$last_exit]，${retry_delay}秒后重试...${NC}" >&2
                    ;;
            esac
            
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))  # 指数退避
            ((attempt++))
        fi
    done
    
    echo -e "${RED}✖ 达到最大重试次数${NC}" >&2
    return $last_exit
}

# ==================== DNS记录验证 ====================
verify_dns_records() {
    local domain=$1
    local expected_records=8  # 预期最少记录数
    local required_types=("A" "MX" "TXT" "CNAME")
    
    echo -e "\n${BLUE}验证DNS记录配置...${NC}"
    local actual_records=$(aliyun alidns DescribeDomainRecords \
        --DomainName "$domain" \
        --profile $ALIYUN_PROFILE \
        --region $ALIYUN_REGION | jq '.DomainRecords.Record | length')
    
    if [[ $actual_records -ge $expected_records ]]; then
        echo -e "${GREEN}✔ 找到$actual_records条DNS记录(预期≥$expected_records)${NC}"
    else
        echo -e "${RED}✖ 只找到$actual_records条DNS记录(预期$expected_records条)${NC}"
        return 1
    fi
    
    for type in "${required_types[@]}"; do
        if aliyun alidns DescribeDomainRecords \
            --DomainName "$domain" \
            --TypeKeyWord "$type" \
            --profile $ALIYUN_PROFILE \
            --region $ALIYUN_REGION | jq -e '.DomainRecords.Record | length > 0' >/dev/null; then
            echo -e "${GREEN}✔ 存在$type记录${NC}"
        else
            echo -e "${RED}✖ 缺少必需的$type记录${NC}"
            return 1
        fi
    done
}

# ==================== 安装依赖 ====================
install_dependencies() {
    echo -e "${BLUE}[1/8] 安装系统依赖...${NC}"
    local pkgs=("curl" "wget" "jq" "docker.io" "docker-compose")
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    
    echo -e "${BLUE}[2/8] 配置阿里云CLI...${NC}"
    if ! command -v aliyun &>/dev/null; then
        curl -fsSL "https://aliyuncli.alicdn.com/aliyun-cli-latest-linux-amd64.tgz" | \
            tar xz -C /usr/local/bin && chmod +x /usr/local/bin/aliyun
    fi
    
    aliyun configure set \
        --profile $ALIYUN_PROFILE \
        --mode AK \
        --access-key-id "$ACCESS_KEY" \
        --access-key-secret "$ACCESS_SECRET" \
        --region $ALIYUN_REGION > /dev/null
}

# ==================== PMail配置 ====================
setup_pmail() {
    echo -e "${BLUE}[3/8] 初始化PMail环境...${NC}"
    mkdir -p ~/pmail/{config,ssl} && cd ~/pmail

    cat > docker-compose.yml <<EOF
version: '3.9'
services:
  pmail:
    image: ghcr.io/jinnrry/pmail:latest
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

    docker-compose down || true
    docker-compose up -d
    
    # 等待服务启动
    local timeout=60
    while ! curl -fsSL "http://$PMAIL_IP" &>/dev/null && [[ $timeout -gt 0 ]]; do
        sleep 5
        ((timeout-=5))
    done
    [[ $timeout -le 0 ]] && {
        echo -e "${RED}✖ PMail启动超时${NC}"
        docker-compose logs
        exit 1
    }
}

# ==================== DNS配置 ====================
configure_dns() {
    echo -e "${BLUE}[4/8] 获取DNS配置...${NC}"
    local api_url="http://$PMAIL_IP/api/setup"
    local dns_config=$(curl -sS "$api_url" \
        -H "Content-Type: application/json" \
        -d '{"action":"get","step":"dns"}')
    
    echo -e "${BLUE}[5/8] 处理DNS记录...${NC}"
    echo "$dns_config" | jq -r '
        .data | to_entries[] | 
        "\(.key) \(.value | to_entries[] | .value.host) \(.value | to_entries[] | .value.type) \(.value | to_entries[] | .value.value)"
    ' | while read -r domain host type value; do
        local priority=5
        [[ "$type" == "MX" ]] && priority=10
        
        aliyun_dns_wrapper "
            aliyun alidns DeleteSubDomainRecords \
                --DomainName \"$domain\" \
                --RR \"$host\" \
                --Type \"$type\" \
                --profile $ALIYUN_PROFILE \
                --region $ALIYUN_REGION
        " && \
        aliyun_dns_wrapper "
            aliyun alidns AddDomainRecord \
                --DomainName \"$domain\" \
                --RR \"$host\" \
                --Type \"$type\" \
                --Value \"$value\" \
                --TTL 600 \
                --Priority $priority \
                --profile $ALIYUN_PROFILE \
                --region $ALIYUN_REGION
        " || {
            echo -e "${RED}✖ 记录设置失败: $host.$domain $type${NC}"
            continue
        }
    done
    
    verify_dns_records "$DOMAIN" || {
        echo -e "${YELLOW}⚠ 部分DNS记录验证失败，请手动检查${NC}"
    }
    
    echo -e "${YELLOW}⏳ 等待DNS传播(60秒)...${NC}"
    sleep 60
}

# ==================== 最终配置 ====================
final_config() {
    echo -e "${BLUE}[6/8] 配置SSL证书...${NC}"
    curl -X POST "http://$PMAIL_IP/api/setup" \
        -H "Content-Type: application/json" \
        -d '{"action":"set","step":"ssl","ssl_type":"0"}' > /dev/null
    
    echo -e "${BLUE}[7/8] 设置主机名...${NC}"
    hostnamectl set-hostname "mail.$DOMAIN"
    
    echo -e "${BLUE}[8/8] 验证服务状态...${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    ss -tulnp | grep -E '25|80|443|465|993|995' || \
        netstat -tulnp | grep -E '25|80|443|465|993|995'
}

# ==================== 主流程 ====================
main() {
    validate_parameters "$@"
    install_dependencies
    setup_pmail
    
    # 关键顺序：先配置基础信息再处理DNS
    echo -e "${BLUE}[4/8] 配置PMail基础信息...${NC}"
    curl -X POST "http://$PMAIL_IP/api/setup" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"set\",\"step\":\"password\",\"account\":\"admin\",\"password\":\"$PASSWORD\"}" > /dev/null
    
    curl -X POST "http://$PMAIL_IP/api/setup" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"set\",\"step\":\"domain\",\"web_domain\":\"mail.$DOMAIN\",\"smtp_domain\":\"$DOMAIN\"}" > /dev/null
    
    configure_dns
    final_config
    
    echo -e "\n${GREEN}✔ 安装完成！${NC}"
    echo -e "访问地址: ${BLUE}http://$PMAIL_IP${NC}"
    echo -e "管理员账号: ${YELLOW}admin${NC}"
    echo -e "管理员密码: ${YELLOW}$PASSWORD${NC}"
}

main "$@"
