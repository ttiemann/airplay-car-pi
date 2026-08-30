#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_INSTALLER="${REPO_ROOT}/install.sh"
ASSET_ROOT="${REPO_ROOT}/scripts/src"
OUTPUT_PATH="${1:-${REPO_ROOT}/dist/install.sh}"

ASSETS=(
  "bin/network-mode-check.sh"
  "bin/wifi-station-watch.sh"
  "NetworkManager/dispatcher.d/90-network-mode-check"
  "systemd/network-mode-check.service"
  "systemd/network-mode-check.timer"
  "systemd/wifi-station-watch.service"
)

make_delimiter() {
  local asset_path sanitized
  asset_path="$1"
  sanitized="${asset_path//[^[:alnum:]]/_}"
  printf "__AIRPLAY_CAR_PI_ASSET_%s__\n" "${sanitized}"
}

write_embedded_function() {
  local asset_path asset_file delimiter

  printf '%s\n' 'extract_embedded_installer_asset() {'
  printf '%s\n' '  local asset_path'
  printf '%s\n' '  asset_path="${1:-}"'
  printf '%s\n' '  case "${asset_path}" in'

  for asset_path in "${ASSETS[@]}"; do
    asset_file="${ASSET_ROOT}/${asset_path}"
    delimiter="$(make_delimiter "${asset_path}")"

    if [[ ! -f "${asset_file}" ]]; then
      echo "Missing asset ${asset_file}" >&2
      return 1
    fi
    if grep -Fqx "${delimiter}" "${asset_file}"; then
      echo "Asset ${asset_file} contains generated delimiter ${delimiter}" >&2
      return 1
    fi

    printf '    %q)\n' "${asset_path}"
    printf '      cat <<'"'%s'"'\n' "${delimiter}"
    cat "${asset_file}"
    printf '%s\n' "${delimiter}"
    printf '%s\n' '      ;;'
  done

  printf '%s\n' '    *)'
  printf '%s\n' '      return 1'
  printf '%s\n' '      ;;'
  printf '%s\n' '  esac'
  printf '%s\n' '}'
}

mkdir -p "$(dirname "${OUTPUT_PATH}")"
embedded_function_file="$(mktemp)"
trap 'rm -f "${embedded_function_file}"' EXIT
write_embedded_function >"${embedded_function_file}"

awk -v embedded_function_file="${embedded_function_file}" '
  function print_embedded_function() {
    while ((getline line < embedded_function_file) > 0) {
      print line
    }
    close(embedded_function_file)
  }

  $0 == "extract_embedded_installer_asset() {" {
    print_embedded_function()
    getline
    getline
    next
  }

  { print }
' "${SOURCE_INSTALLER}" >"${OUTPUT_PATH}"

chmod +x "${OUTPUT_PATH}"
echo "Created bundled installer: ${OUTPUT_PATH}"
