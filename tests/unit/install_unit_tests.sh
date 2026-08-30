#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source installer functions without executing main.
# shellcheck disable=SC1091
source "${REPO_ROOT}/install.sh"

TESTS_RUN=0
TESTS_FAILED=0

fail() {
  printf "[FAIL] %s\n" "$1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

pass() {
  printf "[PASS] %s\n" "$1"
}

assert_contains() {
  local file_path pattern
  file_path="$1"
  pattern="$2"

  if ! grep -Fq "$pattern" "$file_path"; then
    fail "Expected '$pattern' in $file_path"
    return 1
  fi
}

assert_not_contains() {
  local file_path pattern
  file_path="$1"
  pattern="$2"

  if grep -Fq "$pattern" "$file_path"; then
    fail "Did not expect '$pattern' in $file_path"
    return 1
  fi
}

assert_equals() {
  local actual expected message
  actual="$1"
  expected="$2"
  message="$3"

  if [[ "$actual" != "$expected" ]]; then
    fail "$message (expected '$expected', got '$actual')"
    return 1
  fi
}

run_test() {
  local test_name
  test_name="$1"
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$test_name"; then
    pass "$test_name"
  fi
}

test_generate_shairport_config_uses_selected_values() {
  local tmp_dir config_file
  tmp_dir="$(mktemp -d)"
  config_file="${tmp_dir}/shairport-sync.conf"

  # Variables below are read by functions sourced from install.sh.
  # shellcheck disable=SC2034
  SHAIRPORT_CONFIG_FILE="$config_file"
  # shellcheck disable=SC2034
  AIRPLAY_DEVICE_NAME="Unit Test Receiver"
  # shellcheck disable=SC2034
  AIRPLAY_BACKEND="alsa"
  # shellcheck disable=SC2034
  AIRPLAY_MIXER_CONTROL_NAME="Playback Digital"

  generate_shairport_config >/dev/null

  assert_contains "$config_file" 'name = "Unit Test Receiver";'
  assert_contains "$config_file" 'output_backend = "alsa";'
  assert_contains "$config_file" 'mixer_control_name = "Playback Digital";'
  assert_not_contains "$config_file" 'mixer_type = "software";'
  assert_not_contains "$config_file" 'latencies = {'
}

test_mode_detector_keeps_airplay_name_fixed() {
  local tmp_dir detector_file dispatcher_file watcher_file
  tmp_dir="$(mktemp -d)"
  detector_file="${tmp_dir}/airplay-car-pi-mode-check"
  dispatcher_file="${tmp_dir}/90-network-mode-check"
  watcher_file="${tmp_dir}/wifi-station-watch"

  NETWORK_MODE_ENV_FILE="${tmp_dir}/network-mode-check" \
    AIRPLAY_CONFIG_FILE="${tmp_dir}/airplay-car-pi.conf" \
    NETWORK_MODE_CHECK_SCRIPT="$detector_file" \
    NETWORK_MODE_SERVICE_FILE="${tmp_dir}/network-mode-check.service" \
    NETWORK_MODE_TIMER_FILE="${tmp_dir}/network-mode-check.timer" \
    NETWORK_MANAGER_DISPATCHER_FILE="$dispatcher_file" \
    WIFI_STATION_WATCH_SCRIPT="$watcher_file" \
    WIFI_STATION_WATCH_SERVICE_FILE="${tmp_dir}/wifi-station-watch.service" \
    install_mode_detector_files >/dev/null

  assert_not_contains "$detector_file" 'AIRPLAY_CAR_SUFFIX'
  assert_not_contains "$detector_file" 'shairport-sync.conf'
  assert_not_contains "$detector_file" 'systemctl restart shairport-sync'
  assert_contains "$dispatcher_file" 'source "${AIRPLAY_CONFIG_FILE}"'
  assert_contains "$dispatcher_file" '"${action}" == "down"'
  assert_contains "$dispatcher_file" 'systemctl start network-mode-check.service || true'
  assert_contains "$watcher_file" 'rm -f "${probe_stamp_file}"'
}

test_generate_shairport_config_uses_software_mixer_when_no_control_available() {
  local tmp_dir config_file
  tmp_dir="$(mktemp -d)"
  config_file="${tmp_dir}/shairport-sync.conf"

  # Variables below are read by functions sourced from install.sh.
  # shellcheck disable=SC2034
  SHAIRPORT_CONFIG_FILE="$config_file"
  # shellcheck disable=SC2034
  AIRPLAY_DEVICE_NAME="Unit Test Receiver"
  # shellcheck disable=SC2034
  AIRPLAY_BACKEND="alsa"
  # shellcheck disable=SC2034
  AIRPLAY_MIXER_CONTROL_NAME=""

  # shellcheck disable=SC2329
  amixer() { return 127; }

  generate_shairport_config >/dev/null

  unset -f amixer

  assert_not_contains "$config_file" 'mixer_type = "software";'
  assert_not_contains "$config_file" 'mixer_control_name = "'
}

test_get_boot_config_file_prefers_primary_path() {
  local tmp_dir primary legacy selected
  tmp_dir="$(mktemp -d)"
  primary="${tmp_dir}/firmware-config.txt"
  legacy="${tmp_dir}/legacy-config.txt"

  BOOT_CONFIG_PRIMARY="$primary"
  BOOT_CONFIG_LEGACY="$legacy"

  printf "# primary\n" >"$primary"
  printf "# legacy\n" >"$legacy"

  selected="$(get_boot_config_file)"
  assert_equals "$selected" "$primary" "Primary boot config should be selected first"
}

test_configure_hifiberry_dac_is_idempotent() {
  local tmp_dir boot_cfg overlay_count
  tmp_dir="$(mktemp -d)"
  boot_cfg="${tmp_dir}/config.txt"

  # Variables below are read by functions sourced from install.sh.
  # shellcheck disable=SC2034
  BOOT_CONFIG_PRIMARY="$boot_cfg"
  # shellcheck disable=SC2034
  BOOT_CONFIG_LEGACY="${tmp_dir}/unused-legacy.txt"

  cat >"$boot_cfg" <<'EOF'
# test config

dtparam=audio=on
EOF

  configure_hifiberry_dac >/dev/null
  configure_hifiberry_dac >/dev/null

  assert_contains "$boot_cfg" 'dtparam=audio=off'

  overlay_count="$(grep -c '^dtoverlay=hifiberry-dac$' "$boot_cfg")"
  assert_equals "$overlay_count" "1" "Overlay line should be present exactly once"
}

test_configure_boot_time_optimizations_is_idempotent() {
  local tmp_dir boot_cfg cmdline parameter count
  tmp_dir="$(mktemp -d)"
  boot_cfg="${tmp_dir}/config.txt"
  cmdline="${tmp_dir}/cmdline.txt"

  BOOT_CONFIG_PRIMARY="$boot_cfg"
  BOOT_CONFIG_LEGACY="${tmp_dir}/unused-legacy-config.txt"
  BOOT_CMDLINE_PRIMARY="$cmdline"
  BOOT_CMDLINE_LEGACY="${tmp_dir}/unused-legacy-cmdline.txt"
  DISABLE_BLUETOOTH=1

  printf '# test config\nhdmi_blanking=1\n' >"$boot_cfg"
  printf 'console=serial0,115200 root=/dev/mmcblk0p2 rootwait\n' >"$cmdline"

  configure_boot_time_optimizations >/dev/null
  configure_boot_time_optimizations >/dev/null

  for parameter in quiet fastboot loglevel=3 logo.nologo console=tty3 vt.global_cursor_default=0; do
    assert_contains "$cmdline" "$parameter"
    count="$(grep -Fow "$parameter" "$cmdline" | wc -l | tr -d ' ')"
    assert_equals "$count" "1" "Kernel parameter '$parameter' should be present exactly once"
  done

  assert_equals "$(wc -l < "$cmdline" | tr -d ' ')" "1" "Kernel command line should remain one line"
  assert_contains "$boot_cfg" 'hdmi_blanking=2'
  assert_contains "$boot_cfg" 'dtoverlay=disable-bt'
}

main() {
  run_test test_generate_shairport_config_uses_selected_values
  run_test test_mode_detector_keeps_airplay_name_fixed
  run_test test_generate_shairport_config_uses_software_mixer_when_no_control_available
  run_test test_get_boot_config_file_prefers_primary_path
  run_test test_configure_hifiberry_dac_is_idempotent
  run_test test_configure_boot_time_optimizations_is_idempotent

  printf "\nTests run: %d\n" "$TESTS_RUN"

  if [[ "$TESTS_FAILED" -gt 0 ]]; then
    printf "Tests failed: %d\n" "$TESTS_FAILED"
    exit 1
  fi

  printf "All unit tests passed.\n"
}

main "$@"
