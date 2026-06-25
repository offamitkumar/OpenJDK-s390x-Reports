#!/usr/bin/env bash
# =============================================================================
# run_daily.sh — Daily CI orchestrator: tier1 tests across all active streams
#
# What it does, in order:
#   1. Refresh dependencies (Adoptium nightly boot JDK + latest jtreg)
#   2. Resolve active JDK streams via Adoptium API (auto-adds new versions,
#      auto-skips retired ones)
#   3. For each active stream:
#        a. Pull latest source from upstream
#        b. Build fastdebug image → run tier1 → collect artefacts
#        c. Build release   image → run tier1 → collect artefacts
#   4. Commit and push all new report files to the main branch
#
# Usage:
#   bash scripts/run_daily.sh [--stream head] [--level fastdebug]
#
# Optional flags:
#   --stream LABEL   Only run the named stream (e.g. "head", "jdk21")
#   --level  LEVEL   Only run this debug level ("fastdebug" or "release")
#   --skip-deps      Skip setup_deps.sh (use existing /tmp/openjdk-s390x-ci)
#   --dry-run        Print what would run, don't build or test
#
# Any config.sh variable can be overridden by exporting before calling:
#   JDK_SOURCES_ROOT=/custom/path bash scripts/run_daily.sh
#
# Exit codes:
#   0  — pipeline completed (individual test failures are recorded, not fatal)
#   1  — hard infrastructure failure (deps, source, git)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/build_test.sh
source "${SCRIPT_DIR}/build_test.sh"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()     { echo "$(date -u '+%H:%M:%S') [RUN]   $*"; }
info()    { echo "$(date -u '+%H:%M:%S') [INFO]  $*"; }
success() { echo "$(date -u '+%H:%M:%S') [OK]    $*"; }
warn()    { echo "$(date -u '+%H:%M:%S') [WARN]  $*" >&2; }
die()     { echo "$(date -u '+%H:%M:%S') [FATAL] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
FILTER_STREAM=""
FILTER_LEVEL=""
SKIP_DEPS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stream)     FILTER_STREAM="$2"; shift 2 ;;
        --level)      FILTER_LEVEL="$2";  shift 2 ;;
        --skip-deps)  SKIP_DEPS=true;     shift   ;;
        --dry-run)    DRY_RUN=true;       shift   ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Trap: always return to repo root on exit
# ---------------------------------------------------------------------------
trap 'cd "${REPORTS_REPO_ROOT}"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — Refresh dependencies
# ---------------------------------------------------------------------------
refresh_deps() {
    if ${SKIP_DEPS}; then
        info "Skipping dependency refresh (--skip-deps)"
        [[ -x "${BOOT_JDK_DIR}/bin/java" ]] \
            || die "Boot JDK not found at ${BOOT_JDK_DIR} — cannot skip deps."
        [[ -x "${JTREG_DIR}/bin/jtreg" ]] \
            || die "jtreg not found at ${JTREG_DIR} — cannot skip deps."
        return
    fi
    log "Refreshing boot JDK and jtreg …"
    bash "${SCRIPT_DIR}/setup_deps.sh"
}

# ---------------------------------------------------------------------------
# Step 2 — Resolve active streams
#
# Pipes the JDK_STREAMS registry through resolve_streams.py, which calls the
# Adoptium API and filters out any version no longer in active support.
# Returns the filtered list in ACTIVE_STREAMS array.
# ---------------------------------------------------------------------------
resolve_active_streams() {
    log "Resolving active JDK streams …"

    local registry_input=""
    for entry in "${JDK_STREAMS[@]}"; do
        registry_input+="${entry}"$'\n'
    done

    # Run resolver: stderr (status lines) go to our stderr, stdout captured
    local filtered
    filtered="$(echo "${registry_input}" | python3 "${SCRIPT_DIR}/resolve_streams.py")"

    # Apply --stream filter if given
    ACTIVE_STREAMS=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local label
        label="$(echo "${line}" | cut -d'|' -f1)"
        if [[ -n "${FILTER_STREAM}" && "${label}" != "${FILTER_STREAM}" ]]; then
            continue
        fi
        ACTIVE_STREAMS+=("${line}")
    done <<< "${filtered}"

    if [[ ${#ACTIVE_STREAMS[@]} -eq 0 ]]; then
        die "No active streams after filtering. Check --stream value or registry."
    fi

    log "Active streams (${#ACTIVE_STREAMS[@]}):"
    for s in "${ACTIVE_STREAMS[@]}"; do
        info "  → $(echo "${s}" | cut -d'|' -f1)"
    done
}

# ---------------------------------------------------------------------------
# Step 3a — Pull (or shallow-clone) a single JDK source repo
# ---------------------------------------------------------------------------
prepare_source() {
    local label="$1"
    local src_subdir="$2"
    local git_url="$3"

    local src_dir="${JDK_SOURCES_ROOT}/${src_subdir}"

    log "[${label}] Preparing source at ${src_dir} …"

    if [[ -d "${src_dir}/.git" ]]; then
        info "  Existing repo — pulling latest from origin/master …"
        git -C "${src_dir}" fetch --prune origin
        git -C "${src_dir}" checkout master
        git -C "${src_dir}" pull --ff-only origin master
    else
        info "  No repo found — cloning ${git_url} …"
        mkdir -p "${JDK_SOURCES_ROOT}"
        git clone --depth=1 "${git_url}" "${src_dir}"
    fi

    local top_commit
    top_commit="$(git -C "${src_dir}" log -1 \
        --format='commit %H%nauthor %an <%ae>%ndate   %ad%n%n    %s' \
        --date=rfc)"
    info "  Top commit: $(git -C "${src_dir}" log -1 --oneline)"
    echo "${top_commit}"
}

# ---------------------------------------------------------------------------
# Step 3b — Build+test one stream at one debug level; record artefacts
# ---------------------------------------------------------------------------
run_level() {
    local label="$1"
    local src_dir="$2"
    local debug_level="$3"
    local out_base="$4"
    shift 4
    local extra_flags=("$@")

    # Apply --level filter
    if [[ -n "${FILTER_LEVEL}" && "${debug_level}" != "${FILTER_LEVEL}" ]]; then
        info "[${label}] Skipping ${debug_level} (--level filter)"
        return 0
    fi

    local out_dir="${out_base}/${debug_level}"
    mkdir -p "${out_dir}"

    log "[${label}] Starting build+test: ${debug_level} …"

    if ${DRY_RUN}; then
        info "[${label}] DRY-RUN: would run build_and_test_jdk ${src_dir} ${label} ${debug_level} ${out_dir} ${extra_flags[*]:-}"
        return 0
    fi

    local exit_code=0
    build_and_test_jdk \
        "${src_dir}" \
        "${label}" \
        "${debug_level}" \
        "${out_dir}" \
        "${extra_flags[@]}" \
        || exit_code=$?

    if [[ ${exit_code} -ne 0 ]]; then
        warn "[${label}] Build/setup error (exit=${exit_code}) — recorded, continuing."
        echo "BUILD/SETUP ERROR — exit ${exit_code}" >> "${out_dir}/build.log"
        echo "Build failed (exit ${exit_code})"      >  "${out_dir}/test-summary.txt"
    fi

    log "[${label}] Finished ${debug_level} (exit=${exit_code})"
}

# ---------------------------------------------------------------------------
# Step 3 — Process every active stream
# ---------------------------------------------------------------------------
process_streams() {
    local year month day
    year="$(date +%Y)"; month="$(date +%B)"; day="$(date +%d)"

    for entry in "${ACTIVE_STREAMS[@]}"; do
        # Parse pipe-separated fields
        IFS='|' read -r label src_subdir git_url _min_ver extra_flags \
            <<< "${entry}"

        local src_dir="${JDK_SOURCES_ROOT}/${src_subdir}"
        local out_base="${REPORTS_DIR}/${year}/${month}/${day}/${label}"
        mkdir -p "${out_base}"

        # Pull source
        local top_commit
        top_commit="$(prepare_source "${label}" "${src_subdir}" "${git_url}")" \
            || { warn "[${label}] Source preparation failed — skipping."; continue; }
        echo "${top_commit}" > "${out_base}/top_commit"

        # Split extra_flags string into array (may be empty)
        local flags_arr=()
        if [[ -n "${extra_flags}" ]]; then
            # shellcheck disable=SC2206
            flags_arr=(${extra_flags})
        fi

        # Build+test both debug levels
        for level in "${BUILD_LEVELS[@]}"; do
            run_level "${label}" "${src_dir}" "${level}" "${out_base}" \
                "${flags_arr[@]+"${flags_arr[@]}"}"
        done

        success "[${label}] Stream complete."
    done
}

# ---------------------------------------------------------------------------
# Step 4 — Commit and push all new report files
# ---------------------------------------------------------------------------
publish_results() {
    if ${DRY_RUN}; then
        info "DRY-RUN: would commit and push reports to origin/${GIT_RESULTS_BRANCH}"
        return 0
    fi

    log "Publishing results to git …"
    cd "${REPORTS_REPO_ROOT}"

    git fetch origin "${GIT_RESULTS_BRANCH}"
    git checkout "${GIT_RESULTS_BRANCH}"
    git pull --ff-only origin "${GIT_RESULTS_BRANCH}"

    git add "${REPORTS_DIR}/"

    if git diff --cached --quiet; then
        info "  Nothing new to commit."
        return 0
    fi

    local year month day
    year="$(date +%Y)"; month="$(date +%B)"; day="$(date +%d)"

    # List which streams were run
    local stream_list=""
    for entry in "${ACTIVE_STREAMS[@]}"; do
        stream_list+="  $(echo "${entry}" | cut -d'|' -f1)"$'\n'
    done

    git \
        -c "user.name=${GIT_COMMIT_AUTHOR_NAME}" \
        -c "user.email=${GIT_COMMIT_AUTHOR_EMAIL}" \
        commit -m "report: tier1 results ${year}-${month}-${day}

Automated s390x CI run.
Streams tested:
${stream_list}Levels: fastdebug + release
Host:   $(hostname)
"

    git push origin "${GIT_RESULTS_BRANCH}"
    success "Results pushed to origin/${GIT_RESULTS_BRANCH}."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "============================================================"
    log "OpenJDK s390x CI — daily tier1 run"
    log "$(date -u)"
    ${DRY_RUN}         && log "MODE: DRY-RUN"
    [[ -n "${FILTER_STREAM}" ]] && log "FILTER: stream=${FILTER_STREAM}"
    [[ -n "${FILTER_LEVEL}"  ]] && log "FILTER: level=${FILTER_LEVEL}"
    log "============================================================"

    refresh_deps
    resolve_active_streams
    process_streams
    publish_results

    log "============================================================"
    log "Done."
    log "============================================================"
}

main "$@"
