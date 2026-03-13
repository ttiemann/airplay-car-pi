#!/usr/bin/env bash
set -euo pipefail

# Diagnostic script for airplay-car-pi. Checks service status, config file, audio devices, network, and recent logs to help identify common issues.

SERVICE_NAME="shairport-sync"
CONFIG_FILE="/etc/shairport-sync.conf"
HIFIBERRY_CARD_PATTERN='hifiberry|sndrpihifiberry'

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

check_service_active() {
  if has_running_systemd; then
    if run_sudo_if_needed systemctl is-active --quiet "${SERVICE_NAME}"; then
      pass "${SERVICE_NAME} is active"
    else
      warn "${SERVICE_NAME} is not active"
    fi
  elif command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is installed, but systemd is not running"
  else
    warn "systemctl not found, cannot check service state"
  fi
}

check_service_enabled() {
  if has_running_systemd; then
    if run_sudo_if_needed systemctl is-enabled --quiet "${SERVICE_NAME}"; then
      pass "${SERVICE_NAME} is enabled at boot"
    else
      warn "${SERVICE_NAME} is not enabled at boot"
    fi
  elif command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is installed, but systemd is not running"
  else
    warn "systemctl not found, cannot check service enablement"
  fi
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

main() {
  info "Running airplay-car-pi diagnostics"
  check_service_active
  check_service_enabled
  check_config_file
  check_audio_devices
  check_network
  show_recent_logs
  info "Diagnostics complete"
}

main "$@"
