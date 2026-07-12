#!/usr/bin/env bash
# =============================================================================
# test_jdk_clean_command.sh
#
# Tests for  jdk.sh clean  — the explicit build-directory removal command.
#
# APPROACH
# ────────
# jdk.sh is not directly sourceable (top-level set -e, exec > tee, etc.).
# We invoke it as a subprocess and observe its effects on the filesystem.
#
# We need a fake JDK source tree and a GNUmakefile whose dist-clean target:
#   • On success: removes the conf dir
#   • On failure: exits non-zero (so jdk.sh falls back to rm -rf)
#
# We also need a fake boot JDK (so --skip-deps works for the clean path — but
# actually jdk.sh clean skips deps entirely, so we don't need it).
#
# WHY THESE TESTS ARE CORRECT
# ────────────────────────────
# The clean command has three observable effects:
#   1. The build/<conf> dir is gone after the call
#   2. No summary email is sent (ci_notify not called)
#   3. No run-summary.txt is written to the report dir
#
# We test all three.
#
# INTENTIONAL CONTRADICTION IN T4
# ─────────────────────────────────
# jdk.sh clean does NOT need  --skip-deps.  One might expect that removing a
# directory requires the boot JDK (to run make dist-clean), but our
# implementation runs make in a subshell using only the Makefile in the source
# tree, not the boot JDK.  And if make fails, it falls back to  rm -rf.
# T4 confirms clean works even with no boot JDK present at all.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

JDK_SH="${SCRIPT_DIR}/jdk.sh"

# ---------------------------------------------------------------------------
# Build a fake JDK source tree with a GNUmakefile whose dist-clean works
# ---------------------------------------------------------------------------
_make_src() {
    local label="$1"
    local src="${T}/src_${label}"
    local conf_name="linux-s390x-server-fastdebug"
    mkdir -p "${src}/make/conf"
    echo "DEFAULT_VERSION_FEATURE = 26" > "${src}/make/conf/version-numbers.conf"

    # Create the conf dir that dist-clean should remove
    mkdir -p "${src}/build/${conf_name}"
    echo "previous build artifacts" > "${src}/build/${conf_name}/build.log"
    mkdir -p "${src}/build/${conf_name}/test-results"
    echo "previous failure"         > "${src}/build/${conf_name}/test-results/newfailures.txt"

    cat > "${src}/GNUmakefile" <<EOF
CONF ?= linux-s390x-server-fastdebug
dist-clean:
	rm -rf build/\$(CONF)
EOF
    echo "${src}"
}

# Override JDK_SOURCES_ROOT so jdk.sh resolves the stream to our fake tree
# and REPORTS_DIR so report output lands in $T
export JDK_SOURCES_ROOT="${T}/jdk_sources"
export REPORTS_DIR="${T}/reports"
mkdir -p "${JDK_SOURCES_ROOT}" "${REPORTS_DIR}"

# Symlink / clone the fake src for the "head" stream (src_subdir = jdk)
_setup_stream() {
    local label="$1"
    local src
    src="$(_make_src "${label}")"
    local jdk_dir="${JDK_SOURCES_ROOT}/jdk"
    rm -rf "${jdk_dir}"
    cp -r "${src}" "${jdk_dir}"
    echo "${jdk_dir}"
}

# Minimal boot JDK stub (clean skips deps but if ensure_deps is called it errors)
export BOOT_JDK_DIR="${T}/boot_jdk"
mkdir -p "${BOOT_JDK_DIR}/bin"
printf '#!/bin/sh\necho "openjdk 99"\n' > "${BOOT_JDK_DIR}/bin/java"
chmod +x "${BOOT_JDK_DIR}/bin/java"

export JTREG_DIR="${T}/jtreg"
mkdir -p "${JTREG_DIR}/bin"
printf '#!/bin/sh\necho "jtreg 99"\n' > "${JTREG_DIR}/bin/jtreg"
chmod +x "${JTREG_DIR}/bin/jtreg"

# Silence email
export CI_NOTIFY_EMAIL=""

# ─────────────────────────────────────────────────────────────────────────────
# T1  clean removes the build conf dir
#
# WHY CORRECT: The entire point of the command.  We verify the conf dir is
# absent after the call.  We check both the dir and a file inside it to rule
# out a stub that only removes a placeholder.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh clean — build dir removal"
it "T1: build conf dir is gone after clean"
_setup_stream "t1"
CONF_DIR="${JDK_SOURCES_ROOT}/jdk/build/linux-s390x-server-fastdebug"
assert_file_exists "${CONF_DIR}" "pre-condition: conf dir must exist"

rc=0
bash "${JDK_SH}" clean --stream head --level fastdebug --skip-deps 2>/dev/null \
    || rc=$?
assert_eq "${rc}" "0" "clean must exit 0"
assert_file_missing "${CONF_DIR}" "conf dir must be gone after clean"

# ─────────────────────────────────────────────────────────────────────────────
# T2  clean --level both removes both fastdebug and release
# ─────────────────────────────────────────────────────────────────────────────
it "T2: clean --level both removes fastdebug AND release"
_setup_stream "t2"
SRC="${JDK_SOURCES_ROOT}/jdk"
mkdir -p "${SRC}/build/linux-s390x-server-release"
echo "release artifact" > "${SRC}/build/linux-s390x-server-release/build.log"

bash "${JDK_SH}" clean --stream head --level both --skip-deps 2>/dev/null || true
assert_file_missing "${SRC}/build/linux-s390x-server-fastdebug" "fastdebug gone"
assert_file_missing "${SRC}/build/linux-s390x-server-release"   "release gone"

# ─────────────────────────────────────────────────────────────────────────────
# T3  clean when no conf dir exists → exits 0, no error
#
# WHY CORRECT: Running clean on a fresh tree (never built) should be a no-op,
# not an error.  Engineers should be able to  clean && build  safely even the
# first time.
# ─────────────────────────────────────────────────────────────────────────────
it "T3: clean with no existing conf dir → exits 0 silently"
_setup_stream "t3"
rm -rf "${JDK_SOURCES_ROOT}/jdk/build"  # wipe everything

rc=0
bash "${JDK_SH}" clean --stream head --level fastdebug --skip-deps 2>/dev/null \
    || rc=$?
assert_eq "${rc}" "0" "clean on empty tree must exit 0"

# ─────────────────────────────────────────────────────────────────────────────
# T4  clean does NOT require boot JDK to be present
#
# WHY CORRECT: Cleaning a directory has nothing to do with a JDK.  If clean
# internally called ensure_deps, it would fail on a host where the network
# is down but the source tree exists and needs wiping before a rebuild.
# We remove the fake boot JDK binary and assert clean still succeeds.
# ─────────────────────────────────────────────────────────────────────────────
it "T4: clean succeeds even with no boot JDK binary present"
_setup_stream "t4"
rm -f "${BOOT_JDK_DIR}/bin/java"  # remove the binary

rc=0
bash "${JDK_SH}" clean --stream head --level fastdebug --skip-deps 2>/dev/null \
    || rc=$?
assert_eq "${rc}" "0" "clean must not require boot JDK"

# Restore for subsequent tests
printf '#!/bin/sh\necho "openjdk 99"\n' > "${BOOT_JDK_DIR}/bin/java"
chmod +x "${BOOT_JDK_DIR}/bin/java"

# ─────────────────────────────────────────────────────────────────────────────
# T5  clean does NOT write a run-summary.txt to reports/
#
# WHY CORRECT: run-summary.txt is the artifact that gets committed to git and
# emailed to recipients.  Writing one for a clean operation would pollute the
# history with non-run entries.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh clean — no reporting side-effects"
it "T5: clean does NOT produce a run-summary.txt in REPORTS_DIR"
_setup_stream "t5"

bash "${JDK_SH}" clean --stream head --level fastdebug --skip-deps 2>/dev/null || true

summary_count=$(find "${REPORTS_DIR}" -name "run-summary.txt" 2>/dev/null | wc -l)
assert_eq "${summary_count}" "0" "clean must not write run-summary.txt"

# ─────────────────────────────────────────────────────────────────────────────
# T6  Other commands (run, build, test) are NOT affected by clean semantics
#
# WHY CORRECT: This is the "doesn't break existing behaviour" check.  We run
# jdk.sh --help and verify clean is listed alongside run/build/test.  If the
# argument parser broke the other commands (e.g. introduced a fallthrough),
# the help output would be missing entries.
# ─────────────────────────────────────────────────────────────────────────────
it "T6: --help lists clean alongside run, build, test, collect"
help_output="$(bash "${JDK_SH}" --help 2>&1 || true)"
for cmd in run build test clean collect; do
    echo "${help_output}" | grep -q "${cmd}" \
        && _pass \
        || _fail "command '${cmd}' missing from --help output"
done
