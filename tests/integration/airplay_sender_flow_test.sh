#!/usr/bin/env bash
set -euo pipefail

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-raspberrypi.local}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-20}"
AIRPLAY_INTEGRATION_TIMEOUT="${AIRPLAY_INTEGRATION_TIMEOUT:-90}"
AIRPLAY_POLL_INTERVAL="${AIRPLAY_POLL_INTERVAL:-2}"

if ! [[ "${AIRPLAY_INTEGRATION_TIMEOUT}" =~ ^[0-9]+$ ]] || [[ "${AIRPLAY_INTEGRATION_TIMEOUT}" -le 0 ]]; then
  echo "AIRPLAY_INTEGRATION_TIMEOUT must be a positive integer"
  exit 1
fi

if ! [[ "${AIRPLAY_POLL_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${AIRPLAY_POLL_INTERVAL}" -le 0 ]]; then
  echo "AIRPLAY_POLL_INTERVAL must be a positive integer"
  exit 1
fi

SSH_CONTROL_PATH="/tmp/airplay-integration-$$"

remote() {
  ssh -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
      -o ControlMaster=auto \
      -o ControlPath="${SSH_CONTROL_PATH}" \
      -o ControlPersist=300 \
      "${PI_USER}@${PI_HOST}" "$@"
}

cleanup() {
  ssh -O exit -o ControlPath="${SSH_CONTROL_PATH}" "${PI_USER}@${PI_HOST}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[INFO] Verifying shairport-sync is active on ${PI_HOST}"
remote 'systemctl is-active --quiet shairport-sync'

echo "[INFO] Starting live AirPlay integration check"
echo "[INFO] Action needed now: from iPhone/macOS, start AirPlay playback to this receiver within ${AIRPLAY_INTEGRATION_TIMEOUT}s"

start_epoch="$(date +%s)"
end_epoch=$((start_epoch + AIRPLAY_INTEGRATION_TIMEOUT))

while [[ "$(date +%s)" -lt "${end_epoch}" ]]; do
  # Active TCP session on classic/modern AirPlay ports indicates a real sender connection.
  # ss -Htan format: State Recv-Q Send-Q Local:Port Peer:Port
  if remote 'ss -Htan | grep -Eq "ESTAB.*:(5000|7000)\b"'; then
    echo "[PASS] AirPlay sender session detected on shairport-sync ports"

    echo "[INFO] Recent shairport-sync logs:"
    remote 'journalctl -u shairport-sync -n 25 --no-pager' || true

    exit 0
  fi

  sleep "${AIRPLAY_POLL_INTERVAL}"
done

echo "[FAIL] No active AirPlay sender session detected within timeout"
echo "[INFO] Troubleshooting hints:"
echo "  - Ensure phone/mac and Pi are on the same network"
echo "  - Confirm receiver is visible in AirPlay output list"
echo "  - Start playback before timeout expires"
echo "  - Re-run with longer timeout, e.g. AIRPLAY_INTEGRATION_TIMEOUT=180"
exit 1
