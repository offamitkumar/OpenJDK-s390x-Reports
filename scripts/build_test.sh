#!/usr/bin/env bash
# =============================================================================
# build_test.sh — Build and test one (stream × debug-level) combination
#
# Sourced by run_daily.sh and jdk.sh — not invoked directly.
#
# Public functions:
#
#   build_and_test_jdk  <src_dir> <label> <debug_level> <out_dir> \
#                       <jtreg_ok> [extra_configure_flags...]
#       Full pipeline: configure → make images → tier1 tests.
#       jtreg_ok="false" skips the test step (build only in that sense, but
#       still runs configure + images).
#
#   build_only_jdk  <src_dir> <label> <debug_level> <out_dir> \
#                   [extra_configure_flags...]
#       configure + make images, no tests at all.
#
#   run_tests_only  <src_dir> <label> <debug_level> <out_dir> \
#                   <test_target> <jvm_flags>
#       Re-use an existing build (no configure, no make images).
#       Runs the given jtreg test target with optional JVM flags.
#       test_target examples: "tier1", "test/jdk", "test/hotspot/jtreg/gc"
#       jvm_flags  examples: "-Xint", "-Xcomp -ea", "" (empty = none)
#
# Environment expected (set via config.sh):
#   BOOT_JDK_DIR, JTREG_DIR, GTEST_DIR
# =============================================================================

# This file is sourced, not executed directly.
# set -euo pipefail is NOT set at file scope — the caller owns the outer shell.
# Each public function runs its critical body inside a subshell with its own
# set -e so a build failure terminates only that combination.

_bt_info()    { echo "[INFO]  $*"; }
_bt_success() { echo "[OK]    $*"; }
_bt_warn()    { echo "[WARN]  $*" >&2; }

# ---------------------------------------------------------------------------
# Internal: collect tier1 test artifacts after a test run
#
# Parses jtreg result files into three categorised lists:
#   out_dir/test-passed.txt      — one test name per line
#   out_dir/test-failed.txt      — one test name per line
#   out_dir/test-skipped.txt     — one test name per line
#   out_dir/test-failure.log     — full failure output + hs_err notice
#
# hs_err files are harvested from the build tree and copied into:
#   out_dir/hs_err/<RUN_TIMESTAMP>/
# where RUN_TIMESTAMP is the same second-precise stamp used by jdk.sh so that
# repeated same-day runs never overwrite each other.
#
# Arguments:
#   $1  conf_dir        — build/<conf_name> (absolute or relative to CWD)
#   $2  out_dir         — report output directory (where other artefacts live)
#   $3  run_timestamp   — e.g. "20250604_143022" (YYYYMMDD_HHMMSS)
# ---------------------------------------------------------------------------
_collect_tier1_artifacts() {
    local conf_dir="$1"
    local out_dir="$2"
    local run_timestamp="$3"

    local results_dir="${conf_dir}/test-results"
    local support_dir="${conf_dir}/test-support"

    # ---- 1. Categorise tests from jtreg .jtr / summary files ---------------
    # jtreg writes individual <testname>.jtr files under test-support/.
    # The first line of a .jtr is one of:
    #   #status:passed  #status:failed  #status:error  #status:not_run
    # We also fall back to parsing test-summary.txt for a quick tally
    # if no .jtr files exist (e.g. when a previous stage pre-aborted).

    local passed_file="${out_dir}/test-passed.txt"
    local failed_file="${out_dir}/test-failed.txt"
    local skipped_file="${out_dir}/test-skipped.txt"

    : > "${passed_file}"
    : > "${failed_file}"
    : > "${skipped_file}"

    local jtr_count=0
    if [[ -d "${support_dir}" ]]; then
        while IFS= read -r jtr; do
            (( jtr_count++ )) || true
            # Extract test name: strip leading path components and .jtr suffix
            local tname
            tname="$(basename "${jtr}" .jtr)"
            # First non-blank, non-comment line that looks like #status:…
            local status_line
            status_line="$(grep -m1 '^#status:' "${jtr}" 2>/dev/null || echo '#status:unknown')"
            case "${status_line}" in
                "#status:passed")   echo "${tname}" >> "${passed_file}"  ;;
                "#status:failed")   echo "${tname}" >> "${failed_file}"  ;;
                "#status:error")    echo "${tname}" >> "${failed_file}"  ;;
                "#status:not_run")  echo "${tname}" >> "${skipped_file}" ;;
                *)                  echo "${tname}" >> "${skipped_file}" ;;
            esac
        done < <(find "${support_dir}" -name "*.jtr" 2>/dev/null | sort)
    fi

    # If no .jtr files found, try parsing test-summary.txt for a human note
    if [[ "${jtr_count}" -eq 0 && -f "${out_dir}/test-summary.txt" ]]; then
        echo "(no .jtr files found — raw summary below)" >> "${skipped_file}"
        cat "${out_dir}/test-summary.txt"               >> "${skipped_file}"
    fi

    local n_passed n_failed n_skipped
    n_passed="$(wc -l < "${passed_file}"  | tr -d ' ')"
    n_failed="$(wc -l < "${failed_file}"  | tr -d ' ')"
    n_skipped="$(wc -l < "${skipped_file}" | tr -d ' ')"
    _bt_info "  Test results: passed=${n_passed} failed=${n_failed} skipped/other=${n_skipped}"

    # ---- 2. Harvest hs_err files -------------------------------------------
    local hs_err_dest="${out_dir}/hs_err/${run_timestamp}"
    mkdir -p "${hs_err_dest}"

    local hs_count=0
    while IFS= read -r hs_file; do
        cp "${hs_file}" "${hs_err_dest}/" 2>/dev/null && (( hs_count++ )) || true
    done < <(find "${conf_dir}" -name "hs_err_pid*.log" 2>/dev/null | sort)

    if [[ "${hs_count}" -eq 0 ]]; then
        echo "no hs_err file generated" > "${hs_err_dest}/no_hs_err.txt"
        _bt_info "  hs_err: no hs_err_pid*.log files found."
    else
        _bt_info "  hs_err: ${hs_count} file(s) copied to ${hs_err_dest}/"
    fi

    # ---- 3. Write test-failure.log -----------------------------------------
    local failure_log="${out_dir}/test-failure.log"

    {
        echo "========================================================"
        echo "  Tier1 Test Failure Log"
        echo "========================================================"
        echo "  run_timestamp : ${run_timestamp}"
        echo "  date          : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "  passed        : ${n_passed}"
        echo "  failed        : ${n_failed}"
        echo "  skipped/other : ${n_skipped}"
        echo "  hs_err files  : ${hs_count} (in hs_err/${run_timestamp}/)"
        echo "========================================================"
        echo ""

        if [[ "${n_failed}" -eq 0 ]]; then
            echo "  No failures recorded."
        else
            echo "  Failed tests:"
            sed 's/^/    /' "${failed_file}"
            echo ""

            # Include tail of each .jtr failure file for context
            if [[ -d "${support_dir}" ]]; then
                echo "  ---- Per-test failure details ----"
                while IFS= read -r tname; do
                    local jtr_file
                    jtr_file="$(find "${support_dir}" -name "${tname}.jtr" \
                                    2>/dev/null | head -1)"
                    if [[ -f "${jtr_file}" ]]; then
                        echo ""
                        echo "  [${tname}]"
                        tail -40 "${jtr_file}" | sed 's/^/    /'
                    fi
                done < "${failed_file}"
                echo ""
            fi
        fi

        echo "  hs_err location: ${hs_err_dest}/"
        if [[ "${hs_count}" -gt 0 ]]; then
            echo "  Files:"
            ls "${hs_err_dest}/" | sed 's/^/    /'
        else
            echo "  (no hs_err file generated)"
        fi

    } > "${failure_log}"

    _bt_info "  Test failure log: ${failure_log}"
}

# ---------------------------------------------------------------------------
# Internal: detect JDK major version from source tree
# Used to apply per-version configure quirks.
# ---------------------------------------------------------------------------
_detect_jdk_version() {
    local ver_file="make/conf/version-numbers.conf"
    [[ -f "${ver_file}" ]] || ver_file="make/autoconf/version-numbers"
    if [[ -f "${ver_file}" ]]; then
        grep -m1 'DEFAULT_VERSION_FEATURE[[:space:]]*=' "${ver_file}" \
            | grep -oE '[0-9]+' | head -1
    else
        echo "0"
    fi
}

# ---------------------------------------------------------------------------
# Internal: build the configure argument array for a given debug level
#
# Arguments:
#   $1  debug_level
#   $2  boot_jdk_dir  — path to the boot JDK to use (defaults to BOOT_JDK_DIR)
#   $3+ extra_flags
# ---------------------------------------------------------------------------
_configure_jdk() {
    local debug_level="$1"
    local boot_jdk_dir="${2:-${BOOT_JDK_DIR}}"
    shift 2
    local extra_flags=("$@")

    local jdk_ver
    jdk_ver="$(_detect_jdk_version)"

    local args=(
        "--with-boot-jdk=${boot_jdk_dir}"
        "--with-jtreg=${JTREG_DIR}"
        "--with-debug-level=${debug_level}"
        "--with-native-debug-symbols=internal"
        "--disable-precompiled-headers"
    )

    # googletest: only available in JDK 15+ and only if the dir exists
    if [[ "${jdk_ver}" -ge 15 ]] 2>/dev/null && [[ -d "${GTEST_DIR}" ]]; then
        args+=("--with-gtest=${GTEST_DIR}")
    fi

    for flag in "${extra_flags[@]}"; do
        [[ -n "${flag}" ]] && args+=("${flag}")
    done

    bash configure "${args[@]}"
}

# ---------------------------------------------------------------------------
# Internal: resolve the boot JDK directory for a stream's min version.
# Calls boot_jdk_dir_for_version() from config.sh (already sourced by caller).
# Falls back to BOOT_JDK_DIR if the versioned dir does not exist.
# ---------------------------------------------------------------------------
_resolve_boot_jdk_dir() {
    local min_ver="${1:-0}"
    local candidate
    candidate="$(boot_jdk_dir_for_version "${min_ver}")"
    if [[ -x "${candidate}/bin/java" ]]; then
        echo "${candidate}"
    else
        # versioned dir not ready — fall back to the global tip JDK
        _bt_warn "  boot_jdk_${min_ver} not found at ${candidate}; falling back to ${BOOT_JDK_DIR}"
        echo "${BOOT_JDK_DIR}"
    fi
}

# ---------------------------------------------------------------------------
# Internal: find the build output conf directory after configure
# ---------------------------------------------------------------------------
_find_conf_dir() {
    local debug_level="$1"
    find build -maxdepth 1 -type d -name "*${debug_level}*" 2>/dev/null \
        | sort | head -1
}

# ---------------------------------------------------------------------------
# Internal: write build-diagnosis.txt
#
# Always called — on both success and failure.  On success it documents what
# completed cleanly; on failure it pinpoints the crash point.
#
# Arguments:
#   $1  out_dir        — report output directory
#   $2  build_log      — path to build.log (may not exist on configure failure)
#   $3  phase          — "configure" | "images" | "test" | "unknown"
#   $4  build_exit     — exit code of the build step (0 = success)
#   $5  stream_label
#   $6  debug_level
# ---------------------------------------------------------------------------
_write_build_diagnosis() {
    local out_dir="$1"
    local build_log="$2"
    local phase="$3"
    local build_exit="$4"
    local stream_label="$5"
    local debug_level="$6"

    local diag_file="${out_dir}/build-diagnosis.txt"
    mkdir -p "${out_dir}"

    {
        echo "========================================================"
        echo "  Build Diagnosis"
        echo "========================================================"
        echo "  stream      : ${stream_label}"
        echo "  debug_level : ${debug_level}"
        echo "  phase       : ${phase}"
        echo "  build_exit  : ${build_exit}"
        echo "  date        : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "  build_log   : ${build_log}"
        echo ""

        if [[ "${build_exit}" -eq 0 ]]; then
            echo "  status      : BUILD SUCCEEDED"
            echo "========================================================"
            echo ""
            if [[ -f "${build_log}" ]]; then
                echo "--- Last 20 lines of build.log ---"
                tail -20 "${build_log}"
            fi
            return
        fi

        echo "  status      : BUILD FAILED"
        echo "========================================================"
        echo ""

        if [[ ! -f "${build_log}" ]]; then
            echo "(build.log not found — failure occurred before make started,"
            echo " likely during 'bash configure'. Check configure.log.)"
            return
        fi

        # ---- Last make target attempted ---------------------------------
        local last_target
        last_target="$(grep -E "^(Building target|Finished building target)" "${build_log}" \
            | tail -1 || true)"
        if [[ -n "${last_target}" ]]; then
            echo "--- Last make target ---"
            echo "  ${last_target}"
            echo ""
        fi

        # ---- Last compiler / linker command -----------------------------
        local last_cmd
        last_cmd="$(grep -E \
            '/(gcc|g\+\+|cc|c\+\+|ld|ar|clang|clang\+\+|javac|jmod|jlink|link\.exe) ' \
            "${build_log}" | tail -1 || true)"
        if [[ -n "${last_cmd}" ]]; then
            echo "--- Last compiler/linker command ---"
            echo "${last_cmd}" | fold -s -w 120
            echo ""
        fi

        # ---- Error context ----------------------------------------------
        local error_count
        error_count="$(grep -c -E '(: error:|^Error |^make\[|^make: \*\*\*)' \
            "${build_log}" 2>/dev/null || echo 0)"

        echo "--- Error lines in build.log (${error_count} matches) ---"
        if [[ "${error_count}" -eq 0 ]]; then
            echo "  (no 'error:' lines found — check full build.log)"
        else
            grep -n -E '(: error:|^Error |^make\[.*Error|^make: \*\*\*)' \
                "${build_log}" \
                | head -5 \
                | while IFS=: read -r lineno rest; do
                    echo ""
                    echo "  [line ${lineno}] ${rest}"
                    local start=$(( lineno - 8 ))
                    [[ ${start} -lt 1 ]] && start=1
                    local end=$(( lineno + 8 ))
                    echo "  --- context (lines ${start}–${end}) ---"
                    sed -n "${start},${end}p" "${build_log}" \
                        | sed 's/^/  | /'
                done
        fi
        echo ""

        # ---- Tail of build.log ------------------------------------------
        echo "--- Last 40 lines of build.log ---"
        tail -40 "${build_log}"
        echo ""
        echo "(Full log: ${build_log})"

    } > "${diag_file}"

    if [[ "${build_exit}" -ne 0 ]]; then
        _bt_warn "  Build diagnosis written to ${diag_file}"
    else
        _bt_info "  Build diagnosis written to ${diag_file}"
    fi
}

# ---------------------------------------------------------------------------
# Public: build_and_test_jdk
#
# Arguments:
#   $1  src_dir              — absolute path to checked-out JDK source
#   $2  stream_label         — short label for reports (e.g. "head", "jdk21")
#   $3  debug_level          — "fastdebug" or "release"
#   $4  out_dir              — directory to write all artefacts into
#   $5  jtreg_ok             — "true" to run tier1; "false" to skip tests
#   $6  boot_jdk_dir         — path to the boot JDK to use for this stream
#   $7+ extra_configure_flags — passed verbatim to configure (optional)
#
# Exit code:
#   0   build completed (and tests ran if jtreg_ok=true; test failures are
#       recorded in run-metadata.txt, not propagated as a non-zero exit)
#   1   infrastructure / build failure (configure or make images failed)
# ---------------------------------------------------------------------------
build_and_test_jdk() {
    local src_dir="$1"
    local stream_label="$2"
    local debug_level="$3"
    local out_dir="$4"
    local jtreg_ok="${5:-true}"
    local boot_jdk_dir="${6:-${BOOT_JDK_DIR}}"
    shift 6
    local extra_configure_flags=("$@")
    # Timestamp for this specific invocation — used to namespace hs_err dirs
    local _run_ts; _run_ts="$(date '+%Y%m%d_%H%M%S')"

    _bt_info "=== build_and_test_jdk ==="
    _bt_info "    stream   : ${stream_label}"
    _bt_info "    level    : ${debug_level}"
    _bt_info "    src      : ${src_dir}"
    _bt_info "    output   : ${out_dir}"
    _bt_info "    jtreg_ok : ${jtreg_ok}"
    _bt_info "    boot_jdk : ${boot_jdk_dir}"
    [[ ${#extra_configure_flags[@]} -gt 0 ]] && \
        _bt_info "    extra    : ${extra_configure_flags[*]}"

    mkdir -p "${out_dir}"

    (
        set -euo pipefail
        cd "${src_dir}"

        local conf_name="linux-s390x-server-${debug_level}"
        local build_log_path=""
        local current_phase="configure"

        # ---- Trap: always write diagnosis on any exit --------------------
        _on_exit() {
            local exit_code=$?
            local actual_log="${build_log_path}"
            if [[ -z "${actual_log}" ]]; then
                local found_dir
                found_dir="$(_find_conf_dir "${debug_level}")"
                [[ -n "${found_dir}" ]] && actual_log="${found_dir}/build.log"
            fi
            _write_build_diagnosis \
                "${out_dir}" \
                "${actual_log:-}" \
                "${current_phase}" \
                "${exit_code}" \
                "${stream_label}" \
                "${debug_level}"
        }
        trap _on_exit EXIT

        # ---- Clean prior build -------------------------------------------
        if [[ -d "build/${conf_name}" ]]; then
            _bt_info "  Cleaning prior build/${conf_name} …"
            make CONF="${conf_name}" dist-clean 2>/dev/null \
                || rm -rf "build/${conf_name}"
        fi

        # ---- Configure ---------------------------------------------------
        current_phase="configure"
        _bt_info "  Running configure (debug-level=${debug_level}) …"
        _configure_jdk "${debug_level}" "${boot_jdk_dir}" \
            "${extra_configure_flags[@]+"${extra_configure_flags[@]}"}"

        # Verify conf dir — configure may choose a slightly different name
        if [[ ! -d "build/${conf_name}" ]]; then
            local found
            found="$(_find_conf_dir "${debug_level}")"
            if [[ -z "${found}" ]]; then
                echo "ERROR: no build conf dir found after configure" >&2
                exit 1
            fi
            conf_name="$(basename "${found}")"
            _bt_info "  configure used CONF=${conf_name}"
        fi

        build_log_path="build/${conf_name}/build.log"

        # ---- Build images ------------------------------------------------
        # Strategy: redirect stdout+stderr of make to a temp file, then copy
        # to out_dir.  Avoid pipe-tee patterns that swallow make's exit code.
        current_phase="images"
        _bt_info "  Building images (CONF=${conf_name}) …"

        local make_tmp="${out_dir}/build.log.tmp"
        local make_exit=0
        make CONF="${conf_name}" LOG=debug images \
                > "${make_tmp}" 2>&1 || make_exit=$?
        if [[ "${make_exit}" -ne 0 ]]; then
            cp "${make_tmp}" "${out_dir}/build.log" 2>/dev/null || true
            # Also place in the standard build.log location so _on_exit finds it
            cp "${make_tmp}" "${build_log_path}" 2>/dev/null || true
            _bt_warn "  make images failed (exit=${make_exit}) — skipping tests."
            exit "${make_exit}"
        fi

        cp "${make_tmp}" "${out_dir}/build.log"
        cp "${make_tmp}" "${build_log_path}" 2>/dev/null || true
        rm -f "${make_tmp}"

        # ---- Run tier1 tests (if jtreg available) -----------------------
        current_phase="test"
        local test_exit=0

        if [[ "${jtreg_ok}" != "true" ]]; then
            _bt_warn "  Skipping tier1 tests — jtreg not available."
            test_exit="SKIPPED"
        else
            _bt_info "  Running make run-test-tier1 (CONF=${conf_name}) …"
            make CONF="${conf_name}" \
                TEST="tier1" \
                run-test || test_exit=$?
        fi

        # ---- Collect test artefacts -------------------------------------
        local results_dir="build/${conf_name}/test-results"

        if [[ -f "${results_dir}/test-summary.txt" ]]; then
            cp "${results_dir}/test-summary.txt" "${out_dir}/test-summary.txt"
        else
            echo "test-summary.txt not found (test_exit=${test_exit})" \
                > "${out_dir}/test-summary.txt"
        fi

        {
            find "build/${conf_name}/" -name "newfailures.txt" -exec cat {} + 2>/dev/null
        } > "${out_dir}/newfailures.txt" \
            || echo "(none)" > "${out_dir}/newfailures.txt"

        {
            find "build/${conf_name}/" -name "other_errors.txt" -exec cat {} + 2>/dev/null
        } > "${out_dir}/other_errors.txt" \
            || echo "(none)" > "${out_dir}/other_errors.txt"

        # ---- Categorise passed/failed/skipped + harvest hs_err ----------
        if [[ "${jtreg_ok}" == "true" ]]; then
            _collect_tier1_artifacts \
                "build/${conf_name}" "${out_dir}" "${_run_ts}"
        fi

        # ---- Write run metadata ------------------------------------------
        {
            echo "stream:       ${stream_label}"
            echo "debug_level:  ${debug_level}"
            echo "run_ts:       ${_run_ts}"
            echo "date:         $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo "src_dir:      ${src_dir}"
            echo "top_commit:   $(git -C "${src_dir}" log -1 --oneline 2>/dev/null || echo 'unknown')"
            echo "boot_jdk:     $("${boot_jdk_dir}/bin/java" -version 2>&1 | head -1)"
            echo "jtreg:        $(JAVA_HOME="${boot_jdk_dir}" "${JTREG_DIR}/bin/jtreg" -version 2>/dev/null | head -1 || echo 'n/a')"
            echo "extra_flags:  ${extra_configure_flags[*]:-none}"
            echo "jtreg_ok:     ${jtreg_ok}"
            echo "test_exit:    ${test_exit}"
        } > "${out_dir}/run-metadata.txt"

        if [[ "${test_exit}" == "SKIPPED" ]]; then
            _bt_warn "  Tier1 tests SKIPPED (jtreg not available)."
        elif [[ "${test_exit}" -ne 0 ]]; then
            _bt_warn "  Tests finished with failures/errors (exit=${test_exit}) — recorded."
        else
            _bt_success "  All tier1 tests passed for ${stream_label}/${debug_level}."
        fi
    )
}

# ---------------------------------------------------------------------------
# Public: build_only_jdk
#
# Configure + make images for one stream × debug-level.  No tests.
#
# Arguments:
#   $1  src_dir
#   $2  stream_label
#   $3  debug_level
#   $4  out_dir
#   $5  boot_jdk_dir         — path to the boot JDK to use for this stream
#   $6+ extra_configure_flags (optional)
#
# Exit code: 0 success, non-zero build failure.
# ---------------------------------------------------------------------------
build_only_jdk() {
    local src_dir="$1"
    local stream_label="$2"
    local debug_level="$3"
    local out_dir="$4"
    local boot_jdk_dir="${5:-${BOOT_JDK_DIR}}"
    shift 5
    local extra_configure_flags=("$@")

    _bt_info "=== build_only_jdk ==="
    _bt_info "    stream   : ${stream_label}"
    _bt_info "    level    : ${debug_level}"
    _bt_info "    src      : ${src_dir}"
    _bt_info "    output   : ${out_dir}"
    _bt_info "    boot_jdk : ${boot_jdk_dir}"
    [[ ${#extra_configure_flags[@]} -gt 0 ]] && \
        _bt_info "    extra  : ${extra_configure_flags[*]}"

    mkdir -p "${out_dir}"

    (
        set -euo pipefail
        cd "${src_dir}"

        local conf_name="linux-s390x-server-${debug_level}"
        local build_log_path=""
        local current_phase="configure"

        _on_exit() {
            local exit_code=$?
            local actual_log="${build_log_path}"
            if [[ -z "${actual_log}" ]]; then
                local found_dir
                found_dir="$(_find_conf_dir "${debug_level}")"
                [[ -n "${found_dir}" ]] && actual_log="${found_dir}/build.log"
            fi
            _write_build_diagnosis \
                "${out_dir}" "${actual_log:-}" "${current_phase}" \
                "${exit_code}" "${stream_label}" "${debug_level}"
        }
        trap _on_exit EXIT

        if [[ -d "build/${conf_name}" ]]; then
            _bt_info "  Cleaning prior build/${conf_name} …"
            make CONF="${conf_name}" dist-clean 2>/dev/null \
                || rm -rf "build/${conf_name}"
        fi

        current_phase="configure"
        _bt_info "  Running configure (debug-level=${debug_level}) …"
        _configure_jdk "${debug_level}" "${boot_jdk_dir}" \
            "${extra_configure_flags[@]+"${extra_configure_flags[@]}"}"

        if [[ ! -d "build/${conf_name}" ]]; then
            local found; found="$(_find_conf_dir "${debug_level}")"
            [[ -z "${found}" ]] && { echo "ERROR: no conf dir after configure" >&2; exit 1; }
            conf_name="$(basename "${found}")"
        fi

        build_log_path="build/${conf_name}/build.log"

        current_phase="images"
        _bt_info "  Building images (CONF=${conf_name}) …"

        local make_tmp="${out_dir}/build.log.tmp"
        local make_exit=0
        make CONF="${conf_name}" LOG=debug images \
                > "${make_tmp}" 2>&1 || make_exit=$?
        if [[ "${make_exit}" -ne 0 ]]; then
            cp "${make_tmp}" "${out_dir}/build.log" 2>/dev/null || true
            cp "${make_tmp}" "${build_log_path}" 2>/dev/null || true
            _bt_warn "  make images failed (exit=${make_exit})."
            exit "${make_exit}"
        fi

        cp "${make_tmp}" "${out_dir}/build.log"
        cp "${make_tmp}" "${build_log_path}" 2>/dev/null || true
        rm -f "${make_tmp}"

        {
            echo "stream:       ${stream_label}"
            echo "debug_level:  ${debug_level}"
            echo "mode:         build-only"
            echo "date:         $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo "src_dir:      ${src_dir}"
            echo "top_commit:   $(git -C "${src_dir}" log -1 --oneline 2>/dev/null || echo 'unknown')"
            echo "boot_jdk:     $("${boot_jdk_dir}/bin/java" -version 2>&1 | head -1)"
            echo "extra_flags:  ${extra_configure_flags[*]:-none}"
            echo "test_exit:    SKIPPED (build-only mode)"
        } > "${out_dir}/run-metadata.txt"

        _bt_success "  Build complete for ${stream_label}/${debug_level}."
    )
}

# ---------------------------------------------------------------------------
# Public: run_tests_only
#
# Re-use an already-built image.  Runs an arbitrary jtreg test target with
# optional JVM flags.  Does NOT re-configure or re-build.
#
# Arguments:
#   $1  src_dir        — JDK source root (must already be configured+built)
#   $2  stream_label
#   $3  debug_level    — must match the existing build (fastdebug|release)
#   $4  out_dir        — where to write artefacts
#   $5  test_target    — jtreg target, e.g. "tier1", "test/jdk",
#                        "test/hotspot/jtreg/gc/epsilon"
#   $6  jvm_flags      — extra JVM flags passed via JTREG_JAVA_OPTIONS, e.g.
#                        "-Xint" or "-Xcomp -ea" (empty string = none)
#
# Exit code: 0 always (test failures are recorded, not fatal).
# ---------------------------------------------------------------------------
run_tests_only() {
    local src_dir="$1"
    local stream_label="$2"
    local debug_level="$3"
    local out_dir="$4"
    local test_target="${5:-tier1}"
    local jvm_flags="${6:-}"
    local _run_ts; _run_ts="$(date '+%Y%m%d_%H%M%S')"

    _bt_info "=== run_tests_only ==="
    _bt_info "    stream      : ${stream_label}"
    _bt_info "    level       : ${debug_level}"
    _bt_info "    src         : ${src_dir}"
    _bt_info "    output      : ${out_dir}"
    _bt_info "    test_target : ${test_target}"
    _bt_info "    jvm_flags   : ${jvm_flags:-(none)}"

    mkdir -p "${out_dir}"

    # Verify that a build exists for this conf
    local conf_name="linux-s390x-server-${debug_level}"
    if [[ ! -d "${src_dir}/build/${conf_name}" ]]; then
        local found; found="$(_find_conf_dir_abs "${src_dir}" "${debug_level}")"
        if [[ -z "${found}" ]]; then
            _bt_warn "No existing build found for ${stream_label}/${debug_level}."
            _bt_warn "Run a build first: bash scripts/jdk.sh build --level ${debug_level}"
            echo "NO_BUILD" > "${out_dir}/test-summary.txt"
            {
                echo "stream:       ${stream_label}"
                echo "debug_level:  ${debug_level}"
                echo "mode:         test-only"
                echo "test_target:  ${test_target}"
                echo "jvm_flags:    ${jvm_flags:-(none)}"
                echo "test_exit:    SKIPPED (no build found)"
                echo "date:         $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            } > "${out_dir}/run-metadata.txt"
            return 0
        fi
        conf_name="$(basename "${found}")"
    fi

    _bt_info "  Using CONF=${conf_name}"

    (
        set -euo pipefail
        cd "${src_dir}"

        # Build the make TEST= argument.
        # OpenJDK's run-test target accepts TEST= as the jtreg group/path.
        # "tier1" maps to run-test-tier1; everything else uses run-test with TEST=.
        local make_target="run-test"
        local make_test_arg="TEST=${test_target}"

        # Build JTREG_OPTIONS for JVM flags
        local jtreg_opts=""
        if [[ -n "${jvm_flags}" ]]; then
            # Each flag becomes a -javaoption: entry
            local f
            for f in ${jvm_flags}; do
                jtreg_opts+=" -javaoption:${f}"
            done
            jtreg_opts="${jtreg_opts# }"  # strip leading space
        fi

        _bt_info "  Running: make CONF=${conf_name} ${make_test_arg} ${make_target}"
        [[ -n "${jtreg_opts}" ]] && _bt_info "  JTREG extra opts: ${jtreg_opts}"

        local test_exit=0
        if [[ -n "${jtreg_opts}" ]]; then
            JTREG_OPTIONS="${jtreg_opts}" \
                make CONF="${conf_name}" "${make_test_arg}" "${make_target}" \
                || test_exit=$?
        else
            make CONF="${conf_name}" "${make_test_arg}" "${make_target}" \
                || test_exit=$?
        fi

        # Collect artefacts
        local results_dir="build/${conf_name}/test-results"

        if [[ -f "${results_dir}/test-summary.txt" ]]; then
            cp "${results_dir}/test-summary.txt" "${out_dir}/test-summary.txt"
        else
            echo "test-summary.txt not found (test_exit=${test_exit})" \
                > "${out_dir}/test-summary.txt"
        fi

        {
            find "build/${conf_name}/" -name "newfailures.txt" \
                -exec cat {} + 2>/dev/null
        } > "${out_dir}/newfailures.txt" \
            || echo "(none)" > "${out_dir}/newfailures.txt"

        {
            find "build/${conf_name}/" -name "other_errors.txt" \
                -exec cat {} + 2>/dev/null
        } > "${out_dir}/other_errors.txt" \
            || echo "(none)" > "${out_dir}/other_errors.txt"

        # ---- Categorise passed/failed/skipped + harvest hs_err ----------
        _collect_tier1_artifacts \
            "build/${conf_name}" "${out_dir}" "${_run_ts}"

        {
            echo "stream:       ${stream_label}"
            echo "debug_level:  ${debug_level}"
            echo "mode:         test-only"
            echo "test_target:  ${test_target}"
            echo "jvm_flags:    ${jvm_flags:-(none)}"
            echo "run_ts:       ${_run_ts}"
            echo "date:         $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo "src_dir:      ${src_dir}"
            echo "top_commit:   $(git -C "${src_dir}" log -1 --oneline 2>/dev/null || echo 'unknown')"
            echo "boot_jdk:     $("${BOOT_JDK_DIR}/bin/java" -version 2>&1 | head -1)"
            echo "jtreg:        $(JAVA_HOME="${BOOT_JDK_DIR}" "${JTREG_DIR}/bin/jtreg" \
                                     -version 2>/dev/null | head -1 || echo 'n/a')"
            echo "test_exit:    ${test_exit}"
        } > "${out_dir}/run-metadata.txt"

        if [[ "${test_exit}" -ne 0 ]]; then
            _bt_warn "  Tests finished with failures/errors (exit=${test_exit}) — recorded."
        else
            _bt_success "  Tests passed: ${stream_label}/${debug_level} target=${test_target}."
        fi
    )
}

# ---------------------------------------------------------------------------
# Internal helper: find conf dir given an absolute src_dir
# (run_tests_only is called from jdk.sh where CWD is not src_dir yet)
# ---------------------------------------------------------------------------
_find_conf_dir_abs() {
    local src_dir="$1"
    local debug_level="$2"
    find "${src_dir}/build" -maxdepth 1 -type d -name "*${debug_level}*" \
        2>/dev/null | sort | head -1
}
