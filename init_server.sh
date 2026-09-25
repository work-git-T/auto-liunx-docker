#!/bin/bash
# ============================================================
# 服务器初始化脚本
#   1. 防火墙自动识别与端口管理（firewalld/ufw/nftables/iptables）
#   2. SSH 端口修改（自动回退保护）
#   3. 系统包源检查与修复
#   4. 安装 Docker（含 Compose 插件、镜像加速）
#   5. daemon.json 交互式配置
#   6. 依据 docker-compose_<name>.yml 批量部署 Compose 项目
#
# 运行模式:
#   无参数               完全交互（每步确认）
#   --config FILE        半自动（正常按配置走，异常才询问）
#   --config FILE --yes  全自动（不询问，异常跳过/回退，最后汇总）
#   --dump-config        输出配置模板
#
# 使用: sudo bash init_server.sh [--config FILE] [--yes]
# ============================================================

set -euo pipefail

# ============================================================
# 参数解析
# ============================================================
CONFIG_FILE=""
AUTO_YES=false
USE_CONFIG=false
INTERACTIVE=true
show_help() {
    cat <<'HELP'
用法: sudo bash init_server.sh [选项]

选项:
  --config <文件>, -c <文件>   使用配置文件（半自动模式）
  --yes, -y                    全自动模式（覆盖为不询问）
  --dump-config                输出配置模板到标准输出
  --help, -h                   显示此帮助

运行模式:
  无参数
      完全交互。每一步都询问，包括是否修改 SSH 端口、是否部署
      Compose 等。适合首次接触脚本或边操作边学。

  --config FILE
      半自动。正常流程按配置直接执行，只在遇到异常时才询问:
        - SSH 端口修改后未监听  → 询问是否回退
        - 防火墙放行失败       → 询问是否回退 SSH 配置
        - 系统包源不可用       → 询问是否切默认源
        - Docker 安装失败      → 询问是否重试/切官方源
        - YAML 语法校验失败    → 询问是否继续处理其他项目
      正常情况（无异常）下全程静默，按配置执行。

  --config FILE --yes
      全自动。异常也不询问，按以下策略处理:
        - SSH 端口不监听       → 自动回退 SSH 配置
        - 防火墙放行失败       → 自动回退 SSH 配置
        - 包源不可用           → 自动切内置默认源（阿里云）
        - Docker 安装失败      → 记录并跳过 Compose 部署
        - YAML 语法错误        → 自动跳过该项目，继续下一个
        - 容器启动失败         → 记录并继续下一个
      最后统一输出错误/警告汇总。

防火墙处理:
  脚本自动检测并适配以下防火墙（无需配置）:
    - firewalld (CentOS/RHEL/Rocky/Alma/Fedora)
    - ufw (Ubuntu/Debian)
    - nftables (新版 Debian/Arch)
    - iptables (老式系统/自定义环境)
    - 无防火墙（容器/WSL2 等）
  云平台（阿里云/AWS/腾讯云）会额外提示需在控制台安全组
  同步放行端口。

环境变量（可选）:
  LOG_DIR=<路径>        日志目录（默认脚本目录下 logs/）
  LOG_LEVEL=DEBUG       日志级别 DEBUG/INFO/WARN/ERROR（默认 INFO）
  DEBUG=1               开启 set -x，把每条命令写入日志

示例:
  # 完全交互
  sudo bash init_server.sh

  # 半自动（异常时才询问）
  sudo bash init_server.sh --config /etc/my-init.conf

  # 全自动（CI/CD 场景）
  sudo bash init_server.sh --config /etc/my-init.conf --yes

  # 生成配置模板
  bash init_server.sh --dump-config > /etc/my-init.conf
  chmod 600 /etc/my-init.conf
HELP
}

dump_config_template() {
    cat <<'TEMPLATE'
# ============================================================
# init_server.sh 配置文件模板
# ============================================================
# 使用方式:
#   sudo bash init_server.sh --config /path/to/this.conf
#   sudo bash init_server.sh --config /path/to/this.conf --yes
#
# 权限要求:
#   chmod 600 /path/to/this.conf
#   脚本拒绝加载"其他用户可写"的配置文件（防提权）
#
# 语法:
#   本文件以 Bash source 方式加载，支持变量赋值和数组。
#
# 说明:
#   所有变量均为可选。未定义的项使用脚本内置默认值。
#   "半自动 vs 全自动"的差异体现在异常处理上，正常流程一致。
# ============================================================


# ============================================================
# 一、SSH 端口
# ============================================================
# SSH_CHANGE:
#   true  = 执行 SSH 端口修改
#   false = 跳过（默认）
#
#   修改流程（任一环节失败会自动回退，不会让 SSH 失联）:
#     1. 备份 sshd_config
#     2. 写入新 Port
#     3. 通过检测到的防火墙放行新端口
#     4. 处理 SELinux 策略
#     5. 重启 sshd
#     6. 验证新端口监听
#     7. 成功后关闭旧端口（可选）
SSH_CHANGE=false

# SSH_PORT:
#   新 SSH 端口号，范围 1024-65535
#   仅当 SSH_CHANGE=true 时生效
#   示例: 2222 / 22022 / 54321
SSH_PORT=

# SSH_CLOSE_OLD_PORT:
#   true  = 新端口验证成功后，自动关闭旧端口 22
#   false = 保留 22 端口
#
#   建议:
#     首次操作时设为 false，另开终端测试新端口连接后再手动关闭 22
#     确定环境稳定后设为 true，实现全自动切换
SSH_CLOSE_OLD_PORT=true


# ============================================================
# 二、系统包源
# ============================================================
# PACKAGE_SOURCE_MODE:
#   auto    = 先测试现有源，可用则用；不可用时——
#               半自动: 询问是否切默认源
#               全自动: 自动切内置阿里云默认源
#             （推荐）
#   default = 直接应用内置默认源（阿里云镜像）
#   custom  = 使用自定义源，需填 URL 或 FILE
#   skip    = 完全跳过包源检查（离线环境用）
PACKAGE_SOURCE_MODE=auto

# PACKAGE_SOURCE_URL:
#   镜像站 URL 前缀，用于 PACKAGE_SOURCE_MODE=custom
#   示例:
#     https://mirrors.tuna.tsinghua.edu.cn
#     https://mirrors.ustc.edu.cn
#     https://mirrors.aliyun.com
#     https://mirrors.huaweicloud.com
#   注意: 不要带尾部斜杠
PACKAGE_SOURCE_URL=

# PACKAGE_SOURCE_FILE:
#   本地源文件绝对路径，用于 PACKAGE_SOURCE_MODE=custom
#   与 PACKAGE_SOURCE_URL 二选一（同时填写时优先用 FILE）
#   支持的文件类型:
#     apt 系统:  .list  或  .sources
#     yum 系统:  .repo
#   示例:
#     /root/sources.list
#     /root/tuna.repo
PACKAGE_SOURCE_FILE=


# ============================================================
# 三、Docker 安装
# ============================================================
# DOCKER_INSTALL:
#   true  = 安装 Docker（默认）
#   false = 完全跳过 Docker 安装步骤
DOCKER_INSTALL=true

# DOCKER_MIRRORS:
#   Docker Hub 镜像加速地址列表（数组语法）
#   仅对 docker.io（Docker Hub）生效
#   非 Docker Hub 的仓库（ghcr.io / quay.io / gcr.io）需单独处理
#
#   常用地址:
#     https://docker.m.daocloud.io
#     https://docker.xuanyuan.me
#     https://docker.1ms.run
#     腾讯云 CVM 内网: https://mirror.ccs.tencentyun.com
#     阿里云 ECS 内网: https://<你的ID>.mirror.aliyuncs.com
#
#   空数组表示不使用加速器（内网环境可这么写）:
#     DOCKER_MIRRORS=()
DOCKER_MIRRORS=(
    "https://docker.m.daocloud.io"
    "https://docker.xuanyuan.me"
    "https://docker.1ms.run"
)

# DOCKER_LOG_MAX_SIZE:
#   单个容器日志文件最大尺寸
#   支持单位: k / m / g
#   示例: 10m / 50m / 1g / 100k
DOCKER_LOG_MAX_SIZE="10m"

# DOCKER_LOG_MAX_FILE:
#   容器日志文件保留份数（滚动覆盖）
#   示例: 3 / 5 / 10
DOCKER_LOG_MAX_FILE="3"

# DOCKER_LIVE_RESTORE:
#   true  = 重启 Docker 守护进程时容器不停止（推荐生产环境）
#   false = 重启 Docker 会停止所有容器
DOCKER_LIVE_RESTORE=true

# DOCKER_DAEMON_MODE:
#   处理 /etc/docker/daemon.json 的策略
#
#   auto    = 已存在则保留；不存在则用推荐配置创建（推荐）
#             全自动模式下也不会覆盖已有配置
#   keep    = 已存在则保留；不存在则跳过（完全不动）
#   default = 已存在时——
#               半自动: 询问是否覆盖
#               全自动: 直接覆盖（会先备份）
#             不存在时创建推荐配置
#   skip    = 完全不处理 daemon.json
#
#   推荐值:
#     生产环境用 auto（尊重现有配置）
#     全新机器用 auto（无则创建）
#     完全不想让脚本碰配置用 skip
DOCKER_DAEMON_MODE=auto


# ============================================================
# 四、Docker Compose 批量部署
# ============================================================
# COMPOSE_DEPLOY:
#   true  = 执行批量部署
#   false = 跳过（默认）
COMPOSE_DEPLOY=false

# COMPOSE_YAML_DIR:
#   YAML 文件所在目录（绝对路径）
#   留空时使用脚本执行时的当前目录
#
#   该目录下需有以下规则的文件:
#     docker-compose_<name>.yml   或   docker-compose_<name>.yaml
#   可选配套 env 文件:
#     <name>.env  →  会被复制为 <name>/.env
#
#   示例:
#     /root
#     /opt/compose
#     /data/stacks
COMPOSE_YAML_DIR=

# COMPOSE_MODE:
#   A = 保留原文件名，使用 docker compose -p <name> -f <file> up -d
#   B = 复制时将 YAML 重命名为 docker-compose.yml
#
#   说明:
#     A 保留原文件名，后续排查时容易区分项目（推荐）
#     B 符合 Compose 官方约定，进入目录后无需 -f 参数
COMPOSE_MODE=A


# ============================================================
# 五、日志（可选，也可通过环境变量传递）
# ============================================================
# 以下变量通过配置文件设置时，会覆盖同名环境变量。
# 通常不建议在配置文件里修改，用环境变量更灵活:
#   sudo LOG_LEVEL=DEBUG bash init_server.sh --config this.conf

# LOG_DIR="/var/log/init_server"
# LOG_LEVEL="INFO"
# LOG_CMD_OUTPUT=1
# LOG_MAX_BYTES=4000


# ============================================================
# 配置文件结束
# ============================================================
TEMPLATE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config|-c)
            [[ -z "${2:-}" ]] && { echo "错误: --config 需要文件名" >&2; exit 1; }
            CONFIG_FILE="$2"; USE_CONFIG=true; shift 2
            ;;
        --yes|-y)      AUTO_YES=true; INTERACTIVE=false; shift ;;
        --dump-config) dump_config_template; exit 0 ;;
        --help|-h)     show_help; exit 0 ;;
        *) echo "未知参数: $1" >&2; show_help; exit 1 ;;
    esac
done

# ============================================================
# 默认配置
# ============================================================
SSH_CHANGE=false
SSH_PORT=""
SSH_CLOSE_OLD_PORT=true

PACKAGE_SOURCE_MODE=auto
PACKAGE_SOURCE_URL=""
PACKAGE_SOURCE_FILE=""

DOCKER_INSTALL=true
DOCKER_MIRRORS=(
    "https://docker.m.daocloud.io"
    "https://docker.xuanyuan.me"
    "https://docker.1ms.run"
)
DOCKER_LOG_MAX_SIZE="10m"
DOCKER_LOG_MAX_FILE="3"
DOCKER_LIVE_RESTORE=true
DOCKER_DAEMON_MODE=auto

COMPOSE_DEPLOY=false
COMPOSE_YAML_DIR=""
COMPOSE_MODE=A

if [[ -n "$CONFIG_FILE" ]]; then
    [[ ! -f "$CONFIG_FILE" ]] && { echo "配置文件不存在: $CONFIG_FILE" >&2; exit 1; }
    perm="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo "?")"
    case "$perm" in
        *2|*3|*6|*7) echo "配置文件权限 $perm 过宽，拒绝加载。请 chmod 600" >&2; exit 1 ;;
    esac
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ============================================================
# 日志系统
# ============================================================
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

_init_log_dir() {
    local d
    for d in "${LOG_DIR:-}" "$SCRIPT_DIR/logs" "/var/log/init_server" "/tmp"; do
        [[ -z "$d" ]] && continue
        if mkdir -p "$d" 2>/dev/null && touch "$d/.w_test" 2>/dev/null; then
            rm -f "$d/.w_test" 2>/dev/null; echo "$d"; return 0
        fi
    done
    return 1
}

LOG_DIR="$(_init_log_dir)" || { echo "无法创建日志目录。" >&2; exit 1; }
LOG_FILE="$LOG_DIR/init_server_$(date +%Y%m%d_%H%M%S)_$$.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

_log_level_num() { case "$1" in DEBUG) echo 0;; INFO) echo 1;; WARN) echo 2;; ERROR) echo 3;; *) echo 1;; esac; }

_log() {
    local level="$1"; shift; local color="$1"; shift; local msg="$*"
    local lv_num cur_num
    lv_num="$(_log_level_num "$level")"; cur_num="$(_log_level_num "$LOG_LEVEL")"
    [[ "$lv_num" -lt "$cur_num" ]] && return 0
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S.%3N')"
    if [[ -t 1 ]]; then echo -e "${color}[${level}]${NC} ${msg}"; else echo "[${level}] ${msg}"; fi
    echo "[${ts}] [${level}] [PID:$$] ${msg}" >> "$LOG_FILE"
}

log_debug() { _log DEBUG "$CYAN"    "$@"; }
log_info()  { _log INFO  "$GREEN"   "$@"; }
log_warn()  { _log WARN  "$YELLOW"  "$@"; }
log_error() { _log ERROR "$RED"     "$@"; }
log_detail(){ _log INFO  "$MAGENTA" "$@"; }

log_section() {
    local title="$1"; local line="============================================================"
    echo ""
    if [[ -t 1 ]]; then
        echo -e "${BOLD}${BLUE}${line}${NC}"; echo -e "${BOLD}${BLUE}  $title${NC}"; echo -e "${BOLD}${BLUE}${line}${NC}"
    else
        echo "$line"; echo "  $title"; echo "$line"
    fi
    { echo "$line"; echo "  $title"; echo "$line"; } >> "$LOG_FILE"
}

declare -A _STEP_START_TIME
log_step_begin() { local n="$1"; _STEP_START_TIME["$n"]="$(date +%s)"; log_info "▶▶▶ [步骤开始] $n"; }
log_step_end() {
    local n="$1"; local s="${_STEP_START_TIME[$n]:-}"
    if [[ -n "$s" ]]; then log_info "◀◀◀ [步骤结束] $n （耗时 $(( $(date +%s) - s ))s）"
    else log_info "◀◀◀ [步骤结束] $n"; fi
}

# ============================================================
# 全局错误/警告收集
# ============================================================
declare -a GLOBAL_ERRORS=()
declare -a GLOBAL_WARNINGS=()

record_error()   { GLOBAL_ERRORS+=("$1");   log_error "$1"; }
record_warning() { GLOBAL_WARNINGS+=("$1"); log_warn  "$1"; }

print_final_summary() {
    local err=${#GLOBAL_ERRORS[@]} warn=${#GLOBAL_WARNINGS[@]}
    local line="============================================================"

    echo ""
    if [[ -t 1 ]]; then
        if [[ $err -eq 0 && $warn -eq 0 ]]; then
            echo -e "${BOLD}${GREEN}${line}${NC}"
            echo -e "${BOLD}${GREEN}  ✅ 全部步骤执行成功，无错误和警告${NC}"
            echo -e "${BOLD}${GREEN}${line}${NC}"
        else
            echo -e "${BOLD}${YELLOW}${line}${NC}"
            echo -e "${BOLD}${YELLOW}  执行完成：${err} 个错误，${warn} 个警告${NC}"
            echo -e "${BOLD}${YELLOW}${line}${NC}"
        fi
    else
        echo "$line"
        if [[ $err -eq 0 && $warn -eq 0 ]]; then echo " ✅ 全部步骤执行成功，无错误和警告"
        else echo "  执行完成：${err} 个错误，${warn} 个警告"; fi
        echo "$line"
    fi

    if [[ $err -gt 0 ]]; then
        echo ""; log_error "─────── 错误汇总（$err 项） ───────"
        local i=1; for e in "${GLOBAL_ERRORS[@]}"; do log_error "  [$i] $e"; i=$((i+1)); done
    fi
    if [[ $warn -gt 0 ]]; then
        echo ""; log_warn "─────── 警告汇总（$warn 项） ───────"
        local i=1; for w in "${GLOBAL_WARNINGS[@]}"; do log_warn "  [$i] $w"; i=$((i+1)); done
    fi

    {
        echo "$line"; echo " 执行汇总: 错误=$err 警告=$warn"
        for e in "${GLOBAL_ERRORS[@]:-}"; do [[ -n "$e" ]] && echo "  [ERROR] $e"; done
        for w in "${GLOBAL_WARNINGS[@]:-}"; do [[ -n "$w" ]] && echo "  [WARN] $w"; done
        echo "$line"
    } >> "$LOG_FILE"

    [[ $err -gt 0 ]] && return 1
    return 0
}

# ============================================================
# 交互辅助
# ============================================================
ask_yes_no() {
    local prompt="$1" default="$2"
    if [[ "$AUTO_YES" == "true" ]]; then
        [[ "$default" == "yes" ]]; return $?
    fi
    local input
    read -rp "$prompt" input
    input="${input:-$default}"
    [[ "$input" =~ ^[Yy](es)?$ ]]
}

ask_input() {
    local prompt="$1" default="$2"
    if [[ "$AUTO_YES" == "true" ]]; then echo "$default"; return; fi
    local input
    read -rp "$prompt" input
    echo "${input:-$default}"
}

# ============================================================
# 命令执行包装器
# ============================================================
run_cmd() {
    local desc="$1"; shift
    local start end duration rc
    start="$(date +%s.%N)"
    log_detail "[CMD] $desc"
    log_debug "      命令: $*"

    local output=""
    output="$("$@" 2>&1)" && rc=0 || rc=$?

    end="$(date +%s.%N)"
    duration="$(awk "BEGIN{printf \"%.3f\", $end - $start}")"

    if [[ $rc -eq 0 ]]; then log_detail "[CMD] ✅ 成功: $desc （rc=$rc, 耗时 ${duration}s）"
    else log_error "[CMD] ❌ 失败: $desc （rc=$rc, 耗时 ${duration}s）"; fi
    if [[ -n "$output" ]]; then log_debug "$(printf '%s' "$output" | head -c 4000 | sed 's/^/        /')"; fi
    return $rc
}

# ============================================================
# 文件操作
# ============================================================
log_file_snapshot() {
    local file="$1" label="${2:-快照}"
    if [[ ! -f "$file" ]]; then log_debug "$label: $file 不存在"; return; fi
    local size lines sha
    size=$(stat -c%s "$file" 2>/dev/null || echo "?")
    lines=$(wc -l < "$file" 2>/dev/null || echo "?")
    sha=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    log_debug "$label: $file | ${size}B 行数=${lines} sha=${sha:0:16}..."
}

backup_file() {
    local file="$1"
    local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
    if [[ -f "$file" ]]; then
        log_file_snapshot "$file" "备份前"
        cp -a "$file" "$backup"
        log_info "已备份: $file → $backup"
        find "$(dirname "$file")" -maxdepth 1 -name "$(basename "$file").bak.*" -type f 2>/dev/null \
            | sort -r | tail -n +6 | while read -r old; do rm -f "$old"; done
    fi
    echo "$backup"
}

# ============================================================
# 环境信息
# ============================================================
collect_env_info() {
    log_section "环境信息"
    log_info "主机名  : $(hostname 2>/dev/null || echo unknown)"
    log_info "内核    : $(uname -sr 2>/dev/null || echo unknown)"
    log_info "架构    : $(uname -m 2>/dev/null || echo unknown)"
    log_info "当前用户: $(whoami) (uid=$(id -u))"
    log_info "工作目录: $(pwd)"
    if [[ "$AUTO_YES" == "true" ]]; then log_info "运行模式: 全自动"
    elif [[ "$USE_CONFIG" == "true" ]]; then log_info "运行模式: 半自动（$CONFIG_FILE）"
    else log_info "运行模式: 完全交互"; fi

    if [[ -f /etc/os-release ]]; then
        local pretty
        pretty="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"
        log_info "发行版  : $pretty"
    fi

    command -v free &>/dev/null && log_info "内存    : $(free -h 2>/dev/null | awk '/^Mem:/{print $2" 总 / "$7" 可用"}')"
    command -v df &>/dev/null && log_info "根分区  : $(df -h / 2>/dev/null | awk 'NR==2{print $2" 总 / "$4" 可用"}')"

    local pub_ip
    pub_ip=$(timeout 5 curl -s --max-time 4 https://ifconfig.me 2>/dev/null || echo "查询失败")
    log_info "公网出口: $pub_ip"
}

detect_os() {
    log_step_begin "识别操作系统"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="$ID"; OS_LIKE="${ID_LIKE:-}"; OS_VER="${VERSION_ID:-}"; OS_CODENAME="${VERSION_CODENAME:-}"
    else
        record_error "无法识别操作系统"; exit 1
    fi

    if command -v apt-get &>/dev/null; then PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then PKG_MGR="yum"
    else record_error "未找到包管理器"; exit 1; fi

    log_info "系统: $OS_ID $OS_VER, 包管理器: $PKG_MGR"
    log_step_end "识别操作系统"
}

# ============================================================
# 防火墙检测与操作
# ============================================================
FW_TYPE="none"
FW_DETAIL=""
FW_ZONE=""
FW_AVAILABLE=()

_has_cmd() { command -v "$1" &>/dev/null; }

detect_firewall() {
    log_step_begin "检测防火墙"
    FW_AVAILABLE=()

    _has_cmd firewall-cmd && FW_AVAILABLE+=("firewalld")
    _has_cmd ufw          && FW_AVAILABLE+=("ufw")
    _has_cmd nft          && FW_AVAILABLE+=("nftables")
    _has_cmd iptables     && FW_AVAILABLE+=("iptables")

    log_info "已安装防火墙工具: ${FW_AVAILABLE[*]:-<无>}"

    # 1. firewalld
    if _has_cmd firewall-cmd; then
        local fw_state
        fw_state="$(firewall-cmd --state 2>/dev/null || echo "not-running")"
        log_debug "  firewalld state: $fw_state"
        if [[ "$fw_state" == "running" ]]; then
            FW_TYPE="firewalld"
            FW_ZONE="$(firewall-cmd --get-default-zone 2>/dev/null || echo "public")"
            FW_DETAIL="firewalld (zone=$FW_ZONE)"
            log_info "✅ 活跃防火墙: $FW_DETAIL"
            log_step_end "检测防火墙"; return 0
        fi
    fi

    # 2. ufw
    if _has_cmd ufw; then
        local ufw_status
        ufw_status="$(ufw status 2>/dev/null | head -1 | awk '{print $2}' | tr -d ':')"
        log_debug "  ufw status: $ufw_status"
        if [[ "$ufw_status" == "active" ]]; then
            FW_TYPE="ufw"
            FW_DETAIL="ufw"
            log_info "✅ 活跃防火墙: $FW_DETAIL"
            log_step_end "检测防火墙"; return 0
        fi
    fi

    # 3. nftables
    if _has_cmd nft; then
        local nft_rules
        nft_rules="$(nft list ruleset 2>/dev/null | wc -l)"
        if [[ "$nft_rules" -gt 5 ]]; then
            FW_TYPE="nftables"
            FW_DETAIL="nftables (rules=$nft_rules lines)"
            log_info "✅ 活跃防火墙: $FW_DETAIL"
            log_step_end "检测防火墙"; return 0
        fi
    fi

    # 4. iptables
    if _has_cmd iptables; then
        local rule_count policy
        rule_count="$(iptables -L INPUT -n 2>/dev/null | tail -n +3 | wc -l)"
        policy="$(iptables -L INPUT -n 2>/dev/null | head -1 | grep -oP 'policy \K\w+' || echo "ACCEPT")"
        if [[ "$rule_count" -gt 0 || "$policy" == "DROP" || "$policy" == "REJECT" ]]; then
            FW_TYPE="iptables"
            FW_DETAIL="iptables (INPUT policy=$policy, rules=$rule_count)"
            log_info "✅ 活跃防火墙: $FW_DETAIL"
            log_step_end "检测防火墙"; return 0
        fi
    fi

    # 5. 无
    FW_TYPE="none"
    FW_DETAIL="未检测到活跃防火墙"
    log_info "ℹ️  $FW_DETAIL"
    log_step_end "检测防火墙"
    return 0
}

_warn_cloud_security_group() {
    local port="$1" proto="${2:-tcp}"
    local provider=""

    if timeout 2 curl -s --max-time 1 http://100.100.100.200/latest/meta-data/ &>/dev/null; then
        provider="阿里云"
    elif timeout 2 curl -s --max-time 1 http://169.254.169.254/latest/meta-data/ &>/dev/null; then
        provider="AWS/腾讯云"
    fi

    if [[ -n "$provider" ]]; then
        log_warn "  ⚠️  检测到 $provider 环境，请在控制台安全组中放行 ${port}/${proto}"
        record_warning "$provider 安全组需手动放行 ${port}/${proto}"
    fi
}

_iptables_persist() {
    if command -v service &>/dev/null && [[ -f /etc/sysconfig/iptables ]]; then
        service iptables save 2>/dev/null && return 0
    fi
    if [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && return 0
    fi
    if [[ -d /etc/sysconfig ]]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null && return 0
    fi
    iptables-save > /etc/iptables.rules 2>/dev/null && return 0
    return 1
}

firewall_open_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local desc="${3:-}"

    log_info "放行端口 ${port}/${proto}${desc:+（$desc）} [通过 $FW_TYPE]"

    case "$FW_TYPE" in
        firewalld)
            if ! firewall-cmd --permanent --zone="$FW_ZONE" --add-port="${port}/${proto}" &>/dev/null; then
                record_error "firewall-cmd 添加端口失败"; return 1
            fi
            if ! firewall-cmd --reload &>/dev/null; then
                record_error "firewall-cmd reload 失败"; return 1
            fi
            if ! firewall-cmd --zone="$FW_ZONE" --query-port="${port}/${proto}" &>/dev/null; then
                record_error "firewalld 验证失败：${port}/${proto} 未生效"; return 1
            fi
            log_info "  ✅ firewalld 已放行 ${port}/${proto}（zone=$FW_ZONE）"
            ;;
        ufw)
            if ! ufw allow "${port}/${proto}" &>/dev/null; then
                record_error "ufw allow 失败"; return 1
            fi
            if ! ufw status 2>/dev/null | grep -qE "^${port}/${proto}\s+ALLOW"; then
                record_error "ufw 验证失败：${port}/${proto} 未生效"; return 1
            fi
            log_info "  ✅ ufw 已放行 ${port}/${proto}"
            ;;
        nftables)
            if nft list table inet filter &>/dev/null; then
                if nft list chain inet filter input 2>/dev/null | grep -q "dport ${port}.*accept"; then
                    log_info "  ℹ️  nftables 中已存在 ${port}/${proto} 规则"; return 0
                fi
                if ! nft add rule inet filter input "${proto}" dport "$port" accept 2>/dev/null; then
                    record_error "nftables 添加规则失败"; return 1
                fi
                if [[ -f /etc/nftables.conf ]]; then
                    nft list ruleset > /etc/nftables.conf 2>/dev/null || true
                    log_info "  ✅ nftables 已放行 ${port}/${proto} 并持久化"
                else
                    record_warning "nftables 规则未持久化（/etc/nftables.conf 不存在）"
                fi
            else
                record_error "nftables inet filter 表不存在，无法自动放行"
                return 1
            fi
            ;;
        iptables)
            if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                log_info "  ℹ️  iptables 中已存在 ${port}/${proto} 规则"; return 0
            fi
            if ! iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT; then
                record_error "iptables 添加规则失败"; return 1
            fi
            _iptables_persist || record_warning "iptables 规则未持久化，重启后丢失"
            log_info "  ✅ iptables 已放行 ${port}/${proto}"
            ;;
        none)
            log_info "  ℹ️  无防火墙，无需放行端口"
            ;;
        *)
            record_error "未知防火墙类型: $FW_TYPE"; return 1
            ;;
    esac

    _warn_cloud_security_group "$port" "$proto"
    return 0
}

firewall_close_port() {
    local port="$1"
    local proto="${2:-tcp}"

    log_info "关闭端口 ${port}/${proto} [通过 $FW_TYPE]"

    case "$FW_TYPE" in
        firewalld)
            firewall-cmd --permanent --zone="$FW_ZONE" --remove-port="${port}/${proto}" &>/dev/null || true
            firewall-cmd --reload &>/dev/null || true
            log_info "  ✅ firewalld 已关闭 ${port}/${proto}"
            ;;
        ufw)
            ufw delete allow "${port}/${proto}" &>/dev/null || true
            log_info "  ✅ ufw 已关闭 ${port}/${proto}"
            ;;
        nftables)
            local handle
            handle="$(nft -a list chain inet filter input 2>/dev/null \
                | grep "dport ${port}.*accept" | grep -oP 'handle \K\d+' | head -1)"
            if [[ -n "$handle" ]]; then
                nft delete rule inet filter input handle "$handle" 2>/dev/null || true
                [[ -f /etc/nftables.conf ]] && nft list ruleset > /etc/nftables.conf 2>/dev/null || true
                log_info "  ✅ nftables 已关闭 ${port}/${proto}"
            else
                log_debug "  nftables 中未找到 ${port}/${proto} 规则"
            fi
            ;;
        iptables)
            local deleted=0
            while iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT || break
                deleted=$((deleted+1))
            done
            [[ $deleted -gt 0 ]] && _iptables_persist
            log_info "  ✅ iptables 已关闭 ${port}/${proto}（删除 $deleted 条）"
            ;;
        none)
            log_info "  ℹ️  无防火墙，无需操作"
            ;;
    esac
    return 0
}

# ============================================================
# 包源
# ============================================================
test_package_source() {
    local rc=0
    case "$PKG_MGR" in
        apt) timeout 25 apt-get update -qq >/dev/null 2>&1 || rc=$? ;;
        dnf|yum) timeout 40 $PKG_MGR -q makecache >/dev/null 2>&1 || rc=$? ;;
        *) rc=1 ;;
    esac
    return $rc
}

apply_default_source() {
    log_info "应用内置默认源（阿里云）..."
    case "$OS_ID" in
        ubuntu)
            local codename="${OS_CODENAME}"
            [[ -z "$codename" ]] && { log_error "无法获取代号"; return 1; }
            [[ -f /etc/apt/sources.list ]] && backup_file /etc/apt/sources.list >/dev/null
            if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
                cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: https://mirrors.aliyun.com/ubuntu/
Suites: $codename $codename-updates $codename-backports $codename-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
            else
                cat > /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/ubuntu/ $codename main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $codename-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $codename-security main restricted universe multiverse
EOF
            fi ;;
        debian)
            local codename="${OS_CODENAME:-bookworm}"
            backup_file /etc/apt/sources.list >/dev/null
            cat > /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/debian/ $codename main contrib non-free non-free-firmware
deb https://mirrors.aliyun.com/debian-security/ $codename-security main contrib non-free non-free-firmware
EOF
            ;;
        centos)
            local major="${OS_VER%%.*}"
            cp -a /etc/yum.repos.d "/etc/yum.repos.d.bak.$(date +%s)" 2>/dev/null || true
            if [[ "$major" == "7" ]]; then
                cat > /etc/yum.repos.d/CentOS-Base.repo <<'EOF'
[base]
name=CentOS-$releasever - Base
baseurl=https://mirrors.aliyun.com/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
[updates]
name=CentOS-$releasever - Updates
baseurl=https://mirrors.aliyun.com/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
[extras]
name=CentOS-$releasever - Extras
baseurl=https://mirrors.aliyun.com/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
EOF
            else
                log_error "CentOS $major 已 EOL"; return 1
            fi ;;
        rocky|almalinux)
            cp -a /etc/yum.repos.d "/etc/yum.repos.d.bak.$(date +%s)" 2>/dev/null || true
            sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/*.repo 2>/dev/null || true
            sed -i 's|^#baseurl=http://dl.rockylinux.org|baseurl=https://mirrors.aliyun.com/rockylinux|g' /etc/yum.repos.d/*.repo 2>/dev/null || true
            sed -i 's|^#baseurl=http://repo.almalinux.org|baseurl=https://mirrors.aliyun.com/almalinux|g' /etc/yum.repos.d/*.repo 2>/dev/null || true
            ;;
        *) log_error "不支持: $OS_ID"; return 1 ;;
    esac
    return 0
}

apply_custom_source() {
    local url="$PACKAGE_SOURCE_URL" file="$PACKAGE_SOURCE_FILE"
    if [[ -z "$url" && -z "$file" ]]; then
        if [[ "$AUTO_YES" == "true" ]]; then return 1; fi
        local fmt; fmt="$(ask_input "  自定义源: a) 本地文件 b) URL (默认 a): " "a")"
        if [[ "$fmt" == "a" ]]; then
            file="$(ask_input "  本地文件路径: " "")"
            [[ -z "$file" || ! -f "$file" ]] && return 1
        else
            url="$(ask_input "  URL: " "")"; url="${url%/}"
            [[ -z "$url" ]] && return 1
        fi
    fi

    if [[ -n "$file" ]]; then
        case "$PKG_MGR" in
            apt)
                if [[ "$file" == *.sources ]]; then cp "$file" /etc/apt/sources.list.d/
                else backup_file /etc/apt/sources.list >/dev/null; cp "$file" /etc/apt/sources.list; fi ;;
            dnf|yum)
                cp -a /etc/yum.repos.d "/etc/yum.repos.d.bak.$(date +%s)" 2>/dev/null || true
                cp "$file" /etc/yum.repos.d/ ;;
        esac
        return 0
    fi

    case "$OS_ID" in
        ubuntu)
            local codename="${OS_CODENAME}"
            [[ -z "$codename" ]] && return 1
            if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
                cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $url/ubuntu/
Suites: $codename $codename-updates $codename-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
            else
                cat > /etc/apt/sources.list <<EOF
deb $url/ubuntu/ $codename main restricted universe multiverse
deb $url/ubuntu/ $codename-updates main restricted universe multiverse
deb $url/ubuntu/ $codename-security main restricted universe multiverse
EOF
            fi ;;
        debian)
            cat > /etc/apt/sources.list <<EOF
deb $url/debian/ ${OS_CODENAME:-bookworm} main contrib non-free non-free-firmware
EOF
            ;;
        *) return 1 ;;
    esac
    return 0
}

ensure_package_source() {
    log_section "检查系统包源"
    log_step_begin "包源检查"

    case "$PACKAGE_SOURCE_MODE" in
        skip)
            log_info "PACKAGE_SOURCE_MODE=skip，跳过。"
            log_step_end "包源检查"; return 0 ;;
        default)
            apply_default_source || { record_error "应用默认源失败"; log_step_end "包源检查"; return 1; }
            test_package_source && { log_info "✅ 默认源可用"; log_step_end "包源检查"; return 0; }
            record_error "默认源不可用"; log_step_end "包源检查"; return 1 ;;
        custom)
            if apply_custom_source && test_package_source; then
                log_info "✅ 自定义源可用"; log_step_end "包源检查"; return 0
            fi
            record_error "自定义源不可用"; log_step_end "包源检查"; return 1 ;;
    esac

    # auto
    log_info "检测系统包源可用性..."
    test_package_source && { log_info "✅ 包源可用"; log_step_end "包源检查"; return 0; }

    log_warn "包源不可用或超时"
    record_warning "系统包源不可用"

    if [[ "$AUTO_YES" != "true" ]]; then
        if ask_yes_no "是否自动应用内置默认源（阿里云）？(yes/no，默认 yes): " "yes"; then
            if apply_default_source && test_package_source; then
                log_info "✅ 默认源可用"; log_step_end "包源检查"; return 0
            fi
            record_error "默认源仍不可用"
        fi
        PACKAGE_SOURCE_URL=""; PACKAGE_SOURCE_FILE=""
        if ask_yes_no "是否使用自定义源？(yes/no，默认 no): " "no"; then
            if apply_custom_source && test_package_source; then
                log_info "✅ 自定义源可用"; log_step_end "包源检查"; return 0
            fi
            record_error "自定义源不可用"
        fi
        if ! ask_yes_no "包源仍未修复，是否继续？(yes/no，默认 yes): " "yes"; then
            log_error "用户选择终止"; log_step_end "包源检查"; exit 1
        fi
        log_step_end "包源检查"; return 0
    fi

    # 全自动
    if apply_default_source && test_package_source; then
        log_info "✅ 已自动切换到默认源"
        log_step_end "包源检查"; return 0
    fi
    record_error "包源无法自动修复，后续安装可能失败"
    log_step_end "包源检查"
    return 1
}

# ============================================================
# 第一步：SSH 端口修改
# ============================================================
change_ssh_port() {
    log_section "第一步：SSH 端口修改"
    log_step_begin "SSH 端口修改"

    if [[ "$SSH_CHANGE" != "true" ]]; then
        log_info "SSH_CHANGE=false，跳过。"
        log_step_end "SSH 端口修改"; return 0
    fi

    local new_port="$SSH_PORT"
    if [[ -z "$new_port" ]]; then
        if [[ "$AUTO_YES" == "true" || "$USE_CONFIG" == "true" ]]; then
            record_error "SSH_CHANGE=true 但 SSH_PORT 未配置"
            log_step_end "SSH 端口修改"; return 1
        fi
        while true; do
            new_port="$(ask_input "请输入新 SSH 端口（1024-65535）: " "")"
            [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1024 && new_port <= 65535 )) && break
            log_warn "端口无效。"
        done
    fi

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1024 || new_port > 65535 )); then
        record_error "SSH_PORT 无效: $new_port"
        log_step_end "SSH 端口修改"; return 1
    fi

    log_info "目标 SSH 端口: $new_port"

    local sshd_config="/etc/ssh/sshd_config"
    [[ -f "$sshd_config" ]] || { record_error "未找到 $sshd_config"; log_step_end "SSH 端口修改"; return 1; }

    if grep -qE "^\s*Port\s+${new_port}\s*$" "$sshd_config"; then
        log_info "SSH 端口已是 $new_port，无需修改。"
        log_step_end "SSH 端口修改"; return 0
    fi

    if ss -tlnp 2>/dev/null | grep -q ":${new_port} "; then
        record_warning "端口 $new_port 已被其他进程占用"
    fi

    # 备份并修改
    local backup
    backup="$(backup_file "$sshd_config")"
    sed -i '/^#\?Port[[:space:]]/d' "$sshd_config"
    echo "Port $new_port" >> "$sshd_config"
    log_file_snapshot "$sshd_config" "修改后"

    # 防火墙放行
    if ! firewall_open_port "$new_port" "tcp" "SSH 新端口"; then
        record_error "防火墙放行 $new_port 失败"
        local do_rollback=true
        if [[ "$AUTO_YES" != "true" ]]; then
            if ! ask_yes_no "  是否回退 SSH 端口修改？(yes/no，默认 yes): " "yes"; then
                do_rollback=false
            fi
        fi
        if [[ "$do_rollback" == "true" ]]; then
            cp "$backup" "$sshd_config"
            log_file_snapshot "$sshd_config" "回退后"
            log_error "已回退 SSH 配置"
            log_step_end "SSH 端口修改"; return 1
        fi
        log_warn "用户选择不回退，继续执行"
    fi

    # SELinux
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
        if ! command -v semanage &>/dev/null; then
            if [[ "$PKG_MGR" == "apt" ]]; then
                run_cmd "安装 policycoreutils" apt-get install -y -qq policycoreutils-python-utils || true
            else
                run_cmd "安装 policycoreutils" $PKG_MGR install -y -q policycoreutils-python-utils || true
            fi
        fi
        if command -v semanage &>/dev/null; then
            if ! semanage port -l 2>/dev/null | grep -q "ssh_port_t.*${new_port}"; then
                semanage port -a -t ssh_port_t -p tcp "$new_port" 2>/dev/null \
                    || record_warning "SELinux 端口策略添加失败"
            fi
        fi
    fi

    # 重启 SSH
    log_info "重启 SSH 服务..."
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then systemctl restart ssh.socket
    elif systemctl is-active --quiet sshd 2>/dev/null; then systemctl restart sshd
    elif systemctl is-active --quiet ssh 2>/dev/null; then systemctl restart ssh; fi

    sleep 2

    # 验证监听
    if ! ss -tlnp 2>/dev/null | grep -q ":${new_port} "; then
        record_error "新端口 $new_port 未监听"
        local do_rollback=true
        if [[ "$AUTO_YES" != "true" ]]; then
            if ! ask_yes_no "  是否回退 SSH 配置？(yes/no，默认 yes): " "yes"; then
                do_rollback=false
            fi
        fi
        if [[ "$do_rollback" == "true" ]]; then
            cp "$backup" "$sshd_config"
            log_file_snapshot "$sshd_config" "回退后"
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
            log_error "已回退 SSH 配置"
            log_step_end "SSH 端口修改"; return 1
        fi
        log_warn "用户选择不回退，继续执行"
    else
        log_info "✅ SSH 端口已切换到 $new_port 并成功监听"
    fi

    # 关闭 22
    if [[ "$SSH_CLOSE_OLD_PORT" == "true" ]]; then
        log_info "关闭旧端口 22..."
        firewall_close_port "22" "tcp" || record_warning "关闭 22 端口失败"
    else
        log_info "SSH_CLOSE_OLD_PORT=false，保留 22"
    fi

    log_step_end "SSH 端口修改"
}

# ============================================================
# 第二步：Docker
# ============================================================
ensure_docker_running() {
    local svc_state enabled_state
    svc_state="$(systemctl is-active docker 2>/dev/null || true)"
    enabled_state="$(systemctl is-enabled docker 2>/dev/null || true)"
    if [[ "$svc_state" == "active" && "$enabled_state" == "enabled" ]]; then
        log_info "Docker 服务已运行且已自启"
        return 0
    fi
    log_info "Docker 服务状态: is-active=$svc_state, is-enabled=$enabled_state"
    [[ "$enabled_state" != "enabled" ]] && run_cmd "启用 docker 自启" systemctl enable docker
    [[ "$svc_state" != "active" ]] && run_cmd "启动 docker" systemctl start docker
}

_validate_json() {
    local f="$1"
    if command -v jq &>/dev/null; then jq empty "$f" >/dev/null 2>&1 && return 0 || return 1
    elif command -v python3 &>/dev/null; then python3 -c "import json; json.load(open('$f'))" >/dev/null 2>&1 && return 0 || return 1
    fi
    return 0
}

_write_daemon_json() {
    local config_file="$1"
    local mirrors_json="" first=true
    for m in "${DOCKER_MIRRORS[@]}"; do
        if [[ "$first" == "true" ]]; then mirrors_json="\"$m\""; first=false
        else mirrors_json="$mirrors_json, \"$m\""; fi
    done

    local live_restore_line=""
    [[ "$DOCKER_LIVE_RESTORE" == "true" ]] && live_restore_line=', "live-restore": true'

    cat > "$config_file" <<EOF
{
  "registry-mirrors": [$mirrors_json],
  "log-driver": "json-file",
  "log-opts": { "max-size": "$DOCKER_LOG_MAX_SIZE", "max-file": "$DOCKER_LOG_MAX_FILE" }$live_restore_line
}
EOF

    _validate_json "$config_file" || { log_error "JSON 不合法"; return 1; }
    log_file_snapshot "$config_file" "写入后"
    return 0
}

write_daemon_json() {
    local config_file="/etc/docker/daemon.json"
    mkdir -p /etc/docker

    if [[ -f "$config_file" ]]; then
        log_info "检测到已存在的 $config_file"
        cat "$config_file" | sed 's/^/    /' | while read -r l; do log_info "$l"; done

        case "$DOCKER_DAEMON_MODE" in
            keep|skip|auto)
                log_info "DOCKER_DAEMON_MODE=$DOCKER_DAEMON_MODE，保留现有配置。"
                return 1 ;;
            default)
                local default_act="no"
                [[ "$AUTO_YES" == "true" ]] && default_act="yes"
                if ask_yes_no "是否用脚本推荐配置覆盖？(yes/no，默认 $default_act): " "$default_act"; then
                    backup_file "$config_file" >/dev/null
                    _write_daemon_json "$config_file" && return 0
                fi
                return 1 ;;
        esac
        return 1
    fi

    case "$DOCKER_DAEMON_MODE" in
        skip|keep)
            log_info "DOCKER_DAEMON_MODE=$DOCKER_DAEMON_MODE，不创建 daemon.json"
            return 1 ;;
        auto|default)
            _write_daemon_json "$config_file" && return 0
            return 1 ;;
    esac
    return 1
}

install_docker() {
    log_section "第二步：安装 Docker"
    log_step_begin "Docker 安装"

    if [[ "$DOCKER_INSTALL" != "true" ]]; then
        log_info "DOCKER_INSTALL=false，跳过。"
        log_step_end "Docker 安装"; return 0
    fi

    if command -v docker &>/dev/null; then
        log_info "Docker 已安装: $(docker --version)"
        ensure_docker_running

        if write_daemon_json; then
            run_cmd "daemon-reload" systemctl daemon-reload
            run_cmd "重启 docker" systemctl restart docker
        else
            log_info "daemon.json 未变更，不重启"
        fi

        log_step_end "Docker 安装"; return 0
    fi

    log_info "正在安装 Docker..."
    case "$PKG_MGR" in
        apt) run_cmd "apt-get update" apt-get update -qq || true ;;
    esac

    if [[ "$PKG_MGR" == "apt" ]]; then
        log_info "使用 Docker 官方脚本（阿里云镜像）..."
        if ! curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun 2>&1 | tee -a "$LOG_FILE"; then
            record_error "Docker 官方脚本执行失败"
            local do_retry=false
            if [[ "$AUTO_YES" == "true" ]]; then
                do_retry=true
            elif ask_yes_no "是否尝试用 Docker 官方源重试？(yes/no，默认 no): " "no"; then
                do_retry=true
            fi
            if [[ "$do_retry" == "true" ]]; then
                curl -fsSL https://get.docker.com | bash -s docker 2>&1 | tee -a "$LOG_FILE" || {
                    record_error "Docker 安装失败"
                    log_step_end "Docker 安装"; return 1
                }
            else
                log_step_end "Docker 安装"; return 1
            fi
        fi
    else
        run_cmd "安装 yum-utils" $PKG_MGR install -y -q yum-utils || true
        run_cmd "添加 docker-ce repo" yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo || true

        if ! timeout 40 $PKG_MGR -q makecache &>/dev/null; then
            record_warning "Docker 源不可达"
            local do_switch=false
            if [[ "$AUTO_YES" == "true" ]]; then
                do_switch=true
            elif ask_yes_no "是否改用 Docker 官方源？(yes/no，默认 no): " "no"; then
                do_switch=true
            fi
            if [[ "$do_switch" == "true" ]]; then
                rm -f /etc/yum.repos.d/docker-ce.repo
                run_cmd "添加 Docker 官方 repo" yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
            fi
        fi

        if ! $PKG_MGR install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>&1 | tee -a "$LOG_FILE"; then
            record_error "Docker 安装失败"
            log_step_end "Docker 安装"; return 1
        fi
    fi

    ensure_docker_running

    if write_daemon_json; then
        run_cmd "daemon-reload" systemctl daemon-reload
        run_cmd "重启 docker" systemctl restart docker
    fi

    log_info "Docker: $(docker --version 2>/dev/null || echo '未知')"

    if ! docker compose version &>/dev/null; then
        log_info "安装 Compose 插件..."
        if [[ "$PKG_MGR" == "apt" ]]; then
            run_cmd "安装 docker-compose-plugin" apt-get install -y -qq docker-compose-plugin || true
        else
            run_cmd "安装 docker-compose-plugin" $PKG_MGR install -y -q docker-compose-plugin || true
        fi
    fi
    log_info "Compose: $(docker compose version 2>/dev/null || echo '未安装')"

    log_step_end "Docker 安装"
}

# ============================================================
# 第三步：Compose 批量部署
# ============================================================
deploy_compose_stacks() {
    log_section "第三步：批量部署 Compose 项目"
    log_step_begin "Compose 批量部署"

    if [[ "$COMPOSE_DEPLOY" != "true" ]]; then
        log_info "COMPOSE_DEPLOY=false，跳过。"
        log_step_end "Compose 批量部署"; return 0
    fi

    local yaml_dir="$COMPOSE_YAML_DIR"
    if [[ -z "$yaml_dir" ]]; then
        if [[ "$AUTO_YES" == "true" || "$USE_CONFIG" == "true" ]]; then
            record_error "COMPOSE_YAML_DIR 未配置"
            log_step_end "Compose 批量部署"; return 1
        fi
        yaml_dir="$(ask_input "YAML 目录（默认当前目录）: " "$(pwd)")"
    fi
    yaml_dir="${yaml_dir:-$(pwd)}"

    if [[ ! -d "$yaml_dir" ]]; then
        record_error "目录不存在: $yaml_dir"
        log_step_end "Compose 批量部署"; return 1
    fi
    log_info "YAML 目录: $yaml_dir"

    local deploy_mode="$COMPOSE_MODE"
    case "$deploy_mode" in
        A|a|1) deploy_mode="1" ;;
        B|b|2) deploy_mode="2" ;;
        *) deploy_mode="1" ;;
    esac
    log_info "方案: $([[ "$deploy_mode" == "1" ]] && echo "A（保留原文件名）" || echo "B（重命名）")"

    local COMPOSE_CMD=""
    if docker compose version &>/dev/null; then COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then COMPOSE_CMD="docker-compose"
    else
        record_error "未找到 docker compose 命令"
        log_step_end "Compose 批量部署"; return 1
    fi

    local yaml_files=()
    while IFS= read -r -d '' f; do yaml_files+=("$f"); done < <(find "$yaml_dir" -maxdepth 1 \
        \( -name "docker-compose_*.yml" -o -name "docker-compose_*.yaml" \) -print0 2>/dev/null)

    if [[ ${#yaml_files[@]} -eq 0 ]]; then
        log_warn "未找到符合规则的 YAML 文件"
        log_step_end "Compose 批量部署"; return 0
    fi

    log_info "发现 ${#yaml_files[@]} 个 YAML 文件"

    local idx=0 total=${#yaml_files[@]} success=0 fail=0 skip=0
    local stop_all=false

    for yaml_file in "${yaml_files[@]}"; do
        [[ "$stop_all" == "true" ]] && { skip=$((skip+1)); continue; }

        idx=$((idx+1))
        log_section "处理项目 [$idx/$total]"

        local base_name no_ext dir_name target_dir
        base_name="$(basename "$yaml_file")"
        no_ext="${base_name%.*}"
        dir_name="${no_ext#docker-compose_}"

        if [[ -z "$dir_name" || "$dir_name" == "$no_ext" ]]; then
            record_warning "跳过命名不符合规则: $base_name"
            skip=$((skip+1)); continue
        fi

        target_dir="$yaml_dir/$dir_name"
        log_info "处理: $base_name → $target_dir"
        mkdir -p "$target_dir"

        if [[ "$deploy_mode" == "1" ]]; then
            cp -f "$yaml_file" "$target_dir/$base_name"
            log_info "  已复制 $base_name"
        else
            cp -f "$yaml_file" "$target_dir/docker-compose.yml"
            log_info "  已复制 $base_name → docker-compose.yml"
        fi

        if [[ -f "$yaml_dir/$dir_name.env" ]]; then
            cp -f "$yaml_dir/$dir_name.env" "$target_dir/.env"
            log_info "  已复制 $dir_name.env → .env"
        else
            log_info "  无配套 $dir_name.env"
        fi

        local deploy_result=0
        (
            cd "$target_dir" || exit 1
            local yaml_arg
            [[ "$deploy_mode" == "1" ]] && yaml_arg="$base_name" || yaml_arg="docker-compose.yml"

            if ! $COMPOSE_CMD -p "$dir_name" -f "$yaml_arg" config >/dev/null 2>&1; then
                $COMPOSE_CMD -p "$dir_name" -f "$yaml_arg" config 2>&1 | sed 's/^/      /' | tee -a "$LOG_FILE"
                exit 10
            fi
            log_info "  ✅ YAML 校验通过"

            local pull_rc=0
            if [[ -t 1 ]]; then
                $COMPOSE_CMD --progress=auto -p "$dir_name" -f "$yaml_arg" pull 2>&1 | tee -a "$LOG_FILE" || pull_rc=$?
            else
                $COMPOSE_CMD --progress=plain -p "$dir_name" -f "$yaml_arg" pull 2>&1 | tee -a "$LOG_FILE" || pull_rc=$?
            fi
            [[ $pull_rc -ne 0 ]] && log_warn "  镜像拉取有错误，继续尝试启动"

            local up_rc=0
            $COMPOSE_CMD --progress=plain -p "$dir_name" -f "$yaml_arg" up -d 2>&1 | tee -a "$LOG_FILE" || up_rc=$?

            if [[ $up_rc -eq 0 ]]; then
                log_info "  容器状态："
                $COMPOSE_CMD -p "$dir_name" -f "$yaml_arg" ps 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE" || true
            fi
            exit "$up_rc"
        ) && deploy_result=0 || deploy_result=$?

        if [[ $deploy_result -eq 0 ]]; then
            log_info "  ✅ $dir_name 部署成功"
            success=$((success+1))
        elif [[ $deploy_result -eq 10 ]]; then
            record_error "项目 $dir_name：YAML 语法校验失败"
            fail=$((fail+1))
            # 半自动：询问；全自动：继续
            if [[ "$AUTO_YES" != "true" && "$USE_CONFIG" == "true" ]]; then
                if ! ask_yes_no "  是否继续处理其他项目？(yes/no，默认 yes): " "yes"; then
                    log_warn "用户选择停止处理剩余项目"
                    stop_all=true
                fi
            fi
        else
            record_error "项目 $dir_name：容器启动失败（rc=$deploy_result）"
            fail=$((fail+1))
        fi
    done

    log_section "部署汇总"
    log_info "总项目=$total, 成功=$success, 失败=$fail, 跳过=$skip"

    log_info "当前运行的 Compose 项目："
    $COMPOSE_CMD ps 2>&1 | sed 's/^/  /' | tee -a "$LOG_FILE" || true

    log_step_end "Compose 批量部署"
}

# ============================================================
# 主流程
# ============================================================
main() {
    {
        echo "============================================================"
        echo " 服务器初始化 - 会话开始"
        echo " 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo " 进程 PID: $$"
        echo " 日志文件: $LOG_FILE"
        echo "============================================================"
    } >> "$LOG_FILE"

    log_section "服务器初始化脚本"
    log_info "日志文件: $LOG_FILE"
    if [[ "$AUTO_YES" == "true" ]]; then log_info "运行模式: 全自动"
    elif [[ "$USE_CONFIG" == "true" ]]; then log_info "运行模式: 半自动（$CONFIG_FILE）"
    else log_info "运行模式: 完全交互"; fi

    collect_env_info
    detect_os
    detect_firewall

    change_ssh_port || true

    ensure_package_source || true
    install_docker || true

    if ! docker info &>/dev/null; then
        record_error "Docker 不可用，跳过 Compose 部署"
    else
        deploy_compose_stacks || true
    fi

    log_section "执行完毕"
    log_info "Docker:  $(docker --version 2>/dev/null || echo '未安装')"
    log_info "Compose: $(docker compose version 2>/dev/null || echo '未安装')"
    log_info "日志: $LOG_FILE"
    log_warn "免 sudo 使用 Docker: usermod -aG docker \$USER && newgrp docker"

    print_final_summary || exit 1
}

# ---------- trap ----------
_on_err() {
    local exit_code=$? line_no="$1"
    record_error "脚本执行出错: 第 ${line_no} 行，退出码 ${exit_code}"
    exit "$exit_code"
}
trap '_on_err $LINENO' ERR

_on_exit() {
    local exit_code=$?
    {
        echo "============================================================"
        echo " 会话结束 $(date '+%Y-%m-%d %H:%M:%S')  退出码=$exit_code"
        echo "============================================================"
    } >> "$LOG_FILE"
}
trap '_on_exit' EXIT

if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 权限运行。"
    exit 1
fi

if [[ "${DEBUG:-0}" == "1" ]]; then
    exec 19>>"$LOG_FILE"
    BASH_XTRACEFD=19
    set -x
    log_info "DEBUG 模式已开启"
fi

main "$@"
