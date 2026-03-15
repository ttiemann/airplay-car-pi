#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
VERSION="${1:-${VERSION:-}}"
PROJECT_NAME="airplay-car-pi"

if [[ -z "${VERSION}" ]]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 v0.1.0"
  exit 1
fi

if ! [[ "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must match vX.Y.Z (for example v0.1.0)"
  exit 1
fi

mkdir -p "${DIST_DIR}"

STAGE_DIR="$(mktemp -d)"
RELEASE_DIR="${STAGE_DIR}/${PROJECT_NAME}-${VERSION}"
mkdir -p "${RELEASE_DIR}"

cleanup() {
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

if ! command -v git >/dev/null 2>&1; then
  echo "git is required to package tracked release files"
  exit 1
fi

while IFS= read -r -d '' file_path; do
  mkdir -p "${RELEASE_DIR}/$(dirname "${file_path}")"
  cp -p "${REPO_ROOT}/${file_path}" "${RELEASE_DIR}/${file_path}"
done < <(git -C "${REPO_ROOT}" ls-files -z)

TAR_PATH="${DIST_DIR}/${PROJECT_NAME}-${VERSION}.tar.gz"
ZIP_PATH="${DIST_DIR}/${PROJECT_NAME}-${VERSION}.zip"
CHECKSUM_PATH="${DIST_DIR}/${PROJECT_NAME}-${VERSION}.sha256"

rm -f "${TAR_PATH}" "${ZIP_PATH}" "${CHECKSUM_PATH}"

tar -C "${STAGE_DIR}" -czf "${TAR_PATH}" "${PROJECT_NAME}-${VERSION}"

if command -v zip >/dev/null 2>&1; then
  (
    cd "${STAGE_DIR}"
    zip -qr "${ZIP_PATH}" "${PROJECT_NAME}-${VERSION}"
  )
else
  echo "zip not found, skipping .zip artifact"
fi

{
  shasum -a 256 "${TAR_PATH}"
  if [[ -f "${ZIP_PATH}" ]]; then
    shasum -a 256 "${ZIP_PATH}"
  fi
} > "${CHECKSUM_PATH}"

echo "Created release artifacts:"
echo "  ${TAR_PATH}"
if [[ -f "${ZIP_PATH}" ]]; then
  echo "  ${ZIP_PATH}"
fi
echo "  ${CHECKSUM_PATH}"
