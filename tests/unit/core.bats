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
    cmd_allow "mongodb" "10.0.1.0/24"

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
    run cmd_allow "seaweedfs" "10.0.0.0/16"

    [ "$status" -eq 0 ]

    run mock_set_elements "inet nftables-tool" "seaweedfs_ports"
    [ "$status" -eq 0 ]
    [[ "$output" == *"8080-8180"* ]]
    [[ "$output" == *"9333"* ]]
    [[ "$output" == *"8888"* ]]
}

# =============================================================================
# cmd_deny
# =============================================================================

@test "cmd_deny: 移除存在的 IP" {
    # 先添加
    cmd_allow "redis" "192.168.1.0/24"
    cmd_allow "redis" "10.0.0.5"

    # 移除一个
    run cmd_deny "redis" "192.168.1.0/24"
    [ "$status" -eq 0 ]

    # 验证已移除
    run mock_set_elements "inet nftables-tool" "redis_allow"
    [[ "$output" != *"192.168.1.0/24"* ]]
    [[ "$output" == *"10.0.0.5"* ]]
}

@test "cmd_deny: 移除不存在的 IP 给出警告" {
    cmd_allow "redis" "10.0.0.5"

    run cmd_deny "redis" "192.168.1.1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"不在白名单中"* ]]
}

@test "cmd_deny: 集合清空后提示清理" {
    cmd_allow "redis" "10.0.0.5"
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
    cmd_allow "mongodb" "10.0.1.0/24"
    cmd_allow "redis" "192.168.0.5"

    run cmd_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"mongodb"* || "$output" == *"MongoDB"* ]]
    [[ "$output" == *"redis"* || "$output" == *"Redis"* ]]
    [[ "$output" == *"10.0.1.0/24"* ]]
    [[ "$output" == *"192.168.0.5"* ]]
}

@test "cmd_list: 按模板过滤" {
    cmd_allow "mongodb" "10.0.1.0/24"
    cmd_allow "redis" "192.168.0.5"

    run cmd_list "mongodb"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mongodb"* || "$output" == *"MongoDB"* ]]
    [[ "$output" != *"redis"* && "$output" != *"Redis"* ]]
}

# =============================================================================
# cmd_status
# =============================================================================

@test "cmd_status: 显示表存在且统计正确" {
    cmd_allow "mongodb" "10.0.1.0/24"

    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"nftables-tool"* ]]
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
# cmd_reset
# =============================================================================

@test "cmd_reset: 删除表" {
    cmd_allow "mongodb" "10.0.1.0/24"

    NFT_RESET_FORCE=true run cmd_reset
    [ "$status" -eq 0 ]

    # 验证 nft delete table 被调用
    assert_nft_called "delete table inet nftables-tool"
}
