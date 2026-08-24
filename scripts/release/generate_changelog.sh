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

if ! command -v git >/dev/null 2>&1; then
  echo "git is required to generate changelog"
  exit 1
fi

mkdir -p "${DIST_DIR}"
OUTPUT_PATH="${DIST_DIR}/CHANGELOG-${VERSION}.md"

PREVIOUS_TAG="$(git -C "${REPO_ROOT}" tag --sort=-creatordate | awk -v version="${VERSION}" '$0 != version { print; exit }')"

if [[ -n "${PREVIOUS_TAG}" ]]; then
  RANGE="${PREVIOUS_TAG}..HEAD"
else
  RANGE="HEAD"
fi

{
  echo "# ${PROJECT_NAME} ${VERSION}"
  echo
  echo "## Changes"
  echo
  if [[ -n "${PREVIOUS_TAG}" ]]; then
    echo "Changes since ${PREVIOUS_TAG}."
  else
    echo "Initial tagged release history."
  fi
  echo

  git -C "${REPO_ROOT}" log "${RANGE}" --pretty=format:'- %s (%h)' --no-merges

  echo
  echo
  echo "## Artifacts"
  echo
  echo "- ${PROJECT_NAME}-${VERSION}.tar.gz"
  echo "- ${PROJECT_NAME}-${VERSION}.zip"
  echo "- ${PROJECT_NAME}-${VERSION}.sha256"
} > "${OUTPUT_PATH}"

echo "Generated changelog:"
echo "  ${OUTPUT_PATH}"
