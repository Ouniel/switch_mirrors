#!/bin/bash
# Linux一键换源脚本 - 精简运维版
# 支持：Ubuntu/Kali/Arch/Parrot
# 功能：智能源测速｜网络诊断｜基础备份｜自动更新
# 最后更新：2025年6月

# 初始化设置
set -euo pipefail
shopt -s inherit_errexit

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志配置
LOG_FILE="/var/log/source_change_$(date +%Y%m%d).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# 镜像源池
declare -A MIRROR_POOL=(
    [aliyun]="http://mirrors.aliyun.com"
    [ustc]="http://mirrors.ustc.edu.cn"
    [tsinghua]="https://mirrors.tuna.tsinghua.edu.cn"
)

# 检查root权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误：请使用root权限运行此脚本！ (sudo $0)${NC}" >&2
    exit 1
fi

# 检测系统类型
detect_os() {
    if grep -qi "ubuntu" /etc/os-release; then
        echo "ubuntu"
    elif grep -qi "kali" /etc/os-release; then
        echo "kali"
    elif grep -qi "arch" /etc/os-release; then
        echo "arch"
    elif grep -qi "parrot" /etc/os-release; then
        echo "parrot"
    else
        echo "unsupported"
    fi
}

# 基础网络诊断
network_diagnosis() {
    echo -e "${BLUE}[网络诊断]${NC}"
    
    # 基础连通性测试
    local test_urls=(
        "mirrors.aliyun.com"
        "mirrors.ustc.edu.cn"
        "mirrors.tuna.tsinghua.edu.cn"
    )
    
    for url in "${test_urls[@]}"; do
        echo -n "测试 $url ... "
        if ping -c 2 -W 1 "$url" &>/dev/null; then
            echo -e "${GREEN}√ 可达${NC}"
        else
            echo -e "${RED}× 不可达${NC}"
        fi
    done
    
    # DNS解析检查
    echo -e "\nDNS解析测试："
    for url in "${test_urls[@]}"; do
        echo -n "$url: "
        if dig +short "$url" | grep -q '[0-9]'; then
            echo -e "${GREEN}解析成功${NC}"
        else
            echo -e "${RED}解析失败${NC}"
        fi
    done
    
    echo -e "${BLUE}[网络诊断完成]${NC}\n"
}

# 智能源测速
mirror_benchmark() {
    echo -e "${BLUE}[镜像源测速]${NC}"
    local fastest=""
    local min_latency=99999
    
    for mirror_name in "${!MIRROR_POOL[@]}"; do
        local base_url="${MIRROR_POOL[$mirror_name]}"
        local host=$(echo "$base_url" | awk -F/ '{print $3}')
        
        # 计算延迟
        local latency=99999
        if ping -c 2 -W 1 "$host" &>/dev/null; then
            latency=$(ping -c 4 -i 0.2 -W 1 "$host" | tail -1 | awk -F'/' '{print $5}')
        fi
        
        # 评估结果
        if (( $(echo "$latency < $min_latency" | bc -l) )); then
            min_latency=$latency
            fastest=$mirror_name
        fi
        
        # 打印结果
        if [ "$latency" != "99999" ]; then
            echo -e "$mirror_name: 延迟 ${YELLOW}${latency}ms${NC}"
        else
            echo -e "$mirror_name: ${RED}测试失败${NC}"
        fi
    done
    
    if [ -z "$fastest" ]; then
        echo -e "${RED}警告：无可用镜像源，使用默认清华源${NC}"
        SELECTED_SOURCE="tsinghua"
    else
        SELECTED_SOURCE=$fastest
        echo -e "\n${GREEN}最优镜像源：$fastest (延迟 ${min_latency}ms)${NC}"
    fi
}

# 备份原有源
backup_sources() {
    echo -e "${BLUE}[备份原有源]${NC}"
    local backup_dir="/etc/apt/sources_backup_$(date +%Y%m%d_%H%M%S)"
    
    case $OS_TYPE in
        ubuntu|kali|parrot)
            mkdir -p "$backup_dir"
            cp /etc/apt/sources.list "$backup_dir/"
            cp -r /etc/apt/sources.list.d/ "$backup_dir/" 2>/dev/null || true
            echo -e "APT源备份至 ${GREEN}$backup_dir${NC}"
            ;;
        arch)
            cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
            echo -e "Pacman镜像列表备份至 ${GREEN}/etc/pacman.d/mirrorlist.bak${NC}"
            ;;
    esac
}

# 设置国内源
set_mirrors() {
    echo -e "${BLUE}[设置新源]${NC}"
    local os_type=$1
    local source_key=$2
    
    case $os_type in
        ubuntu|parrot)
            local release_name=$(lsb_release -cs)
            case $source_key in
                aliyun)   base_url="http://mirrors.aliyun.com/ubuntu/" ;;
                ustc)     base_url="http://mirrors.ustc.edu.cn/ubuntu/" ;;
                tsinghua) base_url="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/" ;;
            esac
            
            cat > /etc/apt/sources.list <<EOF
deb ${base_url} ${release_name} main restricted universe multiverse
deb ${base_url} ${release_name}-updates main restricted universe multiverse
deb ${base_url} ${release_name}-backports main restricted universe multiverse
deb ${base_url} ${release_name}-security main restricted universe multiverse
EOF
            echo -e "设置为 ${GREEN}${base_url}${NC}"
            ;;

        kali)
            case $source_key in
                aliyun)   base_url="http://mirrors.aliyun.com/kali/" ;;
                ustc)     base_url="http://mirrors.ustc.edu.cn/kali/" ;;
                tsinghua) base_url="https://mirrors.tuna.tsinghua.edu.cn/kali/" ;;
            esac
            
            cat > /etc/apt/sources.list <<EOF
deb ${base_url} kali-rolling main contrib non-free
EOF
            echo -e "设置为 ${GREEN}${base_url}${NC}"
            ;;

        arch)
            # 使用reflector选择最快镜像
            if ! command -v reflector &>/dev/null; then
                echo -e "${YELLOW}安装reflector...${NC}"
                pacman -Sy --noconfirm reflector
            fi
            
            reflector \
                --country China \
                --protocol https \
                --latest 5 \
                --sort rate \
                --save /etc/pacman.d/mirrorlist
            
            echo -e "生成最优镜像列表："
            grep -E '^Server' /etc/pacman.d/mirrorlist | head -3
            ;;
    esac
}

# 更新验证
update_packages() {
    echo -e "${BLUE}[更新验证]${NC}"
    
    case $OS_TYPE in
        ubuntu|kali|parrot)
            apt-get update -y
            echo -e "\n${GREEN}可用更新列表：${NC}"
            apt list --upgradable 2>/dev/null
            ;;
        arch)
            pacman -Syy --noconfirm
            echo -e "\n${GREEN}可用更新列表：${NC}"
            pacman -Qu
            ;;
    esac
    
    echo -e "\n${GREEN}更新验证完成，请手动执行升级命令${NC}"
    case $OS_TYPE in
        ubuntu|kali|parrot) echo "sudo apt-get upgrade" ;;
        arch) echo "sudo pacman -Syu" ;;
    esac
}

# 主流程
main() {
    echo -e "${GREEN}===== Linux一键换源工具 =====${NC}"
    
    # 检测系统
    OS_TYPE=$(detect_os)
    if [ "$OS_TYPE" = "unsupported" ]; then
        echo -e "${RED}错误：不支持此操作系统！${NC}" >&2
        exit 1
    fi
    echo -e "检测到系统: ${BLUE}$OS_TYPE${NC}\n"
    
    # 网络诊断
    network_diagnosis
    
    # 智能选源
    mirror_benchmark
    
    # 用户确认
    read -rp "是否应用变更到$SELECTED_SOURCE源？ [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        exit 0
    fi
    
    # 备份原有源
    backup_sources
    
    # 设置新源
    set_mirrors "$OS_TYPE" "$SELECTED_SOURCE"
    
    # 更新验证
    update_packages
    
    echo -e "\n${GREEN}===== 操作成功完成 =====${NC}"
    echo -e "查看完整日志: ${YELLOW}$LOG_FILE${NC}"
}

main