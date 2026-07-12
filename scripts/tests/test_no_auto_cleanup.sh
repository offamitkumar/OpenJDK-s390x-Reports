#!/usr/bin/env bash
# =============================================================================
# test_build_clean.sh  (was test_no_auto_cleanup.sh)
#
# Tests that build_and_test_jdk() and build_only_jdk() in build_test.sh
# ALWAYS run dist-clean before starting a fresh build.
#
# THE BEHAVIOUR BEING TESTED
# ──────────────────────────
# Every build starts with:
#
#   if [[ -d "build/${conf_name}" ]]; then
#       make CONF="${conf_name}" dist-clean 2>/dev/null \
#           || rm -rf "build/${conf_name}"
#   fi
#
# This ensures every daily (and manual) build is a clean, reproducible build
# from a known-good state rather than an incremental build on top of stale
# objects.
#
# WHY THESE TESTS ARE CORRECT
# ────────────────────────────
# We stub the real build (configure, make) with scripts that always succeed.
# The stub dist-clean removes the conf dir (as the real one does).  We then:
#
#   T1/T2  Place a sentinel file in the conf dir before the call and assert
#          it is GONE after — proving dist-clean ran.
#
#   T3/T4  Assert run-metadata.txt is written into the (freshly recreated)
#          conf dir — proving the build completed after the clean.
#
#   T5     Plant a sentinel AFTER the first run, run again, assert it is
#          gone — proving the second run also cleaned.
#
#   T6     When no prior build dir exists, the clean step is skipped entirely
#          and the build still succeeds (no error on missing dir).
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
# The real  bash configure  and  make images  are replaced by stub scripts
# that succeed immediately and simulate the configure output layout.
# dist-clean removes the conf dir (same as the real target).
# ---------------------------------------------------------------------------
_make_fake_src() {
    local src="${T}/src_$1"
    mkdir -p "${src}/make/conf"
    echo "DEFAULT_VERSION_FEATURE = 26" > "${src}/make/conf/version-numbers.conf"

    # Stub configure: recreates build/<conf>/ after dist-clean wiped it
    cat > "${src}/configure" <<'EOF'
#!/usr/bin/env bash
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

    # Stub make — dist-clean removes the conf dir (correct behaviour);
    # images creates build.log; run-test creates test-results.
    cat > "${src}/GNUmakefile" <<'EOF'
CONF ?= linux-s390x-server-fastdebug

images:
	mkdir -p build/$(CONF)
	echo "make images done" > build/$(CONF)/build.log

run-test:
	mkdir -p build/$(CONF)/test-results/tier1
	echo "(none)" > build/$(CONF)/test-results/tier1/newfailures.txt
	echo "(none)" > build/$(CONF)/test-results/tier1/other_errors.txt

dist-clean:
	rm -rf build/$(CONF)
EOF

    echo "${src}"
}

# ---------------------------------------------------------------------------
# T1  build_and_test_jdk — prior conf dir is removed before the build
#
# WHY CORRECT: We place PREVIOUS_BUILD_SENTINEL in the conf dir before the
# call.  The function must run dist-clean (which removes the whole dir) and
# then configure (which recreates it without the sentinel).  If the sentinel
# survives, cleanup did not run — regression.
# ---------------------------------------------------------------------------
describe "build_and_test_jdk — always cleans before build"

it "T1: PREVIOUS_BUILD_SENTINEL is removed by dist-clean before build"
SRC="$(_make_fake_src "bat" "fastdebug")"
CONF_DIR="${SRC}/build/linux-s390x-server-fastdebug"
mkdir -p "${CONF_DIR}"
echo "sentinel" > "${CONF_DIR}/PREVIOUS_BUILD_SENTINEL"
assert_file_exists "${CONF_DIR}/PREVIOUS_BUILD_SENTINEL" "pre-condition: sentinel must exist"

build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}"

assert_file_missing "${CONF_DIR}/PREVIOUS_BUILD_SENTINEL" \
    "sentinel must be gone — dist-clean ran before build"

# ---------------------------------------------------------------------------
# T2  build_only_jdk — same guarantee via the shared build_and_test_jdk path
# ---------------------------------------------------------------------------
describe "build_only_jdk — always cleans before build"

it "T2: PREVIOUS_BUILD_SENTINEL is removed by dist-clean before build_only_jdk"
SRC="$(_make_fake_src "bo" "fastdebug")"
CONF_DIR="${SRC}/build/linux-s390x-server-fastdebug"
mkdir -p "${CONF_DIR}"
echo "sentinel" > "${CONF_DIR}/PREVIOUS_BUILD_SENTINEL"
assert_file_exists "${CONF_DIR}/PREVIOUS_BUILD_SENTINEL" "pre-condition: sentinel must exist"

build_only_jdk \
    "${SRC}" "test-stream" "fastdebug" "${BOOT_JDK_DIR}"

assert_file_missing "${CONF_DIR}/PREVIOUS_BUILD_SENTINEL" \
    "sentinel must be gone — dist-clean ran before build_only_jdk"

# ---------------------------------------------------------------------------
# T3  build_and_test_jdk writes run-metadata.txt after the clean+build
#
# WHY CORRECT: Proves the build actually completed — dist-clean removed the
# dir, configure recreated it, make images ran, metadata was written.
# ---------------------------------------------------------------------------
it "T3: run-metadata.txt written after clean+build — confirms full cycle ran"
SRC="$(_make_fake_src "bat2" "fastdebug")"
CONF_DIR="${SRC}/build/linux-s390x-server-fastdebug"
mkdir -p "${CONF_DIR}"   # simulate a prior build existing

build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}"

assert_file_exists "${CONF_DIR}/run-metadata.txt" "run-metadata.txt must exist after build"
assert_contains    "${CONF_DIR}/run-metadata.txt" "stream:       test-stream"

# ---------------------------------------------------------------------------
# T4  build_only_jdk writes run-metadata.txt (jtreg_ok=false → test_exit=SKIPPED)
# ---------------------------------------------------------------------------
it "T4: build_only_jdk writes run-metadata.txt after clean+build"
SRC="$(_make_fake_src "bo2" "fastdebug")"
CONF_DIR="${SRC}/build/linux-s390x-server-fastdebug"
mkdir -p "${CONF_DIR}"

build_only_jdk \
    "${SRC}" "test-stream" "fastdebug" "${BOOT_JDK_DIR}"

assert_file_exists "${CONF_DIR}/run-metadata.txt"
assert_contains    "${CONF_DIR}/run-metadata.txt" "test_exit:    SKIPPED"

# ---------------------------------------------------------------------------
# T5  Consecutive builds — second run also cleans the first run's artifacts
#
# WHY CORRECT: The sentinel is planted AFTER the first run completes (i.e.
# inside the freshly-built conf dir).  The second run must clean it away.
# ---------------------------------------------------------------------------
it "T5: second build_and_test_jdk call also cleans the first run's artifacts"
SRC="$(_make_fake_src "consec" "fastdebug")"
CONF_DIR="${SRC}/build/linux-s390x-server-fastdebug"

# First run (builds from scratch — no prior dir)
build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}"

# Plant evidence of the first run inside the conf dir
echo "first run artifact" > "${CONF_DIR}/FIRST_RUN_ARTIFACT"
assert_file_exists "${CONF_DIR}/FIRST_RUN_ARTIFACT" "pre-condition: artifact planted"

# Second run — must clean before building
build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}"

assert_file_missing "${CONF_DIR}/FIRST_RUN_ARTIFACT" \
    "first-run artifact must be gone — second build cleaned"

# ---------------------------------------------------------------------------
# T6  No prior build dir — clean step is a no-op, build still succeeds
#
# WHY CORRECT: The clean block is guarded by  [[ -d "build/${conf_name}" ]].
# If no prior dir exists (first-ever build), the guard is false, dist-clean
# is never called, and the build proceeds normally.
# ---------------------------------------------------------------------------
it "T6: no prior build dir → clean skipped, build succeeds"
SRC="$(_make_fake_src "fresh" "fastdebug")"
# Do NOT pre-create the conf dir — simulate a first-ever build

rc=0
build_and_test_jdk \
    "${SRC}" "test-stream" "fastdebug" "false" "${BOOT_JDK_DIR}" \
    || rc=$?
assert_eq "${rc}" "0" "build must succeed even when no prior conf dir exists"
assert_file_exists "${SRC}/build/linux-s390x-server-fastdebug/run-metadata.txt" \
    "run-metadata.txt must be written on first-ever build"
