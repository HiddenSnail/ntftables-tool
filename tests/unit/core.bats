#!/usr/bin/env bats
#===============================================================================
# core.bats — 测试 lib/core.sh 核心逻辑（使用 mock nft）
#===============================================================================

load ../test_helper.bash

# source core.sh 一次（包含 installer.sh 和 common.sh 的 re-source）
source "$PROJECT_DIR/lib/installer.sh"
source "$PROJECT_DIR/lib/core.sh"

# 每个测试前重置 mock 状态
setup() {
    setup_mock
    # 确保 dry-run 关闭
    NFT_DRY_RUN="false"
    # 预设表已存在（模拟 init 完成后的状态）
    "$NFT_MOCK_DIR/nft" add table "$TABLE"
    "$NFT_MOCK_DIR/nft" add chain "$TABLE" input
    "$NFT_MOCK_DIR/nft" add chain "$TABLE" output
}

teardown() {
    teardown_mock
}

# =============================================================================
# cmd_allow
# =============================================================================

@test "cmd_allow: 首次执行创建链、集合、规则并添加 IP" {
    run cmd_allow "mongodb" "10.0.1.0/24"

    [ "$status" -eq 0 ]

    # 验证链已创建
    run mock_chain_exists "inet nftables-tool" "mongodb_chain"
    [ "$status" -eq 0 ]

    # 验证 IP 白名单集合有元素
    run mock_set_elements "inet nftables-tool" "mongodb_allow"
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.1.0/24"* ]]

    # 验证端口集合有元素
    run mock_set_elements "inet nftables-tool" "mongodb_ports"
    [ "$status" -eq 0 ]
    [[ "$output" == *"27017"* ]]

    # 验证 nft 调用记录
    assert_nft_called "add set inet nftables-tool mongodb_allow"
    assert_nft_called "add element inet nftables-tool mongodb_allow"
    assert_nft_called "add set inet nftables-tool mongodb_ports"
    assert_nft_called "jump mongodb_chain"
}

@test "cmd_allow: 重复执行幂等，不创建重复规则" {
    # 第一次
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]

    # 清空日志，第二次
    > "$NFT_MOCK_LOG"
    run cmd_allow "mongodb" "10.0.2.0/24"

    [ "$status" -eq 0 ]

    # 第二次不应重复创建 set/chain/rule（nft add 在 mock 中也会记录）
    # 但会添加新 IP 元素
    assert_nft_called "add element inet nftables-tool mongodb_allow"

    # 验证两个 IP 都在集合中
    run mock_set_elements "inet nftables-tool" "mongodb_allow"
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.1.0/24"* ]]
    [[ "$output" == *"10.0.2.0/24"* ]]
}

@test "cmd_allow: 表不存在时报错" {
    # 删除表模拟未 init
    "$NFT_MOCK_DIR/nft" delete table "$TABLE"

    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 1 ]
    [[ "$output" == *"请先执行 init"* ]]
}

@test "cmd_allow: 多端口模板为每个端口建端口集合" {
    run cmd_allow "consul" "10.0.0.0/8"

    [ "$status" -eq 0 ]

    # consul 有 5 个端口
    run mock_set_elements "inet nftables-tool" "consul_ports"
    [ "$status" -eq 0 ]
    [[ "$output" == *"8300"* ]]
    [[ "$output" == *"8500"* ]]
    [[ "$output" == *"8600"* ]]
}

@test "cmd_allow: 端口范围正确存储" {
    run cmd_allow "test-range" "10.0.0.0/16"

    [ "$status" -eq 0 ]

    run mock_set_elements "inet nftables-tool" "test-range_ports"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2000-3000"* ]]
    [[ "$output" == *"1000"* ]]
    [[ "$output" == *"4000"* ]]
}

@test "cmd_allow: IP 白名单集合创建时包含 flags interval" {
    # 不加 flags interval 的话，CIDR 前缀（如 10.19.1.0/24）会被 nft 静默拒绝
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]

    assert_nft_called "add set inet nftables-tool mongodb_allow { type ipv4_addr; flags interval; }"
}

@test "cmd_allow: 端口集合创建时包含 flags interval" {
    # 不加 flags interval 的话，端口范围（如 2000-3000）会被 nft 静默拒绝
    run cmd_allow "test-range" "10.0.0.0/16"
    [ "$status" -eq 0 ]

    assert_nft_called "add set inet nftables-tool test-range_ports { type inet_service; flags interval; }"
}

@test "cmd_allow: CIDR 格式 IP 能正确存入含 flags interval 的集合" {
    # 端到端验证：CIDR 前缀白名单 IP 能写入并持久化
    run cmd_allow "redis" "10.19.1.0/24"
    [ "$status" -eq 0 ]

    run mock_set_elements "inet nftables-tool" "redis_allow"
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.19.1.0/24"* ]]
}

@test "CIDR 工具: _cidr_bounds 正确计算网段边界" {
    run _cidr_bounds "10.19.0.0/16"
    [ "$status" -eq 0 ]
    [[ "$output" == "169017344 169082879" ]]

    run _cidr_bounds "10.19.1.0/24"
    [ "$status" -eq 0 ]
    [[ "$output" == "169017600 169017855" ]]

    # 单 IP 视作 /32
    run _cidr_bounds "192.168.1.5"
    [ "$status" -eq 0 ]
    [[ "$output" == "3232235781 3232235781" ]]
}

@test "CIDR 工具: _check_whitelist_overlap 判断包含/覆盖/无冲突" {
    # 预置现有元素 10.19.1.0/24
    printf '10.19.1.0/24\n' > "$NFT_MOCK_STATE_DIR/set_${TABLE}_redis_allow"

    # 新网段被现有元素包含 -> 2
    run _check_whitelist_overlap "redis_allow" "10.19.1.128/25" "redis"
    [ "$status" -eq 2 ]

    # 新网段覆盖现有元素 -> 1，提示先 deny
    run _check_whitelist_overlap "redis_allow" "10.19.0.0/16" "redis"
    [ "$status" -eq 1 ]
    [[ "$output" == *"deny redis 10.19.1.0/24"* ]]

    # 完全无关 -> 0
    run _check_whitelist_overlap "redis_allow" "192.168.0.0/24" "redis"
    [ "$status" -eq 0 ]
}

@test "cmd_allow: 新网段被现有网段完全包含时跳过添加" {
    # 先添加较宽网段
    run cmd_allow "redis" "10.0.0.0/8"
    [ "$status" -eq 0 ]

    > "$NFT_MOCK_LOG"
    run cmd_allow "redis" "10.19.1.0/24"

    [ "$status" -eq 0 ]
    [[ "$output" == *"已包含在现有白名单元素 10.0.0.0/8 中，无需添加"* ]]
    # 不应触发 add element
    refute_nft_called "add element inet nftables-tool redis_allow"
    # 集合仍只有宽网段
    run mock_set_elements "inet nftables-tool" "redis_allow"
    [[ "$output" == *"10.0.0.0/8"* ]]
    [[ "$output" != *"10.19.1.0/24"* ]]
}

@test "cmd_allow: 重复添加相同网段时跳过并提示已包含" {
    run cmd_allow "redis" "10.19.1.0/24"
    [ "$status" -eq 0 ]

    > "$NFT_MOCK_LOG"
    run cmd_allow "redis" "10.19.1.0/24"

    [ "$status" -eq 0 ]
    [[ "$output" == *"已包含在现有白名单元素 10.19.1.0/24 中，无需添加"* ]]
    refute_nft_called "add element inet nftables-tool redis_allow"
}

@test "cmd_allow: 新网段覆盖已有网段时提示先 deny 并中止" {
    # 先添加较窄网段
    run cmd_allow "redis" "10.19.1.0/24"
    [ "$status" -eq 0 ]

    > "$NFT_MOCK_LOG"
    run cmd_allow "redis" "10.19.0.0/16"

    [ "$status" -eq 1 ]
    [[ "$output" == *"deny redis 10.19.1.0/24"* ]]
    # 新网段未被添加
    run mock_set_elements "inet nftables-tool" "redis_allow"
    [[ "$output" == *"10.19.1.0/24"* ]]
    [[ "$output" != *"10.19.0.0/16"* ]]
}

@test "cmd_allow: 新网段覆盖多个已有网段时全部提示 deny" {
    run cmd_allow "redis" "10.19.1.0/24"
    [ "$status" -eq 0 ]
    run cmd_allow "redis" "10.19.2.0/24"
    [ "$status" -eq 0 ]

    > "$NFT_MOCK_LOG"
    run cmd_allow "redis" "10.19.0.0/16"

    [ "$status" -eq 1 ]
    [[ "$output" == *"deny redis 10.19.1.0/24"* ]]
    [[ "$output" == *"deny redis 10.19.2.0/24"* ]]
}

# =============================================================================
# cmd_deny
# =============================================================================

@test "cmd_deny: 移除存在的 IP" {
    # 先添加
    run cmd_allow "redis" "192.168.1.0/24"
    [ "$status" -eq 0 ]
    run cmd_allow "redis" "10.0.0.5"
    [ "$status" -eq 0 ]

    # 移除一个
    run cmd_deny "redis" "192.168.1.0/24"
    [ "$status" -eq 0 ]

    # 验证已移除
    run mock_set_elements "inet nftables-tool" "redis_allow"
    [[ "$output" != *"192.168.1.0/24"* ]]
    [[ "$output" == *"10.0.0.5"* ]]
}

@test "cmd_deny: 移除不存在的 IP 给出警告" {
    run cmd_allow "redis" "10.0.0.5"
    [ "$status" -eq 0 ]

    run cmd_deny "redis" "192.168.1.1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"不在白名单中"* ]]
}

@test "cmd_deny: 集合清空后提示清理" {
    run cmd_allow "redis" "10.0.0.5"
    [ "$status" -eq 0 ]
    run cmd_deny "redis" "10.0.0.5"

    [ "$status" -eq 0 ]
    [[ "$output" == *"白名单已为空"* ]]
    [[ "$output" == *"nft delete chain"* ]]
}

# =============================================================================
# cmd_list
# =============================================================================

@test "cmd_list: 空表输出提示信息" {
    run cmd_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"暂无白名单规则"* ]]
}

@test "cmd_list: 显示已添加的规则" {
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]
    run cmd_allow "redis" "192.168.0.5"
    [ "$status" -eq 0 ]

    run cmd_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"mongodb"* || "$output" == *"MongoDB"* ]]
    [[ "$output" == *"redis"* || "$output" == *"Redis"* ]]
    [[ "$output" == *"10.0.1.0/24"* ]]
    [[ "$output" == *"192.168.0.5"* ]]
}

@test "cmd_list: 按模板过滤" {
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]
    run cmd_allow "redis" "192.168.0.5"
    [ "$status" -eq 0 ]

    run cmd_list "mongodb"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mongodb"* || "$output" == *"MongoDB"* ]]
    [[ "$output" != *"redis"* && "$output" != *"Redis"* ]]
}

@test "cmd_list: elements 多行折行输出时完整列出所有 IP（真实 nft 兼容）" {
    # 真实 nft 在元素较多/较长时会把 elements 折成多行，
    # 旧实现只解析首行导致续行 IP 丢失（复现: seaweedfs 3 个 IP 只显示 2 个）
    run cmd_allow "seaweedfs" "10.19.0.0/16"
    [ "$status" -eq 0 ]
    run cmd_allow "seaweedfs" "10.208.11.191"
    [ "$status" -eq 0 ]
    run cmd_allow "seaweedfs" "10.208.58.208"
    [ "$status" -eq 0 ]

    # 确认 mock 输出确实折行（与真实 nft 行为一致），否则测试无意义
    local raw nlines
    raw=$("$NFT_MOCK_DIR/nft" list set "$TABLE" seaweedfs_allow)
    nlines=$(printf '%s\n' "$raw" | grep -c '10\.')
    echo "elements 折行行数: $nlines"
    [ "$nlines" -ge 2 ]

    run cmd_list "seaweedfs"
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.19.0.0/16"* ]]
    [[ "$output" == *"10.208.11.191"* ]]
    [[ "$output" == *"10.208.58.208"* ]]
}

# =============================================================================
# cmd_status
# =============================================================================

@test "cmd_status: 显示表存在且统计正确" {
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]

    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"nftables-tool"* ]]
}

@test "cmd_status: elements 多行折行输出时 IP 数量统计完整" {
    # 与 cmd_list 折行场景相同：旧实现只统计 elements 首行，会少算
    run cmd_allow "seaweedfs" "10.19.0.0/16"
    [ "$status" -eq 0 ]
    run cmd_allow "seaweedfs" "10.208.11.191"
    [ "$status" -eq 0 ]
    run cmd_allow "seaweedfs" "10.208.58.208"
    [ "$status" -eq 0 ]

    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"seaweedfs: 3 个 IP"* ]]
}

@test "cmd_status: 使用 list table 而非 list sets 获取集合信息" {
    # nft list sets 不接受 table 参数，会失败被 2>/dev/null 吞掉
    # 正确做法是用 nft list table 获取完整表信息
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]
    > "$NFT_MOCK_LOG"

    run cmd_status
    [ "$status" -eq 0 ]

    assert_nft_called "list table inet nftables-tool"
    refute_nft_called "list sets"
}

@test "cmd_list: 使用 list table 而非 list sets 获取集合信息" {
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]
    > "$NFT_MOCK_LOG"

    run cmd_list
    [ "$status" -eq 0 ]

    assert_nft_called "list table inet nftables-tool"
    refute_nft_called "list sets"
}

# =============================================================================
# cmd_init
# =============================================================================

@test "cmd_init: 首次执行创建表和链" {
    # 清除 mock 预设
    "$NFT_MOCK_DIR/nft" delete table "$TABLE"

    run cmd_init
    [ "$status" -eq 0 ]

    # 验证表存在
    assert_nft_called "add table inet nftables-tool"
    assert_nft_called "add chain inet nftables-tool input"
    assert_nft_called "add chain inet nftables-tool output"
}

@test "cmd_init: 重复执行幂等" {
    run cmd_init
    [ "$status" -eq 0 ]

    # 第二次
    > "$NFT_MOCK_LOG"
    run cmd_init
    [ "$status" -eq 0 ]

    # 不应再次 add table
    refute_nft_called "add table inet nftables-tool"
}

# =============================================================================
# cmd_purge
# =============================================================================

@test "cmd_purge: 清除模板的所有配置" {
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]

    run cmd_purge "mongodb"
    [ "$status" -eq 0 ]

    # 验证链已删除
    run mock_chain_exists "inet nftables-tool" "mongodb_chain"
    [ "$status" -ne 0 ]

    # 验证 IP 集合已删除
    run mock_set_elements "inet nftables-tool" "mongodb_allow"
    [ "$status" -ne 0 ] || [ -z "$output" ]

    # 验证端口集合已删除
    run mock_set_elements "inet nftables-tool" "mongodb_ports"
    [ "$status" -ne 0 ] || [ -z "$output" ]

    # 验证 nft 调用记录
    assert_nft_called "flush chain inet nftables-tool mongodb_chain"
    assert_nft_called "delete chain inet nftables-tool mongodb_chain"
    assert_nft_called "flush set inet nftables-tool mongodb_allow"
    assert_nft_called "delete set inet nftables-tool mongodb_allow"
    assert_nft_called "flush set inet nftables-tool mongodb_ports"
    assert_nft_called "delete set inet nftables-tool mongodb_ports"
}

@test "cmd_purge: 表不存在时正常退出" {
    "$NFT_MOCK_DIR/nft" delete table "$TABLE"

    run cmd_purge "mongodb"
    [ "$status" -eq 0 ]
    [[ "$output" == *"无需操作"* ]]
}

@test "cmd_purge: 部分组件缺失时仍成功执行" {
    # 只创建 allow set 不创建其他（模拟部分清理后的状态）
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]

    run cmd_purge "mongodb"
    [ "$status" -eq 0 ]
    [[ "$output" == *"已清除"* ]]
}

@test "cmd_purge: 不影响其他模板" {
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]
    run cmd_allow "redis" "192.168.0.5"
    [ "$status" -eq 0 ]

    run cmd_purge "mongodb"
    [ "$status" -eq 0 ]

    # redis 不应受影响
    run mock_chain_exists "inet nftables-tool" "redis_chain"
    [ "$status" -eq 0 ]

    run mock_set_elements "inet nftables-tool" "redis_allow"
    [ "$status" -eq 0 ]
    [[ "$output" == *"192.168.0.5"* ]]

    # mongodb 链和集合应被清除
    run mock_chain_exists "inet nftables-tool" "mongodb_chain"
    [ "$status" -ne 0 ]
}

@test "cmd_purge: input 链中无跳转规则时仍可清理" {
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]
    # 手动删掉 input 中的跳转规则（模拟残留）
    "$NFT_MOCK_DIR/nft" delete chain "$TABLE" input
    "$NFT_MOCK_DIR/nft" add chain "$TABLE" input

    run cmd_purge "mongodb"
    [ "$status" -eq 0 ]
    [[ "$output" == *"已清除"* ]]
}

# =============================================================================
# cmd_reset
# =============================================================================

@test "cmd_reset: 删除表" {
    run cmd_allow "mongodb" "10.0.1.0/24"
    [ "$status" -eq 0 ]

    NFT_RESET_FORCE=true run cmd_reset
    [ "$status" -eq 0 ]

    # 验证 nft delete table 被调用
    assert_nft_called "delete table inet nftables-tool"
}
