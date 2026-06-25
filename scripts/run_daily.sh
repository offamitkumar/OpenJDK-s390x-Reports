#!/usr/bin/env bash
# =============================================================================
# run_daily.sh — Daily CI orchestrator: tier1 tests for all active streams
#
# Pipeline stages and dependency rules:
#
#   Stage 1: setup_deps.sh
#     • boot JDK fails (exit 1) → ABORT — nothing can build without a boot JDK
#     • jtreg fails    (exit 2) → DEGRADED — builds proceed, tests skipped
#     • both succeed   (exit 0) → Full pipeline
#
#   Stage 2: resolve_streams.py
#     • Queries Adoptium API for active JDK versions.
#     • Versions no longer in support → SKIPPED_EOL.
#     • --stream / --level flags further filter what runs.
#
#   Stage 3 (per stream × debug-level):
#     a. git fetch + pull / clone
#        Failure → SKIPPED_SOURCE_FAIL for that stream; others continue.
#     b. configure
#        Failure → BUILD_FAILED; tests do not run.
#     c. make images
#        Failure → BUILD_FAILED; tests do not run.
#     d. make run-test-tier1   (only when JTREG_OK=true)
#        Non-zero jtreg exit → TEST_FAILED (recorded; pipeline continues).
#
#   Stage 4: write run-summary.txt
#   Stage 5: git commit + push
#
# Every stage writes a timestamped pipeline.log in the day's report dir.
#
# Usage:
#   bash scripts/run_daily.sh [--stream LABEL] [--level LEVEL]
#                             [--skip-deps] [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/build_test.sh
source "${SCRIPT_DIR}/build_test.sh"

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
        *) echo "[FATAL] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Pipeline log — tee stdout/stderr to pipeline.log from this point on
# ---------------------------------------------------------------------------
_YEAR="$(date +%Y)"
_MONTH="$(date +%B)"
_DAY="$(date +%d)"
PIPELINE_LOG_DIR="${REPORTS_DIR}/${_YEAR}/${_MONTH}/${_DAY}"
mkdir -p "${PIPELINE_LOG_DIR}"
PIPELINE_LOG="${PIPELINE_LOG_DIR}/pipeline.log"

exec > >(tee -a "${PIPELINE_LOG}") 2>&1

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()     { echo "$(date -u '+%H:%M:%S') [RUN]   $*"; }
info()    { echo "$(date -u '+%H:%M:%S') [INFO]  $*"; }
success() { echo "$(date -u '+%H:%M:%S') [OK]    $*"; }
warn()    { echo "$(date -u '+%H:%M:%S') [WARN]  $*"; }
die()     { echo "$(date -u '+%H:%M:%S') [FATAL] $*"; exit 1; }

# ---------------------------------------------------------------------------
# Trap: always return to repo root on exit
# ---------------------------------------------------------------------------
trap 'cd "${REPORTS_REPO_ROOT}"' EXIT

# ---------------------------------------------------------------------------
# Dependency flags — updated in refresh_deps()
# ---------------------------------------------------------------------------
BOOT_JDK_OK=false
JTREG_OK=false

# ---------------------------------------------------------------------------
# Run-summary state
# ---------------------------------------------------------------------------
declare -A STREAM_STATUS=()
declare -A STREAM_STATUS_DETAIL=()

ALL_REGISTERED_LABELS=()
for _entry in "${JDK_STREAMS[@]}"; do
    ALL_REGISTERED_LABELS+=("$(echo "${_entry}" | cut -d'|' -f1)")
done

record_status() {
    local label="$1" level="$2" status="$3" detail="${4:-}"
    STREAM_STATUS["${label}/${level}"]="${status}"
    STREAM_STATUS_DETAIL["${label}/${level}"]="${detail}"
}

# ---------------------------------------------------------------------------
# Stage 1 — Download / verify dependencies
# ---------------------------------------------------------------------------
refresh_deps() {
    if ${SKIP_DEPS}; then
        info "Skipping dependency refresh (--skip-deps)"
        if [[ -x "${BOOT_JDK_DIR}/bin/java" ]]; then
            BOOT_JDK_OK=true
            info "  Boot JDK present: $("${BOOT_JDK_DIR}/bin/java" -version 2>&1 | head -1)"
        else
            die "Boot JDK not found at ${BOOT_JDK_DIR} — cannot skip deps."
        fi
        if [[ -x "${JTREG_DIR}/bin/jtreg" ]]; then
            JTREG_OK=true
            info "  jtreg present: ${JTREG_DIR}/bin/jtreg"
        else
            warn "jtreg not found at ${JTREG_DIR} — tests will be SKIPPED."
            JTREG_OK=false
        fi
        return
    fi

    log "========================================================"
    log "Stage 1: Downloading dependencies"
    log "========================================================"

    local deps_exit=0
    local deps_args=()
    [[ -n "${FILTER_STREAM}" ]] && deps_args+=("--stream" "${FILTER_STREAM}")
    bash "${SCRIPT_DIR}/setup_deps.sh" "${deps_args[@]}" || deps_exit=$?

    case "${deps_exit}" in
        0)
            BOOT_JDK_OK=true
            JTREG_OK=true
            success "Stage 1 complete: boot JDK and jtreg ready."
            ;;
        1)
            # boot JDK failure — copy failure record, mark all streams blocked, abort
            if [[ -f "${CI_TMP_DIR}/deps-failure.txt" ]]; then
                cp "${CI_TMP_DIR}/deps-failure.txt" \
                   "${PIPELINE_LOG_DIR}/deps-failure.txt"
                cat "${PIPELINE_LOG_DIR}/deps-failure.txt"
            fi
            for lbl in "${ALL_REGISTERED_LABELS[@]}"; do
                for level in "${BUILD_LEVELS[@]}"; do
                    record_status "${lbl}" "${level}" "SKIPPED_BOOT_JDK_FAIL" \
                        "Boot JDK download failed; see deps-failure.txt"
                done
            done
            write_run_summary
            die "Boot JDK download failed (exit ${deps_exit}). Pipeline aborted."
            ;;
        2)
            # jtreg failure — builds proceed, tests skipped
            BOOT_JDK_OK=true
            JTREG_OK=false
            if [[ -f "${CI_TMP_DIR}/deps-failure.txt" ]]; then
                cp "${CI_TMP_DIR}/deps-failure.txt" \
                   "${PIPELINE_LOG_DIR}/deps-failure.txt"
                cat "${PIPELINE_LOG_DIR}/deps-failure.txt"
            fi
            warn "jtreg download failed — builds will proceed but tests will be SKIPPED."
            ;;
        *)
            die "setup_deps.sh exited with unexpected code ${deps_exit}."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Stage 2 — Resolve which streams are active
# ---------------------------------------------------------------------------
resolve_active_streams() {
    log "========================================================"
    log "Stage 2: Resolving active JDK streams"
    log "========================================================"

    local registry_input=""
    for entry in "${JDK_STREAMS[@]}"; do
        registry_input+="${entry}"$'\n'
    done

    local filtered
    filtered="$(echo "${registry_input}" | python3 "${SCRIPT_DIR}/resolve_streams.py")"

    # Identify EOL streams (registered but filtered out by the API)
    declare -A active_set=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local lbl; lbl="$(echo "${line}" | cut -d'|' -f1)"
        active_set["${lbl}"]=1
    done <<< "${filtered}"

    for lbl in "${ALL_REGISTERED_LABELS[@]}"; do
        if [[ -z "${active_set[${lbl}]+_}" ]]; then
            for level in "${BUILD_LEVELS[@]}"; do
                record_status "${lbl}" "${level}" "SKIPPED_EOL" \
                    "Version not in Adoptium active support set (EOL)"
            done
        fi
    done

    # Apply --stream filter
    ACTIVE_STREAMS=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local label; label="$(echo "${line}" | cut -d'|' -f1)"
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
# Stage 3a — git fetch + pull / clone a single stream
#
# On failure: writes source-failure.txt; returns 1
# On success: prints the top_commit text to stdout; returns 0
# ---------------------------------------------------------------------------
prepare_source() {
    local label="$1"
    local src_subdir="$2"
    local git_url="$3"
    local out_base="$4"

    local src_dir="${JDK_SOURCES_ROOT}/${src_subdir}"

    log "[${label}] Preparing source at ${src_dir} …"
    info "[${label}]   git URL : ${git_url}"

    local commit_before="" is_fresh_clone=false
    local git_log="${out_base}/git-pull.log"
    mkdir -p "${out_base}"
    {
        echo "========================================================"
        echo "  Git Pull Log — ${label}"
        echo "========================================================"
        echo "  src_dir    : ${src_dir}"
        echo "  git_url    : ${git_url}"
        echo "  date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo ""
    } > "${git_log}"

    if [[ -d "${src_dir}/.git" ]]; then
        commit_before="$(git -C "${src_dir}" rev-parse HEAD)"
        info "[${label}]   commit before pull: ${commit_before}"
        echo "  commit_before : ${commit_before}" >> "${git_log}"
        echo "" >> "${git_log}"
        echo "--- git fetch + pull output ---" >> "${git_log}"

        if ! git -C "${src_dir}" fetch --prune origin >> "${git_log}" 2>&1; then
            _record_source_failure "${label}" "${out_base}" "${git_log}" \
                "git fetch failed"
            return 1
        fi
        if ! git -C "${src_dir}" checkout master >> "${git_log}" 2>&1; then
            _record_source_failure "${label}" "${out_base}" "${git_log}" \
                "git checkout master failed"
            return 1
        fi
        if ! git -C "${src_dir}" pull --ff-only origin master >> "${git_log}" 2>&1; then
            _record_source_failure "${label}" "${out_base}" "${git_log}" \
                "git pull --ff-only origin master failed"
            return 1
        fi
    else
        info "[${label}]   No repo found — cloning …"
        echo "  action     : fresh clone" >> "${git_log}"
        echo "--- git clone output ---" >> "${git_log}"
        mkdir -p "${JDK_SOURCES_ROOT}"
        if ! git clone --depth=1 "${git_url}" "${src_dir}" >> "${git_log}" 2>&1; then
            _record_source_failure "${label}" "${out_base}" "${git_log}" \
                "git clone failed"
            return 1
        fi
        is_fresh_clone=true
    fi

    local commit_after
    commit_after="$(git -C "${src_dir}" rev-parse HEAD)"
    info "[${label}]   commit after pull : ${commit_after}"
    echo "" >> "${git_log}"
    echo "  commit_after  : ${commit_after}" >> "${git_log}"
    echo "  result        : SUCCESS" >> "${git_log}"

    # ---- commit-info.txt ------------------------------------------------
    local ci_file="${out_base}/commit-info.txt"
    {
        echo "stream         : ${label}"
        echo "src_dir        : ${src_dir}"
        echo "run_date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo ""
        if ${is_fresh_clone}; then
            echo "commit_before  : (none — fresh clone)"
            echo "commit_after   : ${commit_after}"
        else
            echo "commit_before  : ${commit_before}"
            echo "commit_after   : ${commit_after}"
            echo ""
            if [[ "${commit_before}" == "${commit_after}" ]]; then
                echo "new_commits    : (none — already up to date)"
                echo "bisect_cmd     : (not needed)"
            else
                local n
                n="$(git -C "${src_dir}" rev-list --count \
                    "${commit_before}..${commit_after}")"
                echo "new_commits    : ${n} commit(s) pulled in this run"
                echo "bisect_cmd     : git bisect start ${commit_after} ${commit_before}"
                echo ""
                echo "# Commits introduced (newest first):"
                git -C "${src_dir}" log --oneline --no-merges \
                    "${commit_before}..${commit_after}" | sed 's/^/#   /'
                echo ""
                echo "# Full details:"
                git -C "${src_dir}" log \
                    --format='commit %H%nauthor %an <%ae>%ndate   %ad%n%n    %s%n%n    %b' \
                    --date=rfc "${commit_before}..${commit_after}"
            fi
        fi
    } > "${ci_file}"

    info "[${label}]   top commit: $(git -C "${src_dir}" log -1 --oneline)"

    # Print the top_commit text — captured by caller via command substitution
    git -C "${src_dir}" log -1 \
        --format='commit %H%nauthor %an <%ae>%ndate   %ad%n%n    %s' \
        --date=rfc
}

# Helper: write source-failure.txt
_record_source_failure() {
    local label="$1" out_base="$2" git_log="$3" reason="$4"
    warn "[${label}] Source preparation failed: ${reason}"
    {
        echo "========================================================"
        echo "  Source Preparation Failure"
        echo "========================================================"
        echo "  stream  : ${label}"
        echo "  reason  : ${reason}"
        echo "  date    : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "  impact  : all debug levels skipped for this stream"
        echo "  git_log : ${git_log}"
        echo ""
        echo "  See git-pull.log in this directory for the full git output."
        echo "========================================================"
    } > "${out_base}/source-failure.txt"
}

# ---------------------------------------------------------------------------
# Stage 3b — Build + test one stream × debug level
# ---------------------------------------------------------------------------
run_level() {
    local label="$1"
    local src_dir="$2"
    local debug_level="$3"
    local out_base="$4"
    local boot_jdk_dir="$5"
    shift 5
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
        "${JTREG_OK}" \
        "${boot_jdk_dir}" \
        "${extra_flags[@]+"${extra_flags[@]}"}" \
        || exit_code=$?

    if [[ ${exit_code} -ne 0 ]]; then
        warn "[${label}] Build error (exit=${exit_code}) — recorded, continuing."
        echo "BUILD ERROR — exit ${exit_code}" >> "${out_dir}/build.log"
        echo "Build failed (exit ${exit_code})" > "${out_dir}/test-summary.txt"
        record_status "${label}" "${debug_level}" "BUILD_FAILED" \
            "configure or make images exited ${exit_code}; tier1 tests did not run"
    else
        local test_exit_line
        test_exit_line="$(grep '^test_exit:' "${out_dir}/run-metadata.txt" 2>/dev/null \
            | awk '{print $2}' || echo "0")"
        if [[ "${test_exit_line}" == "SKIPPED" ]]; then
            record_status "${label}" "${debug_level}" "TEST_SKIPPED_NO_JTREG" \
                "build succeeded; tests skipped (jtreg download failed)"
        elif [[ "${test_exit_line}" != "0" ]]; then
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
# Helper: resolve the boot JDK directory for a given stream.
#
# For "head" (or any stream whose min_ver is empty / 0) we need the tip JDK.
# For versioned streams we want boot_jdk_<min_ver>; fall back to BOOT_JDK_DIR
# if setup_deps.sh did not download that version (e.g. --skip-deps + old tree).
# ---------------------------------------------------------------------------
_resolve_boot_jdk_dir_for_stream() {
    local label="$1"
    local min_ver="${2:-0}"

    # "head" always uses the tip JDK (BOOT_JDK_DIR, which setup_deps.sh
    # keeps pointing at the newest downloaded JDK).
    if [[ "${label}" == "head" ]]; then
        echo "${BOOT_JDK_DIR}"
        return
    fi

    # boot_jdk_dir_for_version is defined in config.sh (already sourced)
    local candidate
    candidate="$(boot_jdk_dir_for_version "${min_ver}")"

    if [[ -x "${candidate}/bin/java" ]]; then
        echo "${candidate}"
    else
        warn "[${label}] Versioned boot JDK not found at ${candidate}; falling back to ${BOOT_JDK_DIR}"
        echo "${BOOT_JDK_DIR}"
    fi
}

# ---------------------------------------------------------------------------
# Stage 3 — Process all active streams
# ---------------------------------------------------------------------------
process_streams() {
    log "========================================================"
    log "Stage 3: Processing streams"
    log "========================================================"

    for entry in "${ACTIVE_STREAMS[@]}"; do
        IFS='|' read -r label src_subdir git_url min_ver extra_flags \
            <<< "${entry}"

        local src_dir="${JDK_SOURCES_ROOT}/${src_subdir}"
        local out_base="${PIPELINE_LOG_DIR}/${label}"
        mkdir -p "${out_base}"

        log "----------------------------------------------------"
        log "[${label}] Starting stream"
        log "----------------------------------------------------"

        # Resolve the boot JDK directory for this stream's minimum version.
        local boot_jdk_dir
        boot_jdk_dir="$(_resolve_boot_jdk_dir_for_stream "${label}" "${min_ver}")"
        info "[${label}]   boot JDK : ${boot_jdk_dir}"

        # git pull / clone
        local top_commit
        if ! top_commit="$(prepare_source "${label}" "${src_subdir}" "${git_url}" "${out_base}")"; then
            warn "[${label}] Skipping all levels (source preparation failed)."
            for level in "${BUILD_LEVELS[@]}"; do
                record_status "${label}" "${level}" "SKIPPED_SOURCE_FAIL" \
                    "git pull/clone failed; see source-failure.txt"
            done
            continue
        fi
        echo "${top_commit}" > "${out_base}/top_commit"

        # Split extra_flags string into array (safe: space-separated flags only)
        local flags_arr=()
        if [[ -n "${extra_flags}" ]]; then
            # shellcheck disable=SC2206
            flags_arr=(${extra_flags})
        fi

        for level in "${BUILD_LEVELS[@]}"; do
            run_level "${label}" "${src_dir}" "${level}" "${out_base}" \
                "${boot_jdk_dir}" \
                "${flags_arr[@]+"${flags_arr[@]}"}"
        done

        success "[${label}] Stream complete."
    done
}

# ---------------------------------------------------------------------------
# Stage 4 — Write run-summary.txt
# ---------------------------------------------------------------------------
write_run_summary() {
    local summary_file="${PIPELINE_LOG_DIR}/run-summary.txt"

    local boot_jdk_ver="n/a" jtreg_ver="n/a"
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
        echo "  Date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "  Host       : $(hostname)"
        echo "  Boot JDK   : ${boot_jdk_ver}"
        echo "  jtreg      : ${jtreg_ver}"
        echo "  JTREG_OK   : ${JTREG_OK}"
        echo "  pipeline.log: ${PIPELINE_LOG}"
        [[ -n "${FILTER_STREAM}" ]] && echo "  --stream   : ${FILTER_STREAM}"
        [[ -n "${FILTER_LEVEL}"  ]] && echo "  --level    : ${FILTER_LEVEL}"
        ${DRY_RUN}   && echo "  Mode       : DRY-RUN"
        ${SKIP_DEPS} && echo "  Deps       : skipped (--skip-deps)"
        echo ""
        echo "  Legend:"
        echo "    TEST_PASSED             All tier1 tests passed"
        echo "    TEST_FAILED             Tier1 ran; failures or errors recorded"
        echo "    TEST_SKIPPED_NO_JTREG   Build OK; tests skipped (jtreg not available)"
        echo "    BUILD_FAILED            configure/make failed; tests did not run"
        echo "    SKIPPED_SOURCE_FAIL     git pull/clone failed; nothing ran"
        echo "    SKIPPED_BOOT_JDK_FAIL   Boot JDK download failed; pipeline aborted"
        echo "    SKIPPED_FILTER          Excluded by --stream / --level flag"
        echo "    SKIPPED_DRY_RUN         Dry-run mode; no build or test executed"
        echo "    SKIPPED_EOL             Version no longer in Adoptium active support"
        echo "========================================================"
        echo ""

        # Print per-stream results in registry order
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
                    printf "    %-12s  %-28s  %s\n" \
                        "${level}" \
                        "${STREAM_STATUS[${key}]}" \
                        "${STREAM_STATUS_DETAIL[${key}]:-}"
                fi
            done
            ${any_found} || echo "    (no status recorded)"
            echo ""
        done

        # Totals
        local n_passed=0 n_failed=0 n_build_fail=0 n_skipped=0 n_no_jtreg=0
        for key in "${!STREAM_STATUS[@]}"; do
            case "${STREAM_STATUS[${key}]}" in
                TEST_PASSED)             (( n_passed++    )) ;;
                TEST_FAILED)             (( n_failed++    )) ;;
                TEST_SKIPPED_NO_JTREG)   (( n_no_jtreg++ )) ;;
                BUILD_FAILED)            (( n_build_fail++)) ;;
                SKIPPED_*)               (( n_skipped++   )) ;;
            esac
        done
        local n_total=$(( n_passed + n_failed + n_build_fail + n_skipped + n_no_jtreg ))

        echo "========================================================"
        echo "  Totals  (stream × level combinations)"
        printf "    %-30s %d\n" "Combinations tracked:"       "${n_total}"
        printf "    %-30s %d\n" "TEST_PASSED:"                "${n_passed}"
        printf "    %-30s %d\n" "TEST_FAILED:"                "${n_failed}"
        printf "    %-30s %d\n" "TEST_SKIPPED (no jtreg):"    "${n_no_jtreg}"
        printf "    %-30s %d\n" "BUILD_FAILED:"               "${n_build_fail}"
        printf "    %-30s %d\n" "Skipped (any reason):"       "${n_skipped}"
        echo "========================================================"
        echo ""
        echo "  Report directory: ${PIPELINE_LOG_DIR}/"
        echo "  Files:"
        echo "    pipeline.log      — full timestamped run output"
        echo "    run-summary.txt   — this file"
        echo "    deps-failure.txt  — present only if a dep download failed"
        echo "    <stream>/"
        echo "      top_commit              — HEAD commit built+tested"
        echo "      commit-info.txt         — pre/post pull commits + bisect cmd"
        echo "      git-pull.log            — git fetch/pull output"
        echo "      source-failure.txt      — present only if git pull failed"
        echo "      <level>/"
        echo "        configure.log         — full configure output"
        echo "        build.log             — full make images output"
        echo "        build-diagnosis.txt   — last cmd + error context"
        echo "        test-summary.txt      — jtreg pass/fail totals"
        echo "        newfailures.txt       — failing test names"
        echo "        other_errors.txt      — erroring test names"
        echo "        run-metadata.txt      — versions, exit codes, dates"
        echo "        test-passed.txt       — names of all passed tests"
        echo "        test-failed.txt       — names of all failed tests"
        echo "        test-skipped.txt      — names of all skipped tests"
        echo "        test-failure.log      — failure detail + hs_err notice"
        echo "        test-passed.md        — GitHub: passed tests"
        echo "        test-failed.md        — GitHub: failed tests + days-failing"
        echo "        test-skipped.md       — GitHub: skipped tests"
        echo "        hs_err/<YYYYMMDD_HHmmSS>/ — JVM crash logs (local only)"
        echo "========================================================"

    } > "${summary_file}"

    success "Run summary: ${summary_file}"
    echo ""
    cat "${summary_file}"
    echo ""
}

# ---------------------------------------------------------------------------
# Stage 4b — Retention purge: remove reports older than 90 days
#
# Runs unconditionally on every pipeline execution (even --dry-run logs it).
# Deletes stale day directories from disk and stages their removal in the git
# index so they are wiped from GitHub on the next push.
# Also removes local-only hs_err/ and test-support/ trees within live days.
# ---------------------------------------------------------------------------
purge_old_reports() {
    log "========================================================"
    log "Stage 4b: Retention purge (>90 days)"
    log "========================================================"

    if ${DRY_RUN}; then
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
# Stage 4c — Generate GitHub-readable status pages
#
# Writes:
#   STATUS.md                              — top-level rolling dashboard
#   reports/YYYY/Month/DD/run-summary.md  — per-run Markdown report
# ---------------------------------------------------------------------------
gen_status_pages() {
    log "========================================================"
    log "Stage 4c: Generating status pages"
    log "========================================================"

    if ! python3 "${SCRIPT_DIR}/gen_status.py" \
            "${REPORTS_DIR}" \
            "${REPORTS_REPO_ROOT}" 2>&1; then
        warn "gen_status.py failed — continuing without status pages."
    else
        success "Status pages generated."
    fi
}

# ---------------------------------------------------------------------------
# Stage 5 — Commit and push results
# ---------------------------------------------------------------------------
publish_results() {
    if ${DRY_RUN}; then
        info "DRY-RUN: would commit and push to origin/${GIT_RESULTS_BRANCH}"
        info "  STATUS.md and run-summary.md would also be staged."
        return 0
    fi

    log "========================================================"
    log "Stage 5: Publishing results"
    log "========================================================"

    cd "${REPORTS_REPO_ROOT}"
    git fetch origin "${GIT_RESULTS_BRANCH}"
    git checkout "${GIT_RESULTS_BRANCH}"
    git pull --ff-only origin "${GIT_RESULTS_BRANCH}"

    # Stage all report artefacts + the status pages.
    # Exclude hs_err/ directories — these contain JVM crash logs that are
    # large and intended for local investigation only, never pushed to GitHub.
    git add "${REPORTS_DIR}/"
    git reset HEAD -- "${REPORTS_DIR}"/**/hs_err/ 2>/dev/null || true
    git add --force STATUS.md 2>/dev/null || true

    if git diff --cached --quiet; then
        info "Nothing new to commit."
        return 0
    fi

    local status_lines=""
    for lbl in "${ALL_REGISTERED_LABELS[@]}"; do
        for level in "${BUILD_LEVELS[@]}"; do
            local key="${lbl}/${level}"
            if [[ -n "${STREAM_STATUS[${key}]+_}" ]]; then
                status_lines+="  ${key}: ${STREAM_STATUS[${key}]}"$'\n'
            fi
        done
    done

    # One-line headline for the commit message
    local headline_icon="✅"
    for key in "${!STREAM_STATUS[@]}"; do
        if [[ "${STREAM_STATUS[${key}]}" == "BUILD_FAILED"
           || "${STREAM_STATUS[${key}]}" == "TEST_FAILED"
           || "${STREAM_STATUS[${key}]}" == "SKIPPED_BOOT_JDK_FAIL" ]]; then
            headline_icon="❌"
            break
        fi
    done

    git \
        -c "user.name=${GIT_COMMIT_AUTHOR_NAME}" \
        -c "user.email=${GIT_COMMIT_AUTHOR_EMAIL}" \
        commit -m "${headline_icon} CI: tier1 ${_YEAR}-${_MONTH}-${_DAY}

Automated s390x CI run — see STATUS.md for rolling dashboard.
Host: $(hostname)
JTREG available: ${JTREG_OK}
Retention: reports older than 90 days purged from repo.

Results per stream/level:
${status_lines}
Logs: reports/${_YEAR}/${_MONTH}/${_DAY}/pipeline.log
"
    git push origin "${GIT_RESULTS_BRANCH}"
    success "Results pushed to origin/${GIT_RESULTS_BRANCH}."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "========================================================"
    log "OpenJDK s390x CI — daily tier1 run"
    log "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    log "Host        : $(hostname)"
    log "Reports dir : ${PIPELINE_LOG_DIR}"
    log "Pipeline log: ${PIPELINE_LOG}"
    ${DRY_RUN}                  && log "MODE: DRY-RUN"
    [[ -n "${FILTER_STREAM}" ]] && log "FILTER: stream=${FILTER_STREAM}"
    [[ -n "${FILTER_LEVEL}"  ]] && log "FILTER: level=${FILTER_LEVEL}"
    log "========================================================"

    refresh_deps            # Stage 1 — aborts on boot JDK failure
    resolve_active_streams  # Stage 2
    process_streams         # Stage 3
    write_run_summary       # Stage 4a
    purge_old_reports       # Stage 4b — delete reports >90 days (always runs)
    gen_status_pages        # Stage 4c — writes STATUS.md + per-run .md
    publish_results         # Stage 5

    log "========================================================"
    log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    log "========================================================"
}

main "$@"
