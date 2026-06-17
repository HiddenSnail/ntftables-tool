#!/usr/bin/env bats
#===============================================================================
# templates.bats — 测试所有内置模板文件格式正确性
#===============================================================================

load ../test_helper.bash

# ---- 辅助函数 ----
template_names() {
    for f in "$PROJECT_DIR/templates"/*.conf; do
        [ -f "$f" ] || continue
        local name=$(basename "$f" .conf)
        [[ "$name" == *example* ]] && continue
        echo "$name"
    done
}

# =============================================================================
# 所有内置模板必须能正常加载
# =============================================================================

@test "所有模板必须包含 NAME 字段" {
    SCRIPT_DIR="$PROJECT_DIR"
    for tmpl in $(template_names); do
        load_template "$tmpl"
        [ -n "${NAME:-}" ] || {
            echo "模板 $tmpl 缺少 NAME"
            return 1
        }
    done
}

@test "所有模板必须包含 PORTS 数组" {
    SCRIPT_DIR="$PROJECT_DIR"
    for tmpl in $(template_names); do
        load_template "$tmpl"
        [ "${#PORTS[@]}" -gt 0 ] || {
            echo "模板 $tmpl 的 PORTS 为空"
            return 1
        }
    done
}

@test "所有模板必须包含 PROTOCOL=tcp" {
    SCRIPT_DIR="$PROJECT_DIR"
    for tmpl in $(template_names); do
        load_template "$tmpl"
        [ "$PROTOCOL" = "tcp" ] || {
            echo "模板 $tmpl 的 PROTOCOL 不是 tcp: $PROTOCOL"
            return 1
        }
    done
}

@test "所有模板 PORTS 格式合法（数字或数字-数字）" {
    SCRIPT_DIR="$PROJECT_DIR"
    for tmpl in $(template_names); do
        load_template "$tmpl"
        for p in "${PORTS[@]}"; do
            echo "$p" | grep -qE '^[0-9]+(-[0-9]+)?$' || {
                echo "模板 $tmpl 端口格式非法: $p"
                return 1
            }
        done
    done
}

# =============================================================================
# 特定模板内容校验（仅使用测试专用模板，避免随组件模板调整而频繁修改）
# =============================================================================

@test "test-range: 独立测试模板含范围端口 2000-3000" {
    SCRIPT_DIR="$PROJECT_DIR"
    load_template "test-range"
    [ "${#PORTS[@]}" -eq 3 ]
    [[ "${PORTS[*]}" == *"2000-3000"* ]]
}
