#!/usr/bin/env bash
set -euo pipefail

# Basic installer bootstrap for airplay-car-pi.

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

NETWORK_MODE_ENV_FILE="/etc/default/network-mode-check"
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

  cat >"${NETWORK_MODE_ENV_FILE}" <<EOF
AIRPLAY_DEVICE_NAME="${AIRPLAY_DEVICE_NAME}"
CAR_AP_SSID="${CAR_AP_SSID}"
CAR_AP_PASSWORD="${CAR_AP_PASSWORD}"
CAR_AP_IFACE="${CAR_AP_IFACE}"
CAR_AP_CHANNEL="${CAR_AP_CHANNEL}"
CAR_AP_HOME_PROBE_SEC="${CAR_AP_HOME_PROBE_SEC}"
EOF

  cat >"${NETWORK_MODE_CHECK_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODE_ENV_FILE="/etc/default/network-mode-check"
STATE_DIR="/run/airplay-car-pi"
STATE_FILE="${STATE_DIR}/network-mode"
PROBE_STAMP_FILE="${STATE_DIR}/last-home-probe"
HOTSPOT_CON_NAME="airplay-car-hotspot"

# nmcli and iw live in /usr/sbin, which is missing from some inherited environments
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ -f "${MODE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${MODE_ENV_FILE}"
fi

ap_iface="${CAR_AP_IFACE:-wlan0}"
ap_ssid="${CAR_AP_SSID:-AirPlay-Car-Pi}"
ap_password="${CAR_AP_PASSWORD:-airplaycarpi}"
ap_channel="${CAR_AP_CHANNEL:-6}"
home_probe_sec="${CAR_AP_HOME_PROBE_SEC:-180}"

log_msg() {
  if command -v logger >/dev/null 2>&1; then
    logger -t airplay-car-pi-mode "$*" || true
  fi
}

home_connection_name() {
  nmcli -t -e no -f NAME,TYPE connection show 2>/dev/null |
    awk -F: -v skip="${HOTSPOT_CON_NAME}" '$2=="802-11-wireless" && $1!=skip {print $1; exit}'
}

detect_configured_ssid() {
  local ssid file conn_name

  if [[ -f /etc/wpa_supplicant/wpa_supplicant.conf ]]; then
    ssid="$(sed -n 's/^[[:space:]]*ssid="\([^"]*\)".*/\1/p' /etc/wpa_supplicant/wpa_supplicant.conf | head -n1 || true)"
    if [[ -n "${ssid}" ]]; then
      printf "%s\n" "${ssid}"
      return
    fi
  fi

  for file in /etc/NetworkManager/system-connections/*.nmconnection; do
    if [[ ! -f "${file}" ]]; then
      continue
    fi
    # never mistake our own access-point profile for the home network
    if grep -q '^mode=ap' "${file}"; then
      continue
    fi
    ssid="$(sed -n 's/^ssid=//p' "${file}" | head -n1 || true)"
    if [[ -n "${ssid}" ]]; then
      printf "%s\n" "${ssid}"
      return
    fi
  done

  # netplan-managed connections have no on-disk .nmconnection file; query NetworkManager directly.
  if command -v nmcli >/dev/null 2>&1; then
    conn_name="$(home_connection_name)"
    if [[ -n "${conn_name}" ]]; then
      ssid="$(nmcli -g 802-11-wireless.ssid connection show "${conn_name}" 2>/dev/null || true)"
      if [[ -n "${ssid}" ]]; then
        printf "%s\n" "${ssid}"
        return
      fi
    fi
  fi

  printf "%s\n" ""
}

get_current_ssid() {
  nmcli -t -e no -f active,ssid dev wifi 2>/dev/null | awk -F: '/^yes/{print $2; exit}' || true
}

hotspot_is_active() {
  nmcli -t -e no -f NAME connection show --active 2>/dev/null | grep -Fxq "${HOTSPOT_CON_NAME}"
}

hotspot_has_clients() {
  local leases

  if command -v iw >/dev/null 2>&1; then
    if iw dev "${ap_iface}" station dump 2>/dev/null | grep -q '^Station'; then
      return 0
    fi
    return 1
  fi

  # no iw available: fall back to NetworkManager's shared-mode DHCP leases
  for leases in /var/lib/NetworkManager/dnsmasq-*.leases; do
    if [[ -s "${leases}" ]]; then
      return 0
    fi
  done

  return 1
}

ensure_hotspot_profile() {
  local out rc

  rc=0
  if ! nmcli -t -e no -f NAME connection show 2>/dev/null | grep -Fxq "${HOTSPOT_CON_NAME}"; then
    out="$(nmcli connection add type wifi ifname "${ap_iface}" con-name "${HOTSPOT_CON_NAME}" autoconnect no ssid "${ap_ssid}" 2>&1)" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      log_msg "hotspot profile create failed (rc=${rc}): ${out}"
      return 1
    fi
  fi

  rc=0
  out="$(nmcli connection modify "${HOTSPOT_CON_NAME}" \
    connection.interface-name "${ap_iface}" \
    connection.autoconnect no \
    802-11-wireless.mode ap \
    802-11-wireless.band bg \
    802-11-wireless.channel "${ap_channel}" \
    802-11-wireless.ssid "${ap_ssid}" \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.proto rsn \
    802-11-wireless-security.pairwise ccmp \
    802-11-wireless-security.group ccmp \
    802-11-wireless-security.pmf disable \
    802-11-wireless-security.psk "${ap_password}" \
    ipv4.method shared \
    ipv6.method ignore 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_msg "hotspot profile configure failed (rc=${rc}): ${out}"
    return 1
  fi

  return 0
}

connect_home() {
  local out rc home_con

  home_con="$(home_connection_name)"
  if [[ -z "${home_con}" ]]; then
    log_msg "no home Wi-Fi profile found"
    return 1
  fi

  # never use `nmcli device connect`: it reactivates the most recently used
  # profile, which is the hotspot itself, and still reports success
  rc=0
  out="$(nmcli -w 30 connection up "${home_con}" ifname "${ap_iface}" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_msg "home reconnect failed (rc=${rc}): ${out}"
    return 1
  fi

  return 0
}

start_hotspot() {
  local out rc

  if ! ensure_hotspot_profile; then
    return 1
  fi

  # release wlan0 from the home profile, otherwise NetworkManager keeps
  # auto-retrying the missing SSID and refuses to hand the radio to AP mode
  nmcli device disconnect "${ap_iface}" >/dev/null 2>&1 || true

  rc=0
  out="$(nmcli connection up "${HOTSPOT_CON_NAME}" ifname "${ap_iface}" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_msg "hotspot activation failed (rc=${rc}): ${out}"
    # give the radio back so the Pi can still rejoin home Wi-Fi
    connect_home || true
    return 1
  fi

  mkdir -p "${STATE_DIR}"
  printf "%s\n" "$(date +%s)" >"${PROBE_STAMP_FILE}"
  log_msg "hotspot up ssid=${ap_ssid} iface=${ap_iface} channel=${ap_channel}"
  return 0
}

stop_hotspot() {
  local attempt

  nmcli connection down "${HOTSPOT_CON_NAME}" >/dev/null 2>&1 || true

  # nmcli returns before the radio actually leaves AP mode; reconnecting too
  # early fails and would strand the Pi with neither hotspot nor home Wi-Fi
  for attempt in 1 2 3 4 5; do
    if ! hotspot_is_active; then
      break
    fi
    sleep 1
  done

  connect_home
}

wait_for_home_ssid() {
  local waited

  # activation already blocked above; this only covers the DHCP/settle gap
  for ((waited = 0; waited < 10; waited += 2)); do
    if [[ "$(get_current_ssid)" == "${home_wifi_ssid}" ]]; then
      return 0
    fi
    sleep 2
  done

  return 1
}

home_wifi_ssid="$(detect_configured_ssid)"
current_ssid=""
mode="AWAY"

previous_mode=""
if [[ -f "${STATE_FILE}" ]]; then
  previous_mode="$(cat "${STATE_FILE}" 2>/dev/null || true)"
fi

if hotspot_is_active; then
  current_ssid="$(get_current_ssid)"
  if [[ -n "${home_wifi_ssid}" && "${current_ssid}" == "${home_wifi_ssid}" ]]; then
    # The radio is already on the home network; there is no need to probe it
    # again or drop the hotspot. This avoids pointless AP churn in steady-state.
    mode="CONFIGURED_SSID"
    log_msg "home ssid already active; skipping periodic probe"
  else
    now="$(date +%s)"
    last_probe=0
    if [[ -f "${PROBE_STAMP_FILE}" ]]; then
      last_probe="$(cat "${PROBE_STAMP_FILE}" 2>/dev/null || echo 0)"
    fi

    # in AP mode the radio cannot scan, so drop the hotspot periodically to
    # check whether the home network is reachable again
    if [[ -n "${home_wifi_ssid}" && $((now - last_probe)) -ge "${home_probe_sec}" ]]; then
      if hotspot_has_clients; then
        # a phone is attached (probably streaming): never break its session
        printf "%s\n" "${now}" >"${PROBE_STAMP_FILE}"
        log_msg "home probe deferred: hotspot client connected"
      else
        printf "%s\n" "${now}" >"${PROBE_STAMP_FILE}"
        log_msg "probing for home ssid=${home_wifi_ssid}"
        stop_hotspot || true
        if wait_for_home_ssid; then
          current_ssid="${home_wifi_ssid}"
          mode="CONFIGURED_SSID"
        else
          log_msg "home ssid not reachable, staying in car mode"
        fi
      fi
    fi
  fi
elif [[ -n "${home_wifi_ssid}" ]]; then
  current_ssid="$(get_current_ssid)"
  if [[ "${current_ssid}" == "${home_wifi_ssid}" ]]; then
    mode="CONFIGURED_SSID"
    log_msg "home ssid already active; periodic probe disabled"
  fi
fi

if [[ "${mode}" == "AWAY" ]]; then
  # retried on every tick: a failed activation must not leave the Pi
  # stranded with neither home Wi-Fi nor a hotspot
  if ! hotspot_is_active; then
    start_hotspot || true
  fi
else
  if hotspot_is_active; then
    stop_hotspot
  fi
  rm -f "${PROBE_STAMP_FILE}"
fi

mkdir -p "${STATE_DIR}"
printf "%s\n" "${mode}" >"${STATE_FILE}"

log_msg "mode=${mode} previous=${previous_mode:-none} ssid=${current_ssid:-none} hotspot=$(hotspot_is_active && echo yes || echo no)"
EOF

  chmod +x "${NETWORK_MODE_CHECK_SCRIPT}"

  cat >"${NETWORK_MODE_SERVICE_FILE}" <<EOF
[Unit]
Description=Network mode detection
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=120
ExecStart=${NETWORK_MODE_CHECK_SCRIPT}
EOF

  cat >"${NETWORK_MODE_TIMER_FILE}" <<EOF
[Unit]
Description=Run network mode detection periodically

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
Unit=network-mode-check.service
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat >"${NETWORK_MANAGER_DISPATCHER_FILE}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODE_ENV_FILE="/etc/default/network-mode-check"

if [[ -f "${MODE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${MODE_ENV_FILE}"
fi

iface="${1:-}"
action="${2:-}"

if [[ "${iface}" == "${CAR_AP_IFACE:-wlan0}" && "${action}" == "down" ]]; then
  systemctl start network-mode-check.service || true
fi
EOF

  chmod +x "${NETWORK_MANAGER_DISPATCHER_FILE}"

  cat >"${WIFI_STATION_WATCH_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODE_ENV_FILE="/etc/default/network-mode-check"

# nmcli, iw and systemctl live in /usr/sbin, which is missing from some inherited environments
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ -f "${MODE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${MODE_ENV_FILE}"
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
EOF

  chmod +x "${WIFI_STATION_WATCH_SCRIPT}"

  cat >"${WIFI_STATION_WATCH_SERVICE_FILE}" <<EOF
[Unit]
Description=Wi-Fi station disconnect watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WIFI_STATION_WATCH_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
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
  generate_shairport_config
  configure_shairport_service
  install_mode_detector_files
  configure_mode_detector_service

  log "Bootstrap complete"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || "${0##*/}" == "bash" ]]; then
  main "$@"
fi
