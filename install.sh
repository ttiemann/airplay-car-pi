#!/usr/bin/env bash
set -euo pipefail

# Basic installer bootstrap for airplay-car-pi.

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALLER_ASSET_ROOT="${INSTALLER_ASSET_ROOT:-${INSTALLER_DIR}/scripts/src}"

CORE_PACKAGES=(
  alsa-utils
  avahi-daemon
  dnsmasq-base
  iw
  network-manager
  shairport-sync
)

SHAIRPORT_CONFIG_FILE="/etc/shairport-sync.conf"
HIFIBERRY_OVERLAY="dtoverlay=hifiberry-dac"
AIRPLAY_DEVICE_NAME="${AIRPLAY_DEVICE_NAME:-AirPlay Car Pi}"
AIRPLAY_BACKEND="${AIRPLAY_BACKEND:-alsa}"
AIRPLAY_MIXER_CONTROL_NAME="${AIRPLAY_MIXER_CONTROL_NAME:-}"

CAR_AP_SSID="${CAR_AP_SSID:-AirPlay-Car-Pi}"
CAR_AP_PASSWORD="${CAR_AP_PASSWORD:-airplaycarpi}"
CAR_AP_IFACE="${CAR_AP_IFACE:-wlan0}"
CAR_AP_CHANNEL="${CAR_AP_CHANNEL:-6}"
CAR_AP_HOME_PROBE_SEC="${CAR_AP_HOME_PROBE_SEC:-180}"

# Power is cut abruptly at ignition-off in a vehicle; a read-only overlay
# root protects the SD card from corruption. Set to "0" to skip (e.g. for
# development installs where the filesystem must stay writable).
OVERLAYFS_ENABLE="${OVERLAYFS_ENABLE:-1}"
DISABLE_BLUETOOTH="${DISABLE_BLUETOOTH:-0}"
SKIP_SYSTEMD_SETUP="${SKIP_SYSTEMD_SETUP:-0}"

AIRPLAY_CONFIG_FILE="${AIRPLAY_CONFIG_FILE:-/etc/default/airplay-car-pi}"
NETWORK_MODE_CHECK_SCRIPT="/usr/local/bin/network-mode-check"
NETWORK_MODE_SERVICE_FILE="/etc/systemd/system/network-mode-check.service"
NETWORK_MODE_TIMER_FILE="/etc/systemd/system/network-mode-check.timer"
NETWORK_MANAGER_DISPATCHER_FILE="/etc/NetworkManager/dispatcher.d/90-network-mode-check"
WIFI_STATION_WATCH_SCRIPT="/usr/local/bin/wifi-station-watch"
WIFI_STATION_WATCH_SERVICE_FILE="/etc/systemd/system/wifi-station-watch.service"

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

get_boot_cmdline_file() {
  local primary_boot_cmdline legacy_boot_cmdline

  primary_boot_cmdline="${BOOT_CMDLINE_PRIMARY:-/boot/firmware/cmdline.txt}"
  legacy_boot_cmdline="${BOOT_CMDLINE_LEGACY:-/boot/cmdline.txt}"

  if [[ -f "${primary_boot_cmdline}" ]]; then
    printf "%s\n" "${primary_boot_cmdline}"
  elif [[ -f "${legacy_boot_cmdline}" ]]; then
    printf "%s\n" "${legacy_boot_cmdline}"
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
  fi
  # No mixer_control_name means shairport-sync falls back to software volume
  # control automatically; the "mixer_type" setting is deprecated and ignored.

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

configure_boot_time_optimizations() {
  local boot_config_file boot_cmdline_file cmdline_contents parameter
  local -a kernel_parameters=(
    quiet
    fastboot
    loglevel=3
    logo.nologo
    console=tty3
    vt.global_cursor_default=0
  )

  boot_config_file="$(get_boot_config_file)"
  boot_cmdline_file="$(get_boot_cmdline_file)"

  if [[ -n "${boot_cmdline_file}" ]]; then
    log "Configuring kernel boot options in ${boot_cmdline_file}"
    cmdline_contents="$(tr '\n' ' ' < "${boot_cmdline_file}")"
    for parameter in "${kernel_parameters[@]}"; do
      if ! grep -Fqw "${parameter}" <<<"${cmdline_contents}"; then
        cmdline_contents+=" ${parameter}"
      fi
    done
    printf "%s\n" "${cmdline_contents}" > "${boot_cmdline_file}"
  else
    log "Raspberry Pi kernel command line not found, skipping kernel boot options"
  fi

  if [[ -z "${boot_config_file}" ]]; then
    log "Raspberry Pi boot config not found, skipping HDMI and Bluetooth boot options"
    return
  fi

  log "Configuring HDMI boot options in ${boot_config_file}"
  if grep -Eq '^\s*hdmi_blanking=' "${boot_config_file}"; then
    sed -i '' 's/^\s*hdmi_blanking=.*/hdmi_blanking=2/' "${boot_config_file}" 2>/dev/null || \
      sed -i 's/^\s*hdmi_blanking=.*/hdmi_blanking=2/' "${boot_config_file}"
  else
    printf "\n%s\n" "hdmi_blanking=2" >> "${boot_config_file}"
  fi

  if [[ "${DISABLE_BLUETOOTH}" == "1" ]] && ! grep -Fxq 'dtoverlay=disable-bt' "${boot_config_file}"; then
    log "Disabling unused Bluetooth hardware in ${boot_config_file}"
    printf "%s\n" 'dtoverlay=disable-bt' >> "${boot_config_file}"
  fi
}

has_running_systemd() {
  [[ "${SKIP_SYSTEMD_SETUP}" != "1" ]] &&
    command -v systemctl >/dev/null 2>&1 &&
    [[ -d /run/systemd/system ]] &&
    ! systemd-detect-virt --chroot --quiet
}

enable_read_only_overlay() {
  if [[ "${OVERLAYFS_ENABLE}" != "1" ]]; then
    log "OVERLAYFS_ENABLE=${OVERLAYFS_ENABLE}, skipping read-only overlay filesystem setup"
    return
  fi

  if ! command -v raspi-config >/dev/null 2>&1; then
    log "raspi-config not found, skipping read-only overlay filesystem setup"
    return
  fi

  # get_overlay_conf prints "0" (success exit code) when boot=overlay is
  # already present on the kernel command line.
  if [[ "$(raspi-config nonint get_overlay_conf 2>/dev/null)" == "0" ]]; then
    log "Read-only overlay filesystem already enabled"
    return
  fi

  log "Enabling read-only overlay filesystem (root becomes read-only, dynamic state stays in tmpfs)"
  # do_overlayfs also marks /boot read-only using the same flag; runtime
  # state under /run is tmpfs already and unaffected by either change.
  if raspi-config nonint do_overlayfs 0; then
    log "Overlay filesystem enabled; a reboot is required for it to take effect."
    log "Note: root becomes read-only after reboot -- make persistent config changes before rebooting, or disable the overlay first (raspi-config nonint do_overlayfs 1)."
  else
    log "Failed to enable overlay filesystem"
  fi
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

extract_embedded_installer_asset() {
  return 1
}

install_asset_file() {
  local source_relative_path destination mode source_path destination_dir

  source_relative_path="$1"
  destination="$2"
  mode="$3"
  source_path="${INSTALLER_ASSET_ROOT}/${source_relative_path}"
  destination_dir="$(dirname "${destination}")"

  mkdir -p "${destination_dir}"

  if [[ -f "${source_path}" ]]; then
    install -m "${mode}" "${source_path}" "${destination}"
  elif extract_embedded_installer_asset "${source_relative_path}" >"${destination}"; then
    chmod "${mode}" "${destination}"
  else
    rm -f "${destination}"
    echo "Missing installer asset: ${source_relative_path}" >&2
    echo "Expected ${source_path}, or a bundled install.sh with embedded assets." >&2
    return 1
  fi
}

write_airplay_config() {
  log "Writing airplay-car-pi defaults to ${AIRPLAY_CONFIG_FILE}"

  mkdir -p "$(dirname "${AIRPLAY_CONFIG_FILE}")"
  cat >"${AIRPLAY_CONFIG_FILE}" <<EOF
AIRPLAY_DEVICE_NAME="${AIRPLAY_DEVICE_NAME}"
AIRPLAY_BACKEND="${AIRPLAY_BACKEND}"
AIRPLAY_MIXER_CONTROL_NAME="${AIRPLAY_MIXER_CONTROL_NAME}"
CAR_AP_SSID="${CAR_AP_SSID}"
CAR_AP_PASSWORD="${CAR_AP_PASSWORD}"
CAR_AP_IFACE="${CAR_AP_IFACE}"
CAR_AP_CHANNEL="${CAR_AP_CHANNEL}"
CAR_AP_HOME_PROBE_SEC="${CAR_AP_HOME_PROBE_SEC}"
DISABLE_BLUETOOTH="${DISABLE_BLUETOOTH}"
OVERLAYFS_ENABLE="${OVERLAYFS_ENABLE}"
EOF
  chmod 600 "${AIRPLAY_CONFIG_FILE}"
}

install_mode_detector_files() {
  log "Installing automatic home/away mode detector"

  write_airplay_config
  install_asset_file "bin/network-mode-check.sh" "${NETWORK_MODE_CHECK_SCRIPT}" 755
  install_asset_file "systemd/network-mode-check.service" "${NETWORK_MODE_SERVICE_FILE}" 644
  install_asset_file "systemd/network-mode-check.timer" "${NETWORK_MODE_TIMER_FILE}" 644
  install_asset_file "NetworkManager/dispatcher.d/90-network-mode-check" "${NETWORK_MANAGER_DISPATCHER_FILE}" 755
  install_asset_file "bin/wifi-station-watch.sh" "${WIFI_STATION_WATCH_SCRIPT}" 755
  install_asset_file "systemd/wifi-station-watch.service" "${WIFI_STATION_WATCH_SERVICE_FILE}" 644
}

configure_mode_detector_service() {
  if has_running_systemd; then
    log "Enabling airplay-car-pi mode detector timer"
    # older installs left a throwaway "Hotspot" profile behind
    nmcli connection delete Hotspot >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable --now network-mode-check.timer
    systemctl enable --now wifi-station-watch.service
    systemctl start network-mode-check.service
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
  configure_boot_time_optimizations
  generate_shairport_config
  configure_shairport_service
  install_mode_detector_files
  configure_mode_detector_service
  enable_read_only_overlay

  log "Bootstrap complete"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || "${0##*/}" == "bash" ]]; then
  main "$@"
fi
