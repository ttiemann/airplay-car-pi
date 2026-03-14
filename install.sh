#!/usr/bin/env bash
set -euo pipefail

# Basic installer bootstrap for airplay-car-pi.

CORE_PACKAGES=(
  alsa-utils
  avahi-daemon
  shairport-sync
)

SHAIRPORT_CONFIG_FILE="/etc/shairport-sync.conf"
HIFIBERRY_OVERLAY="dtoverlay=hifiberry-dac"
AIRPLAY_DEVICE_NAME="${AIRPLAY_DEVICE_NAME:-AirPlay Car Pi}"
AIRPLAY_BACKEND="${AIRPLAY_BACKEND:-alsa}"

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
  configure_hifiberry_dac
  generate_shairport_config
  configure_shairport_service

  log "Bootstrap complete"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
