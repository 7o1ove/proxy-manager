#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

XRAY_DIR="/usr/local/etc/xray"

info "正在更新软件包列表..."

apt update

info "正在安装依赖..."

apt install -y \
    curl \
    ca-certificates

info "正在安装 Xray..."

bash <(
    curl -fsSL -L \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
) install

info "正在检查 Xray..."

if command -v xray >/dev/null 2>&1; then
    XRAY_BIN="$(command -v xray)"
elif [[ -x /usr/local/bin/xray ]]; then
    XRAY_BIN="/usr/local/bin/xray"
elif [[ -x /usr/bin/xray ]]; then
    XRAY_BIN="/usr/bin/xray"
else
    error "Xray 安装失败。"
    exit 1
fi

info "正在准备目录..."

mkdir -p \
    "${XRAY_DIR}" \
    "${XRAY_DIR}/protocols" \
    "${XRAY_DIR}/client"

info "正在创建默认出站配置..."

cat > "${XRAY_DIR}/outbound.json" <<EOF
{
  "protocol": "freedom",
  "settings": {}
}
EOF

info "正在启用 Xray 服务..."

systemctl enable xray

# Some versions of Xray-install automatically start the service.
# Stop it now and restart after the protocol configuration is generated.
systemctl stop xray 2>/dev/null || true

banner "Xray Core 安装完成" "$GREEN"

value "$("$XRAY_BIN" version | head -n1)"

echo
path_kv "程序文件        :" "$XRAY_BIN"
path_kv "配置目录        :" "${XRAY_DIR}"
path_kv "协议配置        :" "${XRAY_DIR}/protocols"
path_kv "连接信息        :" "${XRAY_DIR}/client"

echo
divider "$GREEN"
success "安装完成。"
success "Xray 服务已设置为开机启动。"
success "服务会在协议配置完成后启动。"
divider "$GREEN"
