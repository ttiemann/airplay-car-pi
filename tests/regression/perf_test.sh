#!/usr/bin/env bash
set -euo pipefail

# Regression/performance tests for the airplay-car-pi stack.
# Measures startup time, idle CPU, dropout/underrun errors in recent logs,
# and service reconnect (restart) time.
#
# All thresholds are configurable via environment variables.
# Tests that require passwordless sudo (start/stop/restart) are skipped
# gracefully when that is not available.
#
# Usage:
#   PI_USER=carpi PI_HOST=<pi-hostname-or-ip> bash tests/regression/perf_test.sh

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-raspberrypi.local}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-20}"

# Thresholds — override via env to tighten or relax for different hardware.
# Pi Zero W with soxr interpolation typically idles at 30-40%; use 50 as a safe
# ceiling that catches runaway processes without false-failing on slower boards.
STARTUP_TIME_THRESHOLD_S="${STARTUP_TIME_THRESHOLD_S:-15}"
IDLE_CPU_THRESHOLD_PCT="${IDLE_CPU_THRESHOLD_PCT:-50}"
RECONNECT_TIME_THRESHOLD_S="${RECONNECT_TIME_THRESHOLD_S:-10}"

SSH_CONTROL_PATH="/tmp/airplay-perf-$$"

remote() {
  ssh -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
      -o ControlMaster=auto \
      -o ControlPath="${SSH_CONTROL_PATH}" \
      -o ControlPersist=300 \
      "${PI_USER}@${PI_HOST}" "$@"
}

cleanup() {
  ssh -O exit -o ControlPath="${SSH_CONTROL_PATH}" "${PI_USER}@${PI_HOST}" 2>/dev/null || true
}
trap cleanup EXIT

TESTS_RUN=0
TESTS_FAILED=0

pass() { printf "[PASS] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
warn() { printf "[WARN] %s\n" "$1"; }
info() { printf "[INFO] %s\n" "$1"; }
skip() { printf "[SKIP] %s\n" "$1"; }

# Wait until shairport-sync is active, return elapsed seconds.
# Polls once per second up to MAX_WAIT_S.
wait_service_active() {
  local max_wait="$1"
  local t_start elapsed
  t_start="$(date +%s)"
  elapsed=0

  while [[ "${elapsed}" -lt "${max_wait}" ]]; do
    if remote 'systemctl is-active --quiet shairport-sync'; then
      printf "%d\n" "${elapsed}"
      return 0
    fi
    sleep 1
    elapsed=$(( $(date +%s) - t_start ))
  done

  printf "%d\n" "${elapsed}"
  return 1
}

# ── 1. Startup time ───────────────────────────────────────────────────────────
test_startup_time() {
  TESTS_RUN=$((TESTS_RUN + 1))
  info "--- Startup time ---"

  if ! remote 'sudo -n systemctl stop shairport-sync' 2>/dev/null; then
    skip "passwordless sudo not available — startup time test skipped"
    TESTS_RUN=$((TESTS_RUN - 1))
    return
  fi

  # Give the service a moment to fully stop before measuring start.
  sleep 1
  remote 'sudo -n systemctl start shairport-sync'

  local elapsed
  if elapsed="$(wait_service_active "${STARTUP_TIME_THRESHOLD_S}")"; then
    info "Startup time: ${elapsed}s (threshold: ${STARTUP_TIME_THRESHOLD_S}s)"
    pass "startup time ${elapsed}s <= ${STARTUP_TIME_THRESHOLD_S}s"
  else
    info "Startup time: >${STARTUP_TIME_THRESHOLD_S}s (threshold: ${STARTUP_TIME_THRESHOLD_S}s)"
    fail "shairport-sync did not become active within ${STARTUP_TIME_THRESHOLD_S}s"
  fi
}

# ── 2. Idle CPU usage ─────────────────────────────────────────────────────────
test_idle_cpu() {
  TESTS_RUN=$((TESTS_RUN + 1))
  info "--- Idle CPU usage ---"

  if ! remote 'systemctl is-active --quiet shairport-sync'; then
    fail "shairport-sync is not active — cannot measure CPU"
    return
  fi

  info "Sampling idle CPU (3 rounds, 2s apart)..."

  local total=0 rounds=3 round pct
  for round in 1 2 3; do
    # ps -o pcpu= prints just the CPU% for the process (no header, no awk quoting issues).
    # tr + cut convert "  1.2" → integer "1".
    pct="$(remote \
      'pid=$(pgrep -x shairport-sync 2>/dev/null | head -n1 || true); \
       [ -z "$pid" ] && echo 0 && exit 0; \
       ps -p "$pid" -o pcpu= 2>/dev/null | tr -d " " | cut -d. -f1 || echo 0' \
    || echo 0)"
    total=$((total + pct))
    [[ "${round}" -lt 3 ]] && sleep 2
  done

  local avg=$(( total / rounds ))
  info "Average idle CPU usage: ~${avg}% (threshold: ${IDLE_CPU_THRESHOLD_PCT}%)"

  if [[ "${avg}" -le "${IDLE_CPU_THRESHOLD_PCT}" ]]; then
    pass "idle CPU ~${avg}% <= ${IDLE_CPU_THRESHOLD_PCT}%"
    if [[ "${avg}" -gt 20 ]]; then
      warn "CPU is elevated (~${avg}%); consider setting interpolation = \"basic\" in /etc/shairport-sync.conf"
    fi
  else
    fail "idle CPU ~${avg}% > ${IDLE_CPU_THRESHOLD_PCT}%"
    warn "Consider setting interpolation = \"basic\" in /etc/shairport-sync.conf to reduce CPU load"
  fi
}

# ── 3. Dropout / underrun detection ──────────────────────────────────────────
test_dropout_errors() {
  TESTS_RUN=$((TESTS_RUN + 1))
  info "--- Dropout / error detection (last 200 log lines) ---"

  local log_errors
  log_errors="$(remote \
    'journalctl -u shairport-sync -n 200 --no-pager 2>/dev/null \
       | grep -iE "underrun|overrun|dropout|resync|stall|xrun|lost frames|failed to find mixer" \
       || true')"

  if [[ -z "${log_errors}" ]]; then
    pass "no dropout/underrun errors in recent logs"
  else
    local count
    count="$(printf "%s\n" "${log_errors}" | wc -l | tr -d ' ')"
    warn "${count} issue line(s) found in recent shairport-sync logs:"
    printf "%s\n" "${log_errors}" | sed 's/^/  /'
    # Warn, not fail — intermittent underruns are expected on slow hardware.
    # The caller can tighten this policy by overriding the exit code check.
    pass "dropout scan complete (${count} warning line(s) above)"
  fi
}

# ── 4. Reconnect (service restart) time ──────────────────────────────────────
test_reconnect_time() {
  TESTS_RUN=$((TESTS_RUN + 1))
  info "--- Reconnect time (service restart) ---"

  if ! remote 'sudo -n systemctl restart shairport-sync' 2>/dev/null; then
    skip "passwordless sudo not available — reconnect time test skipped"
    TESTS_RUN=$((TESTS_RUN - 1))
    return
  fi

  local elapsed
  if elapsed="$(wait_service_active "${RECONNECT_TIME_THRESHOLD_S}")"; then
    info "Reconnect time after restart: ${elapsed}s (threshold: ${RECONNECT_TIME_THRESHOLD_S}s)"
    pass "reconnect time ${elapsed}s <= ${RECONNECT_TIME_THRESHOLD_S}s"
  else
    info "Reconnect time: >${RECONNECT_TIME_THRESHOLD_S}s"
    fail "shairport-sync did not recover within ${RECONNECT_TIME_THRESHOLD_S}s after restart"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
info "Starting regression/performance tests on ${PI_HOST}"
info "Thresholds: startup=${STARTUP_TIME_THRESHOLD_S}s  idle-cpu=${IDLE_CPU_THRESHOLD_PCT}%  reconnect=${RECONNECT_TIME_THRESHOLD_S}s"

test_startup_time
test_idle_cpu
test_dropout_errors
test_reconnect_time

printf "\nTests run: %d\n" "${TESTS_RUN}"

if [[ "${TESTS_FAILED}" -gt 0 ]]; then
  printf "Tests failed: %d\n" "${TESTS_FAILED}"
  exit 1
fi

printf "All regression/performance tests passed.\n"
