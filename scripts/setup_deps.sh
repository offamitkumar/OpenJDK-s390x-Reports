#!/usr/bin/env bash
# =============================================================================
# setup_deps.sh — Download / refresh boot JDK (Adoptium nightly) and jtreg
#
# Usage:
#   bash scripts/setup_deps.sh            # update both
#   bash scripts/setup_deps.sh --jdk-only
#   bash scripts/setup_deps.sh --jtreg-only
#
# This script is idempotent: re-running it refreshes to the latest nightly.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Colour helpers (safe on non-TTY)
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*" >&2; }
die()     { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Check required tools
# ---------------------------------------------------------------------------
check_tools() {
  local missing=()
  for tool in curl unzip tar sha256sum; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Download latest Adoptium Temurin nightly boot JDK
# ---------------------------------------------------------------------------
setup_boot_jdk() {
  info "Fetching latest Adoptium Temurin nightly boot JDK for s390x …"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf ${tmp_dir}" RETURN

  local archive="${tmp_dir}/boot_jdk.tar.gz"

  info "  URL: ${ADOPTIUM_NIGHTLY_URL}"
  if ! curl --fail --silent --show-error --location \
       --output "${archive}" \
       "${ADOPTIUM_NIGHTLY_URL}"; then
    die "Failed to download Adoptium nightly boot JDK."
  fi

  info "  Extracting to ${BOOT_JDK_DIR} …"
  rm -rf "${BOOT_JDK_DIR}"
  mkdir -p "${BOOT_JDK_DIR}"

  tar --strip-components=1 -xzf "${archive}" -C "${BOOT_JDK_DIR}"
  success "Boot JDK installed at ${BOOT_JDK_DIR}"
  "${BOOT_JDK_DIR}/bin/java" -version
}

# ---------------------------------------------------------------------------
# Download latest jtreg from ci.adoptium.net
# ---------------------------------------------------------------------------
setup_jtreg() {
  info "Fetching latest jtreg from ci.adoptium.net …"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf ${tmp_dir}" RETURN

  local archive="${tmp_dir}/${JTREG_ARCHIVE_NAME}"

  info "  URL: ${JTREG_DOWNLOAD_URL}"
  if ! curl --fail --silent --show-error --location \
       --output "${archive}" \
       "${JTREG_DOWNLOAD_URL}"; then
    die "Failed to download jtreg."
  fi

  info "  Extracting to ${JTREG_DIR} …"
  rm -rf "${JTREG_DIR}"
  mkdir -p "$(dirname "${JTREG_DIR}")"

  unzip -q "${archive}" -d "$(dirname "${JTREG_DIR}")"

  # The zip may expand to a folder named 'jtreg' already; normalise
  local extracted
  extracted="$(unzip -Z1 "${archive}" | head -1 | cut -d/ -f1)"
  local extracted_path
  extracted_path="$(dirname "${JTREG_DIR}")/${extracted}"

  if [[ "${extracted_path}" != "${JTREG_DIR}" && -d "${extracted_path}" ]]; then
    mv "${extracted_path}" "${JTREG_DIR}"
  fi

  success "jtreg installed at ${JTREG_DIR}"
  "${JTREG_DIR}/bin/jtreg" -version 2>/dev/null || \
    "${JTREG_DIR}/lib/jtreg.jar" 2>/dev/null || \
    info "  (version check skipped)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
DO_JDK=true
DO_JTREG=true

for arg in "$@"; do
  case "$arg" in
    --jdk-only)   DO_JTREG=false ;;
    --jtreg-only) DO_JDK=false ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

check_tools

$DO_JDK   && setup_boot_jdk
$DO_JTREG && setup_jtreg

success "Dependencies ready."
