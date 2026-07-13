#!/usr/bin/env bash

set -Eeuo pipefail

CLEANUP_LIST="/var/lib/netkit/xanmod-old-kernels.list"
CLEANUP_UNIT="/etc/systemd/system/netkit-xanmod-cleanup.service"
CLEANUP_SERVICE="netkit-xanmod-cleanup.service"

if [[ $(uname -r) != *xanmod* ]]; then
    echo "NetKit: current kernel is not XanMod; old-kernel cleanup skipped."
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
export UCF_FORCE_CONFFOLD=1

old_packages=()
while IFS= read -r package; do
    [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ ]] || continue

    status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
    if [[ -n "$status" && "$status" != "not-installed" ]]; then
        old_packages+=("$package")
    fi
done < "$CLEANUP_LIST"

if (( ${#old_packages[@]} > 0 )); then
    echo "NetKit: removing non-XanMod kernel packages:"
    printf '  %s\n' "${old_packages[@]}"
    apt-mark unhold "${old_packages[@]}" >/dev/null 2>&1 || true
    apt-get -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confold \
        purge -y --allow-change-held-packages -- "${old_packages[@]}"
else
    echo "NetKit: no non-XanMod kernel packages remain."
fi

if command -v update-grub >/dev/null 2>&1; then
    update-grub
fi

systemctl disable "$CLEANUP_SERVICE" || true
rm -f "$CLEANUP_LIST" "$CLEANUP_UNIT"
systemctl daemon-reload

echo "NetKit: old-kernel cleanup completed."
