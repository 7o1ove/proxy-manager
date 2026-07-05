#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/7o1ove/xray-manager.git"
INSTALL_DIR="/root/xray-manager"
COMMAND_NAME="7o1ove"
COMMAND_PATH="/usr/local/bin/${COMMAND_NAME}"

echo "Installing Xray Manager..."

if [ -d "$INSTALL_DIR/.git" ]; then
    echo
    echo "Directory exists, updating..."

    cd "$INSTALL_DIR"

    echo "==> Force syncing with remote..."
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

# shellcheck source=/root/xray-manager/lib/output.sh
source "${INSTALL_DIR}/lib/output.sh"

info "Creating global command: ${COMMAND_NAME}"

mkdir -p "$(dirname "$COMMAND_PATH")"

cat > "$COMMAND_PATH" <<EOF
#!/usr/bin/env bash
cd "$INSTALL_DIR"
exec bash "$INSTALL_DIR/xray-manager.sh" "\$@"
EOF

chmod +x "$COMMAND_PATH"
hash -r 2>/dev/null || true

banner "Installation completed!" "$GREEN"
success "Run '${COMMAND_NAME}' next time to open Xray Manager."
info "Starting Xray Manager..."
echo

bash xray-manager.sh </dev/tty
