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
# Download one boot JDK for a specific JDK feature version.
#
# Arguments:
#   $1  jdk_version  — numeric JDK version to download (e.g. 21, 25, 28)
#   $2  dest_dir     — directory to extract into
#
# For tip/HEAD versions (tip_version) the GitHub EA repo is used.
# For GA versions (LTS / feature release) the Adoptium Releases API is used.
#
# Steps:
#   1. Locate the s390x release asset URL via GitHub or Adoptium Releases API
#   2. Download the tar.gz
#   3. Verify SHA-256
#   4. Extract
#   5. Smoke-test: java -version
#
# On failure: calls _die_jdk (exits 1)
# ---------------------------------------------------------------------------
_download_one_boot_jdk() {
    local jdk_version="$1"
    local dest_dir="$2"
    local label="boot_jdk_v${jdk_version}"

    info "========================================================"
    info "  STEP: Boot JDK download — JDK ${jdk_version}"
    info "========================================================"

    # ---- Step 1: locate asset URL -----------------------------------------
    info "[${label}] Step 1/5: locating s390x asset for JDK ${jdk_version} …"

    # Write the shared Python asset-finder once per setup_deps run
    local py_script="${CI_TMP_DIR}/find_asset.py"
    if [[ ! -f "${py_script}" ]]; then
        cat > "${py_script}" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    releases = json.load(f)
for rel in releases:
    for a in rel.get("assets", []):
        name = a["name"]
        # Match EA tar.gz (tip builds) or GA tar.gz (stable releases)
        if (name.startswith("OpenJDK-jdk_s390x_linux_hotspot_")
                and name.endswith(".tar.gz")
                and ".tar.gz.sha" not in name):
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
    fi

    local releases_json="${CI_TMP_DIR}/gh_releases_${jdk_version}.json"
    local gh_api="https://api.github.com/repos/${ADOPTIUM_GITHUB_ORG}/temurin${jdk_version}-binaries/releases"
    info "  URL: ${gh_api}?per_page=5"

    if ! curl --fail --silent --show-error --location \
         --max-time 30 \
         --output "${releases_json}" \
         "${gh_api}?per_page=5"; then
        _die_jdk "[${label}] Step 1 FAILED: GitHub API request failed for temurin${jdk_version}-binaries."
    fi
    if [[ ! -s "${releases_json}" ]]; then
        _die_jdk "[${label}] Step 1 FAILED: GitHub API returned empty response for JDK ${jdk_version}."
    fi

    local asset_info asset_name jdk_url sha_url
    if ! asset_info="$(python3 "${py_script}" "${releases_json}")"; then
        _die_jdk "[${label}] Step 1 FAILED: no s390x linux JDK tar.gz found in temurin${jdk_version}-binaries releases."
    fi
    asset_name="$(echo "${asset_info}" | sed -n '1p')"
    jdk_url="$(echo "${asset_info}"    | sed -n '2p')"
    sha_url="$(echo "${asset_info}"    | sed -n '3p')"
    info "  Asset : ${asset_name}"
    info "  URL   : ${jdk_url}"

    # ---- Step 2: download --------------------------------------------------
    info "[${label}] Step 2/5: downloading archive …"
    local archive="${CI_TMP_DIR}/boot_jdk_${jdk_version}.tar.gz"
    info "  Destination: ${archive}"
    if ! curl --fail --silent --show-error --location \
         --max-time 300 \
         --output "${archive}" \
         "${jdk_url}"; then
        _die_jdk "[${label}] Step 2 FAILED: download of ${jdk_url} failed."
    fi
    if [[ ! -s "${archive}" ]]; then
        _die_jdk "[${label}] Step 2 FAILED: downloaded archive is empty (0 bytes)."
    fi
    info "  Downloaded: $(du -h "${archive}" | cut -f1)"

    # ---- Step 3: SHA-256 verify --------------------------------------------
    info "[${label}] Step 3/5: verifying SHA-256 checksum …"
    if [[ -n "${sha_url}" ]]; then
        local sha_file="${CI_TMP_DIR}/boot_jdk_${jdk_version}.tar.gz.sha256.txt"
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
                _die_jdk "[${label}] Step 3 FAILED: SHA-256 mismatch.
  expected: ${expected_sha}
  actual  : ${actual_sha}"
            fi
            info "  SHA-256 verified: ${actual_sha}"
        fi
    else
        warn "  No SHA-256 URL available — skipping verification."
    fi

    # ---- Step 4: extract ---------------------------------------------------
    info "[${label}] Step 4/5: extracting to ${dest_dir} …"
    mkdir -p "${dest_dir}"
    if ! tar --strip-components=1 -xzf "${archive}" -C "${dest_dir}"; then
        _die_jdk "[${label}] Step 4 FAILED: extraction of boot JDK ${jdk_version} archive failed."
    fi
    info "  Extracted to: ${dest_dir}"

    # ---- Step 5: smoke test ------------------------------------------------
    info "[${label}] Step 5/5: smoke-testing java binary …"
    if ! "${dest_dir}/bin/java" -version 2>&1; then
        _die_jdk "[${label}] Step 5 FAILED: java binary at ${dest_dir}/bin/java is not executable."
    fi

    success "Boot JDK ${jdk_version} ready: ${dest_dir}"
}

# ---------------------------------------------------------------------------
# Download all boot JDKs required by the registered streams.
#
# Strategy:
#   1. Resolve tip_version from the Adoptium API.
#   2. Collect the unique MIN_JDK_VERSION values from JDK_STREAMS in config.sh.
#      (field 4, 1-based).  "head" uses tip_version directly.
#   3. For each unique version, download into boot_jdk_<version>/.
#   4. Create/update the tip-version symlink at BOOT_JDK_DIR so the legacy
#      variable still points at the newest available JDK.
# ---------------------------------------------------------------------------
setup_boot_jdk() {
    info "========================================================"
    info "  STEP: Boot JDK download (all required versions)"
    info "========================================================"

    # Step 1 — resolve tip_version (needed for HEAD and for BOOT_JDK_DIR alias)
    info "[boot_jdk] Resolving JDK HEAD tip_version from Adoptium API …"
    info "  URL: ${ADOPTIUM_API_BASE}/info/available_releases"
    local tip_version
    tip_version="$(
        curl --fail --silent --show-error --location \
             --max-time 30 \
             "${ADOPTIUM_API_BASE}/info/available_releases" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tip_version'])"
    )" || _die_jdk "Could not resolve tip_version from Adoptium API."
    info "  tip_version = ${tip_version}"

    # Step 2 — collect unique MIN_JDK_VERSION values from the registry.
    # JDK_STREAMS entries look like: "label|subdir|url|min_ver|extra_flags"
    # 'head' streams are mapped to tip_version.
    local -A versions_needed=()   # keyed by numeric version → dest_dir

    for entry in "${JDK_STREAMS[@]}"; do
        local label; label="$(echo "${entry}"  | cut -d'|' -f1)"
        local min_ver; min_ver="$(echo "${entry}" | cut -d'|' -f4)"

        if [[ "${label}" == "head" || -z "${min_ver}" || "${min_ver}" == "0" ]]; then
            # HEAD always uses the tip JDK
            versions_needed["${tip_version}"]="$(boot_jdk_dir_for_version "${tip_version}")"
        else
            # Map the stream's minimum required version to its versioned dir.
            # OpenJDK configure accepts boot JDK N or N+1 for version N source;
            # we use the declared MIN_JDK_VERSION directly.
            versions_needed["${min_ver}"]="$(boot_jdk_dir_for_version "${min_ver}")"
        fi
    done

    info "  Versions to download: ${!versions_needed[*]}"

    # Step 3 — download each required version
    local ver dest
    for ver in "${!versions_needed[@]}"; do
        dest="${versions_needed[${ver}]}"
        _download_one_boot_jdk "${ver}" "${dest}"
    done

    # Step 4 — point the legacy BOOT_JDK_DIR at the tip-version directory so
    # jtreg smoke-test and any direct $BOOT_JDK_DIR references still work.
    local tip_dir; tip_dir="$(boot_jdk_dir_for_version "${tip_version}")"
    # BOOT_JDK_DIR and tip_dir may already be the same path; only symlink if different
    if [[ "${BOOT_JDK_DIR}" != "${tip_dir}" && -d "${tip_dir}" ]]; then
        ln -sfn "${tip_dir}" "${BOOT_JDK_DIR}"
        info "  BOOT_JDK_DIR → ${tip_dir} (symlink updated)"
    fi

    success "All boot JDKs ready."
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
