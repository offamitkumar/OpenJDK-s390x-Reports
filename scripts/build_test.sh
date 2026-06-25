#!/usr/bin/env bash
# =============================================================================
# build_test.sh — Build and test one (stream × debug-level) combination
#
# Sourced by run_daily.sh — not invoked directly.
#
# Public function:
#   build_and_test_jdk  <src_dir> <stream_label> <debug_level> \
#                       <out_dir> [extra_configure_flags...]
#
# Environment expected (exported by run_daily.sh via config.sh):
#   BOOT_JDK_DIR, JTREG_DIR, GTEST_DIR, MAKE_JOBS
# =============================================================================

# This file is sourced, not executed directly.
# set -euo pipefail is NOT set at this level — the caller owns the outer shell.
# Each public function runs its main body in a subshell with its own set -e.

_bt_info()    { echo "[INFO]  $*"; }
_bt_success() { echo "[OK]    $*"; }
_bt_warn()    { echo "[WARN]  $*" >&2; }

# ---------------------------------------------------------------------------
# Internal: detect JDK major version from source tree
# Used to apply per-version configure quirks.
# ---------------------------------------------------------------------------
_detect_jdk_version() {
    local ver_file="make/conf/version-numbers.conf"
    [[ -f "${ver_file}" ]] || ver_file="make/autoconf/version-numbers"
    if [[ -f "${ver_file}" ]]; then
        grep -m1 'DEFAULT_VERSION_FEATURE\s*=' "${ver_file}" \
            | grep -oE '[0-9]+' | head -1
    else
        echo "0"
    fi
}

# ---------------------------------------------------------------------------
# Internal: build the configure argument array for a given stream + debug level
# ---------------------------------------------------------------------------
_configure_jdk() {
    local debug_level="$1"
    shift
    local extra_flags=("$@")

    local jdk_ver
    jdk_ver="$(_detect_jdk_version)"

    local args=(
        "--with-boot-jdk=${BOOT_JDK_DIR}"
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
            echo " likely during 'bash configure'. Check configure output above.)"
            return
        fi

        # ---- Last make target attempted ---------------------------------
        # OpenJDK make prints "Building target 'foo'" lines
        local last_target
        last_target="$(grep -E "^(Building target|Finished building target)" "${build_log}" \
            | tail -1 || true)"
        if [[ -n "${last_target}" ]]; then
            echo "--- Last make target ---"
            echo "  ${last_target}"
            echo ""
        fi

        # ---- Last compiler / linker command -----------------------------
        # With LOG=cmdlines every compiler invocation is logged verbatim.
        # Compiler drivers on s390x Linux: gcc, g++, cc, c++, ld, ar, as,
        # plus the JDK-internal tools: javac, javah, jmod, jlink.
        local last_cmd
        last_cmd="$(grep -E \
            '/(gcc|g\+\+|cc|c\+\+|ld|ar|clang|clang\+\+|javac|jmod|jlink|link\.exe) ' \
            "${build_log}" | tail -1 || true)"
        if [[ -n "${last_cmd}" ]]; then
            echo "--- Last compiler/linker command ---"
            # Wrap long lines at 120 chars for readability
            echo "${last_cmd}" | fold -s -w 120
            echo ""
        fi

        # ---- Error context ----------------------------------------------
        # Extract every line containing ': error:' or '^Error' and show
        # 8 lines of context around each (capped at 5 occurrences to keep
        # the file readable).
        local error_count
        error_count="$(grep -c -E '(: error:|^Error |^make\[|^make: \*\*\*)' \
            "${build_log}" 2>/dev/null || echo 0)"

        echo "--- Error lines in build.log (${error_count} matches) ---"
        if [[ "${error_count}" -eq 0 ]]; then
            echo "  (no 'error:' lines found — check full build.log)"
        else
            # Show context around first 5 error occurrences
            grep -n -E '(: error:|^Error |^make\[.*Error|^make: \*\*\*)' \
                "${build_log}" \
                | head -5 \
                | while IFS=: read -r lineno rest; do
                    echo ""
                    echo "  [line ${lineno}] ${rest}"
                    # 8 lines before and after in the actual file
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
#   $5+ extra_configure_flags — passed verbatim to configure (optional)
#
# Exit code:
#   0   build + tests ran (test failures are recorded, not fatal)
#   1   infrastructure / build failure
# ---------------------------------------------------------------------------
build_and_test_jdk() {
    local src_dir="$1"
    local stream_label="$2"
    local debug_level="$3"
    local out_dir="$4"
    shift 4
    local extra_configure_flags=("$@")

    _bt_info "=== build_and_test_jdk ==="
    _bt_info "    stream : ${stream_label}"
    _bt_info "    level  : ${debug_level}"
    _bt_info "    src    : ${src_dir}"
    _bt_info "    output : ${out_dir}"
    [[ ${#extra_configure_flags[@]} -gt 0 ]] && \
        _bt_info "    extra  : ${extra_configure_flags[*]}"

    mkdir -p "${out_dir}"

    (
        set -euo pipefail
        cd "${src_dir}"

        local conf_name="linux-s390x-server-${debug_level}"
        local build_log_path=""   # set once build dir exists
        local current_phase="configure"

        # ---- Trap: always write diagnosis on any exit --------------------
        # Captures the subshell's exit status at the moment of exit.
        _on_exit() {
            local exit_code=$?
            # Resolve the actual build.log path (may have changed if conf_name
            # was adjusted after configure)
            local actual_log="${build_log_path}"
            if [[ -z "${actual_log}" ]]; then
                # configure may have created a conf dir — try to find it
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
        _configure_jdk "${debug_level}" "${extra_configure_flags[@]}"

        # Verify conf dir
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
        current_phase="images"
        _bt_info "  Building images (CONF=${conf_name}, -j${MAKE_JOBS}) …"
        make CONF="${conf_name}" images LOG=cmdlines 2>&1 \
            | tee "${build_log_path}"

        # Copy the completed build.log to out_dir
        cp "${build_log_path}" "${out_dir}/build.log"

        # ---- Run tier1 tests --------------------------------------------
        current_phase="test"
        _bt_info "  Running make run-test-tier1 (CONF=${conf_name}) …"
        local test_exit=0
        make CONF="${conf_name}" \
             JTREG="JTR_HOME=${JTREG_DIR}" \
             run-test-tier1 || test_exit=$?

        # ---- Collect test artefacts -------------------------------------
        local results_dir="build/${conf_name}/test-results"

        if [[ -f "${results_dir}/test-summary.txt" ]]; then
            cp "${results_dir}/test-summary.txt" "${out_dir}/test-summary.txt"
        else
            echo "test-summary.txt not found" > "${out_dir}/test-summary.txt"
        fi

        {
            find "build/${conf_name}/" -name "newfailures.txt" -exec cat {} +
        } > "${out_dir}/newfailures.txt" 2>/dev/null \
            || echo "(none)" > "${out_dir}/newfailures.txt"

        {
            find "build/${conf_name}/" -name "other_errors.txt" -exec cat {} +
        } > "${out_dir}/other_errors.txt" 2>/dev/null \
            || echo "(none)" > "${out_dir}/other_errors.txt"

        # ---- Write run metadata ------------------------------------------
        {
            echo "stream:       ${stream_label}"
            echo "debug_level:  ${debug_level}"
            echo "date:         $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo "src_dir:      ${src_dir}"
            echo "top_commit:   $(git -C "${src_dir}" log -1 --oneline 2>/dev/null || echo 'unknown')"
            echo "boot_jdk:     $("${BOOT_JDK_DIR}/bin/java" -version 2>&1 | head -1)"
            echo "jtreg:        $(JAVA_HOME="${BOOT_JDK_DIR}" "${JTREG_DIR}/bin/jtreg" -version 2>/dev/null | head -1 || echo 'n/a')"
            echo "extra_flags:  ${extra_configure_flags[*]:-none}"
            echo "test_exit:    ${test_exit}"
        } > "${out_dir}/run-metadata.txt"

        if [[ ${test_exit} -ne 0 ]]; then
            _bt_warn "  Tests finished with failures/errors (exit=${test_exit}) — recorded."
        else
            _bt_success "  All tier1 tests passed for ${stream_label}/${debug_level}."
        fi
    )
}
