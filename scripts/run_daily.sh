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
#   4. Write run-summary.txt covering every stream × level combination
#   5. Commit and push all new report files to the main branch
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
# Run-summary state tracking
#
# STREAM_STATUS is an associative array keyed by "label/level".
# Possible values:
#   SKIPPED_EOL          — version not in Adoptium active support set
#   SKIPPED_FILTER       — excluded by --stream or --level flag
#   SKIPPED_DRY_RUN      — dry-run mode; nothing executed
#   SKIPPED_SOURCE_FAIL  — git pull/clone failed; tests never ran
#   BUILD_FAILED         — configure or make images failed; no test results
#   TEST_FAILED          — build OK; tier1 ran but had failures or errors
#   TEST_PASSED          — build OK; all tier1 tests passed
# ---------------------------------------------------------------------------
declare -A STREAM_STATUS=()
declare -A STREAM_STATUS_DETAIL=()   # optional one-line reason / extra info

# All registered stream labels (from config.sh) — populated at startup
ALL_REGISTERED_LABELS=()
for _entry in "${JDK_STREAMS[@]}"; do
    ALL_REGISTERED_LABELS+=("$(echo "${_entry}" | cut -d'|' -f1)")
done

record_status() {
    local label="$1"
    local level="$2"
    local status="$3"
    local detail="${4:-}"
    STREAM_STATUS["${label}/${level}"]="${status}"
    STREAM_STATUS_DETAIL["${label}/${level}"]="${detail}"
}

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
# Streams absent from the active set are recorded as SKIPPED_EOL immediately.
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

    # Build a set of active labels
    declare -A active_set=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local lbl
        lbl="$(echo "${line}" | cut -d'|' -f1)"
        active_set["${lbl}"]=1
    done <<< "${filtered}"

    # Any registered label NOT in the active set → SKIPPED_EOL
    for lbl in "${ALL_REGISTERED_LABELS[@]}"; do
        if [[ -z "${active_set[${lbl}]+_}" ]]; then
            for level in "${BUILD_LEVELS[@]}"; do
                record_status "${lbl}" "${level}" "SKIPPED_EOL" \
                    "Version not in Adoptium active support set (EOL)"
            done
        fi
    done

    # Apply --stream filter and build ACTIVE_STREAMS array
    ACTIVE_STREAMS=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local label
        label="$(echo "${line}" | cut -d'|' -f1)"
        if [[ -n "${FILTER_STREAM}" && "${label}" != "${FILTER_STREAM}" ]]; then
            for level in "${BUILD_LEVELS[@]}"; do
                record_status "${label}" "${level}" "SKIPPED_FILTER" \
                    "Excluded by --stream ${FILTER_STREAM}"
            done
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
#
# Writes two files into out_base/:
#
#   top_commit      — the HEAD commit that was built and tested
#                     (kept for backward compatibility)
#
#   commit-info.txt — structured record containing:
#       • commit_before  : HEAD before git pull (empty for fresh clone)
#       • commit_after   : HEAD after  git pull (= what was built)
#       • new_commits    : one-line list of every commit pulled in this run
#                          (the range to bisect on test failure)
#       • bisect_cmd     : ready-to-paste git bisect command
# ---------------------------------------------------------------------------
prepare_source() {
    local label="$1"
    local src_subdir="$2"
    local git_url="$3"
    local out_base="$4"       # destination dir for commit-info.txt

    local src_dir="${JDK_SOURCES_ROOT}/${src_subdir}"

    log "[${label}] Preparing source at ${src_dir} …"

    local commit_before=""
    local is_fresh_clone=false

    if [[ -d "${src_dir}/.git" ]]; then
        # Record HEAD before we touch anything
        commit_before="$(git -C "${src_dir}" rev-parse HEAD)"
        info "  Existing repo — commit before pull: ${commit_before}"
        info "  Pulling latest from origin/master …"
        git -C "${src_dir}" fetch --prune origin
        git -C "${src_dir}" checkout master
        git -C "${src_dir}" pull --ff-only origin master
    else
        info "  No repo found — cloning ${git_url} …"
        mkdir -p "${JDK_SOURCES_ROOT}"
        git clone --depth=1 "${git_url}" "${src_dir}"
        is_fresh_clone=true
    fi

    local commit_after
    commit_after="$(git -C "${src_dir}" rev-parse HEAD)"

    info "  Commit after pull : ${commit_after}"

    # ---- Build commit-info.txt ------------------------------------------
    local ci_file="${out_base}/commit-info.txt"
    mkdir -p "${out_base}"
    {
        echo "stream         : ${label}"
        echo "src_dir        : ${src_dir}"
        echo "run_date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo ""

        if ${is_fresh_clone}; then
            echo "commit_before  : (none — fresh clone)"
            echo "commit_after   : ${commit_after}"
            echo ""
            echo "# Fresh clone — full log not shown (use git log in ${src_dir})"
        else
            echo "commit_before  : ${commit_before}"
            echo "commit_after   : ${commit_after}"
            echo ""

            if [[ "${commit_before}" == "${commit_after}" ]]; then
                echo "# No new commits — repo was already up to date."
                echo "new_commits    : (none)"
                echo "bisect_cmd     : (not needed — no new commits)"
            else
                local new_commit_count
                new_commit_count="$(git -C "${src_dir}" \
                    rev-list --count "${commit_before}..${commit_after}")"
                echo "new_commits    : ${new_commit_count} commit(s) pulled in this run"
                echo "bisect_cmd     : git bisect start ${commit_after} ${commit_before}"
                echo ""
                echo "# Commits introduced in this pull (newest first):"
                echo "# (If tests fail, run the bisect_cmd above in ${src_dir})"
                echo "#"
                git -C "${src_dir}" log \
                    --oneline \
                    --no-merges \
                    "${commit_before}..${commit_after}" \
                    | sed 's/^/#   /'
                echo ""
                echo "# Full details of new commits:"
                git -C "${src_dir}" log \
                    --format='commit %H%nauthor %an <%ae>%ndate   %ad%n%n    %s%n%n    %b' \
                    --date=rfc \
                    "${commit_before}..${commit_after}"
            fi
        fi
    } > "${ci_file}"

    info "  Commit info written to ${ci_file}"

    # ---- top_commit (backward-compatible single-commit record) ----------
    git -C "${src_dir}" log -1 \
        --format='commit %H%nauthor %an <%ae>%ndate   %ad%n%n    %s' \
        --date=rfc
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
        record_status "${label}" "${debug_level}" "SKIPPED_FILTER" \
            "Excluded by --level ${FILTER_LEVEL}"
        return 0
    fi

    local out_dir="${out_base}/${debug_level}"
    mkdir -p "${out_dir}"

    log "[${label}] Starting build+test: ${debug_level} …"

    if ${DRY_RUN}; then
        info "[${label}] DRY-RUN: would build+test ${label}/${debug_level}"
        record_status "${label}" "${debug_level}" "SKIPPED_DRY_RUN" \
            "--dry-run flag set; no build or test executed"
        return 0
    fi

    local exit_code=0
    build_and_test_jdk \
        "${src_dir}" \
        "${label}" \
        "${debug_level}" \
        "${out_dir}" \
        "${extra_flags[@]+"${extra_flags[@]}"}" \
        || exit_code=$?

    if [[ ${exit_code} -ne 0 ]]; then
        warn "[${label}] Build/setup error (exit=${exit_code}) — recorded, continuing."
        echo "BUILD/SETUP ERROR — exit ${exit_code}" >> "${out_dir}/build.log"
        echo "Build failed (exit ${exit_code})"      >  "${out_dir}/test-summary.txt"
        record_status "${label}" "${debug_level}" "BUILD_FAILED" \
            "configure or make images exited ${exit_code}; tier1 tests did not run"
    else
        # Determine pass/fail from the test-summary.txt written by build_test.sh
        local summary_file="${out_dir}/test-summary.txt"
        local test_exit_line
        test_exit_line="$(grep '^test_exit:' "${out_dir}/run-metadata.txt" 2>/dev/null \
            | awk '{print $2}' || echo "0")"

        if [[ "${test_exit_line}" != "0" ]]; then
            record_status "${label}" "${debug_level}" "TEST_FAILED" \
                "tier1 completed with failures/errors (jtreg exit=${test_exit_line}); see newfailures.txt"
        else
            record_status "${label}" "${debug_level}" "TEST_PASSED" \
                "all tier1 tests passed"
        fi
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

        # Pull source — if this fails, mark all levels and move on
        local top_commit
        if ! top_commit="$(prepare_source "${label}" "${src_subdir}" "${git_url}" "${out_base}" 2>&1)"; then
            warn "[${label}] Source preparation failed — skipping all levels."
            for level in "${BUILD_LEVELS[@]}"; do
                record_status "${label}" "${level}" "SKIPPED_SOURCE_FAIL" \
                    "git pull/clone failed; no build attempted"
                echo "SOURCE PREPARATION FAILED" > "${out_base}/${level}/test-summary.txt" 2>/dev/null || true
            done
            echo "SOURCE PREPARATION FAILED" > "${out_base}/top_commit"
            continue
        fi
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
# Step 4 — Write run-summary.txt
#
# Written to: reports/YYYY/Month/DD/run-summary.txt
#
# Covers every (stream × level) combination — both those that ran and those
# that were skipped for any reason, with a clear explanation for each skip.
# ---------------------------------------------------------------------------
write_run_summary() {
    local year month day
    year="$(date +%Y)"; month="$(date +%B)"; day="$(date +%d)"
    local summary_dir="${REPORTS_DIR}/${year}/${month}/${day}"
    local summary_file="${summary_dir}/run-summary.txt"
    mkdir -p "${summary_dir}"

    local run_date
    run_date="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    local boot_jdk_ver="n/a"
    local jtreg_ver="n/a"
    if [[ -x "${BOOT_JDK_DIR}/bin/java" ]]; then
        boot_jdk_ver="$("${BOOT_JDK_DIR}/bin/java" -version 2>&1 | head -1)"
    fi
    if [[ -x "${JTREG_DIR}/bin/jtreg" ]]; then
        jtreg_ver="$(JAVA_HOME="${BOOT_JDK_DIR}" "${JTREG_DIR}/bin/jtreg" \
            -version 2>/dev/null | head -1 || echo 'n/a')"
    fi

    {
        echo "========================================================"
        echo "  OpenJDK s390x CI — Run Summary"
        echo "========================================================"
        echo "  Date      : ${run_date}"
        echo "  Host      : $(hostname)"
        echo "  Boot JDK  : ${boot_jdk_ver}"
        echo "  jtreg     : ${jtreg_ver}"
        [[ -n "${FILTER_STREAM}" ]] && echo "  --stream  : ${FILTER_STREAM}"
        [[ -n "${FILTER_LEVEL}"  ]] && echo "  --level   : ${FILTER_LEVEL}"
        ${DRY_RUN}                  && echo "  Mode      : DRY-RUN"
        ${SKIP_DEPS}                && echo "  Deps      : skipped (--skip-deps)"
        echo ""
        echo "  Legend:"
        echo "    TEST_PASSED         All tier1 tests passed"
        echo "    TEST_FAILED         Tier1 ran; failures or errors recorded"
        echo "    BUILD_FAILED        configure/make failed; tests did not run"
        echo "    SKIPPED_SOURCE_FAIL git pull/clone failed; nothing ran"
        echo "    SKIPPED_FILTER      Excluded by --stream / --level flag"
        echo "    SKIPPED_DRY_RUN     Dry-run mode; no build or test executed"
        echo "    SKIPPED_EOL         Version no longer in Adoptium active support"
        echo "========================================================"
        echo ""

        # ---- Per-stream table -------------------------------------------
        # Collect all unique labels in a defined order:
        # first the registered order, then any extras in the status map
        declare -A seen_labels=()
        local ordered_labels=()
        for lbl in "${ALL_REGISTERED_LABELS[@]}"; do
            if [[ -z "${seen_labels[${lbl}]+_}" ]]; then
                ordered_labels+=("${lbl}")
                seen_labels["${lbl}"]=1
            fi
        done

        for lbl in "${ordered_labels[@]}"; do
            echo "  ── ${lbl} ──────────────────────────────────────────"
            local any_found=false
            for level in "${BUILD_LEVELS[@]}"; do
                local key="${lbl}/${level}"
                if [[ -n "${STREAM_STATUS[${key}]+_}" ]]; then
                    any_found=true
                    local status="${STREAM_STATUS[${key}]}"
                    local detail="${STREAM_STATUS_DETAIL[${key}]:-}"
                    printf "    %-12s  %-20s  %s\n" "${level}" "${status}" "${detail}"
                fi
            done
            if ! ${any_found}; then
                echo "    (no status recorded — stream may have been added mid-run)"
            fi
            echo ""
        done

        # ---- Counts summary -------------------------------------------
        local n_passed=0 n_failed=0 n_build_fail=0 n_skipped=0
        for key in "${!STREAM_STATUS[@]}"; do
            case "${STREAM_STATUS[${key}]}" in
                TEST_PASSED)         (( n_passed++    )) ;;
                TEST_FAILED)         (( n_failed++    )) ;;
                BUILD_FAILED)        (( n_build_fail++)) ;;
                SKIPPED_*)           (( n_skipped++   )) ;;
            esac
        done
        local n_total=$(( n_passed + n_failed + n_build_fail + n_skipped ))

        echo "========================================================"
        echo "  Totals  (stream × level combinations)"
        printf "    %-24s %d\n" "Combinations tracked:" "${n_total}"
        printf "    %-24s %d\n" "TEST_PASSED:"          "${n_passed}"
        printf "    %-24s %d\n" "TEST_FAILED:"          "${n_failed}"
        printf "    %-24s %d\n" "BUILD_FAILED:"         "${n_build_fail}"
        printf "    %-24s %d\n" "Skipped (any reason):" "${n_skipped}"
        echo "========================================================"

    } > "${summary_file}"

    success "Run summary written to ${summary_file}"
    # Print it to stdout too so it appears in the CI log
    echo ""
    cat "${summary_file}"
    echo ""
}

# ---------------------------------------------------------------------------
# Step 5 — Commit and push all new report files
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

    # Build a compact per-stream status for the commit message
    local status_lines=""
    for lbl in "${ALL_REGISTERED_LABELS[@]}"; do
        for level in "${BUILD_LEVELS[@]}"; do
            local key="${lbl}/${level}"
            if [[ -n "${STREAM_STATUS[${key}]+_}" ]]; then
                status_lines+="  ${key}: ${STREAM_STATUS[${key}]}"$'\n'
            fi
        done
    done

    git \
        -c "user.name=${GIT_COMMIT_AUTHOR_NAME}" \
        -c "user.email=${GIT_COMMIT_AUTHOR_EMAIL}" \
        commit -m "report: tier1 results ${year}-${month}-${day}

Automated s390x CI run.
Host: $(hostname)

Results per stream/level:
${status_lines}
See reports/${year}/${month}/${day}/run-summary.txt for full details.
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
    ${DRY_RUN}                  && log "MODE: DRY-RUN"
    [[ -n "${FILTER_STREAM}" ]] && log "FILTER: stream=${FILTER_STREAM}"
    [[ -n "${FILTER_LEVEL}"  ]]  && log "FILTER: level=${FILTER_LEVEL}"
    log "============================================================"

    refresh_deps
    resolve_active_streams
    process_streams
    write_run_summary
    publish_results

    log "============================================================"
    log "Done."
    log "============================================================"
}

main "$@"
