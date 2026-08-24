#!/usr/bin/env bash
set -euo pipefail

# Security checks for airplay-car-pi.
#
# Checks performed:
#   1. shellcheck on all .sh files (severity: warning and above)
#   2. Hardcoded secrets grep (always runs, no external tools needed)
#   3. trivy filesystem scan for CVEs (skipped if trivy not installed)
#   4. gitleaks secret scan (skipped if gitleaks not installed)
#
# Exit code 1 if any check fails; skip messages for unavailable tools.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CHECKS_RUN=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0

pass()  { printf "[PASS] %s\n" "$1"; }
fail()  { printf "[FAIL] %s\n" "$1"; CHECKS_FAILED=$((CHECKS_FAILED + 1)); }
skip()  { printf "[SKIP] %s\n" "$1"; CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1)); }
info()  { printf "[INFO] %s\n" "$1"; }

# ── 1. shellcheck on every .sh file ──────────────────────────────────────────
check_shellcheck() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  info "--- shellcheck (all .sh files, severity >= warning) ---"

  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
    CHECKS_RUN=$((CHECKS_RUN - 1))
    return
  fi

  local scripts=() errors=0
  while IFS= read -r line; do
    scripts+=("$line")
  done < <(find "${REPO_ROOT}" -name "*.sh" -not -path "*/\.*")

  info "Found ${#scripts[@]} script(s):"
  for s in "${scripts[@]}"; do
    printf "  %s\n" "${s#"${REPO_ROOT}/"}"
  done

  if shellcheck --severity=warning "${scripts[@]}"; then
    pass "shellcheck: all scripts clean"
  else
    fail "shellcheck: issues found (see above)"
    errors=$((errors + 1))
  fi
}

# ── 2. Hardcoded secrets grep ─────────────────────────────────────────────────
# Looks for common secret patterns that should never appear in committed code.
# Deliberately conservative: only matches literals, not variable expansions.
check_hardcoded_secrets() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  info "--- Hardcoded secrets grep ---"

  local patterns=(
    'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY'
    'AKIA[0-9A-Z]{16}'                         # AWS access key ID
    'password\s*=\s*"[^"$({][^"]*"'            # password = "literal"
    'secret\s*=\s*"[^"$({][^"]*"'              # secret   = "literal"
    'token\s*=\s*"[^"$({][^"]*"'               # token    = "literal"
    'api[_-]?key\s*=\s*"[^"$({][^"]*"'         # api_key  = "literal"
  )

  local hits=0 pattern
  for pattern in "${patterns[@]}"; do
    local matches
    matches="$(grep -rniE "${pattern}" \
      --include="*.sh" --include="*.yml" --include="*.yaml" \
      --include="*.env" --include="*.conf" --include="*.json" \
      --exclude-dir=".git" \
      "${REPO_ROOT}" 2>/dev/null \
      | grep -v "security_check.sh" \
      || true)"

    if [[ -n "${matches}" ]]; then
      printf "[WARN] Pattern '%s' matched:\n" "${pattern}"
      printf "%s\n" "${matches}" | sed 's/^/  /'
      hits=$((hits + 1))
    fi
  done

  if [[ "${hits}" -eq 0 ]]; then
    pass "hardcoded secrets: none found"
  else
    fail "hardcoded secrets: ${hits} pattern(s) matched (see above)"
  fi
}

# ── 3. trivy filesystem scan ──────────────────────────────────────────────────
check_trivy() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  info "--- trivy filesystem CVE scan (HIGH + CRITICAL) ---"

  if ! command -v trivy >/dev/null 2>&1; then
    skip "trivy not installed (install: https://aquasecurity.github.io/trivy/)"
    CHECKS_RUN=$((CHECKS_RUN - 1))
    return
  fi

  if trivy fs \
       --exit-code 1 \
       --severity HIGH,CRITICAL \
       --no-progress \
       "${REPO_ROOT}"; then
    pass "trivy: no HIGH/CRITICAL CVEs found"
  else
    fail "trivy: HIGH/CRITICAL CVEs detected (see above)"
  fi
}

# ── 4. gitleaks secret scan ───────────────────────────────────────────────────
check_gitleaks() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  info "--- gitleaks secret scan ---"

  if ! command -v gitleaks >/dev/null 2>&1; then
    skip "gitleaks not installed (install: https://github.com/gitleaks/gitleaks)"
    CHECKS_RUN=$((CHECKS_RUN - 1))
    return
  fi

  if gitleaks detect --source "${REPO_ROOT}" --no-git --redact --exit-code 1 2>&1; then
    pass "gitleaks: no secrets detected"
  else
    fail "gitleaks: potential secrets detected (see above)"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
info "Running security checks in ${REPO_ROOT}"

check_shellcheck
check_hardcoded_secrets
check_trivy
check_gitleaks

printf "\nChecks run: %d  skipped: %d\n" "${CHECKS_RUN}" "${CHECKS_SKIPPED}"

if [[ "${CHECKS_FAILED}" -gt 0 ]]; then
  printf "Checks failed: %d\n" "${CHECKS_FAILED}"
  exit 1
fi

printf "All security checks passed.\n"
