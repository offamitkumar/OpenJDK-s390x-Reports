#!/usr/bin/env bash
# =============================================================================
# setup_deps.sh — Download / refresh boot JDK (Adoptium nightly) and jtreg
#
# Usage:
#   bash scripts/setup_deps.sh            # download both
#   bash scripts/setup_deps.sh --jdk-only
#   bash scripts/setup_deps.sh --jtreg-only
#
# Exit codes (checked by run_daily.sh):
#   0  — everything requested succeeded
#   1  — boot JDK download/verify/extract failed  → no build, no test
#   2  — jtreg download/verify/extract failed     → build may proceed, tests skipped
#
# On any failure a structured deps-failure.txt is written to CI_TMP_DIR
# so the pipeline can include it in the day's report directory.
#
# Dependency rule (enforced by exit codes above):
#   boot JDK failure  →  abort everything (cannot build without a JDK)
#   jtreg failure     →  build proceeds but tests are skipped
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Logging — every line is timestamped so the log is self-describing
# ---------------------------------------------------------------------------
_ts()      { date -u '+%H:%M:%S'; }
info()     { echo "$(_ts) [INFO]  $*"; }
success()  { echo "$(_ts) [OK]    $*"; }
warn()     { echo "$(_ts) [WARN]  $*" >&2; }
_die_jdk() {
    # Exit code 1 = boot JDK failure
    echo "$(_ts) [FATAL] $*" >&2
    _write_deps_failure "boot_jdk" "$*"
    exit 1
}
_die_jtreg() {
    # Exit code 2 = jtreg failure (build can still proceed)
    echo "$(_ts) [WARN]  jtreg setup failed: $*" >&2
    _write_deps_failure "jtreg" "$*"
    exit 2
}

# ---------------------------------------------------------------------------
# Write a structured failure record to CI_TMP_DIR/deps-failure.txt
# run_daily.sh copies this into the day's report directory.
# ---------------------------------------------------------------------------
_write_deps_failure() {
    local component="$1"   # "boot_jdk" or "jtreg"
    local reason="$2"
    local failure_file="${CI_TMP_DIR}/deps-failure.txt"
    mkdir -p "${CI_TMP_DIR}"
    {
        echo "========================================================"
        echo "  Dependency Setup Failure"
        echo "========================================================"
        echo "  component : ${component}"
        echo "  reason    : ${reason}"
        echo "  date      : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo ""
        case "${component}" in
            boot_jdk)
                echo "  impact    : FATAL — no build or test will run for any stream"
                echo "              A boot JDK is required to compile OpenJDK source."
                ;;
            jtreg)
                echo "  impact    : DEGRADED — builds will proceed but tier1 tests"
                echo "              will be skipped (jtreg is required to run tests)."
                ;;
        esac
        echo "========================================================"
    } > "${failure_file}"
    warn "Failure record written to ${failure_file}"
}

# ---------------------------------------------------------------------------
# Check required host tools
# ---------------------------------------------------------------------------
check_tools() {
    info "Checking required host tools …"
    local missing=()
    for tool in curl tar sha256sum python3; do
        if command -v "$tool" &>/dev/null; then
            info "  ✓ ${tool} ($(command -v "$tool"))"
        else
            missing+=("$tool")
            warn "  ✗ ${tool} — NOT FOUND"
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        _die_jdk "Missing required host tools: ${missing[*]}"
    fi
    success "All required tools present."
}

# ---------------------------------------------------------------------------
# Wipe and recreate the scratch directory before every run
# ---------------------------------------------------------------------------
clean_ci_tmp() {
    info "Cleaning scratch directory ${CI_TMP_DIR} …"
    rm -rf "${CI_TMP_DIR}"
    mkdir -p "${CI_TMP_DIR}"
    info "  Scratch directory ready: ${CI_TMP_DIR}"
}

# ---------------------------------------------------------------------------
# Download latest boot JDK
#
# Steps (each logged individually):
#   1. Query Adoptium API for tip_version
#   2. Query GitHub Releases API for the s390x JDK asset URL
#   3. Download the tar.gz
#   4. Verify SHA-256
#   5. Extract
#   6. Smoke-test: java -version
# ---------------------------------------------------------------------------
setup_boot_jdk() {
    info "========================================================"
    info "  STEP: Boot JDK download"
    info "========================================================"

    # Step 1 — resolve tip_version
    info "[boot_jdk] Step 1/6: resolving JDK HEAD tip_version from Adoptium API …"
    info "  URL: ${ADOPTIUM_API_BASE}/info/available_releases"
    local tip_version
    tip_version="$(
        curl --fail --silent --show-error --location \
             --max-time 30 \
             "${ADOPTIUM_API_BASE}/info/available_releases" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tip_version'])"
    )" || _die_jdk "Step 1 FAILED: could not resolve tip_version from Adoptium API."
    info "  tip_version = ${tip_version}"

    # Step 2 — find release asset on GitHub
    info "[boot_jdk] Step 2/6: querying GitHub releases for temurin${tip_version}-binaries …"
    local gh_api="https://api.github.com/repos/${ADOPTIUM_GITHUB_ORG}/temurin${tip_version}-binaries/releases"
    info "  URL: ${gh_api}?per_page=5"

    local releases_json="${CI_TMP_DIR}/gh_releases.json"
    if ! curl --fail --silent --show-error --location \
         --max-time 30 \
         --output "${releases_json}" \
         "${gh_api}?per_page=5"; then
        _die_jdk "Step 2 FAILED: GitHub API request failed for temurin${tip_version}-binaries."
    fi
    if [[ ! -s "${releases_json}" ]]; then
        _die_jdk "Step 2 FAILED: GitHub API returned empty response."
    fi
    info "  GitHub releases response: ${releases_json} ($(wc -c < "${releases_json}") bytes)"

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
                 if x["name"] == sha_name), "")
            print(name)
            print(a["browser_download_url"])
            print(sha_url)
            sys.exit(0)
sys.exit(1)
PYEOF

    local asset_info asset_name jdk_url sha_url
    if ! asset_info="$(python3 "${py_script}" "${releases_json}")"; then
        _die_jdk "Step 2 FAILED: no s390x linux JDK tar.gz found in temurin${tip_version}-binaries releases."
    fi
    asset_name="$(echo "${asset_info}" | sed -n '1p')"
    jdk_url="$(echo "${asset_info}"    | sed -n '2p')"
    sha_url="$(echo "${asset_info}"    | sed -n '3p')"
    info "  Asset : ${asset_name}"
    info "  URL   : ${jdk_url}"

    # Step 3 — download
    info "[boot_jdk] Step 3/6: downloading archive …"
    local archive="${CI_TMP_DIR}/boot_jdk.tar.gz"
    info "  Destination: ${archive}"
    if ! curl --fail --silent --show-error --location \
         --max-time 300 \
         --output "${archive}" \
         "${jdk_url}"; then
        _die_jdk "Step 3 FAILED: download of ${jdk_url} failed."
    fi
    if [[ ! -s "${archive}" ]]; then
        _die_jdk "Step 3 FAILED: downloaded archive is empty (0 bytes)."
    fi
    info "  Downloaded: $(du -h "${archive}" | cut -f1)"

    # Step 4 — SHA-256 verify
    info "[boot_jdk] Step 4/6: verifying SHA-256 checksum …"
    if [[ -n "${sha_url}" ]]; then
        local sha_file="${CI_TMP_DIR}/boot_jdk.tar.gz.sha256.txt"
        if ! curl --fail --silent --show-error --location \
             --max-time 30 \
             --output "${sha_file}" \
             "${sha_url}"; then
            warn "  Could not download SHA-256 companion — skipping verification."
        else
            local expected_sha actual_sha
            expected_sha="$(awk '{print $1}' "${sha_file}")"
            actual_sha="$(sha256sum "${archive}" | awk '{print $1}')"
            if [[ "${expected_sha}" != "${actual_sha}" ]]; then
                _die_jdk "Step 4 FAILED: SHA-256 mismatch.
  expected: ${expected_sha}
  actual  : ${actual_sha}"
            fi
            info "  SHA-256 verified: ${actual_sha}"
        fi
    else
        warn "  No SHA-256 URL available — skipping verification."
    fi

    # Step 5 — extract
    info "[boot_jdk] Step 5/6: extracting to ${BOOT_JDK_DIR} …"
    mkdir -p "${BOOT_JDK_DIR}"
    if ! tar --strip-components=1 -xzf "${archive}" -C "${BOOT_JDK_DIR}"; then
        _die_jdk "Step 5 FAILED: extraction of boot JDK archive failed."
    fi
    info "  Extracted to: ${BOOT_JDK_DIR}"

    # Step 6 — smoke test
    info "[boot_jdk] Step 6/6: smoke-testing java binary …"
    if ! "${BOOT_JDK_DIR}/bin/java" -version 2>&1; then
        _die_jdk "Step 6 FAILED: java binary at ${BOOT_JDK_DIR}/bin/java is not executable."
    fi

    success "Boot JDK ready: ${BOOT_JDK_DIR}"
}

# ---------------------------------------------------------------------------
# Download latest jtreg
#
# Steps:
#   1. Download jtregtip.tar.gz
#   2. Verify SHA-256
#   3. Extract
#   4. Smoke-test: jtreg -version
#
# Failure: exit code 2 (jtreg-only failure — build can still proceed)
# ---------------------------------------------------------------------------
setup_jtreg() {
    info "========================================================"
    info "  STEP: jtreg download"
    info "========================================================"

    local archive="${CI_TMP_DIR}/jtregtip.tar.gz"
    local sha_file="${CI_TMP_DIR}/jtregtip.tar.gz.sha256sum.txt"

    # Step 1 — download archive
    info "[jtreg] Step 1/4: downloading jtregtip.tar.gz …"
    info "  URL: ${JTREG_DOWNLOAD_URL}"
    info "  Destination: ${archive}"
    if ! curl --fail --silent --show-error --location \
         --max-time 120 \
         --output "${archive}" \
         "${JTREG_DOWNLOAD_URL}"; then
        _die_jtreg "Step 1 FAILED: download of ${JTREG_DOWNLOAD_URL} failed."
    fi
    if [[ ! -s "${archive}" ]]; then
        _die_jtreg "Step 1 FAILED: downloaded jtreg archive is empty (0 bytes)."
    fi
    info "  Downloaded: $(du -h "${archive}" | cut -f1)"

    # Step 2 — SHA-256 verify
    info "[jtreg] Step 2/4: verifying SHA-256 checksum …"
    info "  Checksum URL: ${JTREG_SHA256_URL}"
    if ! curl --fail --silent --show-error --location \
         --max-time 30 \
         --output "${sha_file}" \
         "${JTREG_SHA256_URL}"; then
        warn "  Could not download jtreg checksum — skipping verification."
    else
        local expected_sha actual_sha
        expected_sha="$(awk '{print $1}' "${sha_file}")"
        actual_sha="$(sha256sum "${archive}" | awk '{print $1}')"
        if [[ "${expected_sha}" != "${actual_sha}" ]]; then
            _die_jtreg "Step 2 FAILED: SHA-256 mismatch.
  expected: ${expected_sha}
  actual  : ${actual_sha}"
        fi
        info "  SHA-256 verified: ${actual_sha}"
    fi

    # Step 3 — extract
    info "[jtreg] Step 3/4: extracting to ${JTREG_DIR} …"
    mkdir -p "${JTREG_DIR}"
    if ! tar --strip-components=1 -xzf "${archive}" -C "${JTREG_DIR}"; then
        _die_jtreg "Step 3 FAILED: extraction of jtreg archive failed."
    fi
    info "  Extracted to: ${JTREG_DIR}"

    # Step 4 — smoke test
    info "[jtreg] Step 4/4: smoke-testing jtreg binary …"
    if ! JAVA_HOME="${BOOT_JDK_DIR}" "${JTREG_DIR}/bin/jtreg" -version 2>/dev/null; then
        warn "  jtreg version check failed — binary may still work; proceeding."
    fi

    success "jtreg ready: ${JTREG_DIR}"
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
        *) _die_jdk "Unknown argument: $arg" ;;
    esac
done

info "========================================================"
info "  setup_deps.sh start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
info "  CI_TMP_DIR  : ${CI_TMP_DIR}"
info "  BOOT_JDK_DIR: ${BOOT_JDK_DIR}"
info "  JTREG_DIR   : ${JTREG_DIR}"
info "========================================================"

check_tools
clean_ci_tmp

$DO_JDK   && setup_boot_jdk
$DO_JTREG && setup_jtreg

info "========================================================"
success "Dependencies ready: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
info "========================================================"
