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
# 特定模板内容校验
# =============================================================================

@test "mongodb: 端口为 27017" {
    SCRIPT_DIR="$PROJECT_DIR"
    load_template "mongodb"
    [ "$NAME" = "MongoDB" ]
    [ "${PORTS[0]}" = "27017" ]
    [ "${#PORTS[@]}" -eq 1 ]
}

@test "redis: 端口为 6379" {
    SCRIPT_DIR="$PROJECT_DIR"
    load_template "redis"
    [ "$NAME" = "Redis" ]
    [ "${PORTS[0]}" = "6379" ]
}

@test "seaweedfs: 端口含范围 9080-9180" {
    SCRIPT_DIR="$PROJECT_DIR"
    load_template "seaweedfs"
    [ "${#PORTS[@]}" -eq 3 ]
    [[ "${PORTS[*]}" == *"9080-9180"* ]]
}

@test "test-range: 独立测试模板含范围端口 2000-3000" {
    SCRIPT_DIR="$PROJECT_DIR"
    load_template "test-range"
    [ "${#PORTS[@]}" -eq 3 ]
    [[ "${PORTS[*]}" == *"2000-3000"* ]]
}

@test "consul: 5 个端口" {
    SCRIPT_DIR="$PROJECT_DIR"
    load_template "consul"
    [ "${#PORTS[@]}" -eq 5 ]
}
