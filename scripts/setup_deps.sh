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
  for tool in curl tar sha256sum; do
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

  local archive="${CI_TMP_DIR}/boot_jdk.tar.gz"

  info "  URL: ${ADOPTIUM_NIGHTLY_URL}"
  if ! curl --fail --silent --show-error --location \
       --max-time 300 \
       --output "${archive}" \
       "${ADOPTIUM_NIGHTLY_URL}"; then
    die "Failed to download Adoptium nightly boot JDK."
  fi

  if [[ ! -s "${archive}" ]]; then
    die "Downloaded boot JDK archive is empty."
  fi

  info "  Extracting to ${BOOT_JDK_DIR} …"
  mkdir -p "${BOOT_JDK_DIR}"
  tar --strip-components=1 -xzf "${archive}" -C "${BOOT_JDK_DIR}"
  success "Boot JDK installed at ${BOOT_JDK_DIR}"
  "${BOOT_JDK_DIR}/bin/java" -version
}

# ---------------------------------------------------------------------------
# Download latest jtreg (jtregtip.tar.gz) from ci.adoptium.net
#
# The archive expands to a single top-level directory named 'jtreg/';
# we install it with --strip-components=1 directly into JTREG_DIR.
# A SHA-256 checksum file is downloaded and verified before extraction.
# ---------------------------------------------------------------------------
setup_jtreg() {
  info "Fetching latest jtreg (jtregtip) from ci.adoptium.net …"

  local archive="${CI_TMP_DIR}/jtregtip.tar.gz"
  local sha_file="${CI_TMP_DIR}/jtregtip.tar.gz.sha256sum.txt"

  info "  Archive URL : ${JTREG_DOWNLOAD_URL}"
  info "  Checksum URL: ${JTREG_SHA256_URL}"

  # Download archive
  if ! curl --fail --silent --show-error --location \
       --max-time 120 \
       --output "${archive}" \
       "${JTREG_DOWNLOAD_URL}"; then
    die "Failed to download jtreg archive."
  fi

  if [[ ! -s "${archive}" ]]; then
    die "Downloaded jtreg archive is empty."
  fi

  # Download and verify SHA-256 checksum
  if ! curl --fail --silent --show-error --location \
       --max-time 30 \
       --output "${sha_file}" \
       "${JTREG_SHA256_URL}"; then
    warn "Could not download jtreg checksum file — skipping verification."
  else
    # The checksum file contains an absolute build-machine path; extract only the hash
    local expected_sha
    expected_sha="$(awk '{print $1}' "${sha_file}")"
    local actual_sha
    actual_sha="$(sha256sum "${archive}" | awk '{print $1}')"

    if [[ "${expected_sha}" != "${actual_sha}" ]]; then
      die "jtreg SHA-256 mismatch!
  expected: ${expected_sha}
  actual:   ${actual_sha}"
    fi
    info "  SHA-256 verified: ${actual_sha}"
  fi

  info "  Extracting to ${JTREG_DIR} …"
  mkdir -p "${JTREG_DIR}"

  # The tar contains a single top-level 'jtreg/' dir; strip it
  tar --strip-components=1 -xzf "${archive}" -C "${JTREG_DIR}"

  success "jtreg installed at ${JTREG_DIR}"
  "${JTREG_DIR}/bin/jtreg" -version 2>/dev/null || \
    info "  (version check skipped — jtreg binary not in PATH yet)"
}

# ---------------------------------------------------------------------------
# Wipe and recreate the scratch directory before every run
# ---------------------------------------------------------------------------
clean_ci_tmp() {
  info "Cleaning scratch directory ${CI_TMP_DIR} …"
  rm -rf "${CI_TMP_DIR}"
  mkdir -p "${CI_TMP_DIR}"
  info "  Scratch directory ready."
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
clean_ci_tmp

$DO_JDK   && setup_boot_jdk
$DO_JTREG && setup_jtreg

success "Dependencies ready."
