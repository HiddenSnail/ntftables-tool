#!/usr/bin/env bash
#===============================================================================
# nftables-tool.sh - nftables IP 白名单端口访问控制工具
#
# 用法:
#   ./nftables-tool.sh install                    检测并安装 nftables
#   ./nftables-tool.sh init                       初始化表结构（input 默认 accept，零干扰）
#   ./nftables-tool.sh template list               列出可用模板
#   ./nftables-tool.sh template show <name>         查看模板详情
#   ./nftables-tool.sh allow <template> <ip[/mask]> 白名单 IP 访问指定中间件
#   ./nftables-tool.sh deny <template> <ip[/mask]>  移除白名单
#   ./nftables-tool.sh list [template]             列出白名单规则
#   ./nftables-tool.sh status                      显示运行状态
#   ./nftables-tool.sh save                        持久化当前规则
#   ./nftables-tool.sh reset                       清除本工具所有规则
#===============================================================================

set -euo pipefail

# ---- 脚本目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 加载库 ----
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/installer.sh
source "${SCRIPT_DIR}/lib/installer.sh"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"

# ---- 帮助信息 ----
show_usage() {
    cat << 'EOF'
nftables-tool — nftables IP 白名单端口访问控制工具

用法:
  nftables-tool.sh <command> [args...]

命令:
  install                        检测并自动安装 nftables（需要 root）
  init                           初始化表结构（input 默认 accept，最小干扰，需要 root）

  template list                  列出所有可用中间件模板
  template show <name>           查看指定模板的端口与协议信息

  allow <template> <ip[/mask]>   允许指定 IP 段访问模板对应的端口（需要 root）
  deny  <template> <ip[/mask]>   移除指定 IP 段的白名单授权（需要 root）

  list [template]                列出白名单规则（可指定模板过滤）
  status                         显示 nftables 运行状态与本工具规则概况
  save                           将当前规则持久化到 /etc/nftables.conf（需要 root）
  reset                          清除本工具创建的所有规则（需要 root）

示例:
  sudo ./nftables-tool.sh install
  sudo ./nftables-tool.sh init
  ./nftables-tool.sh template list
  sudo ./nftables-tool.sh allow mongodb 10.0.1.0/24
  sudo ./nftables-tool.sh allow redis 192.168.0.5
  sudo ./nftables-tool.sh deny mongodb 10.0.1.0/24
  ./nftables-tool.sh list

EOF
}

# ---- 命令路由 ----
main() {
    if [ $# -eq 0 ]; then
        show_usage
        exit 0
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        install)
            ensure_nftables
            ;;

        init)
            cmd_init
            ;;

        template)
            cmd_template "$@"
            ;;

        allow)
            if [ $# -lt 2 ]; then
                log_error "用法: nftables-tool.sh allow <template> <ip[/mask]>"
                exit 1
            fi
            cmd_allow "$1" "$2"
            ;;

        deny)
            if [ $# -lt 2 ]; then
                log_error "用法: nftables-tool.sh deny <template> <ip[/mask]>"
                exit 1
            fi
            cmd_deny "$1" "$2"
            ;;

        list)
            cmd_list "${1:-}"
            ;;

        status)
            cmd_status
            ;;

        save)
            cmd_save
            ;;

        reset)
            cmd_reset
            ;;

        -h|--help|help)
            show_usage
            ;;

        *)
            log_error "未知命令: $cmd"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
