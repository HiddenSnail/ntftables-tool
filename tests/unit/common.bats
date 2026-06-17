#!/usr/bin/env bats
#===============================================================================
# common.bats — 测试 lib/common.sh 基础函数
#===============================================================================

load ../test_helper.bash

# =============================================================================
# validate_ip_range
# =============================================================================

@test "validate_ip_range: 合法 CIDR 通过" {
    run validate_ip_range "10.0.0.0/24"
    [ "$status" -eq 0 ]
}

@test "validate_ip_range: 单个 IP 通过" {
    run validate_ip_range "192.168.1.5"
    [ "$status" -eq 0 ]
}

@test "validate_ip_range: 非法格式报错" {
    run validate_ip_range "not-an-ip"
    [ "$status" -eq 1 ]
}

@test "validate_ip_range: 空字符串报错" {
    run validate_ip_range ""
    [ "$status" -eq 1 ]
}

@test "validate_ip_range: 纯数字但非 IP 格式报错" {
    run validate_ip_range "12345"
    [ "$status" -eq 1 ]
}

@test "validate_ip_range: 含端口号报错" {
    run validate_ip_range "10.0.0.1:8080"
    [ "$status" -eq 1 ]
}

# =============================================================================
# validate_template_name
# =============================================================================

@test "validate_template_name: 存在的模板通过" {
    SCRIPT_DIR="$PROJECT_DIR"
    run validate_template_name "mongodb"
    [ "$status" -eq 0 ]
}

@test "validate_template_name: 不存在的模板报错" {
    SCRIPT_DIR="$PROJECT_DIR"
    run validate_template_name "nonexistent-service"
    [ "$status" -eq 1 ]
}

# =============================================================================
# load_template
# =============================================================================

@test "load_template: 正常加载 mongodb 模板" {
    SCRIPT_DIR="$PROJECT_DIR"
    load_template "mongodb"
    [ "$NAME" = "MongoDB" ]
    [ "${PORTS[0]}" = "27017" ]
    [ "$PROTOCOL" = "tcp" ]
}

@test "load_template: 正常加载 seaweedfs 含范围端口" {
    SCRIPT_DIR="$PROJECT_DIR"
    load_template "seaweedfs"
    [ "$NAME" = "SeaweedFS" ]
    [ "${PORTS[0]}" = "9333" ]
    [ "${PORTS[1]}" = "9080-9180" ]
    [ "${PORTS[2]}" = "8888" ]
}

@test "load_template: 独立测试模板含范围端口" {
    SCRIPT_DIR="$PROJECT_DIR"
    load_template "test-range"
    [ "$NAME" = "Test Range Service" ]
    [ "${PORTS[0]}" = "1000" ]
    [ "${PORTS[1]}" = "2000-3000" ]
    [ "${PORTS[2]}" = "4000" ]
}

@test "load_template: 不存在的模板返回 1" {
    SCRIPT_DIR="$PROJECT_DIR"
    run load_template "nonexistent"
    [ "$status" -eq 1 ]
}

# =============================================================================
# nft_available (dry-run 模式)
# =============================================================================

@test "nft_available: dry-run 模式下返回 true" {
    NFT_DRY_RUN="true"
    run nft_available
    [ "$status" -eq 0 ]
}

@test "nft_available: 使用 type -P 而非 command -v 检测 nft 二进制" {
    # command -v 会找到同名的 nft() shell 函数导致永远返回 true
    # 正确做法是用 type -P 强制 PATH 搜索，忽略函数/别名
    local func_body
    func_body=$(declare -f nft_available)
    [[ "$func_body" == *"type -P nft"* ]]
    [[ "$func_body" != *"command -v nft"* ]]
}

# =============================================================================
# nft 包装器
# =============================================================================

@test "nft wrapper: dry-run 模式打印命令不执行" {
    # 临时清空 NFT_MOCK_DIR，走 dry-run 路径
    local saved="${NFT_MOCK_DIR:-}"
    unset NFT_MOCK_DIR
    NFT_DRY_RUN="true"
    run nft add table inet test-table
    NFT_DRY_RUN="false"
    [ -n "$saved" ] && NFT_MOCK_DIR="$saved"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY RUN] nft"* ]]
}

# =============================================================================
# list_available_templates
# =============================================================================

@test "list_available_templates: 列出所有模板" {
    SCRIPT_DIR="$PROJECT_DIR"
    run list_available_templates
    [ "$status" -eq 0 ]
    [[ "$output" == *"mongodb"* ]]
    [[ "$output" == *"redis"* ]]
    [[ "$output" == *"seaweedfs"* ]]
    [[ "$output" == *"MongoDB"* ]]
    [[ "$output" != *"example"* ]]  # example 文件被排除
}

# =============================================================================
# check_root
# =============================================================================

@test "check_root: 非 root 用户报错退出" {
    # 临时关闭跳过标志
    local saved="${NFT_SKIP_ROOT_CHECK:-}"
    NFT_SKIP_ROOT_CHECK="false"
    run check_root
    [ -n "$saved" ] && NFT_SKIP_ROOT_CHECK="$saved"
    [ "$status" -eq 1 ]
}
