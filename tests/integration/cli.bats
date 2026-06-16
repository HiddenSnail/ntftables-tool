#!/usr/bin/env bats
#===============================================================================
# cli.bats — 端到端集成测试（通过 nftables-tool.sh CLI，使用 mock nft）
#===============================================================================

load ../test_helper.bash

# 工具脚本路径
TOOL="$PROJECT_DIR/nftables-tool.sh"

setup() {
    setup_mock
    export NFT_DRY_RUN="false"
}

teardown() {
    teardown_mock
}

# =============================================================================
# 帮助与错误处理
# =============================================================================

@test "CLI: 无参数显示帮助" {
    run bash "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"用法"* || "$output" == *"命令"* ]]
}

@test "CLI: -h 显示帮助" {
    run bash "$TOOL" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"install"* ]]
}

@test "CLI: 未知命令报错" {
    run bash "$TOOL" unknown-command
    [ "$status" -eq 1 ]
    [[ "$output" == *"未知命令"* ]]
}

@test "CLI: allow 缺参数报错" {
    run bash "$TOOL" allow
    [ "$status" -eq 1 ]
    [[ "$output" == *"用法"* ]]
}

@test "CLI: allow 缺 IP 参数报错" {
    run bash "$TOOL" allow mongodb
    [ "$status" -eq 1 ]
    [[ "$output" == *"用法"* ]]
}

# =============================================================================
# install
# =============================================================================

@test "CLI: install 在 mock 模式下直接通过" {
    run bash "$TOOL" install
    [ "$status" -eq 0 ]
    [[ "$output" == *"nftables 已安装"* ]]
}

# =============================================================================
# template 命令
# =============================================================================

@test "CLI: template list 列出模板" {
    run bash "$TOOL" template list
    [ "$status" -eq 0 ]
    [[ "$output" == *"mongodb"* ]]
    [[ "$output" == *"seaweedfs"* ]]
}

@test "CLI: template show 显示模板详情" {
    run bash "$TOOL" template show mongodb
    [ "$status" -eq 0 ]
    [[ "$output" == *"MongoDB"* ]]
    [[ "$output" == *"27017"* ]]
}

@test "CLI: template show 不存在的模板报错" {
    run bash "$TOOL" template show no-such-template
    [ "$status" -eq 1 ]
}

# =============================================================================
# 完整流程
# =============================================================================

@test "CLI: init → allow → list → deny → reset 完整流程" {
    # 1. init
    run bash "$TOOL" init
    [ "$status" -eq 0 ]
    assert_nft_called "add table inet nftables-tool"
    assert_nft_called "add chain inet nftables-tool input"

    # 2. allow
    run bash "$TOOL" allow mongodb 10.0.1.0/24
    [ "$status" -eq 0 ]
    assert_nft_called "add element inet nftables-tool mongodb_allow"

    # 3. allow 另一个
    run bash "$TOOL" allow redis 192.168.0.5
    [ "$status" -eq 0 ]

    # 4. list
    run bash "$TOOL" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.1.0/24"* ]]
    [[ "$output" == *"192.168.0.5"* ]]

    # 5. status
    run bash "$TOOL" status
    [ "$status" -eq 0 ]

    # 6. deny
    run bash "$TOOL" deny mongodb 10.0.1.0/24
    [ "$status" -eq 0 ]

    # 7. list 验证已移除
    run bash "$TOOL" list
    [ "$status" -eq 0 ]
    [[ "$output" != *"10.0.1.0/24"* ]]

    # 8. reset
    NFT_RESET_FORCE=true run bash "$TOOL" reset
    [ "$status" -eq 0 ]
    assert_nft_called "delete table inet nftables-tool"
}

@test "CLI: 多模板多 IP 场景" {
    run bash "$TOOL" init
    [ "$status" -eq 0 ]

    # 给多个中间件加白名单
    run bash "$TOOL" allow mongodb 10.0.1.0/24
    [ "$status" -eq 0 ]

    run bash "$TOOL" allow mongodb 10.0.2.0/24
    [ "$status" -eq 0 ]

    run bash "$TOOL" allow redis 10.0.1.0/24
    [ "$status" -eq 0 ]

    run bash "$TOOL" allow seaweedfs 10.0.0.0/16
    [ "$status" -eq 0 ]

    # list 验证
    run bash "$TOOL" list
    [ "$status" -eq 0 ]

    # 验证 mongodb 有两个 IP
    run bash "$TOOL" list mongodb
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.1.0/24"* ]]
    [[ "$output" == *"10.0.2.0/24"* ]]
}

# =============================================================================
# --dry-run
# =============================================================================

@test "CLI: --dry-run 模式不执行 nft" {
    export NFT_DRY_RUN=true

    # dry-run 模式只打印不执行
    run bash "$TOOL" --dry-run allow mongodb 10.0.1.0/24
    # 在 mock 存在时 dry-run 优先，print 到 stderr
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY RUN]"* ]]

    unset NFT_DRY_RUN
}

@test "CLI: --dry-run 模式 list 和 status 仍可运行" {
    run bash "$TOOL" --dry-run list
    [ "$status" -eq 0 ]

    run bash "$TOOL" --dry-run status
    [ "$status" -eq 0 ]
}
