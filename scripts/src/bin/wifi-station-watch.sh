#!/usr/bin/env bash
set -euo pipefail

AIRPLAY_CONFIG_FILE="${AIRPLAY_CONFIG_FILE:-/etc/default/airplay-car-pi}"

# nmcli, iw and systemctl live in /usr/sbin, which is missing from some inherited environments
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ -f "${AIRPLAY_CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${AIRPLAY_CONFIG_FILE}"
fi

ap_iface="${CAR_AP_IFACE:-wlan0}"
state_dir="/run/airplay-car-pi"
probe_stamp_file="${state_dir}/last-home-probe"

log_msg() {
  if command -v logger >/dev/null 2>&1; then
    logger -t wifi-station-watch "$*" || true
  fi
}

log_msg "listening for ${ap_iface} station disconnect events"

# iw event streams nl80211 netlink notifications (no polling): react the
# instant the last phone leaves the hotspot instead of waiting for the
# next timer tick. Detecting the home SSID itself still needs the
# periodic probe below, since the radio can't scan while acting as an AP.
iw event | while read -r line; do
  case "${line}" in
    *"${ap_iface}"*"del station"*)
      log_msg "station left ${ap_iface}, triggering immediate mode check"
      rm -f "${probe_stamp_file}"
      systemctl start network-mode-check.service || true
      ;;
  esac
done
