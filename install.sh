#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/i7asuna/netkit.git"
INSTALL_DIR="/root/netkit"
COMMAND_NAME="asuna"
COMMAND_PATH="/usr/local/bin/${COMMAND_NAME}"
LEGACY_COMMAND_PATH="/usr/local/bin/netkit"

echo "Installing NetKit..."

if [ -d "$INSTALL_DIR/.git" ]; then
    echo
    echo "Directory exists, updating..."

    cd "$INSTALL_DIR"

    echo "==> Force syncing with remote..."
    git remote set-url origin "$REPO"
    git fetch origin
    git reset --hard origin/main
    git clean -fd

else
    echo "==> Cloning repo..."
    git clone "$REPO" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

chmod +x *.sh 2>/dev/null || true
chmod +x core/*.sh 2>/dev/null || true
chmod +x system/*.sh 2>/dev/null || true
chmod +x config/*.sh 2>/dev/null || true
chmod +x lib/*.sh 2>/dev/null || true

# shellcheck source=/root/netkit/lib/output.sh
source "${INSTALL_DIR}/lib/output.sh"

info "Creating global command: ${COMMAND_NAME}"

mkdir -p "$(dirname "$COMMAND_PATH")"
rm -f "$LEGACY_COMMAND_PATH"

cat > "$COMMAND_PATH" <<EOF
#!/usr/bin/env bash
cd "$INSTALL_DIR"
exec bash "$INSTALL_DIR/netkit.sh" "\$@"
EOF

chmod +x "$COMMAND_PATH"
hash -r 2>/dev/null || true

banner "安装完成" "$GREEN"
success "下次输入 '${COMMAND_NAME}' 即可打开 NetKit。"
info "正在启动 NetKit..."
echo

bash netkit.sh </dev/tty
