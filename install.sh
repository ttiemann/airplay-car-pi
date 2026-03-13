#!/usr/bin/env bash
set -euo pipefail

# Basic installer bootstrap for airplay-car-pi.

CORE_PACKAGES=(
  alsa-utils
  avahi-daemon
  shairport-sync
)

SHAIRPORT_CONFIG_FILE="/etc/shairport-sync.conf"
AIRPLAY_DEVICE_NAME="${AIRPLAY_DEVICE_NAME:-AirPlay Car Pi}"
AIRPLAY_BACKEND="${AIRPLAY_BACKEND:-alsa}"
AIRPLAY_LATENCY="${AIRPLAY_LATENCY:-88200}"

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
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

install_core_packages() {
  log "Installing core packages"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${CORE_PACKAGES[@]}"
}

validate_config_inputs() {
  if ! [[ "${AIRPLAY_LATENCY}" =~ ^[0-9]+$ ]]; then
    echo "AIRPLAY_LATENCY must be a positive integer, got: ${AIRPLAY_LATENCY}"
    exit 1
  fi
}

generate_shairport_config() {
  log "Generating Shairport Sync config"

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
  mixer_control_name = "Digital";
};

latencies = {
  "${AIRPLAY_BACKEND}" = ${AIRPLAY_LATENCY};
};
EOF
}

configure_shairport_service() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    log "Enabling and restarting shairport-sync"
    systemctl enable shairport-sync
    systemctl restart shairport-sync
  else
    log "systemd not available, skipping shairport-sync enable/restart"
  fi
}

main() {
  require_root "$@"

  log "Starting airplay-car-pi installer bootstrap"
  apt_update_upgrade
  install_core_packages
  validate_config_inputs
  generate_shairport_config
  configure_shairport_service

  log "Bootstrap complete"
}

main "$@"
