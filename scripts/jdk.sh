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
#   clean     Remove the build output directory (make dist-clean) for the
#             chosen stream + level(s).  Does not build or test anything.
#             Safe to run before a fresh build when you want a clean slate.
#
#   collect   Re-collect artefacts from an already-finished test run and
#             re-send the email.  Does not run any build or test.
#             Requires --from <OUT_BASE_DIR>.
#
#   resend    Re-send the notification email for a completed run without
#             rebuilding or re-testing anything.  Reads run-summary.txt,
#             commit-info-all.txt, and per-stream result artefacts directly
#             from the run directory.  Works for daily, manual, and pr runs.
#             Requires --from <RUN_DIR>.
#
# OPTIONS (all commands)
# ──────────────────────
#   --stream LABEL        Target one stream (default: head)
#                         Any label from the JDK_STREAMS registry is accepted:
#                           head   jdk26  jdk25  jdk21  jdk17  jdk11
#   --level  LEVEL        fastdebug | release | both  (default: both)
#   --skip-deps           Skip boot JDK + jtreg download (use cached)
#   --no-push             Write report files but do not git commit/push
#   --dry-run             Print what would happen; do nothing
#
# OPTIONS (test / run only)
# ─────────────────────────
#   --test-target GROUP   jtreg test group, path, or the special value "all".
#                         Default: tier1
#
#                         Special value:
#                           all   Run tier1 → tier2 → tier3 → tier4 in order.
#                                 Each tier gets its own output sub-directory
#                                 and a separate entry in the summary.
#                                 Works with any --stream and --level value.
#
#                         Standard examples:
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
# OPTIONS (collect / resend only)
# ────────────────────────────────
#   --from DIR            Path to an existing run directory.
#                         For collect: OUT_BASE from a previous test/run.
#                         For resend:  the run directory containing
#                                      run-summary.txt (e.g. reports/2025/July/11
#                                      for a daily run, or the timestamped
#                                      sub-directory for a jdk.sh run).
#
#   --run-kind KIND       Override the run kind label in the email subject.
#                         Values: daily | manual | pr  (default: daily)
#                         Only used with the resend command.
#
# EXAMPLES
# ────────
#   # Full default run (same as cron):
#   bash scripts/jdk.sh run
#
#   # Build only, fastdebug:
#   bash scripts/jdk.sh build --level fastdebug
#
#   # Wipe the prior build before building fresh:
#   bash scripts/jdk.sh clean && bash scripts/jdk.sh build --level fastdebug
#
#   # Clean both levels for jdk21 before a full run:
#   bash scripts/jdk.sh clean --stream jdk21
#
#   # Re-run tier1 tests without rebuilding:
#   bash scripts/jdk.sh test
#
#   # Re-run tier1 tests, release build only:
#   bash scripts/jdk.sh test --level release
#
#   # Run all tiers (tier1–tier4) for head, both levels:
#   bash scripts/jdk.sh test --test-target all
#
#   # Run all tiers for jdk21, fastdebug only:
#   bash scripts/jdk.sh test --stream jdk21 --level fastdebug --test-target all
#
#   # Run all tiers for jdk17, release only, no push:
#   bash scripts/jdk.sh test --stream jdk17 --level release --test-target all --no-push
#
#   # Full run (build + all tiers) for jdk21:
#   bash scripts/jdk.sh run --stream jdk21 --test-target all
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
#   # Re-collect artefacts + resend email from a previous fastdebug test run:
#   bash scripts/jdk.sh collect --stream head --level fastdebug \
#       --from reports/2026/July/11/test-tier1-135843
#
#   # Re-send email for a completed daily run (all streams):
#   bash scripts/jdk.sh resend --from reports/2026/July/11
#
#   # Re-send email for a completed jdk.sh manual run:
#   bash scripts/jdk.sh resend --run-kind manual \
#       --from reports/2026/July/11/run-135843
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
source "${SCRIPT_DIR}/notify.sh"

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
OPT_FROM=""           # --from DIR  (collect / resend commands)
OPT_RUN_KIND="daily"  # --run-kind  (resend command)
OPT_STREAM_SET=false  # true when --stream was explicitly passed

# Tiers executed when --test-target all is requested
ALL_TIERS=(tier1 tier2 tier3 tier4)

# Track whether the user supplied any explicit arguments.
# Zero args → treated as an automated CI invocation → ci-results-daily.
# Any arg    → treated as a manual run              → ci-results-manual.
_USER_SUPPLIED_ARGS=false

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
else
    _USER_SUPPLIED_ARGS=true
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        run|build|test|clean|collect|resend)
            COMMAND="$1"; shift ;;
        --from)
            OPT_FROM="$2"; shift 2 ;;
        --run-kind)
            OPT_RUN_KIND="$2"
            case "${OPT_RUN_KIND}" in
                daily|manual|pr) ;;
                *) echo "[jdk.sh] ERROR: --run-kind must be daily, manual, or pr" >&2; exit 1 ;;
            esac
            shift 2 ;;
        --stream)
            OPT_STREAM="$2"; OPT_STREAM_SET=true; shift 2 ;;
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

# ---------------------------------------------------------------------------
# Validate collect --from before anything else
# ---------------------------------------------------------------------------
if [[ "${COMMAND}" == "collect" ]]; then
    if [[ -z "${OPT_FROM}" ]]; then
        echo "[jdk.sh] ERROR: 'collect' requires --from <DIR>" >&2
        exit 1
    fi
    OPT_FROM="$(cd "${OPT_FROM}" 2>/dev/null && pwd)" \
        || { echo "[jdk.sh] ERROR: --from directory not found: ${OPT_FROM}" >&2; exit 1; }
fi

if [[ "${COMMAND}" == "resend" && -n "${OPT_FROM}" ]]; then
    OPT_FROM="$(cd "${OPT_FROM}" 2>/dev/null && pwd)" \
        || { echo "[jdk.sh] ERROR: --from directory not found: ${OPT_FROM}" >&2; exit 1; }
fi

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
# resend — re-send the notification email for an already-completed run.
#
# Reads the run directory for run-summary.txt / commit-info files and
# run-metadata.txt (to derive build_status per stream×level).
# Test results (newfailures.txt, other_errors.txt) and build.log are read
# directly from the JDK source tree — exactly as the live run does.
#
# Run directory layouts supported:
#
#   daily (run_daily.sh):
#     <run_dir>/
#       run-summary.txt
#       commit-info-all.txt
#       <stream>/
#         <level>/
#           run-metadata.txt   (test_exit: …)
#
#   jdk.sh manual run:
#     <run_dir>/
#       run-summary.txt
#       commit-info.txt
#       <level>/
#         run-metadata.txt
#
# Triples are built as  stream:JDK_SOURCES_ROOT/<src_subdir>:level:BUILD_STATUS
# so _notify_build_section reads newfailures.txt / build.log live from
# <src_dir>/build/linux-s390x-server-<level>/test-results/ — the same path
# the original run used.
#
# build_status per stream×level is derived from run-metadata.txt:
#   test_exit: 0        → TEST_PASSED
#   test_exit: SKIPPED* → BUILD_ONLY  (build-only or no-jtreg run)
#   test_exit: <N>      → TEST_FAILED
#   run-metadata.txt missing → BUILD_FAILED (nothing ran)
# ---------------------------------------------------------------------------
_resend_email() {
    local run_dir="${OPT_FROM}"
    local run_kind="${OPT_RUN_KIND}"

    # ---- Auto-discover latest daily run dir if --from was not given -----
    if [[ -z "${run_dir}" ]]; then
        # Find all run-summary.txt files at depth 3 (YYYY/Month/DD),
        # sort by modification time (newest first), take the parent dir.
        run_dir="$(find "${REPORTS_DIR}" -mindepth 3 -maxdepth 3 \
            -name "run-summary.txt" 2>/dev/null \
            | xargs -I{} stat --format="%Y %n" {} 2>/dev/null \
            | sort -rn | head -1 | awk '{print $2}' | xargs -I{} dirname {})"
        if [[ -z "${run_dir}" ]]; then
            die "No completed run found under ${REPORTS_DIR}. Run the daily pipeline first."
        fi
        info "Auto-discovered latest run: ${run_dir}"
    fi

    log "========================================================"
    log "resend: re-sending email from ${run_dir}"
    log "========================================================"

    local summary_file="${run_dir}/run-summary.txt"
    if [[ ! -f "${summary_file}" ]]; then
        die "run-summary.txt not found in ${run_dir} — is this a valid run directory?"
    fi

    # ---- Determine overall PASS/FAIL from run-summary.txt ---------------
    # Look for any TEST_FAILED or BUILD_FAILED line written by write_run_summary.
    local overall="PASS"
    if grep -qE '^\s+(TEST_FAILED|BUILD_FAILED)\s' "${summary_file}" 2>/dev/null; then
        overall="FAIL"
    fi

    # ---- Subject suffix --------------------------------------------------
    # Use the date from run-summary.txt if present, otherwise today.
    local date_str
    date_str="$(grep -m1 'Date' "${summary_file}" 2>/dev/null \
        | sed 's/.*Date[^:]*: *//' | awk '{print $1}' || date -u '+%Y-%m-%d')"
    local subject_suffix
    if ${OPT_STREAM_SET}; then
        subject_suffix="${OPT_STREAM} (${date_str})"
    else
        subject_suffix="all streams (${date_str})"
    fi

    # ---- Commit info file ------------------------------------------------
    # Prefer commit-info-all.txt (daily runs); fall back to commit-info.txt
    local commit_info_file=""
    if [[ -f "${run_dir}/commit-info-all.txt" ]]; then
        commit_info_file="${run_dir}/commit-info-all.txt"
    elif [[ -f "${run_dir}/commit-info.txt" ]]; then
        commit_info_file="${run_dir}/commit-info.txt"
    fi

    # ---- Build registry map: label → JDK_SOURCES_ROOT/<src_subdir> ------
    local -A _registry_src=()
    for _entry in "${JDK_STREAMS[@]}"; do
        local _lbl _sub
        IFS='|' read -r _lbl _sub _ _ _ <<< "${_entry}"
        _registry_src["${_lbl}"]="${JDK_SOURCES_ROOT}/${_sub}"
    done

    # ---- Build triples: stream:src_dir:level:build_status ---------------
    # src_dir is the JDK source tree — _notify_build_section reads
    # newfailures.txt / build.log live from there, same as the original run.
    local triples=()

    # Helper: derive build_status from a level output directory in the run dir
    _build_status_from_dir() {
        local dir="$1"
        local meta="${dir}/run-metadata.txt"
        if [[ ! -f "${meta}" ]]; then
            echo "BUILD_FAILED"
            return
        fi
        local te
        te="$(grep '^test_exit:' "${meta}" | awk '{print $2}' | head -1)"
        case "${te}" in
            0)          echo "TEST_PASSED" ;;
            SKIPPED*)   echo "BUILD_ONLY"  ;;
            "")         echo "BUILD_FAILED" ;;
            *)          echo "TEST_FAILED"  ;;
        esac
    }

    # Daily layout: <run_dir>/<stream>/<level>/
    # If --stream was explicitly passed, only include that stream.
    for stream_dir in "${run_dir}"/*/; do
        [[ -d "${stream_dir}" ]] || continue
        local stream_label
        stream_label="$(basename "${stream_dir}")"

        if ${OPT_STREAM_SET} && [[ "${stream_label}" != "${OPT_STREAM}" ]]; then
            continue
        fi

        local src_dir="${_registry_src[${stream_label}]:-}"

        for level in "${BUILD_LEVELS[@]}"; do
            local level_dir="${stream_dir}${level}"
            if [[ -d "${level_dir}" ]]; then
                local bst
                bst="$(_build_status_from_dir "${level_dir}")"
                triples+=("${stream_label}:${src_dir}:${level}:${bst}")
            fi
        done
    done

    # jdk.sh single-stream layout: levels sit directly under OUT_BASE.
    # Detected when no triples were found from the loop above.
    if [[ ${#triples[@]} -eq 0 ]]; then
        local src_dir="${_registry_src[${OPT_STREAM}]:-}"
        for level in "${BUILD_LEVELS[@]}"; do
            local level_dir="${run_dir}/${level}"
            if [[ -d "${level_dir}" ]]; then
                local bst
                bst="$(_build_status_from_dir "${level_dir}")"
                triples+=("${OPT_STREAM}:${src_dir}:${level}:${bst}")
            fi
        done
    fi

    if [[ ${#triples[@]} -eq 0 ]]; then
        warn "No stream×level result directories found in ${run_dir}."
        warn "Sending email with summary only (no per-stream sections)."
    fi

    info "  run_kind   : ${run_kind}"
    info "  overall    : ${overall}"
    info "  summary    : ${summary_file}"
    info "  commit_info: ${commit_info_file:-(none)}"
    info "  streams    : ${#triples[@]} combination(s) found"

    ci_notify "${run_kind}" "${subject_suffix}" \
        "${summary_file}" "${overall}" \
        "${commit_info_file}" \
        "${triples[@]}"

    log "========================================================"
    log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    log "========================================================"
}

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
_TARGET_SLUG="${_TARGET_SLUG// /-}"       # spaces → dash (all → "all")

case "${COMMAND}" in
    run)     _RUN_LABEL="run-${_TIME}" ;;
    build)   _RUN_LABEL="build-${OPT_LEVEL}-${_TIME}" ;;
    test)    _RUN_LABEL="test-${_TARGET_SLUG}-${_TIME}" ;;
    clean)   _RUN_LABEL="clean-${OPT_LEVEL}-${_TIME}" ;;
    collect) _RUN_LABEL="collect-${OPT_LEVEL}-${_TIME}" ;;
esac

# collect reuses the original run's OUT_BASE; all other commands create a new one
if [[ "${COMMAND}" == "collect" ]]; then
    OUT_BASE="${OPT_FROM}"
else
    OUT_BASE="${REPORTS_DIR}/${_YEAR}/${_MONTH}/${_DAY}/${_RUN_LABEL}"
    mkdir -p "${OUT_BASE}"
fi

# Tee all output to a run log
RUN_LOG="${OUT_BASE}/run.log"
exec > >(tee -a "${RUN_LOG}") 2>&1

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

# Decide which branch to push to.
# No user args  → behaves like the cron job → ci-results-daily
# Any user args → explicit manual invocation → ci-results-manual
if ${_USER_SUPPLIED_ARGS}; then
    PUBLISH_BRANCH="${GIT_RESULTS_BRANCH_MANUAL}"
    _RUN_KIND="manual"
else
    PUBLISH_BRANCH="${GIT_RESULTS_BRANCH_DAILY}"
    _RUN_KIND="ci"
fi

log "========================================================"
log "jdk.sh — OpenJDK s390x CI"
log "run kind    : ${_RUN_KIND} (push → ${PUBLISH_BRANCH})"
log "command     : ${COMMAND}"
log "stream      : ${OPT_STREAM}"
log "level       : ${OPT_LEVEL} → ${EFFECTIVE_LEVELS[*]}"
if [[ "${COMMAND}" != "build" ]]; then
    if [[ "${OPT_TEST_TARGET}" == "all" ]]; then
        log "test-target : all (${ALL_TIERS[*]})"
    else
        log "test-target : ${OPT_TEST_TARGET}"
    fi
fi
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
    bash "${SCRIPT_DIR}/setup_deps.sh" --stream "${OPT_STREAM}" || deps_exit=$?

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
if [[ "${COMMAND}" == "clean" ]]; then
    : # No deps needed to remove a build directory
elif [[ "${COMMAND}" == "test" ]]; then
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

        # Capture HEAD before the pull so we can build a bisect command
        local commit_before
        commit_before="$(git -C "${SRC_DIR}" rev-parse HEAD 2>/dev/null || echo '')"

        git -C "${SRC_DIR}" fetch --prune origin

        # Discard any local modifications that would block the merge.
        # This is a CI source mirror — upstream content always wins.
        local dirty_files
        dirty_files="$(git -C "${SRC_DIR}" status --porcelain 2>/dev/null)"
        if [[ -n "${dirty_files}" ]]; then
            warn "  Local modifications detected — discarding before pull:"
            git -C "${SRC_DIR}" status --short | while IFS= read -r line; do
                warn "    ${line}"
            done
            git -C "${SRC_DIR}" checkout -- .
            git -C "${SRC_DIR}" clean -fd
        fi

        git -C "${SRC_DIR}" checkout master
        git -C "${SRC_DIR}" pull --ff-only origin master
        success "  Source updated: $(git -C "${SRC_DIR}" log -1 --oneline)"

        local commit_after
        commit_after="$(git -C "${SRC_DIR}" rev-parse HEAD)"

        # Write commit-info.txt into the run output directory
        {
            echo "stream         : ${OPT_STREAM}"
            echo "src_dir        : ${SRC_DIR}"
            echo "run_date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo ""
            echo "commit_before  : ${commit_before:-(unknown)}"
            echo "commit_after   : ${commit_after}"
            echo ""
            if [[ -n "${commit_before}" && "${commit_before}" != "${commit_after}" ]]; then
                local n
                n="$(git -C "${SRC_DIR}" rev-list --count \
                    "${commit_before}..${commit_after}" 2>/dev/null || echo '?')"
                echo "new_commits    : ${n} commit(s) pulled in this run"
                echo "bisect_cmd     : git bisect start ${commit_after} ${commit_before}"
                echo ""
                echo "# Commits introduced (newest first):"
                git -C "${SRC_DIR}" log --oneline --no-merges \
                    "${commit_before}..${commit_after}" 2>/dev/null | sed 's/^/#   /'
            else
                echo "new_commits    : (none — already up to date)"
                echo "bisect_cmd     : (not needed)"
            fi
        } > "${OUT_BASE}/commit-info.txt"
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

        local commit_after
        commit_after="$(git -C "${SRC_DIR}" rev-parse HEAD)"
        {
            echo "stream         : ${OPT_STREAM}"
            echo "src_dir        : ${SRC_DIR}"
            echo "run_date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo ""
            echo "commit_before  : (none — fresh clone)"
            echo "commit_after   : ${commit_after}"
            echo "bisect_cmd     : (not applicable — fresh clone)"
        } > "${OUT_BASE}/commit-info.txt"
    fi
}

# ---------------------------------------------------------------------------
# Step 3 — Execute the requested operation per debug level
# ---------------------------------------------------------------------------
declare -A OP_STATUS=()

# _read_test_status LEVEL_OUT_DIR KEY
# Extract the outcome string from run-metadata.txt for a given level dir.
_read_test_status() {
    local dir="$1"
    local test_exit_line
    test_exit_line="$(grep '^test_exit:' "${dir}/run-metadata.txt" \
        2>/dev/null | awk '{print $2}' || echo "0")"
    case "${test_exit_line}" in
        0)           echo "PASSED" ;;
        SKIPPED*)    echo "BUILD_ONLY (no tests)" ;;
        NO_BUILD*)   echo "SKIPPED (no build found)" ;;
        *)           echo "TEST_FAILURES (jtreg=${test_exit_line})" ;;
    esac
}

run_operations() {
    for level in "${EFFECTIVE_LEVELS[@]}"; do
        local level_out="${OUT_BASE}/${level}"
        mkdir -p "${level_out}"

        log "----------------------------------------------------"
        log "[${OPT_STREAM}/${level}] Starting ${COMMAND} …"
        log "----------------------------------------------------"

        if ${OPT_DRY_RUN}; then
            if [[ "${OPT_TEST_TARGET}" == "all" && "${COMMAND}" != "build" ]]; then
                for tier in "${ALL_TIERS[@]}"; do
                    info "DRY-RUN: would ${COMMAND} ${OPT_STREAM}/${level}/${tier}"
                    OP_STATUS["${level}/${tier}"]="DRY_RUN"
                done
            else
                info "DRY-RUN: would ${COMMAND} ${OPT_STREAM}/${level}"
                OP_STATUS["${level}"]="DRY_RUN"
            fi
            continue
        fi

        local exit_code=0

        case "${COMMAND}" in
            # ---- run: full pipeline (build + tests) ---------------
            run)
                if [[ "${OPT_TEST_TARGET}" == "all" ]]; then
                    # Build once, then run each tier in sequence
                    build_only_jdk \
                        "${SRC_DIR}" "${OPT_STREAM}" "${level}" \
                        "${level_out}" "${STREAM_BOOT_JDK}" \
                        || { exit_code=$?; OP_STATUS["${level}/build"]="FAILED (exit=${exit_code})"; continue; }
                    OP_STATUS["${level}/build"]="OK"

                    if [[ "${JTREG_OK}" != "true" ]]; then
                        warn "[${OPT_STREAM}/${level}] jtreg not available — skipping all tiers."
                        for tier in "${ALL_TIERS[@]}"; do
                            OP_STATUS["${level}/${tier}"]="SKIPPED (no jtreg)"
                        done
                    else
                        for tier in "${ALL_TIERS[@]}"; do
                            local tier_out="${level_out}/${tier}"
                            mkdir -p "${tier_out}"
                            log "[${OPT_STREAM}/${level}] Running ${tier} …"
                            local tier_exit=0
                            run_tests_only \
                                "${SRC_DIR}" "${OPT_STREAM}" "${level}" \
                                "${tier_out}" \
                                "${tier}" \
                                "${OPT_JVM_FLAGS}" \
                                || tier_exit=$?
                            if [[ ${tier_exit} -ne 0 ]]; then
                                OP_STATUS["${level}/${tier}"]="FAILED (exit=${tier_exit})"
                            else
                                OP_STATUS["${level}/${tier}"]="$(_read_test_status "${tier_out}")"
                            fi
                            log "[${OPT_STREAM}/${level}/${tier}] ${OP_STATUS["${level}/${tier}"]}"
                        done
                    fi
                else
                    build_and_test_jdk \
                        "${SRC_DIR}" "${OPT_STREAM}" "${level}" \
                        "${level_out}" "${JTREG_OK}" \
                        "${STREAM_BOOT_JDK}" \
                        || exit_code=$?
                    if [[ ${exit_code} -ne 0 ]]; then
                        OP_STATUS["${level}"]="FAILED (exit=${exit_code})"
                    else
                        OP_STATUS["${level}"]="$(_read_test_status "${level_out}")"
                    fi
                fi
                ;;

            # ---- build: configure + images, no tests --------------
            build)
                build_only_jdk \
                    "${SRC_DIR}" "${OPT_STREAM}" "${level}" \
                    "${level_out}" "${STREAM_BOOT_JDK}" \
                    || exit_code=$?
                if [[ ${exit_code} -ne 0 ]]; then
                    OP_STATUS["${level}"]="FAILED (exit=${exit_code})"
                else
                    OP_STATUS["${level}"]="$(_read_test_status "${level_out}")"
                fi
                ;;

            # ---- test: reuse build, run given target ---------------
            test)
                if [[ "${OPT_TEST_TARGET}" == "all" ]]; then
                    for tier in "${ALL_TIERS[@]}"; do
                        local tier_out="${level_out}/${tier}"
                        mkdir -p "${tier_out}"
                        log "[${OPT_STREAM}/${level}] Running ${tier} …"
                        local tier_exit=0
                        run_tests_only \
                            "${SRC_DIR}" "${OPT_STREAM}" "${level}" \
                            "${tier_out}" \
                            "${tier}" \
                            "${OPT_JVM_FLAGS}" \
                            || tier_exit=$?
                        if [[ ${tier_exit} -ne 0 ]]; then
                            OP_STATUS["${level}/${tier}"]="FAILED (exit=${tier_exit})"
                        else
                            OP_STATUS["${level}/${tier}"]="$(_read_test_status "${tier_out}")"
                        fi
                        log "[${OPT_STREAM}/${level}/${tier}] ${OP_STATUS["${level}/${tier}"]}"
                    done
                else
                    run_tests_only \
                        "${SRC_DIR}" "${OPT_STREAM}" "${level}" \
                        "${level_out}" \
                        "${OPT_TEST_TARGET}" \
                        "${OPT_JVM_FLAGS}" \
                        || exit_code=$?
                    if [[ ${exit_code} -ne 0 ]]; then
                        OP_STATUS["${level}"]="FAILED (exit=${exit_code})"
                    else
                        OP_STATUS["${level}"]="$(_read_test_status "${level_out}")"
                    fi
                fi
                ;;

            # ---- clean: remove the build output directory for this level ----
            clean)
                local conf_name="linux-s390x-server-${level}"
                local build_dir="${SRC_DIR}/build/${conf_name}"
                if [[ ! -d "${build_dir}" ]]; then
                    info "[${OPT_STREAM}/${level}] Nothing to clean (${build_dir} does not exist)."
                    OP_STATUS["${level}"]="CLEAN_SKIPPED (no build dir)"
                else
                    info "[${OPT_STREAM}/${level}] Cleaning ${build_dir} …"
                    local clean_exit=0
                    (
                        cd "${SRC_DIR}"
                        MAKEFLAGS= MAKEOVERRIDES= \
                            make CONF="${conf_name}" dist-clean 2>/dev/null
                    ) || clean_exit=$?
                    if [[ ${clean_exit} -ne 0 ]]; then
                        warn "[${OPT_STREAM}/${level}] make dist-clean failed (exit=${clean_exit}) — removing directory."
                        rm -rf "${build_dir}"
                    fi
                    success "[${OPT_STREAM}/${level}] Build directory removed."
                    OP_STATUS["${level}"]="CLEANED"
                fi
                ;;

            # ---- collect: re-collect results from existing test-results/ ----
            collect)
                local conf_name="linux-s390x-server-${level}"
                local results_dir="${SRC_DIR}/build/${conf_name}/test-results"
                if [[ ! -d "${results_dir}" ]]; then
                    warn "[${OPT_STREAM}/${level}] test-results not found at ${results_dir}"
                    warn "  Run the tests first before collecting."
                    OP_STATUS["${level}"]="COLLECT_FAILED (no test-results)"
                else
                    info "[${OPT_STREAM}/${level}] Re-collecting from ${results_dir} …"
                    (
                        cd "${SRC_DIR}"
                        _collect_test_results "build/${conf_name}" "${level_out}"
                    )
                    OP_STATUS["${level}"]="$(_read_test_status "${level_out}")"
                    info "[${OPT_STREAM}/${level}] Collected: ${OP_STATUS[${level}]}"
                fi
                ;;
        esac

        # For non-all targets the status was already set above.
        # Log the per-level outcome only for single-target runs.
        if [[ "${OPT_TEST_TARGET}" != "all" || "${COMMAND}" == "build" ]]; then
            log "[${OPT_STREAM}/${level}] Done: ${OP_STATUS[${level}]}"
        fi
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
        if [[ "${OPT_TEST_TARGET}" == "all" ]]; then
            echo "  test-target  : all (${ALL_TIERS[*]})"
        else
            echo "  test-target  : ${OPT_TEST_TARGET}"
        fi
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
        if [[ "${OPT_TEST_TARGET}" == "all" && "${COMMAND}" != "build" ]]; then
            for level in "${EFFECTIVE_LEVELS[@]}"; do
                # Show build step if it was tracked (run command)
                if [[ -n "${OP_STATUS["${level}/build"]+set}" ]]; then
                    printf "    %-20s  %s\n" "${level}/build" \
                        "${OP_STATUS["${level}/build"]:-not-run}"
                fi
                for tier in "${ALL_TIERS[@]}"; do
                    printf "    %-20s  %s\n" "${level}/${tier}" \
                        "${OP_STATUS["${level}/${tier}"]:-not-run}"
                done
            done
        else
            for level in "${EFFECTIVE_LEVELS[@]}"; do
                printf "    %-12s  %s\n" "${level}" "${OP_STATUS[${level}]:-not-run}"
            done
        fi
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
# Step 5 — Push disabled: results are kept local only
# ---------------------------------------------------------------------------
publish() {
    info "Git push disabled — results stored locally in ${OUT_BASE}"
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
trap 'cd "${REPORTS_REPO_ROOT}"' EXIT

# resend: no build, no summary, no deps — just re-fire the email and exit.
if [[ "${COMMAND}" == "resend" ]]; then
    _resend_email
    exit 0
fi

# Step 1: deps (done above as ensure_deps, before banner could resolve dirs)

# Step 2: source — only needed for run/build (test/collect/clean reuse existing tree)
if [[ "${COMMAND}" != "test" && "${COMMAND}" != "collect" && "${COMMAND}" != "clean" ]]; then
    prepare_src
fi

# Step 3: execute
run_operations

# clean is done — no summary, no retention purge, no email
if [[ "${COMMAND}" == "clean" ]]; then
    log "========================================================"
    log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    log "Output: ${OUT_BASE}"
    log "========================================================"
    exit 0
fi

# Step 4a: summary
write_summary

# Step 4b: retention purge — runs for 'run' command only (default)
if [[ "${COMMAND}" == "run" ]]; then
    purge_old_reports
fi

# Step 5: publish (no-op — push disabled)
publish

# Step 6: email notification
_jdk_overall="PASS"
for _lvl in "${EFFECTIVE_LEVELS[@]}"; do
    _st="${OP_STATUS[${_lvl}]:-}"
    if [[ "${_st}" == FAILED*        || "${_st}" == TEST_FAILURES* \
       || "${_st}" == BUILD_FAILED*  || "${_st}" == COLLECT_FAILED* ]]; then
        _jdk_overall="FAIL"; break
    fi
done
# Build stream_label:src_dir:level:build_status quads for notify.sh
_jdk_triples=()
for _lvl in "${EFFECTIVE_LEVELS[@]}"; do
    _st="${OP_STATUS[${_lvl}]:-UNKNOWN}"
    # Normalise to BUILD_FAILED, BUILD_ONLY, TEST_FAILED, or TEST_PASSED
    if   [[ "${_st}" == FAILED*         ]]; then _bst="BUILD_FAILED"
    elif [[ "${_st}" == TEST_FAILURES*  ]]; then _bst="TEST_FAILED"
    elif [[ "${_st}" == BUILD_ONLY*     ]]; then _bst="BUILD_ONLY"
    elif [[ "${_st}" == COLLECT_FAILED* ]]; then _bst="BUILD_FAILED"
    else                                          _bst="TEST_PASSED"
    fi
    _jdk_triples+=("${OPT_STREAM}:${SRC_DIR}:${_lvl}:${_bst}")
done
# For collect, commit-info.txt already lives in OUT_BASE from the original run
_commit_info_file="${OUT_BASE}/commit-info.txt"
ci_notify "manual" "${OPT_STREAM}/${OPT_LEVEL} ${COMMAND}" \
    "${OUT_BASE}/run-summary.txt" "${_jdk_overall}" \
    "${_commit_info_file}" \
    "${_jdk_triples[@]}"

log "========================================================"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "Output: ${OUT_BASE}"
log "========================================================"
