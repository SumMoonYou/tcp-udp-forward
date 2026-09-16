#!/bin/bash
# ============================================================
# TCP / UDP 通用端口转发管理器
# ============================================================
#
# 文件名建议：
#   tcp-udp-forward.sh
#
# 用途：
#   在服务器 A 上使用 iptables 将指定端口转发到服务器 B。
#
# 支持协议：
#   TCP
#   UDP
#   TCP + UDP
#
# 目标地址支持：
#   IPv4
#   域名
#
# 主要功能：
#   1. 自动检测并安装系统依赖
#   2. 添加 TCP / UDP 转发规则
#   3. 修改已有转发规则
#   4. 删除转发规则
#   5. 支持多条转发规则
#   6. 域名自动解析 IPv4
#   7. Cron 自动定时检查域名 IP
#   8. IP 发生变化时重新建立转发
#   9. 自动开启 IPv4 转发
#  10. 查看当前规则和运行状态
#  11. 查看运行日志
#  12. 一键卸载
#
# 支持系统：
#   Debian
#   Ubuntu
#   Linux Mint
#   CentOS
#   RHEL
#   Rocky Linux
#   AlmaLinux
#   Fedora
#
# 注意：
#   本脚本当前针对 IPv4 转发。
#   IPv6 不在本版本处理范围内。
#
# ============================================================


# ============================================================
# Bash 基础设置
# ============================================================

# -u：
#   使用未定义变量时产生错误。
#
# 注意：
#   这里没有开启 set -e。
#   因为 iptables 某些删除操作即使规则不存在也不应该
#   让整个脚本立即退出。
#
set -u


# ============================================================
# 基础配置
# ============================================================

# ------------------------------------------------------------
# 管理程序安装目录
# ------------------------------------------------------------
#
# 安装完成后，会把当前脚本复制到这里。
#
INSTALL_DIR="/usr/local/sbin"

# 实际安装后的程序名称
SCRIPT_NAME="tcp-udp-forward"

# 完整安装路径
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"


# ------------------------------------------------------------
# 配置目录
# ------------------------------------------------------------

# 所有本程序配置统一放在这里
CONFIG_DIR="/etc/tcp-udp-forward"

# 转发规则配置文件
#
# 每行格式：
#
# ID|协议|目标地址|目标端口|本地端口
#
# 例如：
#
# 1|TCP|example.com|443|8443
# 2|UDP|1.2.3.4|5000|5000
#
CONFIG_FILE="$CONFIG_DIR/rules.conf"


# ------------------------------------------------------------
# 检测间隔配置
# ------------------------------------------------------------

# 保存 Cron 检测间隔
INTERVAL_FILE="$CONFIG_DIR/interval"

# 默认每 5 分钟检测一次
DEFAULT_INTERVAL=5


# ------------------------------------------------------------
# 日志文件
# ------------------------------------------------------------

# 本程序运行日志
LOG_FILE="/var/log/tcp-udp-forward.log"


# ------------------------------------------------------------
# Cron 配置文件
# ------------------------------------------------------------

# 使用 /etc/cron.d/
# 而不是修改 root 用户自己的 crontab。
#
# 这样：
#   1. 更容易管理
#   2. 卸载时直接删除一个文件即可
#   3. 不会影响用户原来的 crontab
#
CRON_FILE="/etc/cron.d/tcp-udp-forward"


# ------------------------------------------------------------
# iptables 规则标识
# ------------------------------------------------------------
#
# 所有由本程序创建的 iptables 规则都会带：
#
#   TUFWD-1
#   TUFWD-2
#   TUFWD-3
#
# 这样卸载或者更新时，只删除本程序自己的规则，
# 不影响服务器上其他 iptables 配置。
#
COMMENT_PREFIX="TUFWD"


# ------------------------------------------------------------
# iptables 命令路径
# ------------------------------------------------------------
#
# 程序启动时自动检测。
#
IPTABLES=""


# ============================================================
# 终端颜色
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'


# ============================================================
# 输出函数
# ============================================================

# 普通信息
info() {
    echo -e "${GREEN}[信息]${NC} $*"
}


# 警告信息
warn() {
    echo -e "${YELLOW}[警告]${NC} $*"
}


# 错误信息
error() {
    echo -e "${RED}[错误]${NC} $*"
}


# 标题
title() {
    echo -e "${CYAN}$*${NC}"
}


# ============================================================
# 写入日志
# ============================================================

log() {

    # 确保日志目录存在
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

    # 写入当前时间和日志内容
    echo "$(date '+%F %T') $*" >> "$LOG_FILE" 2>/dev/null || true
}


# ============================================================
# Root 权限检查
# ============================================================
#
# iptables、sysctl、/etc/cron.d、/etc 等操作都需要 root。
#
check_root() {

    if [ "$(id -u)" != "0" ]; then

        error "请使用 root 用户运行此程序。"

        echo
        echo "例如："
        echo "  sudo $0"
        echo

        exit 1
    fi
}


# ============================================================
# 初始化配置目录
# ============================================================

init_dirs() {

    # 创建配置目录
    mkdir -p "$CONFIG_DIR"

    # 如果配置文件不存在则创建
    touch "$CONFIG_FILE" 2>/dev/null || true

    # 创建日志文件
    touch "$LOG_FILE" 2>/dev/null || true

    # 配置目录只允许 root 使用
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true

    # 配置文件只允许 root 读取
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}


# ============================================================
# 检测操作系统
# ============================================================

detect_os() {

    # Linux 系统通常都有这个文件
    if [ ! -f /etc/os-release ]; then

        error "无法识别当前操作系统。"

        exit 1
    fi


    # 读取系统信息
    . /etc/os-release


    # 获取系统 ID
    OS_ID="${ID:-unknown}"

    # 获取系统完整名称
    OS_NAME="${PRETTY_NAME:-$OS_ID}"


    # --------------------------------------------------------
    # 根据系统选择软件包管理器
    # --------------------------------------------------------

    case "$OS_ID" in

        # Debian 系
        debian|ubuntu|linuxmint)

            PKG_MANAGER="apt"

            ;;


        # RedHat 系
        centos|rhel|rocky|almalinux|fedora)

            if command -v dnf >/dev/null 2>&1; then

                PKG_MANAGER="dnf"

            else

                PKG_MANAGER="yum"

            fi

            ;;


        # 无法准确识别时，根据系统已有命令判断
        *)

            if command -v apt-get >/dev/null 2>&1; then

                PKG_MANAGER="apt"

            elif command -v dnf >/dev/null 2>&1; then

                PKG_MANAGER="dnf"

            elif command -v yum >/dev/null 2>&1; then

                PKG_MANAGER="yum"

            else

                error "无法找到 apt / dnf / yum 软件包管理器。"

                exit 1

            fi

            ;;

    esac
}


# ============================================================
# 安装软件包
# ============================================================

install_package() {

    # 要安装的软件包名称
    PACKAGE="$1"


    info "正在安装软件包：$PACKAGE"


    case "$PKG_MANAGER" in

        # ----------------------------------------------------
        # Debian / Ubuntu
        # ----------------------------------------------------

        apt)

            # 防止 apt 安装过程中出现交互式询问
            export DEBIAN_FRONTEND=noninteractive


            # 更新软件源
            apt-get update -y


            # 安装软件
            apt-get install -y "$PACKAGE"

            ;;


        # ----------------------------------------------------
        # Fedora / Rocky / Alma / 新版 RHEL
        # ----------------------------------------------------

        dnf)

            dnf install -y "$PACKAGE"

            ;;


        # ----------------------------------------------------
        # CentOS / 老版本 RHEL
        # ----------------------------------------------------

        yum)

            yum install -y "$PACKAGE"

            ;;


        *)

            error "未知软件包管理器：$PKG_MANAGER"

            return 1

            ;;

    esac
}


# ============================================================
# 检测并自动安装 dig
# ============================================================
#
# 域名转发时需要使用 dig 查询目标域名的 IPv4 地址。
#
# Debian / Ubuntu：
#   dnsutils
#
# CentOS / RHEL：
#   bind-utils
#
ensure_dig() {

    # 已经存在就直接使用
    if command -v dig >/dev/null 2>&1; then

        return 0
    fi


    warn "系统没有安装 dig，正在自动安装..."


    # Debian 系
    if [ "$PKG_MANAGER" = "apt" ]; then

        install_package "dnsutils"

    # RedHat 系
    else

        install_package "bind-utils"

    fi


    # 再次检查安装结果
    if command -v dig >/dev/null 2>&1; then

        info "dig 安装成功。"

        return 0

    fi


    error "dig 安装失败。"

    return 1
}


# ============================================================
# 检测并自动安装 iptables
# ============================================================

ensure_iptables() {

    # iptables 已存在
    if command -v iptables >/dev/null 2>&1; then

        IPTABLES="$(command -v iptables)"

        return 0
    fi


    # 不存在时自动安装
    warn "系统没有安装 iptables，正在自动安装..."


    install_package "iptables"


    # 安装完成后重新检测
    if command -v iptables >/dev/null 2>&1; then

        IPTABLES="$(command -v iptables)"

        info "iptables 安装成功。"

        return 0

    fi


    error "iptables 安装失败。"

    return 1
}


# ============================================================
# 检测并自动安装 Cron
# ============================================================

ensure_cron() {

    # 如果已经有 crontab 命令，说明 Cron 基本已经存在
    if command -v crontab >/dev/null 2>&1; then

        return 0
    fi


    warn "系统没有安装 Cron，正在自动安装..."


    # Debian / Ubuntu
    if [ "$PKG_MANAGER" = "apt" ]; then

        install_package "cron"

    # RedHat 系
    else

        install_package "cronie"

    fi


    # 再次检测
    if command -v crontab >/dev/null 2>&1; then

        info "Cron 安装成功。"

        return 0

    fi


    error "Cron 安装失败。"

    return 1
}


# ============================================================
# 统一依赖检查
# ============================================================
#
# 所有真正需要网络转发的操作，都通过这里检查。
#
# 这样可以避免出现：
#
#   [错误] iptables 未安装
#
# 而脚本却没有自动安装的问题。
#
ensure_dependencies() {

    # 检测系统
    detect_os


    # 检测 dig
    if ! ensure_dig; then

        return 1
    fi


    # 检测 iptables
    if ! ensure_iptables; then

        return 1
    fi


    # 检测 Cron
    if ! ensure_cron; then

        return 1
    fi


    # 如果前面没有设置，则再次获取
    if [ -z "$IPTABLES" ]; then

        IPTABLES="$(command -v iptables)"
    fi


    return 0
}


# ============================================================
# 启动 Cron 服务
# ============================================================
#
# 不同 Linux 发行版的服务名称可能不同：
#
# Debian：
#   cron
#
# CentOS / Rocky：
#   crond
#
start_cron_service() {

    # systemd 系统
    if command -v systemctl >/dev/null 2>&1; then

        # Debian
        systemctl enable cron >/dev/null 2>&1 || true

        # RHEL
        systemctl enable crond >/dev/null 2>&1 || true

        # 启动服务
        systemctl start cron >/dev/null 2>&1 || true
        systemctl start crond >/dev/null 2>&1 || true

    fi
}


# ============================================================
# 开启 IPv4 转发
# ============================================================
#
# DNAT 转发必须开启：
#
#   net.ipv4.ip_forward = 1
#
# 否则 Linux 内核不会进行 IP 转发。
#
enable_ipv4_forward() {

    # 某些特殊环境可能没有该文件
    if [ ! -f /proc/sys/net/ipv4/ip_forward ]; then

        return 0
    fi


    # 获取当前状态
    CURRENT=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)


    # 如果没有开启
    if [ "$CURRENT" != "1" ]; then

        # 临时立即开启
        echo 1 > /proc/sys/net/ipv4/ip_forward

        info "IPv4 转发已开启。"

    fi


    # --------------------------------------------------------
    # 写入永久配置
    # --------------------------------------------------------

    mkdir -p /etc/sysctl.d


    cat > /etc/sysctl.d/99-tcp-udp-forward.conf <<EOF
# TCP / UDP Forward Manager
# 开启 Linux IPv4 数据包转发
net.ipv4.ip_forward = 1
EOF


    # 立即加载
    sysctl -p /etc/sysctl.d/99-tcp-udp-forward.conf \
        >/dev/null 2>&1 || true
}


# ============================================================
# 检查端口是否合法
# ============================================================

valid_port() {

    PORT="$1"


    # 必须全部是数字
    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then

        return 1
    fi


    # TCP / UDP 端口范围
    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then

        return 1
    fi


    return 0
}


# ============================================================
# 检查目标地址是否合法
# ============================================================
#
# 支持：
#
#   1.2.3.4
#
# 或：
#
#   example.com
#
valid_target() {

    TARGET="$1"


    # 不允许为空
    [ -n "$TARGET" ] || return 1


    # --------------------------------------------------------
    # IPv4
    # --------------------------------------------------------

    if [[ "$TARGET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

        return 0
    fi


    # --------------------------------------------------------
    # 域名
    # --------------------------------------------------------

    if [[ "$TARGET" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then

        return 0
    fi


    return 1
}


# ============================================================
# 获取下一个规则 ID
# ============================================================
#
# 例如当前：
#
#   1
#   2
#   5
#
# 下一个 ID：
#
#   6
#
get_next_id() {

    # 没有任何规则
    if [ ! -s "$CONFIG_FILE" ]; then

        echo 1

        return
    fi


    # 找出最大的 ID
    MAX_ID=$(awk -F'|' '
        $1 ~ /^[0-9]+$/ {

            if ($1 > max)
                max=$1
        }

        END {
            print max+0
        }
    ' "$CONFIG_FILE")


    # 最大 ID + 1
    echo $((MAX_ID + 1))
}


# ============================================================
# 获取指定 ID 的规则
# ============================================================

get_rule() {

    ID="$1"


    # 配置格式：
    #
    # ID|PROTOCOL|TARGET|REMOTE_PORT|LOCAL_PORT
    #
    grep "^${ID}|" "$CONFIG_FILE" | head -n1
}


# ============================================================
# 解析目标地址
# ============================================================
#
# 如果输入：
#
#   1.2.3.4
#
# 直接返回。
#
# 如果输入：
#
#   example.com
#
# 使用 dig 查询 A 记录。
#
resolve_target() {

    TARGET="$1"


    # --------------------------------------------------------
    # IPv4
    # --------------------------------------------------------

    if [[ "$TARGET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

        echo "$TARGET"

        return 0
    fi


    # --------------------------------------------------------
    # 域名解析 IPv4
    # --------------------------------------------------------

    IP=$(
        dig +short "$TARGET" A 2>/dev/null |
        grep -E \
        '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
        head -n1
    )


    # 没有解析结果
    if [ -z "$IP" ]; then

        return 1
    fi


    echo "$IP"

    return 0
}


# ============================================================
# 删除指定 ID 的 iptables 规则
# ============================================================
#
# 只删除：
#
#   TUFWD-ID
#
# 对应的规则。
#
# 不会删除服务器其他 iptables 规则。
#
remove_rule_iptables() {

    ID="$1"


    # 如果还没有找到 iptables，则尝试寻找
    if [ -z "$IPTABLES" ]; then

        IPTABLES="$(command -v iptables 2>/dev/null || true)"
    fi


    # 系统确实没有 iptables
    if [ -z "$IPTABLES" ]; then

        return 0
    fi


    # --------------------------------------------------------
    # 删除 nat PREROUTING
    # --------------------------------------------------------

    "$IPTABLES" -t nat -S PREROUTING 2>/dev/null |
    grep -- "--comment ${COMMENT_PREFIX}-${ID}" |
    while read -r RULE
    do

        # -A 转换成 -D
        RULE="${RULE#-A }"


        # 删除规则
        "$IPTABLES" -t nat -D $RULE \
            >/dev/null 2>&1 || true

    done


    # --------------------------------------------------------
    # 删除 nat POSTROUTING
    # --------------------------------------------------------

    "$IPTABLES" -t nat -S POSTROUTING 2>/dev/null |
    grep -- "--comment ${COMMENT_PREFIX}-${ID}" |
    while read -r RULE
    do

        RULE="${RULE#-A }"


        "$IPTABLES" -t nat -D $RULE \
            >/dev/null 2>&1 || true

    done


    # --------------------------------------------------------
    # 删除 FORWARD
    # --------------------------------------------------------

    "$IPTABLES" -S FORWARD 2>/dev/null |
    grep -- "--comment ${COMMENT_PREFIX}-${ID}" |
    while read -r RULE
    do

        RULE="${RULE#-A }"


        "$IPTABLES" -D $RULE \
            >/dev/null 2>&1 || true

    done


    # --------------------------------------------------------
    # 删除 RETURN 规则
    # --------------------------------------------------------

    "$IPTABLES" -S FORWARD 2>/dev/null |
    grep -- "--comment ${COMMENT_PREFIX}-${ID}-RETURN" |
    while read -r RULE
    do

        RULE="${RULE#-A }"


        "$IPTABLES" -D $RULE \
            >/dev/null 2>&1 || true

    done
}


# ============================================================
# 删除本程序创建的全部 iptables 规则
# ============================================================
#
# 重要：
#
# 这里只搜索：
#
#   TUFWD-
#
# 所以不会清理其他软件创建的规则。
#
remove_all_iptables() {

    # 获取 iptables 路径
    if [ -z "$IPTABLES" ]; then

        IPTABLES="$(command -v iptables 2>/dev/null || true)"
    fi


    # 没有 iptables 就不用处理
    if [ -z "$IPTABLES" ]; then

        return 0
    fi


    # --------------------------------------------------------
    # PREROUTING
    # --------------------------------------------------------

    "$IPTABLES" -t nat -S PREROUTING 2>/dev/null |
    grep "$COMMENT_PREFIX-" |
    while read -r RULE
    do

        RULE="${RULE#-A }"


        "$IPTABLES" -t nat -D $RULE \
            >/dev/null 2>&1 || true

    done


    # --------------------------------------------------------
    # POSTROUTING
    # --------------------------------------------------------

    "$IPTABLES" -t nat -S POSTROUTING 2>/dev/null |
    grep "$COMMENT_PREFIX-" |
    while read -r RULE
    do

        RULE="${RULE#-A }"


        "$IPTABLES" -t nat -D $RULE \
            >/dev/null 2>&1 || true

    done


    # --------------------------------------------------------
    # FORWARD
    # --------------------------------------------------------

    "$IPTABLES" -S FORWARD 2>/dev/null |
    grep "$COMMENT_PREFIX-" |
    while read -r RULE
    do

        RULE="${RULE#-A }"


        "$IPTABLES" -D $RULE \
            >/dev/null 2>&1 || true

    done
}


# ============================================================
# 创建 TCP 转发规则
# ============================================================
#
# 以：
#
#   本机 8443
#       ↓
#   目标服务器 443
#
# 为例。
#
# PREROUTING：
#   收到本机 8443 的 TCP 数据包后，
#   修改目标地址为目标服务器:443。
#
# POSTROUTING：
#   对转发流量进行 MASQUERADE，
#   确保返回数据能够正确回到当前服务器。
#
# FORWARD：
#   允许该 TCP 流量通过。
#
add_tcp_rules() {

    ID="$1"
    TARGET_IP="$2"
    REMOTE_PORT="$3"
    LOCAL_PORT="$4"


    # --------------------------------------------------------
    # TCP DNAT
    # --------------------------------------------------------

    "$IPTABLES" -t nat -A PREROUTING \
        -p tcp \
        --dport "$LOCAL_PORT" \
        -j DNAT \
        --to-destination "$TARGET_IP:$REMOTE_PORT" \
        -m comment \
        --comment "${COMMENT_PREFIX}-${ID}"


    # --------------------------------------------------------
    # TCP MASQUERADE
    # --------------------------------------------------------

    "$IPTABLES" -t nat -A POSTROUTING \
        -p tcp \
        -d "$TARGET_IP" \
        --dport "$REMOTE_PORT" \
        -j MASQUERADE \
        -m comment \
        --comment "${COMMENT_PREFIX}-${ID}"


    # --------------------------------------------------------
    # TCP FORWARD
    # --------------------------------------------------------

    "$IPTABLES" -A FORWARD \
        -p tcp \
        -d "$TARGET_IP" \
        --dport "$REMOTE_PORT" \
        -j ACCEPT \
        -m comment \
        --comment "${COMMENT_PREFIX}-${ID}"
}


# ============================================================
# 创建 UDP 转发规则
# ============================================================

add_udp_rules() {

    ID="$1"
    TARGET_IP="$2"
    REMOTE_PORT="$3"
    LOCAL_PORT="$4"


    # --------------------------------------------------------
    # UDP DNAT
    # --------------------------------------------------------

    "$IPTABLES" -t nat -A PREROUTING \
        -p udp \
        --dport "$LOCAL_PORT" \
        -j DNAT \
        --to-destination "$TARGET_IP:$REMOTE_PORT" \
        -m comment \
        --comment "${COMMENT_PREFIX}-${ID}"


    # --------------------------------------------------------
    # UDP MASQUERADE
    # --------------------------------------------------------

    "$IPTABLES" -t nat -A POSTROUTING \
        -p udp \
        -d "$TARGET_IP" \
        --dport "$REMOTE_PORT" \
        -j MASQUERADE \
        -m comment \
        --comment "${COMMENT_PREFIX}-${ID}"


    # --------------------------------------------------------
    # UDP FORWARD
    # --------------------------------------------------------

    "$IPTABLES" -A FORWARD \
        -p udp \
        -d "$TARGET_IP" \
        --dport "$REMOTE_PORT" \
        -j ACCEPT \
        -m comment \
        --comment "${COMMENT_PREFIX}-${ID}"
}


# ============================================================
# 创建返回流量规则
# ============================================================
#
# 允许已经建立的连接以及相关连接返回。
#
# TCP：
#   TCP 三次握手以及后续连接需要。
#
# UDP：
#   Linux conntrack 会跟踪 UDP 流量。
#
add_return_rule() {

    ID="$1"


    "$IPTABLES" -A FORWARD \
        -m conntrack \
        --ctstate ESTABLISHED,RELATED \
        -j ACCEPT \
        -m comment \
        --comment "${COMMENT_PREFIX}-${ID}-RETURN"
}


# ============================================================
# 根据协议创建完整规则
# ============================================================

apply_rule() {

    ID="$1"
    PROTOCOL="$2"
    TARGET_IP="$3"
    REMOTE_PORT="$4"
    LOCAL_PORT="$5"


    case "$PROTOCOL" in

        # ----------------------------------------------------
        # TCP
        # ----------------------------------------------------

        TCP)

            add_tcp_rules \
                "$ID" \
                "$TARGET_IP" \
                "$REMOTE_PORT" \
                "$LOCAL_PORT"

            ;;


        # ----------------------------------------------------
        # UDP
        # ----------------------------------------------------

        UDP)

            add_udp_rules \
                "$ID" \
                "$TARGET_IP" \
                "$REMOTE_PORT" \
                "$LOCAL_PORT"

            ;;


        # ----------------------------------------------------
        # TCP + UDP
        # ----------------------------------------------------

        BOTH)

            add_tcp_rules \
                "$ID" \
                "$TARGET_IP" \
                "$REMOTE_PORT" \
                "$LOCAL_PORT"


            add_udp_rules \
                "$ID" \
                "$TARGET_IP" \
                "$REMOTE_PORT" \
                "$LOCAL_PORT"

            ;;


        # ----------------------------------------------------
        # 未知协议
        # ----------------------------------------------------

        *)

            error "未知协议：$PROTOCOL"

            return 1

            ;;

    esac


    # 添加返回流量规则
    add_return_rule "$ID"
}


# ============================================================
# 更新全部转发规则
# ============================================================
#
# Cron 最终执行的就是：
#
#   tcp-udp-forward run
#
# 主要流程：
#
#   1. 自动检查依赖
#   2. 开启 IPv4 转发
#   3. 清理本程序旧规则
#   4. 读取配置文件
#   5. 解析目标域名
#   6. 重新创建 iptables
#
update_all() {

    # 必须 root
    check_root


    # 初始化配置目录
    init_dirs


    # --------------------------------------------------------
    # 自动检查依赖
    # --------------------------------------------------------
    #
    # 这里非常重要。
    #
    # 即使用户直接执行：
    #
    #   ./tcp-udp-forward.sh run
    #
    # 也会自动检查：
    #
    #   dig
    #   iptables
    #   cron
    #
    if ! ensure_dependencies; then

        error "依赖检查失败，无法更新规则。"

        return 1
    fi


    # 开启 IPv4 转发
    enable_ipv4_forward


    # 没有配置规则
    if [ ! -s "$CONFIG_FILE" ]; then

        info "当前没有任何转发规则。"

        return 0
    fi


    info "正在检查并更新转发规则..."


    # --------------------------------------------------------
    # 删除本程序以前创建的规则
    # --------------------------------------------------------
    #
    # 注意：
    #   只删除 TUFWD-*。
    #
    # 不会影响其他软件的 iptables 规则。
    #
    remove_all_iptables


    # --------------------------------------------------------
    # 逐条读取配置
    # --------------------------------------------------------

    while IFS='|' read -r ID PROTOCOL TARGET REMOTE_PORT LOCAL_PORT
    do

        # 跳过空行
        [ -z "$ID" ] && continue


        # ----------------------------------------------------
        # 解析目标地址
        # ----------------------------------------------------

        TARGET_IP=$(resolve_target "$TARGET")


        # 域名解析失败
        if [ -z "$TARGET_IP" ]; then

            error "规则 $ID：无法解析目标地址：$TARGET"

            log "规则 $ID 解析失败：$TARGET"

            continue
        fi


        # ----------------------------------------------------
        # 检查目标端口
        # ----------------------------------------------------

        if ! valid_port "$REMOTE_PORT"; then

            error "规则 $ID：目标端口无效：$REMOTE_PORT"

            log "规则 $ID 目标端口无效：$REMOTE_PORT"

            continue
        fi


        # ----------------------------------------------------
        # 检查本地端口
        # ----------------------------------------------------

        if ! valid_port "$LOCAL_PORT"; then

            error "规则 $ID：本地端口无效：$LOCAL_PORT"

            log "规则 $ID 本地端口无效：$LOCAL_PORT"

            continue
        fi


        # ----------------------------------------------------
        # 创建 iptables
        # ----------------------------------------------------

        if ! apply_rule \
            "$ID" \
            "$PROTOCOL" \
            "$TARGET_IP" \
            "$REMOTE_PORT" \
            "$LOCAL_PORT"
        then

            error "规则 $ID 添加失败。"

            log "规则 $ID 添加失败。"

            continue
        fi


        # 显示结果
        info "规则 $ID：$PROTOCOL $LOCAL_PORT → $TARGET_IP:$REMOTE_PORT"


        # 写日志
        log "规则 $ID：$PROTOCOL $LOCAL_PORT -> $TARGET_IP:$REMOTE_PORT"


    done < "$CONFIG_FILE"


    info "全部转发规则更新完成。"
}


# ============================================================
# 选择协议
# ============================================================

input_protocol() {

    while true
    do

        echo
        echo "协议类型："
        echo
        echo "  1. TCP"
        echo "  2. UDP"
        echo "  3. TCP + UDP"
        echo


        read -rp "请选择 [1-3]: " CHOICE


        case "$CHOICE" in

            1)

                PROTOCOL="TCP"

                break

                ;;


            2)

                PROTOCOL="UDP"

                break

                ;;


            3)

                PROTOCOL="BOTH"

                break

                ;;


            *)

                error "请输入 1、2 或 3。"

                ;;

        esac

    done
}


# ============================================================
# 交互输入一条转发规则
# ============================================================

input_rule() {

    # --------------------------------------------------------
    # 输入协议
    # --------------------------------------------------------

    input_protocol


    # --------------------------------------------------------
    # 输入目标地址
    # --------------------------------------------------------

    while true
    do

        read -rp "请输入目标地址（域名/IP）: " TARGET


        if valid_target "$TARGET"; then

            break
        fi


        error "目标地址格式不正确。"

    done


    # --------------------------------------------------------
    # 输入目标端口
    # --------------------------------------------------------

    while true
    do

        read -rp "请输入目标端口: " REMOTE_PORT


        if valid_port "$REMOTE_PORT"; then

            break
        fi


        error "端口必须是 1-65535。"

    done


    # --------------------------------------------------------
    # 输入本地端口
    # --------------------------------------------------------

    while true
    do

        read -rp "请输入本地端口: " LOCAL_PORT


        if valid_port "$LOCAL_PORT"; then

            break
        fi


        error "端口必须是 1-65535。"

    done
}


# ============================================================
# 添加转发规则
# ============================================================

add_rule() {

    check_root


    # --------------------------------------------------------
    # 这里必须自动检查依赖
    # --------------------------------------------------------
    #
    # 修复之前：
    #
    #   [错误] iptables 未安装
    #
    # 的问题。
    #
    if ! ensure_dependencies; then

        return 1
    fi


    init_dirs


    echo
    title "========== 添加转发规则 =========="
    echo


    # 获取用户输入
    input_rule


    # 获取新的规则 ID
    ID=$(get_next_id)


    # 显示配置
    echo
    echo "------------------------------------------"
    echo "规则编号 : $ID"
    echo "协议     : $PROTOCOL"
    echo "目标地址 : $TARGET"
    echo "目标端口 : $REMOTE_PORT"
    echo "本地端口 : $LOCAL_PORT"
    echo "------------------------------------------"
    echo


    # 用户确认
    read -rp "确认添加？[Y/n]: " CONFIRM


    # 输入 N 取消
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then

        info "已取消。"

        return
    fi


    # --------------------------------------------------------
    # 写入配置文件
    # --------------------------------------------------------

    echo "$ID|$PROTOCOL|$TARGET|$REMOTE_PORT|$LOCAL_PORT" \
        >> "$CONFIG_FILE"


    chmod 600 "$CONFIG_FILE"


    info "规则 $ID 已添加。"


    # 立即应用
    update_all
}


# ============================================================
# 查看当前规则
# ============================================================

show_rules() {

    echo
    title "========== 当前转发规则 =========="
    echo


    # 没有规则
    if [ ! -s "$CONFIG_FILE" ]; then

        warn "当前没有转发规则。"

        echo

        return
    fi


    # 表头
    printf "%-5s %-9s %-35s %-10s %-10s\n" \
        "ID" "协议" "目标" "目标端口" "本地端口"


    echo "--------------------------------------------------------------------------"


    # 读取规则
    while IFS='|' read -r ID PROTOCOL TARGET REMOTE_PORT LOCAL_PORT
    do

        [ -z "$ID" ] && continue


        printf "%-5s %-9s %-35s %-10s %-10s\n" \
            "$ID" \
            "$PROTOCOL" \
            "$TARGET" \
            "$REMOTE_PORT" \
            "$LOCAL_PORT"

    done < "$CONFIG_FILE"


    echo
}


# ============================================================
# 修改规则
# ============================================================

modify_rule() {

    # 显示当前规则
    show_rules


    # 没有规则就退出
    if [ ! -s "$CONFIG_FILE" ]; then

        return
    fi


    # 输入 ID
    read -rp "请输入要修改的规则编号: " ID


    # 获取旧规则
    OLD_RULE=$(get_rule "$ID")


    # 检查是否存在
    if [ -z "$OLD_RULE" ]; then

        error "规则 $ID 不存在。"

        return
    fi


    echo
    title "========== 修改规则 $ID =========="
    echo


    # 输入新的规则
    input_rule


    echo
    echo "新的配置："
    echo
    echo "协议     : $PROTOCOL"
    echo "目标地址 : $TARGET"
    echo "目标端口 : $REMOTE_PORT"
    echo "本地端口 : $LOCAL_PORT"
    echo


    # 确认
    read -rp "确认修改？[Y/n]: " CONFIRM


    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then

        info "已取消。"

        return
    fi


    # --------------------------------------------------------
    # 创建临时文件
    # --------------------------------------------------------

    TMP_FILE="${CONFIG_FILE}.tmp"


    # --------------------------------------------------------
    # 替换对应 ID
    # --------------------------------------------------------

    awk -F'|' \
        -v id="$ID" \
        -v protocol="$PROTOCOL" \
        -v target="$TARGET" \
        -v remote="$REMOTE_PORT" \
        -v local="$LOCAL_PORT" '

        BEGIN {
            OFS="|"
        }

        # 找到指定 ID
        $1 == id {

            print id, protocol, target, remote, local

            next
        }

        # 其他规则保持不变
        {
            print
        }

    ' "$CONFIG_FILE" > "$TMP_FILE"


    # 替换配置文件
    mv "$TMP_FILE" "$CONFIG_FILE"


    chmod 600 "$CONFIG_FILE"


    info "规则 $ID 修改成功。"


    # 立即重新应用
    update_all
}


# ============================================================
# 删除规则
# ============================================================

delete_rule() {

    # 显示规则
    show_rules


    if [ ! -s "$CONFIG_FILE" ]; then

        return
    fi


    # 输入 ID
    read -rp "请输入要删除的规则编号: " ID


    # 检查规则
    if ! grep -q "^${ID}|" "$CONFIG_FILE"; then

        error "规则 $ID 不存在。"

        return
    fi


    # 确认
    read -rp "确认删除规则 $ID？[y/N]: " CONFIRM


    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

        info "已取消。"

        return
    fi


    # --------------------------------------------------------
    # 删除 iptables
    # --------------------------------------------------------

    remove_rule_iptables "$ID"


    # --------------------------------------------------------
    # 删除配置
    # --------------------------------------------------------

    sed -i "/^${ID}|/d" "$CONFIG_FILE"


    info "规则 $ID 已删除。"


    # 重新检查所有规则
    update_all
}


# ============================================================
# 修改检测间隔
# ============================================================
#
# 这里允许：
#
#   1 - 1440 分钟
#
# 例如：
#
#   5    = 5 分钟
#   10   = 10 分钟
#   30   = 30 分钟
#   60   = 60 分钟
#
# ============================================================

change_interval() {

    # 获取当前值
    CURRENT="$DEFAULT_INTERVAL"


    if [ -f "$INTERVAL_FILE" ]; then

        CURRENT=$(cat "$INTERVAL_FILE")

    fi


    echo
    echo "当前检测间隔：每 $CURRENT 分钟"
    echo


    while true
    do

        read -rp \
            "请输入新的检测间隔（1-1440 分钟）: " \
            INTERVAL


        # 检查数字
        if [[ "$INTERVAL" =~ ^[0-9]+$ ]] &&
           [ "$INTERVAL" -ge 1 ] &&
           [ "$INTERVAL" -le 1440 ]; then

            break
        fi


        error "请输入 1-1440 之间的数字。"

    done


    # 创建配置目录
    mkdir -p "$CONFIG_DIR"


    # 保存
    echo "$INTERVAL" > "$INTERVAL_FILE"


    # 重新创建 Cron
    create_cron


    info "检测间隔已修改为每 $INTERVAL 分钟。"
}


# ============================================================
# 创建 Cron 定时任务
# ============================================================
#
# Cron 最终执行：
#
#   /usr/local/sbin/tcp-udp-forward run
#
# 使用安装后的固定路径，而不是用户当前目录。
#
create_cron() {

    # 确保 Cron 已安装
    if ! ensure_cron; then

        return 1
    fi


    mkdir -p "$CONFIG_DIR"


    # 默认值
    INTERVAL="$DEFAULT_INTERVAL"


    # 如果用户修改过，则读取用户设置
    if [ -f "$INTERVAL_FILE" ]; then

        INTERVAL=$(cat "$INTERVAL_FILE")

    fi


    # --------------------------------------------------------
    # 确保主程序已经安装
    # --------------------------------------------------------

    if [ ! -f "$SCRIPT_PATH" ]; then

        # 获取当前脚本真实路径
        CURRENT_SCRIPT=$(readlink -f "$0" 2>/dev/null || echo "$0")


        # 创建安装目录
        mkdir -p "$INSTALL_DIR"


        # 复制程序
        cp "$CURRENT_SCRIPT" "$SCRIPT_PATH"


        # 设置可执行权限
        chmod 755 "$SCRIPT_PATH"

    fi


    # --------------------------------------------------------
    # 创建 /etc/cron.d/ 文件
    # --------------------------------------------------------

    cat > "$CRON_FILE" <<EOF
# ============================================================
# TCP / UDP Forward Manager
# ============================================================
#
# 自动检查目标域名 IP 并更新端口转发。
#
# 当前检测间隔：
#   每 ${INTERVAL} 分钟
#
# ============================================================

*/$INTERVAL * * * * root $SCRIPT_PATH run >/dev/null 2>&1
EOF


    # Cron 文件权限必须比较严格
    chmod 644 "$CRON_FILE"


    # 启动 Cron
    start_cron_service


    info "Cron 已启用：每 $INTERVAL 分钟执行一次。"
}


# ============================================================
# 查看运行状态
# ============================================================

show_status() {

    echo
    title "========== TCP / UDP 转发状态 =========="
    echo


    # --------------------------------------------------------
    # IPv4 Forward
    # --------------------------------------------------------

    IP_FORWARD=$(cat \
        /proc/sys/net/ipv4/ip_forward \
        2>/dev/null || echo 0)


    if [ "$IP_FORWARD" = "1" ]; then

        echo -e \
            "IPv4 转发 : ${GREEN}已开启${NC}"

    else

        echo -e \
            "IPv4 转发 : ${RED}未开启${NC}"

    fi


    echo


    # --------------------------------------------------------
    # Cron 状态
    # --------------------------------------------------------

    if [ -f "$CRON_FILE" ]; then

        INTERVAL="$DEFAULT_INTERVAL"


        if [ -f "$INTERVAL_FILE" ]; then

            INTERVAL=$(cat "$INTERVAL_FILE")

        fi


        echo -e \
            "定时任务 : ${GREEN}已启用${NC}"


        echo "检测间隔 : 每 $INTERVAL 分钟"

        echo "Cron 文件: $CRON_FILE"

    else

        echo -e \
            "定时任务 : ${RED}未启用${NC}"

    fi


    echo


    # --------------------------------------------------------
    # 当前配置
    # --------------------------------------------------------

    show_rules


    # --------------------------------------------------------
    # 当前 iptables
    # --------------------------------------------------------

    echo "iptables 本工具规则："
    echo


    if command -v iptables >/dev/null 2>&1; then

        IPTABLES="$(command -v iptables)"


        echo "【PREROUTING】"

        "$IPTABLES" -t nat -S PREROUTING 2>/dev/null |
            grep "$COMMENT_PREFIX-" ||
            echo "  无"


        echo
        echo "【POSTROUTING】"

        "$IPTABLES" -t nat -S POSTROUTING 2>/dev/null |
            grep "$COMMENT_PREFIX-" ||
            echo "  无"


        echo
        echo "【FORWARD】"

        "$IPTABLES" -S FORWARD 2>/dev/null |
            grep "$COMMENT_PREFIX-" ||
            echo "  无"

    else

        echo "  iptables 未安装"

    fi


    echo
}


# ============================================================
# 查看日志
# ============================================================

show_log() {

    echo
    title "========== 最近日志 =========="
    echo


    # 日志不存在
    if [ ! -f "$LOG_FILE" ]; then

        warn "日志文件不存在。"

        return
    fi


    # 显示最后 50 行
    tail -n 50 "$LOG_FILE"


    echo
}


# ============================================================
# 安装管理器
# ============================================================

install_manager() {

    check_root


    echo
    title "========== 安装 TCP / UDP 转发管理器 =========="
    echo


    # --------------------------------------------------------
    # 检测操作系统
    # --------------------------------------------------------

    detect_os


    info "操作系统：$OS_NAME"

    info "软件包管理器：$PKG_MANAGER"


    # --------------------------------------------------------
    # 自动安装依赖
    # --------------------------------------------------------

    if ! ensure_dependencies; then

        error "依赖安装失败。"

        exit 1
    fi


    # 创建配置目录
    init_dirs


    # 开启 IPv4 转发
    enable_ipv4_forward


    # --------------------------------------------------------
    # 创建默认检测间隔
    # --------------------------------------------------------

    if [ ! -f "$INTERVAL_FILE" ]; then

        echo "$DEFAULT_INTERVAL" > "$INTERVAL_FILE"

    fi


    # --------------------------------------------------------
    # 获取当前脚本路径
    # --------------------------------------------------------

    CURRENT_SCRIPT=$(readlink -f "$0" 2>/dev/null || echo "$0")


    # 创建安装目录
    mkdir -p "$INSTALL_DIR"


    # --------------------------------------------------------
    # 如果当前脚本不是安装路径，则复制
    # --------------------------------------------------------

    if [ "$CURRENT_SCRIPT" != "$SCRIPT_PATH" ]; then

        cp "$CURRENT_SCRIPT" "$SCRIPT_PATH"

        chmod 755 "$SCRIPT_PATH"

        info "管理程序已安装：$SCRIPT_PATH"

    else

        chmod 755 "$SCRIPT_PATH"

    fi


    # --------------------------------------------------------
    # 创建 Cron
    # --------------------------------------------------------

    create_cron


    echo
    echo "=========================================="
    echo "             安装完成"
    echo "=========================================="
    echo
    echo "管理命令："
    echo
    echo "  $SCRIPT_PATH"
    echo
    echo "配置文件："
    echo
    echo "  $CONFIG_FILE"
    echo
    echo "日志文件："
    echo
    echo "  $LOG_FILE"
    echo
    echo "Cron："
    echo
    echo "  $CRON_FILE"
    echo


    # 第一次安装时询问是否添加规则
    read -rp \
        "现在添加第一条转发规则？[Y/n]: " ADD


    if [[ ! "$ADD" =~ ^[Nn]$ ]]; then

        add_rule

    fi
}


# ============================================================
# 卸载管理器
# ============================================================

uninstall_manager() {

    check_root


    echo
    title "========== 卸载 TCP / UDP 转发管理器 =========="
    echo


    echo "将删除："
    echo
    echo "  - 本工具创建的 TCP / UDP iptables 规则"
    echo "  - 本工具 Cron 定时任务"
    echo "  - 本工具配置文件"
    echo "  - 本工具管理程序"
    echo "  - 本工具 sysctl 配置"
    echo


    echo "不会删除："
    echo
    echo "  - 其他 iptables 规则"
    echo "  - 其他 Cron 任务"
    echo "  - 其他系统服务"
    echo "  - 其他配置文件"
    echo


    # 为避免误操作，需要明确输入 YES
    read -rp \
        "确认卸载？请输入 YES： " \
        CONFIRM


    if [ "$CONFIRM" != "YES" ]; then

        info "已取消卸载。"

        return
    fi


    # --------------------------------------------------------
    # 删除本程序 iptables
    # --------------------------------------------------------

    if command -v iptables >/dev/null 2>&1; then

        IPTABLES="$(command -v iptables)"


        remove_all_iptables

    fi


    # --------------------------------------------------------
    # 删除 Cron
    # --------------------------------------------------------

    rm -f "$CRON_FILE"


    # --------------------------------------------------------
    # 删除配置
    # --------------------------------------------------------

    rm -rf "$CONFIG_DIR"


    # --------------------------------------------------------
    # 删除 IPv4 转发持久化配置
    # --------------------------------------------------------

    rm -f \
        /etc/sysctl.d/99-tcp-udp-forward.conf


    # --------------------------------------------------------
    # 删除管理程序
    # --------------------------------------------------------

    rm -f "$SCRIPT_PATH"


    echo
    echo "=========================================="
    echo "             卸载完成"
    echo "=========================================="
    echo


    echo "本工具的转发规则和 Cron 已删除。"
    echo


    # 日志故意保留，方便以后排查
    echo "日志文件已保留："
    echo
    echo "  $LOG_FILE"
    echo


    # 不主动关闭 ip_forward。
    #
    # 原因：
    #   服务器可能还有其他 NAT / Docker / VPN / 路由业务。
    #
    echo "IPv4 转发保持当前状态，没有自动关闭。"
    echo
}


# ============================================================
# 主菜单
# ============================================================

menu() {

    while true
    do

        # 清屏
        clear


        echo
        echo "=========================================="
        echo "       TCP / UDP 通用端口转发管理器"
        echo "=========================================="
        echo
        echo "  1. 添加转发规则"
        echo "  2. 查看转发规则"
        echo "  3. 修改转发规则"
        echo "  4. 删除转发规则"
        echo "  5. 立即更新全部规则"
        echo "  6. 修改检测间隔"
        echo "  7. 查看运行状态"
        echo "  8. 查看运行日志"
        echo "  9. 卸载"
        echo "  0. 退出"
        echo
        echo "=========================================="
        echo


        # 获取菜单选择
        read -rp "请选择 [0-9]: " CHOICE


        case "$CHOICE" in

            # ------------------------------------------------
            # 添加
            # ------------------------------------------------

            1)

                add_rule

                read -rp "按 Enter 返回菜单..."

                ;;


            # ------------------------------------------------
            # 查看
            # ------------------------------------------------

            2)

                show_rules

                read -rp "按 Enter 返回菜单..."

                ;;


            # ------------------------------------------------
            # 修改
            # ------------------------------------------------

            3)

                modify_rule

                read -rp "按 Enter 返回菜单..."

                ;;


            # ------------------------------------------------
            # 删除
            # ------------------------------------------------

            4)

                delete_rule

                read -rp "按 Enter 返回菜单..."

                ;;


            # ------------------------------------------------
            # 立即更新
            # ------------------------------------------------

            5)

                update_all

                read -rp "按 Enter 返回菜单..."

                ;;


            # ------------------------------------------------
            # 修改检测间隔
            # ------------------------------------------------

            6)

                change_interval

                read -rp "按 Enter 返回菜单..."

                ;;


            # ------------------------------------------------
            # 查看状态
            # ------------------------------------------------

            7)

                show_status

                read -rp "按 Enter 返回菜单..."

                ;;


            # ------------------------------------------------
            # 查看日志
            # ------------------------------------------------

            8)

                show_log

                read -rp "按 Enter 返回菜单..."

                ;;


            # ------------------------------------------------
            # 卸载
            # ------------------------------------------------

            9)

                uninstall_manager

                read -rp "按 Enter 返回菜单..."

                ;;


            # ------------------------------------------------
            # 退出
            # ------------------------------------------------

            0)

                exit 0

                ;;


            # ------------------------------------------------
            # 无效选项
            # ------------------------------------------------

            *)

                error "无效选择。"

                sleep 1

                ;;

        esac

    done
}


# ============================================================
# 命令行模式
# ============================================================
#
# 除了交互菜单，还支持：
#
#   install
#   run
#   status
#   uninstall
#
# Cron 使用：
#
#   tcp-udp-forward run
#
# 这样 Cron 不需要进入交互菜单。
#
# ============================================================

case "${1:-menu}" in


    # --------------------------------------------------------
    # 安装
    # --------------------------------------------------------

    install)

        install_manager

        ;;


    # --------------------------------------------------------
    # Cron / 手动立即更新
    # --------------------------------------------------------

    run)

        check_root

        init_dirs

        update_all

        ;;


    # --------------------------------------------------------
    # 查看状态
    # --------------------------------------------------------

    status)

        check_root

        init_dirs

        show_status

        ;;


    # --------------------------------------------------------
    # 卸载
    # --------------------------------------------------------

    uninstall)

        uninstall_manager

        ;;


    # --------------------------------------------------------
    # 默认进入菜单
    # --------------------------------------------------------

    menu)

        check_root

        init_dirs

        menu

        ;;


    # --------------------------------------------------------
    # 未知参数
    # --------------------------------------------------------

    *)

        echo
        echo "TCP / UDP 通用端口转发管理器"
        echo
        echo "用法："
        echo
        echo "  $0              进入管理菜单"
        echo "  $0 install      安装管理器"
        echo "  $0 run          立即更新转发"
        echo "  $0 status       查看状态"
        echo "  $0 uninstall    卸载管理器"
        echo

        ;;

esacv
