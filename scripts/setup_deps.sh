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
  for tool in curl tar sha256sum python3; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Resolve the current JDK HEAD tip_version from the Adoptium API,
# then download the latest EA nightly for that version from the
# corresponding adoptium/temurin{N}-binaries GitHub Releases repo.
#
# Asset naming convention (as observed from the GitHub releases page):
#   OpenJDK-jdk_s390x_linux_hotspot_{VER}_{BUILD}-ea.tar.gz
# Companion SHA-256 file:
#   OpenJDK-jdk_s390x_linux_hotspot_{VER}_{BUILD}-ea.tar.gz.sha256.txt
# ---------------------------------------------------------------------------
setup_boot_jdk() {
  info "Resolving JDK HEAD tip_version from Adoptium API …"

  # Step 1: get the current tip_version (e.g. 28)
  local tip_version
  tip_version="$(
    curl --fail --silent --show-error --location \
         --max-time 30 \
         "${ADOPTIUM_API_BASE}/info/available_releases" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tip_version'])"
  )" || die "Failed to resolve tip_version from Adoptium API."

  info "  tip_version = ${tip_version} (JDK HEAD)"

  # Step 2: find the latest release in temurin{N}-binaries that has a
  #         JDK s390x linux tar.gz asset.
  # We save the API response to a file first, then parse it with a
  # python3 script file — avoids the stdin conflict that occurs when
  # piping curl output into `python3 - <<'HEREDOC'`.
  local gh_api="https://api.github.com/repos/${ADOPTIUM_GITHUB_ORG}/temurin${tip_version}-binaries/releases"
  info "  Querying GitHub releases: ${gh_api}"

  local releases_json="${CI_TMP_DIR}/gh_releases.json"
  if ! curl --fail --silent --show-error --location \
       --max-time 30 \
       --output "${releases_json}" \
       "${gh_api}?per_page=5"; then
    die "Failed to query GitHub releases for temurin${tip_version}-binaries."
  fi

  if [[ ! -s "${releases_json}" ]]; then
    die "GitHub releases response is empty for temurin${tip_version}-binaries."
  fi

  # Write the parser to a temp file so python3 reads the script from
  # a file descriptor and the JSON from a separate file argument.
  local py_script="${CI_TMP_DIR}/find_asset.py"
  cat > "${py_script}" <<'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    releases = json.load(f)

for rel in releases:
    for a in rel.get("assets", []):
        name = a["name"]
        if (name.startswith("OpenJDK-jdk_s390x_linux_hotspot_")
                and name.endswith("-ea.tar.gz")):
            sha_name = name + ".sha256.txt"
            sha_url = next(
                (x["browser_download_url"] for x in rel["assets"]
                 if x["name"] == sha_name),
                ""
            )
            print(name)
            print(a["browser_download_url"])
            print(sha_url)
            sys.exit(0)

sys.exit(1)
PYEOF

  local asset_name jdk_url sha_url
  if ! asset_info="$(python3 "${py_script}" "${releases_json}")"; then
    die "No s390x linux JDK tar.gz found in the latest temurin${tip_version}-binaries releases."
  fi

  asset_name="$(echo "${asset_info}" | sed -n '1p')"
  jdk_url="$(echo "${asset_info}"    | sed -n '2p')"
  sha_url="$(echo "${asset_info}"    | sed -n '3p')"

  info "  Asset    : ${asset_name}"
  info "  JDK URL  : ${jdk_url}"
  info "  SHA URL  : ${sha_url}"

  # Step 3: download the archive
  local archive="${CI_TMP_DIR}/boot_jdk.tar.gz"
  if ! curl --fail --silent --show-error --location \
       --max-time 300 \
       --output "${archive}" \
       "${jdk_url}"; then
    die "Failed to download boot JDK archive."
  fi

  if [[ ! -s "${archive}" ]]; then
    die "Downloaded boot JDK archive is empty."
  fi

  # Step 4: verify SHA-256 if companion file is available
  if [[ -n "${sha_url}" ]]; then
    local sha_file="${CI_TMP_DIR}/boot_jdk.tar.gz.sha256.txt"
    if curl --fail --silent --show-error --location \
            --max-time 30 \
            --output "${sha_file}" \
            "${sha_url}"; then
      local expected_sha actual_sha
      expected_sha="$(awk '{print $1}' "${sha_file}")"
      actual_sha="$(sha256sum "${archive}" | awk '{print $1}')"
      if [[ "${expected_sha}" != "${actual_sha}" ]]; then
        die "Boot JDK SHA-256 mismatch!
  expected: ${expected_sha}
  actual:   ${actual_sha}"
      fi
      info "  SHA-256 verified: ${actual_sha}"
    else
      warn "Could not download SHA-256 companion — skipping verification."
    fi
  fi

  # Step 5: extract (archive has a single top-level jdk-XX+N/ dir — strip it)
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
  JAVA_HOME="${BOOT_JDK_DIR}" "${JTREG_DIR}/bin/jtreg" -version 2>/dev/null || \
    info "  (version check skipped)"
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
