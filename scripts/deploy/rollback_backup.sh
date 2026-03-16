#!/usr/bin/env bash
set -euo pipefail

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-raspberrypi.local}"
PI_PATH="${PI_PATH:-/home/${PI_USER}}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-20}"
ROLLBACK_ROOT="${ROLLBACK_ROOT:-${PI_PATH}/airplay-car-pi-rollbacks}"
SNAPSHOT_ID="${1:-${SNAPSHOT_ID:-}}"

if [[ -z "${SNAPSHOT_ID}" ]]; then
  echo "Usage: $0 <snapshot-id>"
  echo "Example: $0 20260315153000"
  exit 1
fi

ssh -tt -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" "${PI_USER}@${PI_HOST}" "bash -s" <<EOF
set -euo pipefail
snapshot_dir="${ROLLBACK_ROOT}/${SNAPSHOT_ID}"

if [[ ! -d "${snapshot_dir}" ]]; then
  echo "Snapshot not found: ${snapshot_dir}"
  exit 1
fi

restore_if_exists() {
  local source_path="$1"
  local target_path="$2"
  if sudo test -f "${source_path}"; then
    sudo cp -a "${source_path}" "${target_path}"
  fi
}

restore_if_exists "${snapshot_dir}/shairport-sync.conf" /etc/shairport-sync.conf

if sudo test -f "${snapshot_dir}/boot-config.txt"; then
  boot_target=/boot/firmware/config.txt
  if sudo test -f "${snapshot_dir}/boot-config-path.txt"; then
    boot_target="$(sudo cat "${snapshot_dir}/boot-config-path.txt")"
  elif sudo test -f /boot/config.txt; then
    boot_target=/boot/config.txt
  fi
  sudo cp -a "${snapshot_dir}/boot-config.txt" "${boot_target}"
fi

if test -f "${snapshot_dir}/install.sh"; then
  cp -a "${snapshot_dir}/install.sh" "${PI_PATH}/install.sh"
fi
if test -f "${snapshot_dir}/diagnose.sh"; then
  cp -a "${snapshot_dir}/diagnose.sh" "${PI_PATH}/diagnose.sh"
fi

sudo systemctl restart shairport-sync || true

echo "Rollback restored from snapshot: ${snapshot_dir}"
EOF
