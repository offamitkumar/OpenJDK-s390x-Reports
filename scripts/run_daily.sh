#!/usr/bin/env bash
# =============================================================================
# run_daily.sh — Daily CI orchestrator: tier1 tests for all active streams
#
# Pipeline stages:
#   1. Download boot JDK + jtreg (setup_deps.sh)
#      boot JDK fail → ABORT; jtreg fail → DEGRADED (builds only)
#   2. resolve_streams.py — filter registry to active Adoptium versions
#   3. Per stream × level: git pull → configure → build → tier1 tests
#      Results are read from <src_dir>/build/<conf>/ — no separate report dir.
#   4. write run-summary.txt (stdout only — no file)
#   5. Email notification
#
# Usage:
#   bash scripts/run_daily.sh [--stream LABEL] [--level LEVEL]
#                             [--skip-deps] [--skip-tests] [--dry-run]
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
SKIP_TESTS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stream)      FILTER_STREAM="$2"; shift 2 ;;
        --level)       FILTER_LEVEL="$2";  shift 2 ;;
        --skip-deps)   SKIP_DEPS=true;     shift   ;;
        --skip-tests)  SKIP_TESTS=true;    shift   ;;
        --dry-run)     DRY_RUN=true;       shift   ;;
        *) echo "[FATAL] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

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

    if [[ "${JTREG_OK}" != "true" ]]; then
        warn "jtreg not available — tests will be SKIPPED."
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
    local boot_jdk_dir="$4"
    shift 4
    local extra_flags=("$@")

    # Apply --level filter
    if [[ -n "${FILTER_LEVEL}" && "${debug_level}" != "${FILTER_LEVEL}" ]]; then
        info "[${label}] Skipping ${debug_level} (--level filter)"
        record_status "${label}" "${debug_level}" "SKIPPED_FILTER" \
            "Excluded by --level ${FILTER_LEVEL}"
        return 0
    fi

    log "[${label}] Starting build+test: ${debug_level} …"

    if ${DRY_RUN}; then
        info "[${label}] DRY-RUN: would build+test ${label}/${debug_level}"
        record_status "${label}" "${debug_level}" "SKIPPED_DRY_RUN" \
            "--dry-run flag set; no build or test executed"
        return 0
    fi

    local _run_jtreg="${JTREG_OK}"
    ${SKIP_TESTS} && _run_jtreg="false"

    local exit_code=0
    build_and_test_jdk \
        "${src_dir}" \
        "${label}" \
        "${debug_level}" \
        "${_run_jtreg}" \
        "${boot_jdk_dir}" \
        "${extra_flags[@]+"${extra_flags[@]}"}" \
        || exit_code=$?

    if [[ ${exit_code} -ne 0 ]]; then
        warn "[${label}] Build error (exit=${exit_code}) — recorded, continuing."
        record_status "${label}" "${debug_level}" "BUILD_FAILED" \
            "configure or make images exited ${exit_code}"
    else
        # Read test_exit from run-metadata.txt in the build conf dir
        local conf_dir
        conf_dir="$(find "${src_dir}/build" -maxdepth 1 -type d \
            -name "*${debug_level}*" 2>/dev/null | sort | head -1)"
        local test_exit_line="0"
        if [[ -n "${conf_dir}" && -f "${conf_dir}/run-metadata.txt" ]]; then
            test_exit_line="$(grep '^test_exit:' "${conf_dir}/run-metadata.txt" \
                | awk '{print $2}' || echo "0")"
        fi
        if [[ "${test_exit_line}" == "SKIPPED" ]]; then
            record_status "${label}" "${debug_level}" "TEST_SKIPPED_NO_JTREG" \
                "build succeeded; tests skipped"
        elif [[ "${test_exit_line}" != "0" ]]; then
            record_status "${label}" "${debug_level}" "TEST_FAILED" \
                "tier1 completed with failures/errors (jtreg exit=${test_exit_line})"
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

        log "----------------------------------------------------"
        log "[${label}] Starting stream"
        log "----------------------------------------------------"

        local boot_jdk_dir
        boot_jdk_dir="$(resolve_boot_jdk "${label}" "${min_ver}")"
        info "[${label}]   boot JDK : ${boot_jdk_dir}"

        # git pull / clone — writes metadata into src_dir itself
        if ! update_source "${label}" "${src_subdir}" "${git_url}"; then
            warn "[${label}] Skipping all levels (source preparation failed)."
            for level in "${BUILD_LEVELS[@]}"; do
                record_status "${label}" "${level}" "SKIPPED_SOURCE_FAIL" \
                    "git pull/clone failed"
            done
            continue
        fi

        local flags_arr=()
        if [[ -n "${extra_flags}" ]]; then
            # shellcheck disable=SC2206
            flags_arr=(${extra_flags})
        fi

        for level in "${BUILD_LEVELS[@]}"; do
            run_level "${label}" "${src_dir}" "${level}" \
                "${boot_jdk_dir}" \
                "${flags_arr[@]+"${flags_arr[@]}"}"
        done

        success "[${label}] Stream complete."
    done
}

# ---------------------------------------------------------------------------
# Stage 4 — Print run summary to stdout
# ---------------------------------------------------------------------------
print_run_summary() {
    local boot_jdk_ver="n/a" jtreg_ver="n/a"
    if [[ -x "${BOOT_JDK_DIR}/bin/java" ]]; then
        boot_jdk_ver="$("${BOOT_JDK_DIR}/bin/java" -version 2>&1 | head -1)"
    fi
    if [[ -x "${JTREG_DIR}/bin/jtreg" ]]; then
        jtreg_ver="$(JAVA_HOME="${BOOT_JDK_DIR}" "${JTREG_DIR}/bin/jtreg" \
            -version 2>/dev/null | head -1 || echo 'n/a')"
    fi

    echo "========================================================"
    echo "  OpenJDK s390x CI — Run Summary"
    echo "========================================================"
    echo "  Date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "  Host       : $(hostname)"
    echo "  Boot JDK   : ${boot_jdk_ver}"
    echo "  jtreg      : ${jtreg_ver}"
    [[ -n "${FILTER_STREAM}" ]] && echo "  --stream   : ${FILTER_STREAM}"
    [[ -n "${FILTER_LEVEL}"  ]] && echo "  --level    : ${FILTER_LEVEL}"
    ${DRY_RUN}    && echo "  Mode       : DRY-RUN"
    ${SKIP_TESTS} && echo "  Tests      : skipped (--skip-tests)"
    ${SKIP_DEPS}  && echo "  Deps       : skipped (--skip-deps)"
    echo ""

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

    local n_passed=0 n_failed=0 n_build_fail=0 n_skipped=0 n_no_jtreg=0
    for key in "${!STREAM_STATUS[@]}"; do
        case "${STREAM_STATUS[${key}]}" in
            TEST_PASSED)             n_passed=$(( n_passed + 1 ))        ;;
            TEST_FAILED)             n_failed=$(( n_failed + 1 ))        ;;
            TEST_SKIPPED_NO_JTREG)   n_no_jtreg=$(( n_no_jtreg + 1 ))   ;;
            BUILD_FAILED)            n_build_fail=$(( n_build_fail + 1 ));;
            SKIPPED_*)               n_skipped=$(( n_skipped + 1 ))      ;;
        esac
    done

    echo "========================================================"
    echo "  Totals"
    printf "    %-30s %d\n" "TEST_PASSED:"             "${n_passed}"
    printf "    %-30s %d\n" "TEST_FAILED:"             "${n_failed}"
    printf "    %-30s %d\n" "TEST_SKIPPED (no jtreg):" "${n_no_jtreg}"
    printf "    %-30s %d\n" "BUILD_FAILED:"            "${n_build_fail}"
    printf "    %-30s %d\n" "Skipped:"                 "${n_skipped}"
    echo "========================================================"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "========================================================"
    log "OpenJDK s390x CI — daily tier1 run"
    log "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    log "Host   : $(hostname)"
    ${DRY_RUN}                  && log "MODE: DRY-RUN"
    ${SKIP_TESTS}               && log "Tests: SKIPPED (--skip-tests)"
    [[ -n "${FILTER_STREAM}" ]] && log "FILTER: stream=${FILTER_STREAM}"
    [[ -n "${FILTER_LEVEL}"  ]] && log "FILTER: level=${FILTER_LEVEL}"
    log "========================================================"

    refresh_deps            # Stage 1 — aborts on boot JDK failure
    resolve_active_streams  # Stage 2
    process_streams         # Stage 3
    print_run_summary       # Stage 4 — stdout only

    # Stage 5 — Email notification
    local _overall="PASS"
    for key in "${!STREAM_STATUS[@]}"; do
        case "${STREAM_STATUS[${key}]}" in
            BUILD_FAILED|TEST_FAILED|SKIPPED_BOOT_JDK_FAIL)
                _overall="FAIL"; break ;;
        esac
    done
    local _date_str; _date_str="$(date -u '+%Y-%m-%d')"
    local _subject_suffix="all streams (${_date_str})"
    [[ -n "${FILTER_STREAM}" ]] && _subject_suffix="${FILTER_STREAM} (${_date_str})"

    # Build quads: stream_label:src_dir:level:build_status
    local _triples=()
    for _entry in "${ACTIVE_STREAMS[@]}"; do
        local _lbl _sub
        IFS='|' read -r _lbl _sub _ _ _ <<< "${_entry}"
        for _lvl in "${BUILD_LEVELS[@]}"; do
            local _key="${_lbl}/${_lvl}"
            local _st="${STREAM_STATUS[${_key}]:-UNKNOWN}"
            local _bst
            if   [[ "${_st}" == "BUILD_FAILED" ]]; then _bst="BUILD_FAILED"
            elif [[ "${_st}" == "TEST_FAILED"  ]]; then _bst="TEST_FAILED"
            else                                        _bst="TEST_PASSED"
            fi
            _triples+=("${_lbl}:${JDK_SOURCES_ROOT}/${_sub}:${_lvl}:${_bst}")
        done
    done

    # Combined commit info from each stream's source tree
    local _tmp_commits; _tmp_commits="$(mktemp)"
    for _entry in "${ACTIVE_STREAMS[@]}"; do
        local _lbl _sub
        IFS='|' read -r _lbl _sub _ _ _ <<< "${_entry}"
        local _ci="${JDK_SOURCES_ROOT}/${_sub}/commit-info.txt"
        if [[ -f "${_ci}" ]]; then
            echo "" >> "${_tmp_commits}"
            echo "════ ${_lbl} ════════════════════════════════════════" >> "${_tmp_commits}"
            cat "${_ci}" >> "${_tmp_commits}"
        fi
    done

    # Build a minimal summary string for the email body
    local _tmp_summary; _tmp_summary="$(mktemp)"
    print_run_summary > "${_tmp_summary}"

    ci_notify "daily" "${_subject_suffix}" \
        "${_tmp_summary}" "${_overall}" \
        "${_tmp_commits}" \
        "${_triples[@]}"

    rm -f "${_tmp_summary}" "${_tmp_commits}"

    log "========================================================"
    log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    log "========================================================"
}

main "$@"
