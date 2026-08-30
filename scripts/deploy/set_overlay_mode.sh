#!/usr/bin/env bash
set -euo pipefail

# Toggle the read-only overlay filesystem on the target Pi so updates can be
# installed. Usage: set_overlay_mode.sh <writable|readonly>

MODE="${1:-}"
PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-raspberrypi.local}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-20}"

if [[ "${MODE}" != "writable" && "${MODE}" != "readonly" ]]; then
  echo "Usage: $0 <writable|readonly>" >&2
  exit 1
fi

if [[ "${MODE}" == "writable" ]]; then
  OVERLAYFS_FLAG=1
else
  OVERLAYFS_FLAG=0
fi

ssh -tt -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" "${PI_USER}@${PI_HOST}" "sudo raspi-config nonint do_overlayfs ${OVERLAYFS_FLAG}"

echo "Overlay set to ${MODE} on ${PI_HOST}. Reboot required for it to take effect: ssh ${PI_USER}@${PI_HOST} sudo reboot"
