#!/usr/bin/env bash
set -euo pipefail

# Diagnostic script for airplay-car-pi. Checks service status, config file, audio devices, network, and recent logs to help identify common issues.

SERVICE_NAME="shairport-sync"
CONFIG_FILE="/etc/shairport-sync.conf"
HIFIBERRY_CARD_PATTERN='hifiberry|sndrpihifiberry|hifiberrydac'

pass() {
  printf "[PASS] %s\n" "$1"
}

warn() {
  printf "[WARN] %s\n" "$1"
}

info() {
  printf "[INFO] %s\n" "$1"
}

run_sudo_if_needed() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

has_running_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

check_systemd_unit_state() {
  local subcommand state_label
  subcommand="$1"
  state_label="$2"

  if has_running_systemd; then
    # systemctl is-active/is-enabled are unprivileged reads; no sudo needed.
    if systemctl "${subcommand}" --quiet "${SERVICE_NAME}"; then
      pass "${SERVICE_NAME} is ${state_label}"
    else
      warn "${SERVICE_NAME} is not ${state_label}"
    fi
  elif command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is installed, but systemd is not running"
  else
    warn "systemctl not found, cannot check ${subcommand} state"
  fi
}

check_service_active() {
  check_systemd_unit_state \
    "is-active" \
    "active"
}

check_service_enabled() {
  check_systemd_unit_state \
    "is-enabled" \
    "enabled at boot"
}

check_config_file() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    pass "Config file found: ${CONFIG_FILE}"
  else
    warn "Config file missing: ${CONFIG_FILE}"
  fi
}

check_audio_devices() {
  if command -v aplay >/dev/null 2>&1; then
    if aplay -l | grep -q "^card "; then
      pass "Audio devices detected by ALSA"
      info "Detected audio cards:"
      aplay -l | sed -n 's/^card /  card /p'

      if aplay -l | grep -Eiq "${HIFIBERRY_CARD_PATTERN}"; then
        pass "HiFiBerry DAC appears in ALSA device list"
      else
        warn "HiFiBerry DAC not detected in ALSA device list"
      fi
    else
      warn "No ALSA audio devices detected"
    fi
  else
    warn "aplay not found, cannot inspect ALSA devices"
  fi
}

show_recent_logs() {
  if has_running_systemd; then
    info "Recent ${SERVICE_NAME} logs (last 50 lines):"
    run_sudo_if_needed journalctl -u "${SERVICE_NAME}" -n 50 --no-pager || warn "Failed to read journal logs"
  elif command -v journalctl >/dev/null 2>&1; then
    warn "journalctl is installed, but systemd journal is not running"
  else
    warn "journalctl not found, cannot display service logs"
  fi
}

check_network() {
  if command -v ip >/dev/null 2>&1; then
    if ip -o -4 addr show scope global | grep -q .; then
      pass "Network interface has IPv4 address"
      info "IPv4 addresses:"
      ip -o -4 addr show scope global | awk '{print "  " $2 ": " $4}'
    else
      warn "No global IPv4 address found"
    fi
  else
    warn "ip command not found, cannot check network interfaces"
  fi
}

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

check_wifi_mode() {
  local expected_home_ssid current_ssid

  expected_home_ssid="${HOME_WIFI_SSID:-}"

  if [[ -z "${expected_home_ssid}" ]]; then
    expected_home_ssid="$(detect_configured_ssid)"
  fi

  if [[ -z "${expected_home_ssid}" ]]; then
    info "Could not auto-detect a configured home SSID; skipping home-vs-car Wi-Fi mode check"
    return
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    warn "nmcli not found; cannot detect current Wi-Fi SSID"
    return
  fi

  # If NetworkManager hotspot is active, wlan0 is in AP mode.
  if has_running_systemd && command -v nmcli >/dev/null 2>&1 && \
     nmcli -t -f NAME connection show --active 2>/dev/null | grep -qi hotspot; then
    warn "Network mode: AWAY (car hotspot is active)"
    return
  fi

  current_ssid="$(get_current_ssid)"

  if [[ -z "${current_ssid}" ]]; then
    warn "No active Wi-Fi SSID detected (likely away from home Wi-Fi / car mode)"
    return
  fi

  info "Current Wi-Fi SSID: ${current_ssid}"

  if [[ "${current_ssid}" == "${expected_home_ssid}" ]]; then
    pass "Network mode: CONFIGURED_SSID"
  else
    warn "Network mode: AWAY (configured SSID not seen: '${expected_home_ssid}')"
  fi
}

main() {
  info "Running airplay-car-pi diagnostics"
  check_service_active
  check_service_enabled
  check_config_file
  check_audio_devices
  check_network
  check_wifi_mode
  show_recent_logs
  info "Diagnostics complete"
}

main "$@"
