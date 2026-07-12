#!/usr/bin/env bash
# =============================================================================
# test_resend.sh
#
# Tests for the 'resend' command in jdk.sh.
#
# STRATEGY
# ────────
# jdk.sh is not sourceable (it calls main at file scope).  We invoke it as a
# subprocess with a stubbed notify.sh and capture output / notify args.
#
# resend reads results directly from the JDK build tree:
#   <src_dir>/build/linux-s390x-server-<level>/test-results/
#
# We override JDK_SOURCES_ROOT to point at a fake tree we control.
# We stub ci_notify to capture the arguments it receives.
#
# WHY THESE TESTS ARE CORRECT
# ────────────────────────────
# resend has three responsibilities:
#   1. Collect triples from the live JDK build tree (src_dir × level).
#   2. Derive overall PASS/FAIL from newfailures.txt in test-results/.
#   3. Call ci_notify with those arguments.
#
# We stub ci_notify (via a patched notify.sh) and assert on what it received.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Stub notify.sh — write ci_notify arguments to files under NOTIFY_OUT.
# ---------------------------------------------------------------------------
STUB_NOTIFY="${T}/stub_notify.sh"
cat > "${STUB_NOTIFY}" << 'STUB'
#!/usr/bin/env bash
[[ -n "${_CI_NOTIFY_SH_LOADED:-}" ]] && return 0
_CI_NOTIFY_SH_LOADED=1
_notify_info() { echo "[notify] $*"; }
_notify_warn() { echo "[notify] WARN: $*" >&2; }
ci_notify() {
    local run_kind="$1" subject_suffix="$2" summary_file="$3"
    local overall_status="$4" commit_info_file="$5"
    shift 5
    local triples=("$@")
    echo "${run_kind}"        > "${NOTIFY_OUT}/run_kind"
    echo "${subject_suffix}"  > "${NOTIFY_OUT}/subject_suffix"
    echo "${overall_status}"  > "${NOTIFY_OUT}/overall"
    printf '%s\n' "${triples[@]}" > "${NOTIFY_OUT}/triples"
    echo "CALLED"             > "${NOTIFY_OUT}/called"
}
STUB

NOTIFY_OUT="${T}/notify_out"
mkdir -p "${NOTIFY_OUT}"

# ---------------------------------------------------------------------------
# Fake JDK source tree root — override JDK_SOURCES_ROOT so jdk.sh resolves
# streams to our controlled paths.
# JDK_STREAMS in config.sh maps "head" → src_subdir "jdk".
# ---------------------------------------------------------------------------
FAKE_ROOT="${T}/jdk_sources"
mkdir -p "${FAKE_ROOT}"

# _make_conf_dir <stream_src_subdir> <level> <test_exit>
# Creates <FAKE_ROOT>/<src_subdir>/build/linux-s390x-server-<level>/
# with a minimal run-metadata.txt and (if test_exit==0) a passing
# newfailures.txt, or (if test_exit!=0) a failing one.
_make_conf_dir() {
    local sub="$1" level="$2" test_exit="${3:-0}"
    local conf_dir="${FAKE_ROOT}/${sub}/build/linux-s390x-server-${level}"
    mkdir -p "${conf_dir}/test-results/tier1"
    echo "test_exit:    ${test_exit}" > "${conf_dir}/run-metadata.txt"
    if [[ "${test_exit}" == "0" ]]; then
        echo "(none)" > "${conf_dir}/test-results/tier1/newfailures.txt"
    else
        echo "some.test.FailedTest" > "${conf_dir}/test-results/tier1/newfailures.txt"
    fi
}

# ---------------------------------------------------------------------------
# _run_resend <extra_args...>
# Invokes jdk.sh resend with the stub notify and NOTIFY_OUT + JDK_SOURCES_ROOT.
# Sets RESEND_OUTPUT to the captured stdout+stderr.
# ---------------------------------------------------------------------------
_run_resend() {
    rm -f "${NOTIFY_OUT}"/*
    RESEND_OUTPUT="$(
        NOTIFY_OUT="${NOTIFY_OUT}" \
        JDK_SOURCES_ROOT="${FAKE_ROOT}" \
        _STUB_NOTIFY_PATH="${STUB_NOTIFY}" \
        bash -c '
            PATCHED="${TMPDIR:-/tmp}/jdk_patched_$$.sh"
            sed "s|source \"\${SCRIPT_DIR}/notify.sh\"|source \"${_STUB_NOTIFY_PATH}\"|" \
                '"${SCRIPT_DIR}"'/jdk.sh > "${PATCHED}"
            JDK_SOURCES_ROOT="${JDK_SOURCES_ROOT}" \
            NOTIFY_OUT="${NOTIFY_OUT}" \
                bash "${PATCHED}" '"$*"'
            rc=$?
            rm -f "${PATCHED}"
            exit ${rc}
        ' 2>&1
    )" || true
}

# ─────────────────────────────────────────────────────────────────────────────
# T1  No build results exist → ci_notify still called (with empty triples)
#
# WHY CORRECT: resend reads from the live build tree.  If no streams have been
# built yet, it finds no conf dirs, builds an empty triples list, and still
# calls ci_notify (with overall=PASS and no triples).  It must NOT die.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — no build results"
it "T1: no build dirs → ci_notify called with empty triples"
_run_resend resend
assert_file_exists "${NOTIFY_OUT}/called" "ci_notify must be called even with no results"

# ─────────────────────────────────────────────────────────────────────────────
# T2  One stream built, one level passing → ci_notify called, overall=PASS
#
# WHY CORRECT: We create a conf dir for head/fastdebug with test_exit=0 and a
# passing newfailures.txt.  resend must detect TEST_PASSED and set overall=PASS.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — passing build"
it "T2: head/fastdebug passing → overall=PASS"
_make_conf_dir "jdk" "fastdebug" "0"
_run_resend resend
assert_file_exists "${NOTIFY_OUT}/called"  "ci_notify must be called"
assert_eq "$(cat "${NOTIFY_OUT}/overall")" "PASS" "overall must be PASS"

# ─────────────────────────────────────────────────────────────────────────────
# T3  One stream built, failing test → overall=FAIL
#
# WHY CORRECT: newfailures.txt has a non-empty entry → TEST_FAILED → overall FAIL.
# ─────────────────────────────────────────────────────────────────────────────
it "T3: head/fastdebug with failures → overall=FAIL"
_make_conf_dir "jdk" "fastdebug" "1"
_run_resend resend
assert_eq "$(cat "${NOTIFY_OUT}/overall")" "FAIL" "overall must be FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T4  Triples carry the JDK source tree path and real level
#
# WHY CORRECT: The triple format is "stream:src_dir:level:build_status".
# We assert src_dir contains FAKE_ROOT (the live tree), not any report dir.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — triple content"
it "T4: triples carry stream, level, and JDK source-tree path"
_make_conf_dir "jdk" "fastdebug" "0"
_run_resend resend
assert_contains     "${NOTIFY_OUT}/triples" "head:"        "head stream must appear"
assert_contains     "${NOTIFY_OUT}/triples" ":fastdebug:"  "fastdebug level must appear"
assert_contains     "${NOTIFY_OUT}/triples" "${FAKE_ROOT}" "src path must be the live build tree"

# ─────────────────────────────────────────────────────────────────────────────
# T5  test_exit=0 → TEST_PASSED in triple
# ─────────────────────────────────────────────────────────────────────────────
it "T5: test_exit=0 + empty newfailures → TEST_PASSED in triple"
_make_conf_dir "jdk" "fastdebug" "0"
_run_resend resend
assert_contains "${NOTIFY_OUT}/triples" "TEST_PASSED" "passed status must appear"

# ─────────────────────────────────────────────────────────────────────────────
# T6  Failing newfailures.txt → TEST_FAILED in triple
# ─────────────────────────────────────────────────────────────────────────────
it "T6: non-empty newfailures.txt → TEST_FAILED in triple"
_make_conf_dir "jdk" "fastdebug" "1"
_run_resend resend
assert_contains "${NOTIFY_OUT}/triples" "TEST_FAILED" "failed status must appear"

# ─────────────────────────────────────────────────────────────────────────────
# T7  Build dir exists but no test-results → BUILD_ONLY in triple
#
# WHY CORRECT: A build that completed without tests produces no test-results/.
# resend must report BUILD_ONLY rather than treating it as a failure.
# ─────────────────────────────────────────────────────────────────────────────
it "T7: build dir without test-results → BUILD_ONLY in triple"
BUILD_ONLY_DIR="${FAKE_ROOT}/jdk/build/linux-s390x-server-release"
mkdir -p "${BUILD_ONLY_DIR}"
rm -rf "${BUILD_ONLY_DIR}/test-results"
_run_resend resend
assert_contains "${NOTIFY_OUT}/triples" "BUILD_ONLY" "build-only status must appear"

# ─────────────────────────────────────────────────────────────────────────────
# T8  --run-kind manual overrides the kind passed to ci_notify
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — --run-kind override"
it "T8: --run-kind manual → ci_notify receives run_kind=manual"
_make_conf_dir "jdk" "fastdebug" "0"
_run_resend resend --run-kind manual
assert_eq "$(cat "${NOTIFY_OUT}/run_kind")" "manual" "run_kind must be manual"

# ─────────────────────────────────────────────────────────────────────────────
# T9  Default run_kind is daily
# ─────────────────────────────────────────────────────────────────────────────
it "T9: default run_kind is daily"
_make_conf_dir "jdk" "fastdebug" "0"
_run_resend resend
assert_eq "$(cat "${NOTIFY_OUT}/run_kind")" "daily" "default run_kind must be daily"

# ─────────────────────────────────────────────────────────────────────────────
# T10  --stream filter: only the requested stream appears in triples
#
# WHY CORRECT: FAKE_ROOT has jdk/ (head stream).  Passing --stream head must
# produce triples only for head.  An unknown stream produces no triples but
# ci_notify is still called.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — --stream filter"
it "T10: --stream head → head triples appear"
_make_conf_dir "jdk" "fastdebug" "0"
_run_resend resend --stream head
assert_file_exists "${NOTIFY_OUT}/called"       "ci_notify must be called"
assert_contains    "${NOTIFY_OUT}/triples" "head:" "head must appear"

it "T10b: --stream head → subject suffix contains 'head' not 'all streams'"
assert_contains     "${NOTIFY_OUT}/subject_suffix" "head"        "subject must name the stream"
assert_not_contains "${NOTIFY_OUT}/subject_suffix" "all streams" "must not say all streams"

# ─────────────────────────────────────────────────────────────────────────────
# T11  --from is no longer accepted — unknown argument → exits non-zero
#
# WHY CORRECT: resend now reads from the live build tree; --from was removed.
# Passing it should cause jdk.sh to exit with an error.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — removed --from flag"
it "T11: --from is no longer accepted → exits non-zero"
RESEND_OUTPUT="$(
    JDK_SOURCES_ROOT="${FAKE_ROOT}" \
    _STUB_NOTIFY_PATH="${STUB_NOTIFY}" \
    bash -c '
        PATCHED="${TMPDIR:-/tmp}/jdk_patched_$$.sh"
        sed "s|source \"\${SCRIPT_DIR}/notify.sh\"|source \"${_STUB_NOTIFY_PATH}\"|" \
            '"${SCRIPT_DIR}"'/jdk.sh > "${PATCHED}"
        JDK_SOURCES_ROOT="${JDK_SOURCES_ROOT}" \
            bash "${PATCHED}" resend --from /tmp/some-dir
        rc=$?; rm -f "${PATCHED}"; exit ${rc}
    ' 2>&1
)" && _RESEND_RC=0 || _RESEND_RC=$?
assert_ne "${_RESEND_RC}" "0" "--from must cause a non-zero exit"
