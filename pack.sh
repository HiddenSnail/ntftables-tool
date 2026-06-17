#!/usr/bin/env bash
#===============================================================================
# pack.sh — nftables-tool 打包分发脚本
#
# 用法:
#   ./pack.sh              # 语法检查 + 打包 .tar.gz
#   ./pack.sh --test       # 打包前先跑测试
#   ./pack.sh --single     # 额外生成单文件版本（零依赖部署）
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="${VERSION:-$(date +%Y%m%d)}"
PACK_NAME="nftables-tool"
OUTPUT_DIR="output"
OUTPUT="${OUTPUT_DIR}/${PACK_NAME}-${VERSION}.tar.gz"
SINGLE_OUTPUT="${OUTPUT_DIR}/${PACK_NAME}-${VERSION}.sh"
DO_TEST=false
DO_SINGLE=false

for arg in "$@"; do
    case "$arg" in
        --test)   DO_TEST=true ;;
        --single) DO_SINGLE=true ;;
        -h|--help)
            echo "用法: ./pack.sh [--test] [--single]"
            echo "  --test   打包前运行 bats 测试"
            echo "  --single 额外生成单文件版本"
            exit 0 ;;
    esac
done

# ---- 语法检查 ----
echo "=== 语法检查 ==="
for f in nftables-tool.sh lib/*.sh; do
    printf "  %-30s " "$f"
    bash -n "$f" && echo "✓" || { echo "✗"; exit 1; }
done

# ---- 测试（可选） ----
if $DO_TEST; then
    echo ""
    echo "=== 运行测试 ==="
    if command -v bats &>/dev/null; then
        bats tests/ || { echo "✗ 测试未通过，取消打包"; exit 1; }
    else
        echo "  ⚠ bats 未安装，跳过测试"
        echo "    brew install bats-core"
    fi
fi

# ---- 打包 tar.gz ----
echo ""
echo "=== 打包: ${OUTPUT} ==="

mkdir -p "$OUTPUT_DIR"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

DISTDIR="$TMPDIR/$PACK_NAME"
mkdir -p "$DISTDIR"/{lib,templates}

cp nftables-tool.sh "$DISTDIR/"
cp lib/common.sh lib/installer.sh lib/core.sh "$DISTDIR/lib/"
cp templates/*.conf "$DISTDIR/templates/"
cp templates/custom.conf.example "$DISTDIR/templates/"
cp README.md "$DISTDIR/"
echo "$VERSION" > "$DISTDIR/VERSION"
chmod +x "$DISTDIR/nftables-tool.sh"

tar czf "$OUTPUT" -C "$TMPDIR" "$PACK_NAME"
echo "  ✓ ${OUTPUT} ($(du -h "$OUTPUT" | cut -f1))"

# ---- 单文件版本（可选） ----
if $DO_SINGLE; then
    echo ""
    echo "=== 生成单文件: ${SINGLE_OUTPUT} ==="

    {
        echo '#!/usr/bin/env bash'
        echo '#==============================================================================='
        echo "# nftables-tool (单文件版本 ${VERSION})"
        echo '# 生成方式: ./pack.sh --single'
        echo '# 部署: scp 此文件到服务器，chmod +x 后直接运行'
        echo '#==============================================================================='
        echo ''
        echo 'set -euo pipefail'
        echo ''
        echo 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
        echo ''

        # 嵌入 lib 文件（去掉 shebang 和 shellcheck 注释）
        for lib in common installer core; do
            echo "# ====== lib/${lib}.sh ======"
            tail -n +2 "lib/${lib}.sh" | grep -v '^# shellcheck'
            echo ''
        done

        # 嵌入模板
        echo '# ====== 内置模板 ======'
        echo '# 首次运行时自动生成到 ${SCRIPT_DIR}/templates/ 目录'
        echo 'generate_templates() {'
        echo '  local d="${1:-${SCRIPT_DIR}/templates}"'
        echo '  mkdir -p "$d"'
        for f in templates/*.conf; do
            echo "  cat > \"\$d/$(basename "$f")\" << 'TMPL_EOF'"
            cat "$f"
            echo 'TMPL_EOF'
        done
        echo '}'
        echo ''
        echo '# 自动生成内置模板'
        echo 'generate_templates "${SCRIPT_DIR}/templates"'
        echo ''

        # 嵌入主入口的命令路由部分
        echo '# ====== 命令路由 ======'
        awk '/^# ---- 命令路由 ----/{found=1; next} found' nftables-tool.sh

    } > "$SINGLE_OUTPUT"

    chmod +x "$SINGLE_OUTPUT"
    echo "  ✓ ${SINGLE_OUTPUT} ($(du -h "$SINGLE_OUTPUT" | cut -f1))"
fi

echo ""
echo "=== 打包完成 ==="
ls -lh "$OUTPUT"
$DO_SINGLE && ls -lh "$SINGLE_OUTPUT"
echo ""
echo "部署方式:"
echo "  scp ${OUTPUT} user@server:/opt/"
echo "  ssh user@server 'cd /opt && tar xzf ${PACK_NAME}-*.tar.gz && cd ${PACK_NAME} && sudo ./nftables-tool.sh init'"
