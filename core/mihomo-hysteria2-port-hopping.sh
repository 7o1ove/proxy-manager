#!/usr/bin/env bash
# 为 Mihomo Hysteria2 listener 管理 UDP 端口跳跃转发规则。

set -Eeuo pipefail

ACTION="${1:-}"
RANGE_START="${2:-}"
RANGE_END="${3:-}"
TARGET_PORT="${4:-}"
RULE_COMMENT="netkit-mihomo-hysteria2-port-hopping"

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "必须使用 root 管理 Hysteria2 端口跳跃规则" >&2
    exit 1
fi

if [[ "${ACTION}" != "start" && "${ACTION}" != "stop" ]]; then
    echo "用法：$0 <start|stop> <起始端口> <结束端口> <监听端口>" >&2
    exit 2
fi

if ! valid_port "${RANGE_START}" || ! valid_port "${RANGE_END}" || ! valid_port "${TARGET_PORT}" ||
   (( RANGE_START > RANGE_END || TARGET_PORT < RANGE_START || TARGET_PORT > RANGE_END )); then
    echo "Hysteria2 端口跳跃参数无效" >&2
    exit 2
fi

RULE=(
    -p udp
    --dport "${RANGE_START}:${RANGE_END}"
    -m comment --comment "${RULE_COMMENT}"
    -j REDIRECT --to-ports "${TARGET_PORT}"
)

add_rule() {
    local command="$1"

    if ! "${command}" -w -t nat -C PREROUTING "${RULE[@]}" >/dev/null 2>&1; then
        "${command}" -w -t nat -A PREROUTING "${RULE[@]}"
    fi
}

delete_rule() {
    local command="$1"

    while "${command}" -w -t nat -C PREROUTING "${RULE[@]}" >/dev/null 2>&1; do
        "${command}" -w -t nat -D PREROUTING "${RULE[@]}" || break
    done
}

if [[ "${ACTION}" == "start" ]]; then
    if ! command -v iptables >/dev/null 2>&1; then
        echo "未找到 iptables，无法启用 Hysteria2 端口跳跃" >&2
        exit 1
    fi

    add_rule iptables
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -w -t nat -L PREROUTING -n >/dev/null 2>&1; then
        add_rule ip6tables
    fi
else
    command -v iptables >/dev/null 2>&1 && delete_rule iptables
    if command -v ip6tables >/dev/null 2>&1; then
        delete_rule ip6tables
    fi
fi
