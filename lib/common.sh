#!/usr/bin/env bash
#===============================================================================
# common.sh - 通用函数库
# 提供：root 权限检查、OS 检测、彩色日志、nft 命令检测
#===============================================================================

set -euo pipefail

# ---- 颜色定义 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# ---- 日志函数 ----
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

# ---- 脚本目录定位 ----
# 确保无论从哪里调用，SCRIPT_DIR 都指向脚本所在目录
if [ -z "${SCRIPT_DIR:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# ---- Dry-run / 测试模式 ----
# 环境变量 NFT_DRY_RUN=true 或 --dry-run 参数启用
# 启用后所有 nft 命令仅打印不执行
NFT_DRY_RUN="${NFT_DRY_RUN:-false}"

# ---- nft 命令包装器 ----
# 所有 nft 调用自动经过此函数，支持 dry-run 和 mock 注入。
# 测试时设置 NFT_MOCK_DIR 指向 mock nft 脚本所在目录，
# 该目录下的 nft 脚本会代替系统 nft 执行。
nft() {
    # Dry-run 模式优先：只打印，不执行（包括不走 mock）
    if [ "$NFT_DRY_RUN" = "true" ]; then
        echo "[DRY RUN] nft $*" >&2
        return 0
    fi

    # 测试 mock 模式
    if [ -n "${NFT_MOCK_DIR:-}" ] && [ -x "${NFT_MOCK_DIR}/nft" ]; then
        "${NFT_MOCK_DIR}/nft" "$@"
        return $?
    fi

    # 正常模式：调用真实 nft
    command nft "$@"
}

# 直接读取 nftables 规则集（绕过 dry-run，供 save 命令使用）
_nft_list_ruleset_raw() {
    if [ "$NFT_DRY_RUN" = "true" ]; then
        echo "[DRY RUN] nft list ruleset" >&2
    elif [ -n "${NFT_MOCK_DIR:-}" ] && [ -x "${NFT_MOCK_DIR}/nft" ]; then
        "${NFT_MOCK_DIR}/nft" list ruleset
    else
        command nft list ruleset
    fi
}

# ---- 权限检查 ----
check_root() {
    # 测试环境跳过 root 检查
    if [ "${NFT_SKIP_ROOT_CHECK:-}" = "true" ]; then
        return 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此操作需要 root 权限，请使用 sudo 运行。"
        exit 1
    fi
}

# ---- OS 检测 ----
# 返回包管理器类型：apt / dnf / yum / pacman / zypper / unknown
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)
                echo "apt"
                ;;
            rhel|centos|fedora|rocky|almalinux|ol|amzn)
                if command -v dnf &>/dev/null; then
                    echo "dnf"
                else
                    echo "yum"
                fi
                ;;
            arch|manjaro|endeavouros)
                echo "pacman"
                ;;
            opensuse*|sles)
                echo "zypper"
                ;;
            *)
                echo "unknown"
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        echo "apt"
    elif [ -f /etc/redhat-release ]; then
        if command -v dnf &>/dev/null; then
            echo "dnf"
        else
            echo "yum"
        fi
    elif [ -f /etc/arch-release ]; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# ---- nft 命令检测 ----
nft_available() {
    # 注意：不可用 command -v nft，那会找到同文件中定义的 nft() shell 函数
    [ "$NFT_DRY_RUN" = "true" ] || [ -n "${NFT_MOCK_DIR:-}" ] || type -P nft &>/dev/null
}

# ---- nftables 服务检测 ----
nftables_service_active() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active --quiet nftables 2>/dev/null
    else
        return 1
    fi
}

# ---- 检查工具表是否存在 ----
nftables_tool_table_exists() {
    nft list tables 2>/dev/null | grep -q "inet nftables-tool"
}

# ---- 参数校验 ----
validate_template_name() {
    local name="$1"
    local tmpl_file="${SCRIPT_DIR}/templates/${name}.conf"
    if [ ! -f "$tmpl_file" ]; then
        log_error "模板 '$name' 不存在。"
        log_info "可用模板列表："
        list_available_templates
        exit 1
    fi
}

validate_ip_range() {
    local ip="$1"
    # 简单的 IPv4 CIDR 格式校验
    if ! echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; then
        log_error "无效的 IP 地址格式: $ip（期望格式：192.168.1.0/24 或 10.0.0.5）"
        exit 1
    fi
}

# ---- 列出所有可用模板名 ----
list_available_templates() {
    local tmpl_dir="${SCRIPT_DIR}/templates"
    if [ -d "$tmpl_dir" ]; then
        for f in "$tmpl_dir"/*.conf; do
            [ -f "$f" ] || continue
            local name
            name="$(basename "$f" .conf)"
            # 跳过 example 文件
            [[ "$name" == *example* ]] && continue
            # 读取模板 NAME（兼容 macOS BSD grep，不使用 -P）
            local display_name
            display_name=$(grep '^NAME=' "$f" 2>/dev/null | sed 's/^NAME="//;s/"$//' || echo "$name")
            echo "  - ${name}  (${display_name})"
        done
    fi
}

# ---- 加载模板文件 ----
load_template() {
    local name="$1"
    local tmpl_file="${SCRIPT_DIR}/templates/${name}.conf"

    if [ ! -f "$tmpl_file" ]; then
        log_error "模板文件不存在: $tmpl_file"
        return 1
    fi

    # 清除可能残留的变量
    unset NAME DESCRIPTION PORTS PROTOCOL

    # shellcheck disable=SC1090
    source "$tmpl_file"

    # 校验必要字段
    if [ -z "${NAME:-}" ]; then
        log_error "模板 '$name' 缺少 NAME 字段。"
        return 1
    fi
    if [ -z "${PORTS:-}" ]; then
        log_error "模板 '$name' 缺少 PORTS 字段。"
        return 1
    fi

    return 0
}
