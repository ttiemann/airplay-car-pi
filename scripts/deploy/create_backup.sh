#!/usr/bin/env bash
set -euo pipefail

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-raspberrypi.local}"
PI_PATH="${PI_PATH:-/home/${PI_USER}}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-20}"
SNAPSHOT_ID="${SNAPSHOT_ID:-$(date +%Y%m%d%H%M%S)}"
ROLLBACK_ROOT="${ROLLBACK_ROOT:-${PI_PATH}/airplay-car-pi-rollbacks}"

ssh -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" "${PI_USER}@${PI_HOST}" "bash -s" <<EOF
set -euo pipefail
snapshot_dir="${ROLLBACK_ROOT}/${SNAPSHOT_ID}"
mkdir -p "${snapshot_dir}"

backup_if_exists() {
  local source_path="$1"
  local target_name="$2"
  if sudo test -f "${source_path}"; then
    sudo cp -a "${source_path}" "${snapshot_dir}/${target_name}"
  fi
}

boot_config=''
if sudo test -f /boot/firmware/config.txt; then
  boot_config=/boot/firmware/config.txt
elif sudo test -f /boot/config.txt; then
  boot_config=/boot/config.txt
fi

backup_if_exists /etc/shairport-sync.conf shairport-sync.conf
if [[ -n "${boot_config}" ]]; then
  backup_if_exists "${boot_config}" boot-config.txt
  printf '%s\n' "${boot_config}" | sudo tee "${snapshot_dir}/boot-config-path.txt" >/dev/null
fi

if test -f "${PI_PATH}/install.sh"; then
  cp -a "${PI_PATH}/install.sh" "${snapshot_dir}/install.sh"
fi
if test -f "${PI_PATH}/diagnose.sh"; then
  cp -a "${PI_PATH}/diagnose.sh" "${snapshot_dir}/diagnose.sh"
fi

{
  echo "snapshot_id=${SNAPSHOT_ID}"
  echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname)"
} | sudo tee "${snapshot_dir}/manifest.txt" >/dev/null

echo "Created rollback snapshot: ${snapshot_dir}"
EOF
