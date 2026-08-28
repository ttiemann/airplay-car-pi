#!/usr/bin/env bash
set -euo pipefail

# Basic installer bootstrap for airplay-car-pi.

CORE_PACKAGES=(
  alsa-utils
  avahi-daemon
  network-manager
  shairport-sync
)

SHAIRPORT_CONFIG_FILE="/etc/shairport-sync.conf"
HIFIBERRY_OVERLAY="dtoverlay=hifiberry-dac"
AIRPLAY_DEVICE_NAME="${AIRPLAY_DEVICE_NAME:-AirPlay Car Pi}"
AIRPLAY_BACKEND="${AIRPLAY_BACKEND:-alsa}"
AIRPLAY_MIXER_CONTROL_NAME="${AIRPLAY_MIXER_CONTROL_NAME:-}"
AIRPLAY_CAR_SUFFIX="${AIRPLAY_CAR_SUFFIX:- [CAR]}"

CAR_AP_SSID="${CAR_AP_SSID:-AirPlay-Car-Pi}"
CAR_AP_PASSWORD="${CAR_AP_PASSWORD:-airplaycarpi}"
CAR_AP_IFACE="${CAR_AP_IFACE:-wlan0}"
CAR_AP_CHANNEL="${CAR_AP_CHANNEL:-6}"

AIRPLAY_MODE_ENV_FILE="/etc/default/airplay-car-pi-mode"
AIRPLAY_MODE_CHECK_SCRIPT="/usr/local/bin/airplay-car-pi-mode-check"
AIRPLAY_MODE_SERVICE_FILE="/etc/systemd/system/airplay-car-pi-mode.service"
AIRPLAY_MODE_TIMER_FILE="/etc/systemd/system/airplay-car-pi-mode.timer"

log() {
  printf "\n[%s] %s\n" "$(date +"%Y-%m-%d %H:%M:%S")" "$1"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Re-running installer with sudo..."
    exec sudo "$0" "$@"
  fi
}

apt_update_upgrade() {
  log "Updating package index"
  apt-get update

  log "Upgrading installed packages"
  DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get upgrade -y
}

install_core_packages() {
  log "Installing core packages"
  DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y "${CORE_PACKAGES[@]}"
}

get_boot_config_file() {
  local primary_boot_config legacy_boot_config

  primary_boot_config="${BOOT_CONFIG_PRIMARY:-/boot/firmware/config.txt}"
  legacy_boot_config="${BOOT_CONFIG_LEGACY:-/boot/config.txt}"

  if [[ -f "${primary_boot_config}" ]]; then
    printf "%s\n" "${primary_boot_config}"
  elif [[ -f "${legacy_boot_config}" ]]; then
    printf "%s\n" "${legacy_boot_config}"
  else
    printf "%s\n" ""
  fi
}

detect_mixer_control_name() {
  local controls candidate

  if [[ -n "${AIRPLAY_MIXER_CONTROL_NAME}" ]]; then
    printf "%s\n" "${AIRPLAY_MIXER_CONTROL_NAME}"
    return
  fi

  if ! command -v amixer >/dev/null 2>&1; then
    printf "%s\n" ""
    return
  fi

  controls="$(amixer -D default scontrols 2>/dev/null || amixer scontrols 2>/dev/null || true)"

  if [[ -z "${controls}" ]]; then
    printf "%s\n" ""
    return
  fi

  for candidate in "Playback Digital" "Digital" "PCM" "Master"; do
    if grep -Fq "Simple mixer control '${candidate}'," <<<"${controls}"; then
      printf "%s\n" "${candidate}"
      return
    fi
  done

  printf "%s\n" "$(sed -n "s/^Simple mixer control '\([^']*\)',.*/\1/p" <<<"${controls}" | head -n1)"
}

generate_shairport_config() {
  local mixer_control_name

  log "Generating Shairport Sync config"

  mixer_control_name="$(detect_mixer_control_name)"

  if [[ -f "${SHAIRPORT_CONFIG_FILE}" ]]; then
    cp -a "${SHAIRPORT_CONFIG_FILE}" "${SHAIRPORT_CONFIG_FILE}.bak.$(date +"%Y%m%d%H%M%S")"
  fi

  cat >"${SHAIRPORT_CONFIG_FILE}" <<EOF
general = {
  name = "${AIRPLAY_DEVICE_NAME}";
  interpolation = "soxr";
  output_backend = "${AIRPLAY_BACKEND}";
};

sessioncontrol = {
  allow_session_interruption = "yes";
};

alsa = {
  output_device = "default";
EOF

  if [[ -n "${mixer_control_name}" ]]; then
    printf "  mixer_control_name = \"%s\";\n" "${mixer_control_name}" >>"${SHAIRPORT_CONFIG_FILE}"
  else
    # Fallback to software volume if no ALSA mixer control is discoverable.
    printf "  mixer_type = \"software\";\n" >>"${SHAIRPORT_CONFIG_FILE}"
  fi

  cat >>"${SHAIRPORT_CONFIG_FILE}" <<EOF
};
EOF
}

configure_hifiberry_dac() {
  local boot_config_file

  boot_config_file="$(get_boot_config_file)"

  if [[ -z "${boot_config_file}" ]]; then
    log "Raspberry Pi boot config not found, skipping HiFiBerry DAC boot configuration"
    return
  fi

  log "Configuring HiFiBerry DAC in ${boot_config_file}"
  cp -a "${boot_config_file}" "${boot_config_file}.bak.$(date +"%Y%m%d%H%M%S")"

  if grep -Eq '^\s*dtparam=audio=' "${boot_config_file}"; then
    sed -i '' 's/^\s*dtparam=audio=.*/dtparam=audio=off/' "${boot_config_file}" 2>/dev/null || \
      sed -i 's/^\s*dtparam=audio=.*/dtparam=audio=off/' "${boot_config_file}"
  else
    printf "\n%s\n" "dtparam=audio=off" >> "${boot_config_file}"
  fi

  if ! grep -Fxq "${HIFIBERRY_OVERLAY}" "${boot_config_file}"; then
    printf "%s\n" "${HIFIBERRY_OVERLAY}" >> "${boot_config_file}"
  fi
}

has_running_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

configure_shairport_service() {
  if has_running_systemd; then
    log "Enabling and restarting shairport-sync"
    systemctl enable shairport-sync
    systemctl restart shairport-sync
  else
    log "systemd not available, skipping shairport-sync enable/restart"
  fi
}

install_mode_detector_files() {
  log "Installing automatic home/away mode detector"

  cat >"${AIRPLAY_MODE_ENV_FILE}" <<EOF
AIRPLAY_DEVICE_NAME="${AIRPLAY_DEVICE_NAME}"
AIRPLAY_CAR_SUFFIX="${AIRPLAY_CAR_SUFFIX}"
CAR_AP_SSID="${CAR_AP_SSID}"
CAR_AP_PASSWORD="${CAR_AP_PASSWORD}"
CAR_AP_IFACE="${CAR_AP_IFACE}"
CAR_AP_CHANNEL="${CAR_AP_CHANNEL}"
EOF

  cat >"${AIRPLAY_MODE_CHECK_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODE_ENV_FILE="/etc/default/airplay-car-pi-mode"
SHAIRPORT_CONFIG_FILE="/etc/shairport-sync.conf"
STATE_DIR="/run/airplay-car-pi"
STATE_FILE="${STATE_DIR}/network-mode"

if [[ -f "${MODE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${MODE_ENV_FILE}"
fi

detect_configured_ssid() {
  local ssid

  if [[ -f /etc/wpa_supplicant/wpa_supplicant.conf ]]; then
    ssid="$(sed -n 's/^[[:space:]]*ssid="\([^"]*\)".*/\1/p' /etc/wpa_supplicant/wpa_supplicant.conf | head -n1 || true)"
    if [[ -n "${ssid}" ]]; then
      printf "%s\n" "${ssid}"
      return
    fi
  fi

  ssid="$(grep -h '^ssid=' /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | sed -n 's/^ssid=//p' | head -n1 || true)"
  if [[ -n "${ssid}" ]]; then
    printf "%s\n" "${ssid}"
    return
  fi

  printf "%s\n" ""
}

get_current_ssid() {
  nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '/^yes/{print $2; exit}' || true
}

start_hotspot() {
  local ap_iface ap_ssid ap_password ap_channel
  ap_iface="${CAR_AP_IFACE:-wlan0}"
  ap_ssid="${CAR_AP_SSID:-AirPlay-Car-Pi}"
  ap_password="${CAR_AP_PASSWORD:-airplaycarpi}"
  ap_channel="${CAR_AP_CHANNEL:-6}"

  nmcli device wifi hotspot \
    ifname "${ap_iface}" \
    ssid "${ap_ssid}" \
    password "${ap_password}" \
    channel "${ap_channel}" 2>/dev/null || true
}

stop_hotspot() {
  local ap_iface
  ap_iface="${CAR_AP_IFACE:-wlan0}"

  nmcli connection delete Hotspot 2>/dev/null || true
  nmcli device connect "${ap_iface}" 2>/dev/null || true
}

device_name="${AIRPLAY_DEVICE_NAME:-AirPlay Car Pi}"
car_suffix="${AIRPLAY_CAR_SUFFIX:- [CAR]}"
current_ssid=""
home_wifi_ssid="$(detect_configured_ssid)"
mode="AWAY"

previous_mode=""
if [[ -f "${STATE_FILE}" ]]; then
  previous_mode="$(cat "${STATE_FILE}" 2>/dev/null || true)"
fi

if systemctl is-active --quiet NetworkManager 2>/dev/null && nmcli -t -f NAME connection show --active 2>/dev/null | grep -qi hotspot; then
  mode="AWAY"
elif [[ -n "${home_wifi_ssid}" ]]; then
  current_ssid="$(get_current_ssid)"
  if [[ "${current_ssid}" == "${home_wifi_ssid}" ]]; then
    mode="CONFIGURED_SSID"
  fi
fi

target_name="${device_name}"
if [[ "${mode}" == "AWAY" ]]; then
  target_name="${device_name}${car_suffix}"
fi

if [[ -f "${SHAIRPORT_CONFIG_FILE}" ]]; then
  current_name="$(sed -n 's/^[[:space:]]*name = "\([^"]*\)";.*/\1/p' "${SHAIRPORT_CONFIG_FILE}" | head -n1 || true)"

  if [[ "${current_name}" != "${target_name}" ]]; then
    escaped_target_name="${target_name//\\/\\\\}"
    escaped_target_name="${escaped_target_name//\//\\/}"
    escaped_target_name="${escaped_target_name//&/\\&}"
    sed -i '0,/^[[:space:]]*name = ".*";/s//  name = "'"${escaped_target_name}"'";/' "${SHAIRPORT_CONFIG_FILE}"
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
      systemctl restart shairport-sync || true
    fi
  fi
fi

if [[ "${mode}" == "AWAY" && "${previous_mode}" != "AWAY" ]]; then
  start_hotspot
elif [[ "${mode}" == "CONFIGURED_SSID" && "${previous_mode}" == "AWAY" ]]; then
  stop_hotspot
fi

mkdir -p "${STATE_DIR}"
printf "%s\n" "${mode}" >"${STATE_FILE}"

if command -v logger >/dev/null 2>&1; then
  logger -t airplay-car-pi-mode "mode=${mode} ssid=${current_ssid:-none} name=${target_name}" || true
fi
EOF

  chmod +x "${AIRPLAY_MODE_CHECK_SCRIPT}"

  cat >"${AIRPLAY_MODE_SERVICE_FILE}" <<EOF
[Unit]
Description=AirPlay Car Pi network mode detection
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${AIRPLAY_MODE_CHECK_SCRIPT}
EOF

  cat >"${AIRPLAY_MODE_TIMER_FILE}" <<EOF
[Unit]
Description=Run AirPlay Car Pi network mode detection periodically

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
Unit=airplay-car-pi-mode.service
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

configure_mode_detector_service() {
  if has_running_systemd; then
    log "Enabling airplay-car-pi mode detector timer"
    systemctl daemon-reload
    systemctl enable --now airplay-car-pi-mode.timer
    systemctl start airplay-car-pi-mode.service
  else
    log "systemd not available, skipping mode detector timer setup"
  fi
}

main() {
  require_root "$@"

  log "Starting airplay-car-pi installer bootstrap"
  apt_update_upgrade
  install_core_packages
  configure_hifiberry_dac
  generate_shairport_config
  configure_shairport_service
  install_mode_detector_files
  configure_mode_detector_service

  log "Bootstrap complete"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || "${0##*/}" == "bash" ]]; then
  main "$@"
fi
