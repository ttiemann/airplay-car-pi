#!/usr/bin/env bash
set -euo pipefail

# Basic installer bootstrap for airplay-car-pi.

CORE_PACKAGES=(
  alsa-utils
  avahi-daemon
  shairport-sync
)

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

main() {
  require_root "$@"

  log "Starting airplay-car-pi installer bootstrap"
  apt_update_upgrade
  install_core_packages

  log "Bootstrap complete"
}

main "$@"
