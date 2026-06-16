#!/usr/bin/env bash
#===============================================================================
# installer.sh - nftables 检测与自动安装
#===============================================================================

# 依赖 common.sh，由主入口 source 引入

# ---- 确保 nftables 可用 ----
ensure_nftables() {
    check_root

    if nft_available; then
        log_info "nftables 已安装: $(nft --version 2>&1 | head -1)"
        # 确保服务已启用
        _enable_nftables_service
        return 0
    fi

    log_warn "未检测到 nftables，正在自动安装..."

    local pkg_manager
    pkg_manager=$(detect_os)

    case "$pkg_manager" in
        apt)
            log_step "检测到 Debian/Ubuntu 系列，使用 apt 安装..."
            apt-get update -qq
            apt-get install -y -qq nftables
            ;;
        dnf)
            log_step "检测到 RHEL/Fedora 系列，使用 dnf 安装..."
            dnf install -y nftables
            ;;
        yum)
            log_step "检测到 RHEL/CentOS 系列，使用 yum 安装..."
            yum install -y nftables
            ;;
        pacman)
            log_step "检测到 Arch 系列，使用 pacman 安装..."
            pacman -S --noconfirm nftables
            ;;
        zypper)
            log_step "检测到 openSUSE 系列，使用 zypper 安装..."
            zypper install -y nftables
            ;;
        *)
            log_error "无法识别当前操作系统，请手动安装 nftables。"
            log_info "Debian/Ubuntu:  apt install nftables"
            log_info "RHEL/CentOS:    yum install nftables"
            log_info "Fedora:         dnf install nftables"
            log_info "Arch:           pacman -S nftables"
            exit 1
            ;;
    esac

    # 验证安装结果
    if nft_available; then
        log_info "nftables 安装成功: $(nft --version 2>&1 | head -1)"
        _enable_nftables_service
    else
        log_error "nftables 安装失败，请检查包管理器配置后手动安装。"
        exit 1
    fi
}

# ---- 启用并启动 nftables systemd 服务 ----
_enable_nftables_service() {
    if ! command -v systemctl &>/dev/null; then
        log_warn "未检测到 systemd，请手动启动 nftables 服务。"
        return 0
    fi

    if ! systemctl is-enabled --quiet nftables 2>/dev/null; then
        log_step "启用 nftables 开机自启动..."
        systemctl enable nftables 2>/dev/null || log_warn "无法启用 nftables 开机自启。"
    fi

    if ! systemctl is-active --quiet nftables 2>/dev/null; then
        log_step "启动 nftables 服务..."
        systemctl start nftables 2>/dev/null || log_warn "无法启动 nftables 服务，将尝试直接加载规则。"
    else
        log_info "nftables 服务已在运行。"
    fi
}
