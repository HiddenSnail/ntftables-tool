#!/usr/bin/env bash
#===============================================================================
# test_helper.bash — Bats 测试公共配置
#===============================================================================

# 定位项目根目录
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TEST_DIR/.." && pwd)"

# Mock nft 配置
export NFT_MOCK_DIR="$TEST_DIR/mocks"
# 使用固定的 UUID 作为状态目录，确保跨 bash 子进程共享 mock 状态
NFT_MOCK_STATE_DIR="/tmp/nft-mock-state-$(uuidgen 2>/dev/null || echo "test-${RANDOM}")"
export NFT_MOCK_STATE_DIR
export NFT_MOCK_LOG="/tmp/nft-mock-${RANDOM}.log"

# 确保 mock nft 在 PATH 最前（common.sh 的 NFT_MOCK_DIR 机制优先）
export PATH="$NFT_MOCK_DIR:$PATH"

# 测试模式标志
export NFT_SKIP_ROOT_CHECK="true"
export NFT_RESET_FORCE="true"

# 加载公共库（不加载 installer.sh 和 core.sh，由测试按需加载）
source "$PROJECT_DIR/lib/common.sh"

# ---- 工具函数 ----

# 初始化干净的 mock 环境
setup_mock() {
    rm -rf "$NFT_MOCK_STATE_DIR"
    mkdir -p "$NFT_MOCK_STATE_DIR"
    > "$NFT_MOCK_LOG"
}

# 清理 mock 环境
teardown_mock() {
    rm -rf "$NFT_MOCK_STATE_DIR"
    rm -f "$NFT_MOCK_LOG"
}

# 断言 mock nft 收到过某个命令
assert_nft_called() {
    local pattern="$1"
    if ! grep -qF "$pattern" "$NFT_MOCK_LOG"; then
        echo "Expected nft call matching: $pattern"
        echo "Actual nft calls:"
        cat "$NFT_MOCK_LOG"
        return 1
    fi
}

# 断言 mock nft 没有收到某个命令
refute_nft_called() {
    local pattern="$1"
    if grep -qF "$pattern" "$NFT_MOCK_LOG"; then
        echo "Unexpected nft call matching: $pattern"
        echo "Actual nft calls:"
        cat "$NFT_MOCK_LOG"
        return 1
    fi
}

# 获取 mock 状态中某 set 的元素
mock_set_elements() {
    local table="$1"
    local set_name="$2"
    local f="$NFT_MOCK_STATE_DIR/set_${table}_${set_name}"
    if [ -f "$f" ]; then
        cat "$f"
    fi
}

# 检查 mock 中某个链是否存在
mock_chain_exists() {
    local table="$1"
    local chain="$2"
    [ -f "$NFT_MOCK_STATE_DIR/chain_${table}_${chain}" ]
}

# 设置 SCRIPT_DIR 指向项目目录（因为测试从 tests/ 目录运行）
export SCRIPT_DIR="$PROJECT_DIR"
