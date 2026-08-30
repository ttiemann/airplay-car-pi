#!/usr/bin/env bash
set -euo pipefail

AIRPLAY_CONFIG_FILE="${AIRPLAY_CONFIG_FILE:-/etc/default/airplay-car-pi}"
STATE_DIR="/run/airplay-car-pi"
STATE_FILE="${STATE_DIR}/network-mode"
PROBE_STAMP_FILE="${STATE_DIR}/last-home-probe"
HOTSPOT_CON_NAME="airplay-car-hotspot"

# nmcli and iw live in /usr/sbin, which is missing from some inherited environments
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ -f "${AIRPLAY_CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${AIRPLAY_CONFIG_FILE}"
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
