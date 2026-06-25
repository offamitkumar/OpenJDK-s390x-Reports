#!/usr/bin/env bash
# =============================================================================
# jdk.sh — Human-facing CLI for OpenJDK s390x CI
#
# The single entry point for all manual interactions with the pipeline.
# For the fully-automated daily cron job, run_daily.sh is used instead.
#
# USAGE
# ─────
#   bash scripts/jdk.sh <command> [options]
#
# COMMANDS
# ────────
#   run       (DEFAULT) Refresh artifacts, build fastdebug+release, run tier1.
#             This is exactly what the daily cron job does.
#
#   build     Configure + make images only. No tests.
#
#   test      Re-use an existing build. Run tests without rebuilding.
#
# OPTIONS (all commands)
# ──────────────────────
#   --stream LABEL        Target one stream (default: head)
#   --level  LEVEL        fastdebug | release | both  (default: both)
#   --skip-deps           Skip boot JDK + jtreg download (use cached)
#   --no-push             Write report files but do not git commit/push
#   --dry-run             Print what would happen; do nothing
#
# OPTIONS (test / run only)
# ─────────────────────────
#   --test-target GROUP   jtreg test group or path
#                         Default: tier1
#                         Examples:
#                           tier1
#                           tier2
#                           test/jdk
#                           test/jdk/java/lang
#                           test/hotspot/jtreg/gc
#                           test/hotspot/jtreg/gc/epsilon/TestElasticHeapEnabled.java
#
#   --jvm-flags "FLAGS"   Extra JVM flags injected into every jtreg run.
#                         Quote the whole string if passing multiple flags.
#                         Examples:
#                           --jvm-flags "-Xint"
#                           --jvm-flags "-Xcomp"
#                           --jvm-flags "-Xmx512m -ea"
#                           --jvm-flags "-XX:+UseG1GC"
#
# EXAMPLES
# ────────
#   # Full default run (same as cron):
#   bash scripts/jdk.sh run
#
#   # Build only, fastdebug:
#   bash scripts/jdk.sh build --level fastdebug
#
#   # Re-run tier1 tests without rebuilding:
#   bash scripts/jdk.sh test
#
#   # Re-run tier1 tests, release build only:
#   bash scripts/jdk.sh test --level release
#
#   # Run a specific jtreg group:
#   bash scripts/jdk.sh test --test-target test/jdk/java/lang
#
#   # Run tier1 with -Xint (interpreter-only mode):
#   bash scripts/jdk.sh test --test-target tier1 --jvm-flags "-Xint"
#
#   # Run a single test class with -Xcomp:
#   bash scripts/jdk.sh test \
#       --test-target test/hotspot/jtreg/gc/epsilon/TestElasticHeapEnabled.java \
#       --jvm-flags "-Xcomp"
#
#   # Fastdebug build + tier1 test, no push (quick ad-hoc check):
#   bash scripts/jdk.sh run --level fastdebug --no-push
#
# EXIT CODES
# ──────────
#   0  All requested work completed (test failures are recorded, not fatal)
#   1  Infrastructure/build failure or bad arguments
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/build_test.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
COMMAND=""
OPT_STREAM="head"
OPT_LEVEL="both"
OPT_SKIP_DEPS=false
OPT_NO_PUSH=false
OPT_DRY_RUN=false
OPT_TEST_TARGET="tier1"
OPT_JVM_FLAGS=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# USAGE/,/^# =/{ /^# =/d; s/^# \{0,1\}//; p }' "$0"
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    echo "[jdk.sh] No command given — running default (run)"
    echo "         Use 'bash scripts/jdk.sh --help' for all options."
    COMMAND="run"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        run|build|test)
            COMMAND="$1"; shift ;;
        --stream)
            OPT_STREAM="$2"; shift 2 ;;
        --level)
            OPT_LEVEL="$2"
            if [[ "$OPT_LEVEL" != "fastdebug" && "$OPT_LEVEL" != "release" \
               && "$OPT_LEVEL" != "both" ]]; then
                echo "[jdk.sh] ERROR: --level must be fastdebug, release, or both" >&2
                exit 1
            fi
            shift 2 ;;
        --skip-deps)
            OPT_SKIP_DEPS=true; shift ;;
        --no-push)
            OPT_NO_PUSH=true; shift ;;
        --dry-run)
            OPT_DRY_RUN=true; shift ;;
        --test-target)
            OPT_TEST_TARGET="$2"; shift 2 ;;
        --jvm-flags)
            OPT_JVM_FLAGS="$2"; shift 2 ;;
        --help|-h)
            usage 0 ;;
        *)
            echo "[jdk.sh] ERROR: unknown argument: $1" >&2
            echo "         Run 'bash scripts/jdk.sh --help' for usage." >&2
            exit 1 ;;
    esac
done

# Default command if only options were passed
: "${COMMAND:=run}"

# Expand 'both' to the canonical BUILD_LEVELS array from config.sh
if [[ "${OPT_LEVEL}" == "both" ]]; then
    EFFECTIVE_LEVELS=("${BUILD_LEVELS[@]}")   # fastdebug release
else
    EFFECTIVE_LEVELS=("${OPT_LEVEL}")
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_ts()     { date -u '+%H:%M:%S'; }
log()     { echo "$(_ts) [jdk]   $*"; }
info()    { echo "$(_ts) [INFO]  $*"; }
success() { echo "$(_ts) [OK]    $*"; }
warn()    { echo "$(_ts) [WARN]  $*" >&2; }
die()     { echo "$(_ts) [FATAL] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Report directory — one per invocation, timestamped to the minute so
# repeated runs on the same day don't overwrite each other.
# Layout: reports/YYYY/Month/DD/manual-HHMMSS/
# ---------------------------------------------------------------------------
_YEAR="$(date +%Y)"
_MONTH="$(date +%B)"
_DAY="$(date +%d)"
_TIME="$(date +%H%M%S)"

# For --test-target, include the target in the dir name to make logs easy to
# find when running the same build with different targets.
_TARGET_SLUG="${OPT_TEST_TARGET//\//_}"   # replace / with _
_TARGET_SLUG="${_TARGET_SLUG// /-}"       # spaces → dash

case "${COMMAND}" in
    run)   _RUN_LABEL="run-${_TIME}" ;;
    build) _RUN_LABEL="build-${OPT_LEVEL}-${_TIME}" ;;
    test)  _RUN_LABEL="test-${_TARGET_SLUG}-${_TIME}" ;;
esac

OUT_BASE="${REPORTS_DIR}/${_YEAR}/${_MONTH}/${_DAY}/${_RUN_LABEL}"
mkdir -p "${OUT_BASE}"

# Tee all output to a run log
RUN_LOG="${OUT_BASE}/run.log"
exec > >(tee -a "${RUN_LOG}") 2>&1

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
log "========================================================"
log "jdk.sh — OpenJDK s390x manual CI"
log "command     : ${COMMAND}"
log "stream      : ${OPT_STREAM}"
log "level       : ${OPT_LEVEL} → ${EFFECTIVE_LEVELS[*]}"
[[ "${COMMAND}" != "build" ]] && log "test-target : ${OPT_TEST_TARGET}"
[[ -n "${OPT_JVM_FLAGS}" ]]   && log "jvm-flags   : ${OPT_JVM_FLAGS}"
${OPT_SKIP_DEPS} && log "deps        : skipped (--skip-deps)"
${OPT_NO_PUSH}   && log "push        : disabled (--no-push)"
${OPT_DRY_RUN}   && log "mode        : DRY-RUN"
log "output dir  : ${OUT_BASE}"
log "run log     : ${RUN_LOG}"
log "========================================================"

# ---------------------------------------------------------------------------
# Resolve the source directory for the requested stream
# ---------------------------------------------------------------------------
resolve_stream_src() {
    local target_label="$1"
    for entry in "${JDK_STREAMS[@]}"; do
        IFS='|' read -r lbl src_subdir _url _min _flags <<< "${entry}"
        if [[ "${lbl}" == "${target_label}" ]]; then
            echo "${JDK_SOURCES_ROOT}/${src_subdir}"
            return 0
        fi
    done
    return 1
}

# Return the correct boot JDK directory for the given stream label,
# using the MIN_JDK_VERSION field from the registry.
resolve_stream_boot_jdk() {
    local target_label="$1"

    # "head" always uses the tip JDK (BOOT_JDK_DIR)
    if [[ "${target_label}" == "head" ]]; then
        echo "${BOOT_JDK_DIR}"
        return 0
    fi

    for entry in "${JDK_STREAMS[@]}"; do
        IFS='|' read -r lbl _sub _url min_ver _flags <<< "${entry}"
        if [[ "${lbl}" == "${target_label}" ]]; then
            local candidate
            candidate="$(boot_jdk_dir_for_version "${min_ver}")"
            if [[ -x "${candidate}/bin/java" ]]; then
                echo "${candidate}"
            else
                warn "[${target_label}] Versioned boot JDK not found at ${candidate}; falling back to ${BOOT_JDK_DIR}"
                echo "${BOOT_JDK_DIR}"
            fi
            return 0
        fi
    done
    # Stream not found — use the global default
    echo "${BOOT_JDK_DIR}"
}

SRC_DIR=""
if ! SRC_DIR="$(resolve_stream_src "${OPT_STREAM}")"; then
    die "Stream '${OPT_STREAM}' is not in the registry (scripts/config.sh JDK_STREAMS)."
fi
info "Source directory : ${SRC_DIR}"

STREAM_BOOT_JDK=""
STREAM_BOOT_JDK="$(resolve_stream_boot_jdk "${OPT_STREAM}")"
info "Boot JDK         : ${STREAM_BOOT_JDK}"

# ---------------------------------------------------------------------------
# Step 1 — Download / verify dependencies
# ---------------------------------------------------------------------------
ensure_deps() {
    if ${OPT_SKIP_DEPS}; then
        if [[ ! -x "${BOOT_JDK_DIR}/bin/java" ]]; then
            die "Boot JDK not found at ${BOOT_JDK_DIR}. Remove --skip-deps to download it."
        fi
        info "Using cached boot JDK: $("${BOOT_JDK_DIR}/bin/java" -version 2>&1 | head -1)"
        if [[ ! -x "${JTREG_DIR}/bin/jtreg" ]]; then
            warn "jtreg not found at ${JTREG_DIR} — tests will be skipped."
            JTREG_OK=false
        else
            info "Using cached jtreg: ${JTREG_DIR}/bin/jtreg"
            JTREG_OK=true
        fi
        return
    fi

    log "Step 1: Downloading dependencies …"
    local deps_exit=0
    bash "${SCRIPT_DIR}/setup_deps.sh" || deps_exit=$?

    case "${deps_exit}" in
        0)
            JTREG_OK=true
            success "Boot JDK and jtreg ready."
            ;;
        1)
            [[ -f "${CI_TMP_DIR}/deps-failure.txt" ]] \
                && cat "${CI_TMP_DIR}/deps-failure.txt"
            die "Boot JDK download failed — cannot continue."
            ;;
        2)
            JTREG_OK=false
            warn "jtreg download failed — build will proceed but tests will be SKIPPED."
            ;;
        *)
            die "setup_deps.sh exited with unexpected code ${deps_exit}."
            ;;
    esac
}

JTREG_OK=false
if [[ "${COMMAND}" == "test" ]]; then
    # For test-only: we still need JTREG; boot JDK may already be present
    ensure_deps
    [[ "${JTREG_OK}" != "true" ]] \
        && die "jtreg is required for the 'test' command but is not available."
else
    ensure_deps
fi

# ---------------------------------------------------------------------------
# Step 2 — Git pull (for run and build; skipped for test-only)
# ---------------------------------------------------------------------------
prepare_src() {
    if ${OPT_DRY_RUN}; then
        info "DRY-RUN: would git pull in ${SRC_DIR}"
        return 0
    fi

    log "Step 2: Updating source (${OPT_STREAM}) …"
    if [[ -d "${SRC_DIR}/.git" ]]; then
        info "  Fetching + pulling ${SRC_DIR} …"
        git -C "${SRC_DIR}" fetch --prune origin
        git -C "${SRC_DIR}" checkout master
        git -C "${SRC_DIR}" pull --ff-only origin master
        success "  Source updated: $(git -C "${SRC_DIR}" log -1 --oneline)"
    else
        info "  No repo found — cloning …"
        # Look up URL from registry
        local git_url=""
        for entry in "${JDK_STREAMS[@]}"; do
            IFS='|' read -r lbl _sub url _min _flags <<< "${entry}"
            if [[ "${lbl}" == "${OPT_STREAM}" ]]; then
                git_url="${url}"; break
            fi
        done
        [[ -z "${git_url}" ]] && die "Could not find git URL for stream ${OPT_STREAM}"
        mkdir -p "${SRC_DIR}"
        git clone --depth=1 "${git_url}" "${SRC_DIR}"
        success "  Cloned: ${SRC_DIR}"
    fi
}

# ---------------------------------------------------------------------------
# Step 3 — Execute the requested operation per debug level
# ---------------------------------------------------------------------------
declare -A OP_STATUS=()

run_operations() {
    for level in "${EFFECTIVE_LEVELS[@]}"; do
        local level_out="${OUT_BASE}/${level}"
        mkdir -p "${level_out}"

        log "----------------------------------------------------"
        log "[${OPT_STREAM}/${level}] Starting ${COMMAND} …"
        log "----------------------------------------------------"

        if ${OPT_DRY_RUN}; then
            info "DRY-RUN: would ${COMMAND} ${OPT_STREAM}/${level}"
            OP_STATUS["${level}"]="DRY_RUN"
            continue
        fi

        local exit_code=0

        case "${COMMAND}" in
            # ---- run: full pipeline (build + tier1) ---------------
            run)
                build_and_test_jdk \
                    "${SRC_DIR}" "${OPT_STREAM}" "${level}" \
                    "${level_out}" "${JTREG_OK}" \
                    "${STREAM_BOOT_JDK}" \
                    || exit_code=$?
                ;;

            # ---- build: configure + images, no tests --------------
            build)
                build_only_jdk \
                    "${SRC_DIR}" "${OPT_STREAM}" "${level}" \
                    "${level_out}" "${STREAM_BOOT_JDK}" \
                    || exit_code=$?
                ;;

            # ---- test: reuse build, run given target ---------------
            test)
                run_tests_only \
                    "${SRC_DIR}" "${OPT_STREAM}" "${level}" \
                    "${level_out}" \
                    "${OPT_TEST_TARGET}" \
                    "${OPT_JVM_FLAGS}" \
                    || exit_code=$?
                ;;
        esac

        # Determine outcome for the summary
        if [[ ${exit_code} -ne 0 ]]; then
            OP_STATUS["${level}"]="FAILED (exit=${exit_code})"
        else
            local test_exit_line
            test_exit_line="$(grep '^test_exit:' "${level_out}/run-metadata.txt" \
                2>/dev/null | awk '{print $2}' || echo "0")"
            case "${test_exit_line}" in
                0)           OP_STATUS["${level}"]="PASSED" ;;
                SKIPPED*)    OP_STATUS["${level}"]="BUILD_ONLY (no tests)" ;;
                NO_BUILD*)   OP_STATUS["${level}"]="SKIPPED (no build found)" ;;
                *)           OP_STATUS["${level}"]="TEST_FAILURES (jtreg=${test_exit_line})" ;;
            esac
        fi

        log "[${OPT_STREAM}/${level}] Done: ${OP_STATUS[${level}]}"
    done
}

# ---------------------------------------------------------------------------
# Step 4 — Write run summary
# ---------------------------------------------------------------------------
write_summary() {
    local summary="${OUT_BASE}/run-summary.txt"
    {
        echo "========================================================"
        echo "  jdk.sh Run Summary"
        echo "========================================================"
        echo "  command      : ${COMMAND}"
        echo "  stream       : ${OPT_STREAM}"
        echo "  levels       : ${EFFECTIVE_LEVELS[*]}"
        echo "  test-target  : ${OPT_TEST_TARGET}"
        echo "  jvm-flags    : ${OPT_JVM_FLAGS:-(none)}"
        echo "  date         : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "  host         : $(hostname)"
        if [[ -x "${BOOT_JDK_DIR}/bin/java" ]]; then
            echo "  boot-jdk     : $("${BOOT_JDK_DIR}/bin/java" -version 2>&1 | head -1)"
        fi
        if [[ -x "${JTREG_DIR}/bin/jtreg" ]]; then
            echo "  jtreg        : $(JAVA_HOME="${BOOT_JDK_DIR}" \
                                       "${JTREG_DIR}/bin/jtreg" -version 2>/dev/null \
                                     | head -1 || echo 'n/a')"
        fi
        echo "  output dir   : ${OUT_BASE}"
        echo "========================================================"
        echo ""
        echo "  Results:"
        for level in "${EFFECTIVE_LEVELS[@]}"; do
            printf "    %-12s  %s\n" "${level}" "${OP_STATUS[${level}]:-not-run}"
        done
        echo ""
        echo "  Artefacts per level:"
        echo "    run-metadata.txt   — mode, versions, exit codes"
        echo "    build.log          — full make output (build/run commands)"
        echo "    build-diagnosis.txt — last compiler cmd + first error lines"
        echo "    test-summary.txt   — jtreg pass/fail totals"
        echo "    newfailures.txt    — failing test names"
        echo "    other_errors.txt   — erroring test names"
        echo "    test-passed.txt    — names of all passed tests"
        echo "    test-failed.txt    — names of all failed tests"
        echo "    test-skipped.txt   — names of all skipped tests"
        echo "    test-failure.log   — failure detail + hs_err notice"
        echo "    test-passed.md     — GitHub: passed tests"
        echo "    test-failed.md     — GitHub: failed tests + days-failing"
        echo "    test-skipped.md    — GitHub: skipped tests"
        echo "    hs_err/<timestamp>/ — JVM crash logs (local only, not pushed)"
        echo "========================================================"
    } > "${summary}"
    echo ""
    cat "${summary}"
    echo ""
    success "Summary written to: ${summary}"
}

# ---------------------------------------------------------------------------
# Step 4b — Retention purge: remove reports older than 90 days
#
# Runs unconditionally for the 'run' command (the default).
# Deletes stale day directories from disk and stages their removal in the git
# index so they are wiped from GitHub on the next push.
# Also removes local-only hs_err/ and test-support/ trees within live days.
# ---------------------------------------------------------------------------
purge_old_reports() {
    log "Step 4b: Retention purge (>90 days) …"

    if ${OPT_DRY_RUN}; then
        info "DRY-RUN: would run retention purge (gen_status.py --purge-only)"
        return 0
    fi

    if ! python3 "${SCRIPT_DIR}/gen_status.py" \
            "${REPORTS_DIR}" "${REPORTS_REPO_ROOT}" --purge-only 2>&1; then
        warn "Retention purge failed — continuing."
    else
        success "Retention purge complete."
    fi
}

# ---------------------------------------------------------------------------
# Step 5 — Commit and push (optional)
# ---------------------------------------------------------------------------
publish() {
    if ${OPT_NO_PUSH} || ${OPT_DRY_RUN}; then
        info "Skipping git push (--no-push or --dry-run)."
        return 0
    fi

    log "Step 5: Publishing results …"

    # Regenerate STATUS.md and run the 90-day retention purge.
    # gen_status.py stages git rm --cached for any day dirs past the cutoff,
    # and removes hs_err/ / test-support/ trees from disk.
    if ! python3 "${SCRIPT_DIR}/gen_status.py" \
            "${REPORTS_DIR}" "${REPORTS_REPO_ROOT}" 2>&1; then
        warn "gen_status.py failed — STATUS.md may be stale."
    fi

    cd "${REPORTS_REPO_ROOT}"
    git fetch origin "${GIT_RESULTS_BRANCH}"
    git checkout "${GIT_RESULTS_BRANCH}"
    git pull --ff-only origin "${GIT_RESULTS_BRANCH}"
    # Exclude hs_err/ — JVM crash logs are for local investigation only
    git add "${REPORTS_DIR}/"
    git reset HEAD -- "${REPORTS_DIR}"/**/hs_err/ 2>/dev/null || true
    git add --force STATUS.md 2>/dev/null || true

    if git diff --cached --quiet; then
        info "Nothing new to commit."
        return 0
    fi

    # Build result summary for commit message
    local result_lines=""
    for level in "${EFFECTIVE_LEVELS[@]}"; do
        result_lines+="  ${OPT_STREAM}/${level}: ${OP_STATUS[${level}]:-not-run}"$'\n'
    done

    local headline_icon="✅"
    for level in "${EFFECTIVE_LEVELS[@]}"; do
        if [[ "${OP_STATUS[${level}]:-}" == FAILED* \
           || "${OP_STATUS[${level}]:-}" == TEST_FAILURES* ]]; then
            headline_icon="❌"; break
        fi
    done

    git \
        -c "user.name=${GIT_COMMIT_AUTHOR_NAME}" \
        -c "user.email=${GIT_COMMIT_AUTHOR_EMAIL}" \
        commit -m "${headline_icon} manual ${COMMAND}: ${OPT_STREAM} (${OPT_LEVEL}) ${_YEAR}-${_MONTH}-${_DAY}

Command: jdk.sh ${COMMAND}
Stream : ${OPT_STREAM}  Levels: ${EFFECTIVE_LEVELS[*]}
Target : ${OPT_TEST_TARGET}
JVM    : ${OPT_JVM_FLAGS:-(none)}
Retention: reports older than 90 days purged from repo.

Results:
${result_lines}
Logs: ${OUT_BASE#"${REPORTS_REPO_ROOT}/"}
"
    git push origin "${GIT_RESULTS_BRANCH}"
    success "Results pushed to origin/${GIT_RESULTS_BRANCH}."
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
trap 'cd "${REPORTS_REPO_ROOT}"' EXIT

# Step 1: deps (done above as ensure_deps, before banner could resolve dirs)

# Step 2: source — only needed for run/build (test reuses existing build)
if [[ "${COMMAND}" != "test" ]]; then
    prepare_src
fi

# Step 3: execute
run_operations

# Step 4a: summary
write_summary

# Step 4b: retention purge — runs for 'run' command only (default)
if [[ "${COMMAND}" == "run" ]]; then
    purge_old_reports
fi

# Step 5: publish
publish

log "========================================================"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "Output: ${OUT_BASE}"
log "========================================================"
