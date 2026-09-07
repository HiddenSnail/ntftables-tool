#!/usr/bin/env bash
#===============================================================================
# core.sh - nftables 规则核心管理
# 提供：init, allow, deny, purge, list, status, save, reset
#===============================================================================

# 依赖 common.sh，由主入口 source 引入

readonly TABLE="inet nftables-tool"

# =============================================================================
# 内部辅助函数
# =============================================================================

# 检查表是否存在
_table_exists() {
    nft list tables 2>/dev/null | grep -qF "$TABLE"
}

# 检查链是否存在
_chain_exists() {
    local chain="$1"
    nft list chain "$TABLE" "$chain" &>/dev/null
}

# 检查 set 是否存在
_set_exists() {
    local set_name="$1"
    nft list set "$TABLE" "$set_name" &>/dev/null
}

# 将模板端口数组转为 nftables 集合格式 { 80, 443 }
_ports_to_nft_set() {
    local ports=("$@")
    local result="{ "
    local first=true
    for p in "${ports[@]}"; do
        if $first; then
            result+="$p"
            first=false
        else
            result+=", $p"
        fi
    done
    result+=" }"
    echo "$result"
}

# 从 nft 链中提取已存在的 handle 号（用于删除规则时使用）
_get_rule_handles() {
    local chain="$1"
    local pattern="$2"
    nft -a list chain "$TABLE" "$chain" 2>/dev/null | grep "$pattern" | awk '{print $NF}' || true
}

# ---- IPv4 / CIDR 工具函数（白名单包含关系判断用）----

# 点分十进制 IPv4 -> 32 位无符号整数
_ipv4_to_int() {
    local ip="$1" o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}

# 前缀长度 -> 子网掩码（32 位无符号整数）
_prefix_mask() {
    local prefix="$1"
    if [ "$prefix" -le 0 ]; then
        echo 0
    elif [ "$prefix" -ge 32 ]; then
        echo 4294967295
    else
        echo $(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
}

# 解析 "ip" 或 "ip/prefix"，输出起始/结束地址整数（start end）
_cidr_bounds() {
    local input="$1" ip prefix ip_int mask start size
    if [[ "$input" == */* ]]; then
        ip="${input%/*}"
        prefix="${input#*/}"
        [ "$prefix" -le 32 ] || prefix=32
    else
        ip="$input"
        prefix=32
    fi
    # 注意：算术表达式 $(( )) 内不能直接调用 shell 函数，需先取到值再参与计算
    ip_int=$(_ipv4_to_int "$ip")
    mask=$(_prefix_mask "$prefix")
    start=$(( ip_int & mask ))
    size=$(( 1 << (32 - prefix) ))
    echo "$start $(( start + size - 1 ))"
}

# 从集合中提取现有元素（兼容多行 elements 输出与单 IP 主机）
_get_set_elements() {
    local set_name="$1"
    nft list set "$TABLE" "$set_name" 2>/dev/null \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' \
        | sort -u
}

# 从集合输出中提取 elements 块内的全部元素，每行一个。
# 真实 nft 在元素较多/较长时会把 elements 折成多行，仅 grep 首行会丢失续行元素，
# 故此处从 "elements = {" 到闭合 "}" 整块截取后再按逗号拆分。
_get_set_members() {
    local set_name="$1"
    # grep -v 输出会为末行补上换行（sed 会保留“无结尾换行”，导致 wc -l 少计 1）
    nft list set "$TABLE" "$set_name" 2>/dev/null \
        | sed -n '/elements = {/,/}/p' \
        | tr '\n' ' ' \
        | sed 's/.*elements = { *//; s/ *}.*//' \
        | tr ',' '\n' \
        | sed 's/^ *//; s/ *$//' \
        | grep -v '^$'
}

# 打印集合成员（每行一个 "prefix- item"），供 list/status/allow 展示；空集合打印 "(空)"
_print_set_members() {
    local prefix="$1"
    local set_name="$2"
    local items
    items=$(_get_set_members "$set_name")
    if [ -z "$items" ]; then
        echo "${prefix}(空)"
        return 0
    fi
    while read -r item; do
        [ -n "$item" ] && echo "${prefix}- $item"
    done <<< "$items"
}

# ---- 白名单包含关系检查 ----
# 在向 interval 集合 add element 前检查重叠关系，返回：
#   0 = 无冲突可添加；1 = 新网段覆盖已有元素，需先 deny（已打印提示）；
#   2 = 新网段已被现有元素覆盖（含完全相同），无需添加（已打印提示）
_check_whitelist_overlap() {
    local set_name="$1"
    local ip_range="$2"
    local template_name="$3"

    local new_start new_end
    read -r new_start new_end <<< "$(_cidr_bounds "$ip_range")"

    local covered_by=""
    local -a need_deny=()
    local elem e_start e_end

    while read -r elem; do
        [ -n "$elem" ] || continue
        read -r e_start e_end <<< "$(_cidr_bounds "$elem")"

        # 新网段完全被该现有元素覆盖（含重复添加相同网段）
        if [ "$new_start" -ge "$e_start" ] && [ "$new_end" -le "$e_end" ]; then
            covered_by="$elem"
        # 新网段覆盖了该现有元素
        elif [ "$new_start" -le "$e_start" ] && [ "$new_end" -ge "$e_end" ]; then
            need_deny+=("$elem")
        fi
    done <<< "$(_get_set_elements "$set_name")"

    if [ -n "$covered_by" ]; then
        log_info "网段 $ip_range 已包含在现有白名单元素 $covered_by 中，无需添加。"
        return 2
    fi

    if [ "${#need_deny[@]}" -gt 0 ]; then
        log_warn "网段 $ip_range 覆盖了以下现有白名单元素（nftables 区间集合不允许重叠）："
        local d
        for d in "${need_deny[@]}"; do
            log_warn "  请先执行: nftables-tool.sh deny ${template_name} ${d}"
        done
        log_warn "移除后再重新执行 allow 添加 $ip_range 即可（新网段已包含旧网段，无需再加回）。"
        return 1
    fi

    return 0
}

# 保存规则到 /etc/nftables.conf
_save_rules() {
    log_step "持久化规则到 /etc/nftables.conf..."
    # 测试/mock 模式下写入 /dev/null
    if [ -n "${NFT_MOCK_DIR:-}" ] || [ "$NFT_DRY_RUN" = "true" ]; then
        _nft_list_ruleset_raw > /dev/null 2>/dev/null || true
    else
        _nft_list_ruleset_raw > /etc/nftables.conf
    fi
    log_info "规则已保存。"
}

# =============================================================================
# cmd_init - 初始化表结构、安全基线、开机自启
# =============================================================================
cmd_init() {
    set +e; set +o pipefail
    check_root

    log_info "正在初始化 nftables 白名单工具..."

    # 1. 确保 nftables 已安装且服务已运行
    ensure_nftables

    # 2. 创建表（幂等：已存在则忽略错误）
    if ! _table_exists; then
        log_step "创建表 $TABLE ..."
        nft add table "$TABLE"
    else
        log_info "表 $TABLE 已存在，跳过创建。"
    fi

    # 3. 创建 input 链（policy accept：仅管理已声明端口，其余放行不干扰其他规则）
    if ! _chain_exists "input"; then
        log_step "创建 input 链（默认 ACCEPT）..."
        nft add chain "$TABLE" input \
            '{ type filter hook input priority 0; policy accept; }'
    else
        log_info "input 链已存在。"
    fi

    # 4. 创建 output 链（放行）
    if ! _chain_exists "output"; then
        log_step "创建 output 链..."
        nft add chain "$TABLE" output \
            '{ type filter hook output priority 0; policy accept; }'
    else
        log_info "output 链已存在。"
    fi

    # 5. 安全基线规则（可选，默认 policy accept 已保证最小干扰）
    #    _add_baseline_rules 仅在需要显式加固时手动调用
    #    ── 以下注释掉，不再自动添加 loopback/established/SSH/ICMP 规则 ──
    # _add_baseline_rules

    # 6. 持久化并确保开机自启
    _save_rules
    _enable_nftables_service

    log_info "============================================"
    log_info "初始化完成！表结构如下："
    log_info "============================================"
    nft list table "$TABLE" 2>/dev/null || true
}

_add_baseline_rules() {
    local chain_input="input"

    # 检查并添加 loopback 放行
    if ! nft list chain "$TABLE" "$chain_input" 2>/dev/null | grep -q "iif.*lo.*accept"; then
        nft add rule "$TABLE" "$chain_input" iif lo accept comment \"Allow loopback\"
    fi

    # 检查并添加 established/related 放行
    if ! nft list chain "$TABLE" "$chain_input" 2>/dev/null | grep -q "ct state.*established"; then
        nft add rule "$TABLE" "$chain_input" ct state established,related accept \
            comment \"Allow established connections\"
    fi

    # 检查并添加 ICMP 放行
    if ! nft list chain "$TABLE" "$chain_input" 2>/dev/null | grep -q "icmp type.*echo-request.*accept"; then
        nft add rule "$TABLE" "$chain_input" icmp type echo-request accept \
            comment \"Allow ping\"
        nft add rule "$TABLE" "$chain_input" icmpv6 type echo-request accept \
            comment \"Allow ping IPv6\"
    fi

    # 检查并添加 SSH 放行（防止 lockout）
    if ! nft list chain "$TABLE" "$chain_input" 2>/dev/null | grep -q "tcp dport 22 accept"; then
        nft add rule "$TABLE" "$chain_input" tcp dport 22 accept \
            comment \"Allow SSH\"
        log_info "SSH (22) 已默认放行，防止远程管理被锁。"
    fi
}

# =============================================================================
# cmd_template - 模板管理
# =============================================================================
cmd_template() {
    local sub="$1"
    shift || true

    case "$sub" in
        list)
            echo ""
            echo "可用模板:"
            echo "---------"
            list_available_templates
            echo ""
            echo "自定义模板: 将 .conf 文件放入 ${SCRIPT_DIR}/templates/ 目录即可。"
            echo "参考示例:   ${SCRIPT_DIR}/templates/custom.conf.example"
            ;;

        show)
            if [ $# -lt 1 ]; then
                log_error "用法: nftables-tool.sh template show <name>"
                exit 1
            fi
            local name="$1"
            validate_template_name "$name"
            load_template "$name"

            echo ""
            echo "模板详情: ${name}"
            echo "-----------------------------"
            echo "名称:     ${NAME}"
            echo "描述:     ${DESCRIPTION}"
            echo "协议:     ${PROTOCOL}"
            echo "端口:     ${PORTS[*]}"
            echo ""
            ;;

        *)
            log_error "用法: nftables-tool.sh template {list|show <name>}"
            exit 1
            ;;
    esac
}

# =============================================================================
# cmd_allow - 白名单 IP 访问指定模板的端口
# =============================================================================
cmd_allow() {
    local template_name="$1"
    local ip_range="$2"

    set +e; set +o pipefail

    check_root
    validate_template_name "$template_name"
    validate_ip_range "$ip_range"
    load_template "$template_name"

    local chain_name="${template_name}_chain"
    local set_name="${template_name}_allow"
    local port_set_name="${template_name}_ports"

    log_info "正在为 ${NAME}（${template_name}）添加白名单: $ip_range"

    # 确保表存在（dry-run 模式跳过检查）
    if [ "$NFT_DRY_RUN" != "true" ]; then
        if ! _table_exists; then
            log_error "表 $TABLE 不存在，请先执行 init。"
            log_info "运行: sudo ./nftables-tool.sh init"
            exit 1
        fi
    fi

    # 1. 创建中间件链（幂等）
    if ! _chain_exists "$chain_name"; then
        log_step "创建链: $chain_name"
        nft add chain "$TABLE" "$chain_name"
    fi

    # 2. 创建 IP 白名单 set（幂等）
    if ! _set_exists "$set_name"; then
        log_step "创建 IP 白名单集合: $set_name"
        nft add set "$TABLE" "$set_name" '{ type ipv4_addr; flags interval; }'
    fi

    # 3. 创建端口集合 + 添加端口元素 + 一条 set 引用跳转规则（幂等）
    if ! _set_exists "$port_set_name"; then
        log_step "创建端口集合: $port_set_name"
        nft add set "$TABLE" "$port_set_name" '{ type inet_service; flags interval; }'
    fi
    for port in "${PORTS[@]}"; do
        nft add element "$TABLE" "$port_set_name" "{ $port }" 2>/dev/null || true
    done
    if ! nft list chain "$TABLE" input 2>/dev/null | grep -q "dport @${port_set_name} jump $chain_name"; then
        log_step "添加跳转规则: input -> $chain_name (端口集 @${port_set_name})"
        nft add rule "$TABLE" input tcp dport "@${port_set_name}" jump "$chain_name" \
            comment "\"${NAME} whitelist\""
    fi

    # 4. 确保中间件链内有 accept + reject 规则（幂等）
    if ! nft list chain "$TABLE" "$chain_name" 2>/dev/null | grep -q "ip saddr @${set_name} accept"; then
        nft add rule "$TABLE" "$chain_name" ip saddr "@${set_name}" accept \
            comment "\"Allowed ${NAME} clients\""
    fi
    if ! nft list chain "$TABLE" "$chain_name" 2>/dev/null | grep -q "reject"; then
        nft add rule "$TABLE" "$chain_name" reject \
            comment "\"Reject other ${NAME} traffic\""
    fi

    # 5. 添加 IP 到白名单集合（先做包含关系检查，避免 interval 集合重叠被拒）
    log_step "检查 $ip_range 与现有白名单的包含关系..."
    _check_whitelist_overlap "$set_name" "$ip_range" "$template_name"
    local overlap_rc=$?
    if [ "$overlap_rc" -eq 2 ]; then
        # 已包含，无需添加，也无需重复持久化
        log_info "  当前白名单:"
        _print_set_members "  " "$set_name"
        return 0
    elif [ "$overlap_rc" -eq 1 ]; then
        # 需先 deny 旧元素，中止本次添加
        exit 1
    fi

    log_step "添加 $ip_range 到白名单集合 $set_name"
    local add_err
    add_err=$(nft add element "$TABLE" "$set_name" "{ $ip_range }" 2>&1) || {
        log_warn "添加 $ip_range 失败: ${add_err:-未知错误}"
        exit 1
    }

    # 6. 持久化
    _save_rules

    log_info "✓ ${NAME} 白名单已更新。"
    log_info "  当前白名单:"
    _print_set_members "  " "$set_name"
}

# =============================================================================
# cmd_deny - 移除 IP 白名单
# =============================================================================
cmd_deny() {
    local template_name="$1"
    local ip_range="$2"

    set +e; set +o pipefail

    check_root
    validate_template_name "$template_name"
    validate_ip_range "$ip_range"
    load_template "$template_name"

    local set_name="${template_name}_allow"
    local chain_name="${template_name}_chain"

    log_info "正在从 ${NAME} 白名单中移除: $ip_range"

    if ! _table_exists; then
        log_error "表 $TABLE 不存在，无需操作。"
        exit 0
    fi

    if ! _set_exists "$set_name"; then
        log_warn "白名单集合 $set_name 不存在，无需操作。"
        exit 0
    fi

    # 移除 IP
    if nft delete element "$TABLE" "$set_name" "{ $ip_range }" 2>/dev/null; then
        log_info "✓ 已从 ${NAME} 白名单移除: $ip_range"
    else
        log_warn "$ip_range 不在白名单中，无需移除。"
    fi

    # 检查集合是否为空，提示用户清理
    local remaining
    remaining=$(_get_set_members "$set_name" | wc -l | tr -d ' ' || echo "0")
    if [ "$remaining" -eq 0 ]; then
        log_warn "${NAME} 白名单已为空。"
        log_info "如需清理对应链和规则，请手动执行:"
        log_info "  nft delete chain $TABLE $chain_name"
        log_info "  nft delete set $TABLE $set_name"
        log_info "  nft delete set $TABLE ${template_name}_ports"
    fi

    _save_rules
}

# =============================================================================
# cmd_purge - 清除模板的所有配置（规则、链、IP集、端口集）
# =============================================================================
cmd_purge() {
    local template_name="$1"

    set +e; set +o pipefail

    check_root
    validate_template_name "$template_name"
    load_template "$template_name"

    local chain_name="${template_name}_chain"
    local set_name="${template_name}_allow"
    local port_set_name="${template_name}_ports"

    if ! _table_exists; then
        log_error "表 $TABLE 不存在，无需操作。"
        exit 0
    fi

    log_info "正在清除 ${NAME}（${template_name}）的所有配置..."

    # 1. 删除 input 链中的跳转规则
    if _chain_exists "input"; then
        local handles
        handles=$(_get_rule_handles "input" "jump ${chain_name}")
        for h in $handles; do
            log_step "删除 input 跳转规则 (handle $h)"
            nft delete rule "$TABLE" input handle "$h" 2>/dev/null || true
        done
    fi

    # 2. 删除模板链（需先 flush 清空规则，nft 不允许删除非空链）
    if _chain_exists "$chain_name"; then
        log_step "清空链规则: $chain_name"
        nft flush chain "$TABLE" "$chain_name" 2>/dev/null || true
        log_step "删除链: $chain_name"
        nft delete chain "$TABLE" "$chain_name" 2>/dev/null || true
    else
        log_info "链 $chain_name 不存在，跳过。"
    fi

    # 3. 删除 IP 白名单集合
    if _set_exists "$set_name"; then
        log_step "清空 IP 白名单集合: $set_name"
        nft flush set "$TABLE" "$set_name" 2>/dev/null || true
        log_step "删除 IP 白名单集合: $set_name"
        nft delete set "$TABLE" "$set_name" 2>/dev/null || true
    else
        log_info "集合 $set_name 不存在，跳过。"
    fi

    # 4. 删除端口集合
    if _set_exists "$port_set_name"; then
        log_step "清空端口集合: $port_set_name"
        nft flush set "$TABLE" "$port_set_name" 2>/dev/null || true
        log_step "删除端口集合: $port_set_name"
        nft delete set "$TABLE" "$port_set_name" 2>/dev/null || true
    else
        log_info "集合 $port_set_name 不存在，跳过。"
    fi

    # 5. 持久化
    _save_rules

    log_info "✓ ${NAME} 配置已清除。"
}

# =============================================================================
# cmd_list - 列出白名单规则
# =============================================================================
cmd_list() {
    local filter="${1:-}"

    # 临时关闭 errexit + pipefail，避免 grep/awk 空结果触发退出
    set +e; set +o pipefail

    echo ""
    echo "============================================"
    echo "  nftables-tool 白名单规则"
    echo "============================================"

    if ! _table_exists; then
        echo "  表 $TABLE 不存在，请先执行 init。"
        echo "  运行: sudo ./nftables-tool.sh init"
        echo ""
        return 0
    fi

    # 查找所有 _allow 集合（仅匹配 set 定义行，避免误匹配规则体中的 @xxx_allow 引用）
    local sets
    sets=$(nft list table "$TABLE" 2>/dev/null | grep -oE 'set \S+_allow' | awk '{print $2}' | sed 's/_allow$//' | sort -u || true)

    if [ -z "$sets" ]; then
        echo "  暂无白名单规则。"
        echo ""
        return 0
    fi

    for s in $sets; do
        local set_full="${s}_allow"
        # 如果指定了过滤且不匹配，跳过
        if [ -n "$filter" ] && [ "$s" != "$filter" ]; then
            continue
        fi

        # 尝试加载模板获取显示名称
        local display_name="$s"
        if load_template "$s" 2>/dev/null; then
            display_name="${NAME} (${s})"
        fi

        echo ""
        echo "── ${display_name} ──"
        echo "   端口: "
        # 从端口集合中读取
        local port_set="${s}_ports"
        if nft list set "$TABLE" "$port_set" &>/dev/null; then
            _print_set_members "     " "$port_set"
        else
            echo "     (未配置)"
        fi

        echo "   白名单 IP:"
        _print_set_members "     " "$set_full"
    done

    echo ""
    return 0
}

# =============================================================================
# cmd_status - 运行状态
# =============================================================================
cmd_status() {
    set +e; set +o pipefail
    echo ""
    echo "============================================"
    echo "  nftables-tool 状态"
    echo "============================================"
    echo ""

    # nft 命令
    if nft_available; then
        echo "nft 版本:   $(nft --version 2>&1 | head -1)"
    else
        echo "nft 状态:   ✗ 未安装"
        echo "运行 'sudo ./nftables-tool.sh install' 安装。"
        echo ""
        return 0
    fi

    # 服务状态
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet nftables 2>/dev/null; then
            echo "服务状态:   ✓ 运行中"
            if systemctl is-enabled --quiet nftables 2>/dev/null; then
                echo "开机自启:   ✓ 已启用"
            else
                echo "开机自启:   ✗ 未启用"
            fi
        else
            echo "服务状态:   ✗ 未运行"
        fi
    fi

    # 工具表状态
    if _table_exists; then
        echo ""
        echo "工具表:     ✓ $TABLE 存在"

        # 统计集合数（nft list sets 不接受 table 参数，改用 list table）
        local set_count
        set_count=$(nft list table "$TABLE" 2>/dev/null | grep -c "set " || echo "0")
        echo "白名单集:   $set_count 个"

        # 逐个集合统计 IP 数（仅匹配 set 定义行，避免误匹配规则体中的 @xxx_allow 引用）
        local sets
        sets=$(nft list table "$TABLE" 2>/dev/null | grep -oE 'set \S+_allow' | awk '{print $2}' | sed 's/_allow$//' | sort -u || true)
        if [ -n "$sets" ]; then
            echo ""
            echo "各集合 IP 数量:"
            for s in $sets; do
                local count
                count=$(_get_set_members "${s}_allow" | wc -l | tr -d ' ' || echo "0")
                echo "  - ${s}: ${count} 个 IP"
            done
        fi
    else
        echo ""
        echo "工具表:     ✗ $TABLE 不存在"
        echo "运行 'sudo ./nftables-tool.sh init' 初始化。"
    fi

    echo ""
    return 0
}

# =============================================================================
# cmd_save - 持久化规则
# =============================================================================
cmd_save() {
    check_root
    _save_rules
}

# =============================================================================
# cmd_reset - 清除本工具所有规则
# =============================================================================
cmd_reset() {
    set +e; set +o pipefail
    check_root

    echo ""
    if ! _table_exists; then
        log_info "表 $TABLE 不存在，无需清除。"
        echo ""
        return 0
    fi

    log_warn "即将删除以下所有规则:"
    nft list table "$TABLE" 2>/dev/null || true
    echo ""

    # 简单确认（非交互模式或 FORCE 模式下直接执行）
    if [ "${NFT_RESET_FORCE:-}" = "true" ]; then
        :  # 跳过确认
    elif [ -t 0 ]; then
        read -r -p "确认删除? 输入 yes 继续: " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "已取消。"
            return 0
        fi
    fi

    log_step "删除表 $TABLE ..."
    nft delete table "$TABLE"
    _save_rules

    log_info "✓ 已清除 nftables-tool 的所有规则。"
    echo ""
    return 0
}
