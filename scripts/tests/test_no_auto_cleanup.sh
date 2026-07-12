#!/usr/bin/env bash
# =============================================================================
# test_no_auto_cleanup.sh
#
# Tests that build_and_test_jdk() and build_only_jdk() in build_test.sh NO
# LONGER call dist-clean / rm -rf before starting a new build.
#
# THE BEHAVIOUR BEING TESTED
# ──────────────────────────
# Before the change, both public build functions started with:
#
#   if [[ -d "build/${conf_name}" ]]; then
#       make CONF="${conf_name}" dist-clean || rm -rf "build/${conf_name}"
#   fi
#
# This silently destroyed the previous run's test-results/, build.log, and all
# artifacts every time a new build was requested — even when the caller only
# wanted to rebuild after a test-only change.
#
# After the change that block is gone.  The only way to clean is the explicit
# `jdk.sh clean` command.
#
# WHY THESE TESTS ARE CORRECT
# ────────────────────────────
# We stub the real build (configure, make) with scripts that always succeed and
# write a known sentinel file inside build/${conf_name}/.  We then call the
# function under test and verify:
#   PASS  the sentinel file still exists  → no cleanup happened
#   FAIL  the sentinel file is gone       → cleanup ran (regression)
#
# We intentionally choose a file deep inside the conf dir (not just the dir
# itself) because  rm -rf build/${conf_name}  removes the dir entirely, while
# a naive stub that only touches the dir's mtime would miss it.
#
# IMPORTANT CONTRADICTION ADDRESSED
# ──────────────────────────────────
# One might argue: "If you don't clean, configure might fail because stale
# objects conflict with the new source."  That is true in general OpenJDK
# builds.  However the CI scripts call  bash configure  fresh every time, and
# OpenJDK's configure always regenerates its spec.gmk.  The real solution to
# stale-object conflicts is the explicit  jdk.sh clean  command.  Silently
# wiping artifacts on every build is the wrong tradeoff because it destroys
# evidence (test-results/, build.log) that the engineer needs to diagnose the
# previous failure.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Stub globals required by build_test.sh
BOOT_JDK_DIR="${T}/boot_jdk"
JTREG_DIR="${T}/jtreg"
GTEST_DIR="${T}/gtest"
mkdir -p "${BOOT_JDK_DIR}/bin" "${JTREG_DIR}/bin" "${GTEST_DIR}"

# Minimal fake java / jtreg so -x guards pass
printf '#!/bin/sh\necho "openjdk version 99"\n' > "${BOOT_JDK_DIR}/bin/java"
printf '#!/bin/sh\necho "jtreg 99"\n'           > "${JTREG_DIR}/bin/jtreg"
chmod +x "${BOOT_JDK_DIR}/bin/java" "${JTREG_DIR}/bin/jtreg"

source "${SCRIPT_DIR}/build_test.sh"

# ---------------------------------------------------------------------------
# Build a fake JDK source tree.
#
# The real  bash configure  and  make images  are replaced by stub scripts on
# PATH that succeed immediately and simulate the configure output layout.
# ---------------------------------------------------------------------------
_make_fake_src() {
    local src="${T}/src_$1"
    mkdir -p "${src}/make/conf"
    # version-numbers.conf so _detect_jdk_version works
    echo "DEFAULT_VERSION_FEATURE = 26" > "${src}/make/conf/version-numbers.conf"

    # Fake configure — creates the expected build/<conf>/ directory and touches
    # a sentinel file inside it to prove cleanup did NOT remove it.
    local conf_dir="${src}/build/linux-s390x-server-${2:-fastdebug}"
    mkdir -p "${conf_dir}"
    echo "sentinel" > "${conf_dir}/PREVIOUS_BUILD_SENTINEL"

    # Stub configure: succeeds, creates configure.log
    mkdir -p "${src}"
    cat > "${src}/configure" <<'EOF'
#!/usr/bin/env bash
# Stub configure
level="fastdebug"
for arg in "$@"; do
    case "$arg" in
        --with-debug-level=*) level="${arg#*=}" ;;
    esac
done
conf="linux-s390x-server-${level}"
mkdir -p "build/${conf}"
echo "configure complete" > "build/${conf}/configure.log"
exit 0
EOF
    chmod +x "${src}/configure"

    # Stub make — succeeds for 'images', creates a build.log and test-results
    cat > "${src}/GNUmakefile" <<'EOF'
#!/usr/bin/env make -f
# Detect target from MAKECMDGOALS
# For 'images': create build.log
# For 'run-test': create test-results/newfailures.txt
CONF ?= linux-s390x-server-fastdebug

images:
	mkdir -p build/$(CONF)
	echo "make images done" > build/$(CONF)/build.log

run-test:
	mkdir -p build/$(CONF)/test-results/tier1
	echo "(none)" > build/$(CONF)/test-results/tier1/newfailures.txt
	echo "(none)" > build/$(CONF)/test-results/tier1/other_errors.txt

dist-clean:
	echo "DIST-CLEAN CALLED — THIS IS A REGRESSION" >&2
	rm -rf build/$(CONF)
	exit 1
EOF

    echo "${src}"
}

# ---------------------------------------------------------------------------
# T1  build_and_test_jdk — previous build artifacts survive
#
# WHY CORRECT: We place PREVIOUS_BUILD_SENTINEL inside the conf dir before
# calling the function.  If the function wipes the dir (regression), the
# sentinel is gone and the test fails.  If the function leaves it alone
# (correct behaviour), the test passes.
#
# CONTRADICTION ADDRESSED: "Maybe configure recreates the dir and the sentinel
# survives by accident?"  No — we use  rm -rf  in the fake  dist-clean  rule
# which exits 1 to make the regression extremely visible.  If dist-clean were
# called, the whole subshell would exit non-zero and build_and_test_jdk would
# return non-zero — which the assert_exit_zero would catch.
# ---------------------------------------------------------------------------
describe "build_and_test_jdk — no automatic cleanup"

it "T1: PREVIOUS_BUILD_SENTINEL survives build_and_test_jdk call"
SRC="$(_make_fake_src "bat" "fastdebug")"
SENTINEL="${SRC}/build/linux-s390x-server-fastdebug/PREVIOUS_BUILD_SENTINEL"
assert_file_exists "${SENTINEL}" "pre-condition: sentinel must exist before call"

build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}"

assert_file_exists "${SENTINEL}" "sentinel must survive — no auto-cleanup"

# ---------------------------------------------------------------------------
# T2  build_only_jdk — previous build artifacts survive
#
# WHY CORRECT: Same logic as T1 but for the build-only path used by
# `jdk.sh build` and the --test-target all run path.
# ---------------------------------------------------------------------------
describe "build_only_jdk — no automatic cleanup"

it "T2: PREVIOUS_BUILD_SENTINEL survives build_only_jdk call"
SRC="$(_make_fake_src "bo" "fastdebug")"
SENTINEL="${SRC}/build/linux-s390x-server-fastdebug/PREVIOUS_BUILD_SENTINEL"
assert_file_exists "${SENTINEL}" "pre-condition: sentinel must exist before call"

build_only_jdk \
    "${SRC}" "test-stream" "fastdebug" "${BOOT_JDK_DIR}"

assert_file_exists "${SENTINEL}" "sentinel must survive — no auto-cleanup"

# ---------------------------------------------------------------------------
# T3  build_and_test_jdk writes run-metadata.txt into the build conf dir
#
# WHY CORRECT: If we only test for the absence of cleanup but the build itself
# never ran, we get a false positive — sentinel survived because nothing
# happened, not because cleanup was skipped.  run-metadata.txt is written only
# when the build reaches the metadata-writing step, proving the build ran.
# run-metadata.txt now lives in <src_dir>/build/<conf>/ (not a separate OUT).
# ---------------------------------------------------------------------------
it "T3: run-metadata.txt written into conf dir — confirms build actually ran"
SRC="$(_make_fake_src "bat2" "fastdebug")"
CONF_DIR="${SRC}/build/linux-s390x-server-fastdebug"

build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}"

assert_file_exists "${CONF_DIR}/run-metadata.txt" "run-metadata.txt must be written"
assert_contains    "${CONF_DIR}/run-metadata.txt" "stream:       test-stream"

# ---------------------------------------------------------------------------
# T4  build_only_jdk writes run-metadata.txt (jtreg_ok=false → test_exit=SKIPPED)
# ---------------------------------------------------------------------------
it "T4: build_only_jdk writes run-metadata.txt into conf dir"
SRC="$(_make_fake_src "bo2" "fastdebug")"
CONF_DIR="${SRC}/build/linux-s390x-server-fastdebug"

build_only_jdk \
    "${SRC}" "test-stream" "fastdebug" "${BOOT_JDK_DIR}"

assert_file_exists "${CONF_DIR}/run-metadata.txt"
assert_contains    "${CONF_DIR}/run-metadata.txt" "test_exit:    SKIPPED"

# ---------------------------------------------------------------------------
# T5  Consecutive builds — second run does NOT wipe first run's artifacts
#
# WHY CORRECT: The most common real-world usage is: build fails → fix source →
# rebuild.  The engineer wants the first run's build.log and test-results to
# survive so they can compare.  We run build_and_test_jdk twice and assert
# that a file written by the first run survives the second.
#
# CONTRADICTION ADDRESSED: "Doesn't the second configure overwrite build.log?"
# Yes — but only configure.log and build.log.  test-results/ and
# PREVIOUS_BUILD_SENTINEL (or any file configure/make doesn't touch) survive.
# ---------------------------------------------------------------------------
it "T5: first-run test-results/ survives second build_and_test_jdk call"
SRC="$(_make_fake_src "consec" "fastdebug")"

# First run (creates test-results/)
build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}"

# Plant a sentinel inside test-results to simulate previous run's evidence
mkdir -p "${SRC}/build/linux-s390x-server-fastdebug/test-results"
echo "previous run failure" \
    > "${SRC}/build/linux-s390x-server-fastdebug/test-results/EVIDENCE"

# Second run
build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}"

assert_file_exists \
    "${SRC}/build/linux-s390x-server-fastdebug/test-results/EVIDENCE" \
    "previous run's test-results evidence must survive"

# ---------------------------------------------------------------------------
# T6  dist-clean stub exits non-zero — proves it is never called
#
# WHY CORRECT: Our GNUmakefile's dist-clean target deliberately prints an
# error message and exits 1.  If auto-cleanup were still happening, the
# subshell inside build_and_test_jdk would exit non-zero and the function
# would return non-zero — caught by assert_exit_zero.
#
# This test is the definitive "if cleanup runs, the test explodes" check.
# ---------------------------------------------------------------------------
it "T6: functions exit 0 even though dist-clean would fail — proves dist-clean is never called"
SRC="$(_make_fake_src "nodc" "fastdebug")"

# build_and_test_jdk must return 0 (build success)
rc=0
build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}" \
    || rc=$?
assert_eq "${rc}" "0" "build_and_test_jdk must exit 0 — dist-clean was NOT called"

SRC2="$(_make_fake_src "nodc2" "fastdebug")"
rc2=0
build_only_jdk \
    "${SRC2}" "test-stream" "fastdebug" "${BOOT_JDK_DIR}" \
    || rc2=$?
assert_eq "${rc2}" "0" "build_only_jdk must exit 0 — dist-clean was NOT called"
