#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/proxy-manager"

# shellcheck source=/root/proxy-manager/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

########################################
# Variables
########################################

SSH_CONFIG="/etc/ssh/sshd_config"

FAIL2BAN_CONFIG="/etc/fail2ban/jail.local"

SYSCTL_CONFIG="/etc/sysctl.d/99-z-bbr.conf"

SWAPFILE="/swapfile"

TIMEZONE="Asia/Hong_Kong"

info "正在更新软件包列表..."

apt update

info "正在安装依赖..."

apt install -y \
    openssl \
    openssh-server \
    python3-systemd \
    net-tools \
    ufw \
    fail2ban

info "正在配置 SSH..."

OLD_SSH_PORT=$(awk '
    /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
        print $2
        found=1
        exit
    }
    END {
        if (!found)
            print 22
    }
' "$SSH_CONFIG")

read -r -p "$(prompt_text "SSH 端口: ")" SSH_PORT

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || \
   [[ "$SSH_PORT" -lt 1 ]] || \
   [[ "$SSH_PORT" -gt 65535 ]]; then

    error "SSH 端口无效。"

    exit 1

fi

if [[ "$SSH_PORT" != "$OLD_SSH_PORT" ]] && \
   ss -ltnH | awk '{print $4}' | grep -q ":${SSH_PORT}$"; then

    error "端口已被占用。"

    exit 1

fi

echo

read -r -p "$(prompt_text "SSH 公钥: ")" PUBLIC_KEY

if [[ -z "$PUBLIC_KEY" ]]; then

    error "SSH 公钥不能为空。"

    exit 1

fi

mkdir -p /root/.ssh

chmod 700 /root/.ssh

echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys

chmod 600 /root/.ssh/authorized_keys


info "正在应用 SSH 配置..."

declare -A SSH_CONFIGS=(
    ["Port"]="$SSH_PORT"
    ["PasswordAuthentication"]="no"
    ["PubkeyAuthentication"]="yes"
    ["PermitRootLogin"]="prohibit-password"
)

NEW_CONFIG=""

for KEY in "${!SSH_CONFIGS[@]}"; do

    sed -i "/^[#[:space:]]*${KEY}[[:space:]]/d" "$SSH_CONFIG"

    NEW_CONFIG+="${KEY} ${SSH_CONFIGS[$KEY]}"$'\n'

done

awk -v CONFIG="$NEW_CONFIG" '

/^[[:space:]]*Match/ && !DONE {

    printf "%s", CONFIG

    DONE=1

}

{

    print

}

END {

    if (!DONE)

        printf "%s", CONFIG

}

' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp"

mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"

info "正在配置防火墙..."

ufw allow "${SSH_PORT}/tcp" comment "SSH"

if [[ "$SSH_PORT" != "$OLD_SSH_PORT" ]]; then

    ufw delete allow "${OLD_SSH_PORT}/tcp" >/dev/null 2>&1 || true

    if [[ "$OLD_SSH_PORT" == "22" ]]; then

        ufw delete allow OpenSSH >/dev/null 2>&1 || true

    fi

fi

info "正在配置 Fail2Ban..."

cat > "$FAIL2BAN_CONFIG" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 604800
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 3
bantime = 604800
EOF


read -r -p "$(prompt_text "创建 1G 虚拟内存？[y/n]: ")" CREATE_SWAP

CREATE_SWAP=${CREATE_SWAP:-y}

SWAP_STATUS="已跳过"

if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then

    info "正在创建虚拟内存..."

    if [[ -z "$(swapon --show)" ]]; then

        fallocate -l 1G "$SWAPFILE" || \
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024

        chmod 600 "$SWAPFILE"

        mkswap "$SWAPFILE"

        swapon "$SWAPFILE"

        grep -q "^${SWAPFILE}" /etc/fstab || \
        echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab

        SWAP_STATUS="已创建"

    else

        SWAP_STATUS="已存在"

    fi

else

    warning "已跳过虚拟内存。"

fi

info "正在配置时区..."

timedatectl set-timezone "$TIMEZONE"

info "正在应用系统调优..."

modprobe nf_conntrack 2>/dev/null || true

echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

cat > "$SYSCTL_CONFIG" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.netfilter.nf_conntrack_max = 32768
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

net.core.somaxconn = 1024
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_mtu_probing = 1

vm.swappiness = 10
EOF

sysctl --system >/dev/null

info "正在重启服务..."

systemctl restart ssh

ufw --force enable >/dev/null

ufw --force reload

systemctl enable fail2ban

systemctl restart fail2ban

banner "系统配置摘要" "$GREEN"

kv "SSH 端口    :" "$SSH_PORT"
kv "SSH 认证    :" "仅密钥"

echo

kv "防火墙      :" "$(ufw status | grep -q active && echo 已启用 || echo 未启用)"
kv "Fail2Ban    :" "$(systemctl is-active --quiet fail2ban && echo 已启用 || echo 未启用)"

echo

kv "虚拟内存    :" "$SWAP_STATUS"
kv "时区        :" "$TIMEZONE"

echo

kv "TCP 拥塞控制:" "bbr"
kv "队列算法    :" "fq"

echo

echo
