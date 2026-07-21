#!/usr/bin/env bash
# Mihomo Hysteria2 入站配置脚本
# 说明：按照 Mihomo 官方 Hysteria2 listener 格式生成配置。

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
MIHOMO_CONFIG="${MIHOMO_DIR}/config.yaml"
PROTOCOL_CONFIG="${MIHOMO_DIR}/protocols/hysteria2.yaml"
CLIENT_FILE="${MIHOMO_DIR}/client/hysteria2.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
HOP_HELPER="${SCRIPT_DIR}/core/mihomo-hysteria2-port-hopping.sh"
HOP_SERVICE="mihomo-hysteria2-port-hopping.service"
HOP_SERVICE_FILE="/etc/systemd/system/${HOP_SERVICE}"
HOP_DROPIN_DIR="/etc/systemd/system/mihomo.service.d"
HOP_DROPIN_FILE="${HOP_DROPIN_DIR}/hysteria2-port-hopping.conf"
CERT_FILE="${MIHOMO_DIR}/certs/fullchain.pem"
KEY_FILE="${MIHOMO_DIR}/certs/private.key"
DOMAIN_FILE="${MIHOMO_DIR}/certs/domain"
USERNAME="netkit"
DEFAULT_CLIENT_UP_MBPS="100"
DEFAULT_CLIENT_DOWN_MBPS="100"
HOP_START="20000"
HOP_END="50000"
HOP_INTERVAL="30"

PORT=""
CLIENT_UP_MBPS=""
CLIENT_DOWN_MBPS=""
CLIENT_BANDWIDTH_VALUE=""
PASSWORD=""
DOMAIN=""
SERVER_IP=""
OLD_PORT=""
PROTOCOL_BACKUP=""
CONFIG_BACKUP=""
UFW_RULE_ADDED=0
HAD_OLD_CONFIG=0

trap 'rc=$?; echo; err "Hysteria2 配置失败：第 ${LINENO} 行，命令：${BASH_COMMAND}（退出码：${rc}）"; exit "${rc}"' ERR

err() { error "$@"; }
warn() { warning "$@"; }
ok() { success "$@"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 用户运行此脚本"
        exit 1
    fi
}

install_dependencies() {
    local missing=()
    local package

    for package in curl openssl coreutils iproute2 iptables; do
        if ! dpkg -s "${package}" >/dev/null 2>&1; then
            missing+=("${package}")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        info "正在安装 Mihomo Hysteria2 环境依赖..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
    fi
}

check_mihomo() {
    if ! command -v mihomo >/dev/null 2>&1; then
        err "未检测到 Mihomo，请先安装 Mihomo 内核"
        exit 1
    fi

    if [[ ! -x "${BUILD_CONFIG_SCRIPT}" ]]; then
        err "未找到配置构建脚本：${BUILD_CONFIG_SCRIPT}"
        exit 1
    fi

    if [[ ! -r "${HOP_HELPER}" ]]; then
        err "未找到 Hysteria2 端口跳跃规则脚本：${HOP_HELPER}"
        exit 1
    fi
}

check_certificate() {
    info "检查 Hysteria2 TLS 证书..."

    if [[ ! -r "${CERT_FILE}" || ! -r "${KEY_FILE}" || ! -r "${DOMAIN_FILE}" ]]; then
        err "未找到可用的 TLS 证书"
        echo "请先在 Mihomo 菜单中运行“TLS 证书申请与管理”"
        echo "证书路径：${CERT_FILE}"
        echo "私钥路径：${KEY_FILE}"
        exit 1
    fi

    DOMAIN="$(tr -d '\r\n' < "${DOMAIN_FILE}")"
    if [[ -z "${DOMAIN}" ]]; then
        err "证书域名记录为空：${DOMAIN_FILE}"
        exit 1
    fi

    if ! openssl x509 -in "${CERT_FILE}" -noout >/dev/null 2>&1; then
        err "证书文件无效：${CERT_FILE}"
        exit 1
    fi

    if ! openssl pkey -in "${KEY_FILE}" -noout >/dev/null 2>&1; then
        err "私钥文件无效：${KEY_FILE}"
        exit 1
    fi

    if ! openssl x509 -in "${CERT_FILE}" -noout -checkend 0 >/dev/null 2>&1; then
        err "TLS 证书已经过期，请先续期证书"
        exit 1
    fi

    if ! openssl x509 -in "${CERT_FILE}" -noout -checkhost "${DOMAIN}" >/dev/null 2>&1; then
        err "TLS 证书不包含域名：${DOMAIN}"
        exit 1
    fi

    local cert_public_key key_public_key
    cert_public_key="$(openssl x509 -in "${CERT_FILE}" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_public_key="$(openssl pkey -in "${KEY_FILE}" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    if [[ -z "${cert_public_key}" || "${cert_public_key}" != "${key_public_key}" ]]; then
        err "TLS 证书与私钥不匹配"
        exit 1
    fi

    ok "TLS 证书有效：${DOMAIN}"
}

get_server_ip() {
    SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "${SERVER_IP}" ]]; then
        SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
    fi
    [[ -n "${SERVER_IP}" ]] || SERVER_IP="未知"
}

show_dns_warning() {
    local resolved_ip=""
    resolved_ip="$(getent ahosts "${DOMAIN}" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    if [[ -z "${resolved_ip}" ]]; then
        warn "域名 ${DOMAIN} 当前未解析；客户端连接前请配置正确的 A 或 AAAA 记录"
    else
        info "域名当前解析到：${resolved_ip}"
    fi
}

select_listener_port() {
    if [[ -n "${OLD_PORT}" ]]; then
        if ! valid_port "${OLD_PORT}" || (( OLD_PORT < HOP_START || OLD_PORT > HOP_END )); then
            err "现有 Hysteria2 监听端口不在 ${HOP_START}-${HOP_END} 范围内：${OLD_PORT}"
            echo "请先卸载旧的 Hysteria2 配置，再重新安装。"
            exit 1
        fi
        PORT="${OLD_PORT}"
        info "沿用现有 Hysteria2 监听端口：${PORT}"
        return 0
    fi

    PORT="${HOP_START}"
    if port_in_use "${PORT}"; then
        err "Hysteria2 实际监听端口 ${PORT} 已被占用"
        echo "请先调整占用该端口的服务；HY2 跳跃范围固定为 ${HOP_START}-${HOP_END}。"
        exit 1
    fi
}

prompt_client_bandwidth_value() {
    local label="$1"
    local default_value="$2"
    local value=""

    while true; do
        read -r -p "请输入本地客户端${label}带宽 Mbps（默认 ${default_value}，输入 0 取消）: " value
        value="${value:-${default_value}}"
        if [[ "${value}" == "0" ]]; then
            err "操作已取消"
            exit 1
        fi
        if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 100000 )); then
            CLIENT_BANDWIDTH_VALUE="${value}"
            return 0
        fi
        warn "请输入 1 到 100000 之间的整数"
    done
}

prompt_client_bandwidth() {
    prompt_client_bandwidth_value "上传" "${DEFAULT_CLIENT_UP_MBPS}"
    CLIENT_UP_MBPS="${CLIENT_BANDWIDTH_VALUE}"
    prompt_client_bandwidth_value "下载" "${DEFAULT_CLIENT_DOWN_MBPS}"
    CLIENT_DOWN_MBPS="${CLIENT_BANDWIDTH_VALUE}"
}

read_old_port() {
    if [[ -f "${PROTOCOL_CONFIG}" ]]; then
        HAD_OLD_CONFIG=1
        OLD_PORT="$(yaml_number_field "${PROTOCOL_CONFIG}" "port" || true)"
        [[ -n "${OLD_PORT}" ]] || { err "无法读取现有 Hysteria2 监听端口"; exit 1; }
    fi
}

backup_configs() {
    if [[ -f "${PROTOCOL_CONFIG}" ]]; then
        PROTOCOL_BACKUP="$(mktemp /tmp/netkit-hysteria2.XXXXXX.yaml)"
        cp -a "${PROTOCOL_CONFIG}" "${PROTOCOL_BACKUP}"
    fi
    if [[ -f "${MIHOMO_CONFIG}" ]]; then
        CONFIG_BACKUP="$(mktemp /tmp/netkit-mihomo-config.XXXXXX.yaml)"
        cp -a "${MIHOMO_CONFIG}" "${CONFIG_BACKUP}"
    fi
}

write_protocol_config() {
    local yaml_password yaml_cert yaml_key
    yaml_password="$(yaml_quote "${PASSWORD}")"
    yaml_cert="$(yaml_quote "${CERT_FILE}")"
    yaml_key="$(yaml_quote "${KEY_FILE}")"

    umask 077
    mkdir -p "${MIHOMO_DIR}/protocols" "${MIHOMO_DIR}/client"

    {
        echo "  - name: hysteria2-in"
        echo "    type: hysteria2"
        echo "    port: ${PORT}"
        echo "    listen: 0.0.0.0"
        echo "    users:"
        echo "      ${USERNAME}: ${yaml_password}"
        echo "    masquerade: \"\""
        echo "    alpn:"
        echo "      - h3"
        echo "    certificate: ${yaml_cert}"
        echo "    private-key: ${yaml_key}"
    } > "${PROTOCOL_CONFIG}"
    chmod 600 "${PROTOCOL_CONFIG}"
}

install_port_hopping() {
    info "配置 Hysteria2 UDP 跳跃端口 ${HOP_START}-${HOP_END}..."
    mkdir -p "${HOP_DROPIN_DIR}"

    cat > "${HOP_SERVICE_FILE}" <<EOF
[Unit]
Description=Mihomo Hysteria2 UDP Port Hopping
After=network-online.target
Before=mihomo.service
PartOf=mihomo.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${HOP_HELPER} start ${HOP_START} ${HOP_END} ${PORT}
ExecStop=/bin/bash ${HOP_HELPER} stop ${HOP_START} ${HOP_END} ${PORT}

[Install]
WantedBy=multi-user.target
EOF

    cat > "${HOP_DROPIN_FILE}" <<EOF
[Unit]
Wants=${HOP_SERVICE}
After=${HOP_SERVICE}
EOF

    chmod 644 "${HOP_SERVICE_FILE}" "${HOP_DROPIN_FILE}"
    systemctl daemon-reload
    systemctl enable "${HOP_SERVICE}" >/dev/null
    systemctl restart "${HOP_SERVICE}"
}

remove_port_hopping() {
    systemctl disable --now "${HOP_SERVICE}" >/dev/null 2>&1 || true
    bash "${HOP_HELPER}" stop "${HOP_START}" "${HOP_END}" "${PORT}" >/dev/null 2>&1 || true
    rm -f "${HOP_SERVICE_FILE}" "${HOP_DROPIN_FILE}"
    rmdir "${HOP_DROPIN_DIR}" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
}

remove_hop_ufw_rule() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw --force delete allow "${HOP_START}:${HOP_END}/udp" >/dev/null 2>&1 || true
}

rollback() {
    warn "正在回滚 Hysteria2 配置..."

    if [[ -n "${PROTOCOL_BACKUP}" && -f "${PROTOCOL_BACKUP}" ]]; then
        cp -a "${PROTOCOL_BACKUP}" "${PROTOCOL_CONFIG}"
    else
        rm -f "${PROTOCOL_CONFIG}"
    fi

    if [[ -n "${CONFIG_BACKUP}" && -f "${CONFIG_BACKUP}" ]]; then
        cp -a "${CONFIG_BACKUP}" "${MIHOMO_CONFIG}"
    else
        "${BUILD_CONFIG_SCRIPT}" >/dev/null 2>&1 || true
    fi

    if (( UFW_RULE_ADDED == 1 )); then
        remove_hop_ufw_rule
    fi
    (( HAD_OLD_CONFIG == 1 )) || remove_port_hopping

    systemctl restart mihomo >/dev/null 2>&1 || true
}

apply_config() {
    info "构建并验证 Mihomo 配置..."
    if ! "${BUILD_CONFIG_SCRIPT}"; then
        rollback
        err "Mihomo 配置验证失败，已恢复原配置"
        exit 1
    fi

    if ! install_port_hopping; then
        rollback
        err "Hysteria2 端口跳跃规则配置失败，已恢复原配置"
        exit 1
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ! ufw status 2>/dev/null | grep -Fq "${HOP_START}:${HOP_END}/udp"; then
            info "放行 Hysteria2 UDP 跳跃端口 ${HOP_START}-${HOP_END}..."
            ufw allow "${HOP_START}:${HOP_END}/udp" comment "Mihomo Hysteria2 UDP Hopping" >/dev/null
            UFW_RULE_ADDED=1
        fi
    fi

    if ! systemctl restart mihomo; then
        rollback
        err "Mihomo 启动失败，已恢复原配置"
        exit 1
    fi

    if ! systemctl is-active --quiet mihomo; then
        rollback
        err "Mihomo 服务未正常运行，已恢复原配置"
        exit 1
    fi
}

remove_old_firewall_rule() {
    [[ -n "${OLD_PORT}" ]] && remove_ufw_port_rule "${OLD_PORT}" "udp"
}

write_client_info() {
    local yaml_domain yaml_password hy2_link
    yaml_domain="$(yaml_quote "${DOMAIN}")"
    yaml_password="$(yaml_quote "${PASSWORD}")"
    hy2_link="hysteria2://${PASSWORD}@${DOMAIN}:${HOP_START}-${HOP_END}/?sni=${DOMAIN}&insecure=0"

    umask 077
    {
        echo "Hysteria2 Link:"
        echo "${hy2_link}"
        echo
        echo "Mihomo / Clash:"
        echo "- name: Mihomo Hysteria2"
        echo "  type: hysteria2"
        echo "  server: ${yaml_domain}"
        echo "  port: ${PORT}"
        echo "  ports: \"${HOP_START}-${HOP_END}\""
        echo "  hop-interval: ${HOP_INTERVAL}"
        echo "  password: ${yaml_password}"
        echo "  up: \"${CLIENT_UP_MBPS} Mbps\""
        echo "  down: \"${CLIENT_DOWN_MBPS} Mbps\""
        echo "  sni: ${yaml_domain}"
        echo "  skip-cert-verify: false"
        echo "  alpn:"
        echo "    - h3"
    } > "${CLIENT_FILE}"
    chmod 600 "${CLIENT_FILE}"
}

cleanup_backups() {
    [[ -z "${PROTOCOL_BACKUP}" ]] || rm -f "${PROTOCOL_BACKUP}"
    [[ -z "${CONFIG_BACKUP}" ]] || rm -f "${CONFIG_BACKUP}"
}

show_result() {
    local hy2_link
    hy2_link="$(sed -n '/^Hysteria2 Link:$/ {n;p;q;}' "${CLIENT_FILE}")"

    banner "Mihomo Hysteria2 安装成功" "$GREEN"
    kv "Server IP    :" "${SERVER_IP}"
    kv "Domain       :" "${DOMAIN}"
    kv "Hop Ports    :" "${HOP_START}-${HOP_END}/UDP"
    kv "Listen Port  :" "${PORT}/UDP"
    kv "Hop Interval :" "${HOP_INTERVAL} 秒"
    kv "Password     :" "${PASSWORD}"
    kv "Client Upload  :" "${CLIENT_UP_MBPS} Mbps"
    kv "Client Download:" "${CLIENT_DOWN_MBPS} Mbps"
    echo
    label " Hysteria2 Link"
    value "${hy2_link}"
    echo
    path_kv "主配置文件      :" "${MIHOMO_CONFIG}"
    path_kv "协议配置文件    :" "${PROTOCOL_CONFIG}"
    path_kv "连接信息文件    :" "${CLIENT_FILE}"
    path_kv "TLS 证书        :" "${CERT_FILE}"
    echo
    label " Mihomo / Clash YAML"
    echo
    sed -n '/^Mihomo \/ Clash:/,$p' "${CLIENT_FILE}" | tail -n +2 | while IFS= read -r line; do
        value "${line}"
    done
    warning "如果云服务商启用了安全组或云防火墙，还需要放行 ${HOP_START}-${HOP_END}/UDP。"
    echo
    divider "$GREEN"
}

main() {
    check_root
    banner "安装 Mihomo Hysteria2"
    install_dependencies
    check_mihomo
    check_certificate
    get_server_ip
    show_dns_warning
    read_old_port
    select_listener_port
    prompt_client_bandwidth
    PASSWORD="$(openssl rand -hex 32)"
    backup_configs
    write_protocol_config
    apply_config
    remove_old_firewall_rule
    write_client_info
    cleanup_backups
    show_result
}

main "$@"
