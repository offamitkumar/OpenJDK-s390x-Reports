#!/usr/bin/env bash
# =============================================================================
# run_daily.sh — Daily CI orchestrator: tier1 tests for all active streams
#
# Pipeline stages:
#   1. Download boot JDK + jtreg (setup_deps.sh)
#      boot JDK fail → ABORT; jtreg fail → DEGRADED (builds only)
#   2. resolve_streams.py — filter registry to active Adoptium versions
#   3. Per stream × level: git pull → configure → build → tier1 tests
#   4a. write run-summary.txt
#   4b. retention purge (>90 days)
#   4c. gen_status.py → STATUS.md + per-run run-summary.md
#   5. Email notification
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
# shellcheck source=scripts/notify.sh
source "${SCRIPT_DIR}/notify.sh"

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
# Trap: always return to repo root on exit
# ---------------------------------------------------------------------------
trap 'cd "${REPORTS_REPO_ROOT}"' EXIT

# ---------------------------------------------------------------------------
# Dependency flags
# ---------------------------------------------------------------------------
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
    log "========================================================"
    log "Stage 1: Downloading dependencies"
    log "========================================================"

    local stream_arg="${FILTER_STREAM:-head}"
    ensure_deps "${stream_arg}" "${SKIP_DEPS}"

    # On boot JDK failure ensure_deps already exits; reaching here = success or jtreg-only fail.
    # Copy deps-failure.txt into the run log dir if jtreg failed.
    if [[ "${JTREG_OK}" != "true" ]]; then
        if [[ -f "${CI_TMP_DIR}/deps-failure.txt" ]]; then
            cp "${CI_TMP_DIR}/deps-failure.txt" "${PIPELINE_LOG_DIR}/deps-failure.txt"
            cat "${PIPELINE_LOG_DIR}/deps-failure.txt"
        fi
    else
        success "Stage 1 complete: boot JDK and jtreg ready."
    fi
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

        local boot_jdk_dir
        boot_jdk_dir="$(resolve_boot_jdk "${label}" "${min_ver}")"
        info "[${label}]   boot JDK : ${boot_jdk_dir}"

        # git pull / clone (shared function from build_test.sh)
        local top_commit
        if ! top_commit="$(update_source "${label}" "${src_subdir}" "${git_url}" "${out_base}")"; then
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
                TEST_PASSED)             n_passed=$(( n_passed + 1 ))       ;;
                TEST_FAILED)             n_failed=$(( n_failed + 1 ))       ;;
                TEST_SKIPPED_NO_JTREG)   n_no_jtreg=$(( n_no_jtreg + 1 ))  ;;
                BUILD_FAILED)            n_build_fail=$(( n_build_fail + 1 ));;
                SKIPPED_*)               n_skipped=$(( n_skipped + 1 ))     ;;
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
    purge_old_reports       # Stage 4b — delete reports >90 days
    gen_status_pages        # Stage 4c — writes STATUS.md + per-run .md

    # Stage 5 — Email notification
    local _overall="PASS"
    for key in "${!STREAM_STATUS[@]}"; do
        case "${STREAM_STATUS[${key}]}" in
            BUILD_FAILED|TEST_FAILED|SKIPPED_BOOT_JDK_FAIL)
                _overall="FAIL"; break ;;
        esac
    done
    local _subject_suffix="all streams (${_YEAR}-${_MONTH}-${_DAY})"
    [[ -n "${FILTER_STREAM}" ]] && _subject_suffix="${FILTER_STREAM} (${_YEAR}-${_MONTH}-${_DAY})"

    # Build stream_label:src_dir:level:build_status quads for notify.sh
    local _triples=()
    for _entry in "${ACTIVE_STREAMS[@]}"; do
        local _lbl _sub
        IFS='|' read -r _lbl _sub _ _ _ <<< "${_entry}"
        for _lvl in "${BUILD_LEVELS[@]}"; do
            local _key="${_lbl}/${_lvl}"
            local _st="${STREAM_STATUS[${_key}]:-UNKNOWN}"
            local _bst
            if   [[ "${_st}" == "BUILD_FAILED"  ]]; then _bst="BUILD_FAILED"
            elif [[ "${_st}" == "TEST_FAILED"   ]]; then _bst="TEST_FAILED"
            else                                         _bst="TEST_PASSED"
            fi
            _triples+=("${_lbl}:${JDK_SOURCES_ROOT}/${_sub}:${_lvl}:${_bst}")
        done
    done
    # For daily runs, build a combined commit-info file from all active streams
    local _ci_combined="${PIPELINE_LOG_DIR}/commit-info-all.txt"
    : > "${_ci_combined}"
    for _entry in "${ACTIVE_STREAMS[@]}"; do
        local _lbl _sub
        IFS='|' read -r _lbl _sub _ _ _ <<< "${_entry}"
        local _ci="${PIPELINE_LOG_DIR}/${_lbl}/commit-info.txt"
        if [[ -f "${_ci}" ]]; then
            echo "" >> "${_ci_combined}"
            echo "════ ${_lbl} ════════════════════════════════════════" \
                >> "${_ci_combined}"
            cat "${_ci}" >> "${_ci_combined}"
        fi
    done
    ci_notify "daily" "${_subject_suffix}" \
        "${PIPELINE_LOG_DIR}/run-summary.txt" "${_overall}" \
        "${_ci_combined}" \
        "${_triples[@]}"

    log "========================================================"
    log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    log "========================================================"
}

main "$@"
