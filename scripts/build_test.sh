#!/usr/bin/env bash
# =============================================================================
# build_test.sh — Build and test one (stream × debug-level) combination
#
# Sourced by run_daily.sh, jdk.sh, and pr_test.sh — not invoked directly.
#
# Public functions:
#
#   update_source   <label> <src_subdir> <git_url> <out_base>
#       git fetch + pull (or clone) the source tree.  Writes commit-info.txt
#       and top_commit into out_base.  Returns 1 on failure.
#
#   build_and_test_jdk  <src_dir> <label> <debug_level> <out_dir> \
#                       <jtreg_ok> <boot_jdk_dir> [extra_configure_flags...]
#       Full pipeline: configure → make images → tier1 tests.
#       Pass jtreg_ok=false to skip tests (build-only mode).
#
#   build_only_jdk  <src_dir> <label> <debug_level> <out_dir> <boot_jdk_dir> \
#                   [extra_configure_flags...]
#       Thin wrapper: calls build_and_test_jdk with jtreg_ok=false.
#
#   run_tests_only  <src_dir> <label> <debug_level> <out_dir> \
#                   <test_target> <jvm_flags>
#       Re-use an existing build (no configure, no make images).
#
# Environment expected (set via config.sh):
#   BOOT_JDK_DIR, JTREG_DIR, GTEST_DIR
# =============================================================================

# This file is sourced, not executed directly.
# set -euo pipefail is NOT set at file scope — the caller owns the outer shell.
# Each public function runs its critical body inside a subshell with its own
# set -e so a build failure terminates only that combination.

# Internal aliases that forward to the shared helpers in config.sh
_bt_info()    { info    "$*" 2>/dev/null || echo "[INFO]  $*"; }
_bt_success() { success "$*" 2>/dev/null || echo "[OK]    $*"; }
_bt_warn()    { warn    "$*" 2>/dev/null || echo "[WARN]  $*" >&2; }

# ---------------------------------------------------------------------------
# _collect_test_results  <conf_dir>
#
# Logs the newfailures/other_errors counts from jtreg's output tree.
# Results stay in the source tree — nothing is copied to the report dir.
#   <conf_dir>/test-results/<suite>/newfailures.txt
#   <conf_dir>/test-results/<suite>/other_errors.txt
# ---------------------------------------------------------------------------
_collect_test_results() {
    local conf_dir="$1"
    local results_dir="${conf_dir}/test-results"

    local n_fail n_err
    n_fail="$(find "${results_dir}" -name "newfailures.txt" \
        -exec cat {} + 2>/dev/null | grep -vc '^$' || echo 0)"
    n_err="$(find "${results_dir}" -name "other_errors.txt" \
        -exec cat {} + 2>/dev/null | grep -vc '^$' || echo 0)"
    _bt_info "  newfailures=${n_fail}  other_errors=${n_err}"
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
# Public: update_source
#
# git fetch + pull (or shallow clone) one JDK source tree.
# Writes:
#   <out_base>/git-pull.log      — full git output
#   <out_base>/commit-info.txt   — before/after commits + bisect command
#   <out_base>/top_commit        — one-line HEAD commit (printed to stdout)
#   <out_base>/source-failure.txt — present only on failure
#
# Arguments:
#   $1  label       — stream label (e.g. "head", "jdk21")
#   $2  src_subdir  — subdirectory under JDK_SOURCES_ROOT
#   $3  git_url     — upstream remote URL
#   $4  out_base    — directory for output artefacts
#
# Returns 1 on git failure (writes source-failure.txt).
# On success, prints the top_commit text to stdout.
# ---------------------------------------------------------------------------
update_source() {
    local label="$1"
    local src_subdir="$2"
    local git_url="$3"
    local out_base="$4"

    local src_dir="${JDK_SOURCES_ROOT}/${src_subdir}"

    _bt_info "[${label}] Preparing source at ${src_dir} …"
    _bt_info "[${label}]   git URL : ${git_url}"

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
        _bt_info "[${label}]   commit before pull: ${commit_before}"
        echo "  commit_before : ${commit_before}" >> "${git_log}"
        echo "" >> "${git_log}"
        echo "--- git fetch + pull output ---" >> "${git_log}"

        if ! git -C "${src_dir}" fetch --prune origin >> "${git_log}" 2>&1; then
            _record_source_failure "${label}" "${out_base}" "${git_log}" "git fetch failed"
            return 1
        fi

        local dirty_files
        dirty_files="$(git -C "${src_dir}" status --porcelain 2>/dev/null)"
        if [[ -n "${dirty_files}" ]]; then
            _bt_warn "[${label}] Local modifications detected — discarding before pull."
            git -C "${src_dir}" checkout -- . >> "${git_log}" 2>&1
            git -C "${src_dir}" clean -fd    >> "${git_log}" 2>&1
        fi

        if ! git -C "${src_dir}" checkout master >> "${git_log}" 2>&1; then
            _record_source_failure "${label}" "${out_base}" "${git_log}" "git checkout master failed"
            return 1
        fi
        if ! git -C "${src_dir}" pull --ff-only origin master >> "${git_log}" 2>&1; then
            _record_source_failure "${label}" "${out_base}" "${git_log}" "git pull --ff-only failed"
            return 1
        fi
    else
        _bt_info "[${label}]   No repo found — cloning …"
        echo "  action     : fresh clone" >> "${git_log}"
        echo "--- git clone output ---" >> "${git_log}"
        mkdir -p "${JDK_SOURCES_ROOT}"
        if ! git clone --depth=1 "${git_url}" "${src_dir}" >> "${git_log}" 2>&1; then
            _record_source_failure "${label}" "${out_base}" "${git_log}" "git clone failed"
            return 1
        fi
        is_fresh_clone=true
    fi

    local commit_after
    commit_after="$(git -C "${src_dir}" rev-parse HEAD)"
    _bt_info "[${label}]   commit after pull : ${commit_after}"
    { echo ""; echo "  commit_after  : ${commit_after}"; echo "  result        : SUCCESS"; } \
        >> "${git_log}"

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

    _bt_info "[${label}]   top commit: $(git -C "${src_dir}" log -1 --oneline)"

    # Print top_commit to stdout so callers can capture it
    git -C "${src_dir}" log -1 \
        --format='commit %H%nauthor %an <%ae>%ndate   %ad%n%n    %s' \
        --date=rfc
}

# Helper: write source-failure.txt
_record_source_failure() {
    local label="$1" out_base="$2" git_log="$3" reason="$4"
    _bt_warn "[${label}] Source preparation failed: ${reason}"
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
        current_phase="images"
        _bt_info "  Building images (CONF=${conf_name}) …"

        local make_exit=0
        # Unset MAKEFLAGS/MAKEOVERRIDES — a parent make or shell alias may inject
        # -jN into the environment, which OpenJDK's wrapper explicitly rejects.
        MAKEFLAGS= MAKEOVERRIDES= \
        make CONF="${conf_name}" LOG=debug images \
                2>&1 || make_exit=$?
        if [[ "${make_exit}" -ne 0 ]]; then
            _bt_warn "  make images failed (exit=${make_exit}) — skipping tests."
            exit "${make_exit}"
        fi

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

        # ---- Log newfailures + other_errors counts ----------------------
        if [[ "${jtreg_ok}" == "true" ]]; then
            _collect_test_results "build/${conf_name}"
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
# Thin wrapper — configure + make images, no tests.
# Delegates to build_and_test_jdk with jtreg_ok=false.
# ---------------------------------------------------------------------------
build_only_jdk() {
    local src_dir="$1"
    local stream_label="$2"
    local debug_level="$3"
    local out_dir="$4"
    local boot_jdk_dir="${5:-${BOOT_JDK_DIR}}"
    shift 5
    build_and_test_jdk \
        "${src_dir}" "${stream_label}" "${debug_level}" \
        "${out_dir}" "false" "${boot_jdk_dir}" "$@"
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

        local results_dir="build/${conf_name}/test-results"

        # ---- Log newfailures + other_errors counts ----------------------
        _collect_test_results "build/${conf_name}"

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
