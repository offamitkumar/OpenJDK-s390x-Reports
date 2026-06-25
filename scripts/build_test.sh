#!/usr/bin/env bash
# =============================================================================
# build_test.sh — Build and test one (stream × debug-level) combination
#
# Usage (called from run_daily.sh — not meant to be invoked directly):
#   source scripts/build_test.sh
#   build_and_test_jdk <src_dir> <stream_label> <debug_level> <out_dir>
#
# Arguments:
#   src_dir      — absolute path to the JDK source tree
#   stream_label — human label stored in reports (e.g. "head")
#   debug_level  — "fastdebug" or "release"
#   out_dir      — directory where artifacts will be written
#
# Environment expected (from config.sh):
#   BOOT_JDK_DIR, JTREG_DIR, GTEST_DIR, MAKE_JOBS
# =============================================================================

# This file is sourced, not executed directly, so we do NOT set -euo pipefail
# at the top level — the caller owns that. Each function uses a local subshell.

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
die()     { echo "[ERROR] $*" >&2; return 1; }

# ---------------------------------------------------------------------------
# Internal: run configure for a given debug level
# ---------------------------------------------------------------------------
_configure_jdk() {
  local debug_level="$1"

  local extra_flags=()
  # JDK 11 and earlier need --disable-warnings-as-errors and have no gtest
  # We detect this by checking if the source dir has the 'make/autoconf' layout
  if [[ -f "make/autoconf/configure.ac" ]]; then
    : # modern layout — gtest is fine
  fi

  # Build the configure argument list
  local configure_args=(
    "--with-boot-jdk=${BOOT_JDK_DIR}"
    "--with-jtreg=${JTREG_DIR}"
    "--with-debug-level=${debug_level}"
    "--with-native-debug-symbols=internal"
    "--disable-precompiled-headers"
  )

  # Only pass gtest if the dir actually exists
  if [[ -d "${GTEST_DIR}" ]]; then
    configure_args+=("--with-gtest=${GTEST_DIR}")
  fi

  bash configure "${configure_args[@]}"
}

# ---------------------------------------------------------------------------
# Internal: derive the build output directory name from CONF
# ---------------------------------------------------------------------------
_build_output_dir() {
  # OpenJDK puts build artefacts under build/<conf-name>/
  # 'make CONF=… reconfigure' prints the conf-name; we just find it.
  local debug_level="$1"
  find build -maxdepth 1 -type d -name "*${debug_level}*" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Public: build JDK image and run tier1 tests, collect artefacts
# ---------------------------------------------------------------------------
build_and_test_jdk() {
  local src_dir="$1"
  local stream_label="$2"
  local debug_level="$3"
  local out_dir="$4"

  info "=== build_and_test_jdk: stream=${stream_label} level=${debug_level} ==="
  info "    src  : ${src_dir}"
  info "    output: ${out_dir}"

  # Run everything in a subshell so that 'cd' and 'set -e' are scoped
  (
    set -euo pipefail

    cd "${src_dir}"

    # --- Determine CONF name before we start ---
    # s390x naming: linux-s390x-server-{fastdebug|release}
    local conf_name="linux-s390x-server-${debug_level}"

    # --- Clean any prior build for this conf ---
    if [[ -d "build/${conf_name}" ]]; then
      info "  Cleaning prior build/${conf_name} …"
      make CONF="${conf_name}" dist-clean 2>/dev/null || rm -rf "build/${conf_name}"
    fi

    # --- Configure ---
    info "  Running configure (debug-level=${debug_level}) …"
    _configure_jdk "${debug_level}"

    # After configure the conf dir is created; verify
    if [[ ! -d "build/${conf_name}" ]]; then
      # Fallback: find whatever configure just created
      conf_name="$(_build_output_dir "${debug_level}")"
      conf_name="$(basename "${conf_name}")"
    fi

    info "  Using CONF=${conf_name}"

    # --- Build images ---
    info "  Building images (CONF=${conf_name}, jobs=${MAKE_JOBS}) …"
    make CONF="${conf_name}" images LOG=cmdlines 2>&1 | tee /tmp/jdk_build_$$.log

    # Copy build log
    mkdir -p "${out_dir}"
    cp "build/${conf_name}/build.log" "${out_dir}/build.log" 2>/dev/null || \
      cp /tmp/jdk_build_$$.log "${out_dir}/build.log"
    rm -f /tmp/jdk_build_$$.log

    # --- Run tier1 tests ---
    info "  Running make run-test-tier1 (CONF=${conf_name}) …"
    local test_exit=0
    make CONF="${conf_name}" run-test-tier1 || test_exit=$?

    # --- Collect test artefacts ---
    local test_results_dir="build/${conf_name}/test-results"

    if [[ -f "${test_results_dir}/test-summary.txt" ]]; then
      cp "${test_results_dir}/test-summary.txt" "${out_dir}/test-summary.txt"
    else
      echo "test-summary.txt not found" > "${out_dir}/test-summary.txt"
    fi

    # Merge all newfailures.txt and other_errors.txt files
    find "build/${conf_name}/" -name "newfailures.txt" -exec cat {} + \
      > "${out_dir}/newfailures.txt" 2>/dev/null || \
      echo "(no failures file found)" > "${out_dir}/newfailures.txt"

    find "build/${conf_name}/" -name "other_errors.txt" -exec cat {} + \
      > "${out_dir}/other_errors.txt" 2>/dev/null || \
      echo "(no errors file found)" > "${out_dir}/other_errors.txt"

    # --- Write run metadata ---
    {
      echo "stream:      ${stream_label}"
      echo "debug_level: ${debug_level}"
      echo "date:        $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      echo "src_dir:     ${src_dir}"
      echo "top_commit:  $(git -C "${src_dir}" log -1 --oneline)"
      echo "boot_jdk:    $(${BOOT_JDK_DIR}/bin/java -version 2>&1 | head -1)"
      echo "jtreg:       $(${JTREG_DIR}/bin/jtreg -version 2>/dev/null | head -1 || echo 'n/a')"
      echo "test_exit:   ${test_exit}"
    } > "${out_dir}/run-metadata.txt"

    if [[ ${test_exit} -ne 0 ]]; then
      info "  Tests completed with non-zero exit (${test_exit}) — failures recorded."
    else
      success "  Tests passed for ${stream_label}/${debug_level}."
    fi
  )
}
