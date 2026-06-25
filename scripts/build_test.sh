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
    # version-numbers file exists in all OpenJDK trees
    local ver_file="make/conf/version-numbers.conf"
    # older layout
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
    local extra_flags=("$@")   # stream-specific flags from registry

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

    # Append any stream-specific extra flags (e.g. --disable-warnings-as-errors
    # for jdk11 which doesn't compile cleanly with modern GCC)
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

    # Run the build+test entirely in a subshell so that:
    #  - 'cd' is scoped
    #  - set -e failures surface as a non-zero exit from the subshell
    #    without killing the parent (run_daily.sh captures the exit code)
    (
        set -euo pipefail
        cd "${src_dir}"

        # ---- Determine expected CONF name --------------------------------
        # s390x standard naming: linux-s390x-server-{fastdebug|release}
        local conf_name="linux-s390x-server-${debug_level}"

        # ---- Clean prior build for this conf -----------------------------
        if [[ -d "build/${conf_name}" ]]; then
            _bt_info "  Cleaning prior build/${conf_name} …"
            make CONF="${conf_name}" dist-clean 2>/dev/null \
                || rm -rf "build/${conf_name}"
        fi

        # ---- Configure ---------------------------------------------------
        _bt_info "  Running configure (debug-level=${debug_level}) …"
        _configure_jdk "${debug_level}" "${extra_configure_flags[@]}"

        # Verify conf dir was created (configure may use a different name)
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

        # ---- Build images ------------------------------------------------
        _bt_info "  Building images (CONF=${conf_name}, -j${MAKE_JOBS}) …"
        local build_log_tmp="/tmp/jdk_build_$$.log"
        make CONF="${conf_name}" images LOG=cmdlines 2>&1 \
            | tee "${build_log_tmp}"

        # Copy build log
        cp "build/${conf_name}/build.log" "${out_dir}/build.log" 2>/dev/null \
            || cp "${build_log_tmp}" "${out_dir}/build.log"
        rm -f "${build_log_tmp}"

        # ---- Run tier1 tests --------------------------------------------
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

        # Merge all per-suite newfailures / other_errors files
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
