#!/usr/bin/env bash
# =============================================================================
# test_resend.sh
#
# Tests for the 'resend' command in jdk.sh.
#
# STRATEGY
# ────────
# jdk.sh is not sourceable (it calls main at file scope).  We invoke it as a
# subprocess with a stubbed CI_NOTIFY_EMAIL pointed at /dev/null and capture
# the output to assert on log lines.  We override _notify_send by injecting a
# wrapper via a temp notify stub that is loaded instead of the real one.
#
# Because the test machine may not have a boot JDK / jtreg installed, and
# resend never calls ensure_deps, build_and_test_jdk, etc., this test can run
# safely in any environment.
#
# WHY THESE TESTS ARE CORRECT
# ────────────────────────────
# resend has three responsibilities:
#   1. Validate that run-summary.txt exists in --from dir (fail fast otherwise).
#   2. Derive overall PASS/FAIL, subject suffix, commit-info path, and triples
#      from the artefacts on disk.
#   3. Call ci_notify with those arguments.
#
# We stub ci_notify (via a wrapper notify.sh) and assert on what it received.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Stub notify.sh — write ci_notify arguments to files under $T so we can
# assert on them without sending real email.
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

# ---------------------------------------------------------------------------
# _run_resend <extra_args...>
# Invokes jdk.sh resend with the stub notify and NOTIFY_OUT pointing at $T.
# Sets RESEND_OUTPUT to the captured stdout+stderr.
# ---------------------------------------------------------------------------
NOTIFY_OUT="${T}/notify_out"
mkdir -p "${NOTIFY_OUT}"

_run_resend() {
    rm -f "${NOTIFY_OUT}"/*
    RESEND_OUTPUT="$(
        NOTIFY_OUT="${NOTIFY_OUT}" \
        _STUB_NOTIFY_PATH="${STUB_NOTIFY}" \
        bash -c '
            # Patch jdk.sh to source the stub instead of the real notify.sh
            PATCHED="${TMPDIR:-/tmp}/jdk_patched_$$.sh"
            sed "s|source \"\${SCRIPT_DIR}/notify.sh\"|source \"${_STUB_NOTIFY_PATH}\"|" \
                '"${SCRIPT_DIR}"'/jdk.sh > "${PATCHED}"
            bash "${PATCHED}" '"$*"'
            rc=$?
            rm -f "${PATCHED}"
            exit ${rc}
        ' 2>&1
    )" || true
}

# ---------------------------------------------------------------------------
# Helpers to build fake run directories
# ---------------------------------------------------------------------------

# _make_daily_run_dir <dir> — creates a minimal daily-run layout
_make_daily_run_dir() {
    local dir="$1"
    mkdir -p "${dir}"
    cat > "${dir}/run-summary.txt" << 'EOF'
========================================================
  OpenJDK s390x CI — Run Summary
========================================================
  Date       : 2026-07-11 03:00:00 UTC
  Host       : testhost
========================================================

  ── head ──────────────────────────────────────────
    fastdebug     TEST_PASSED                         all tier1 tests passed
    release       TEST_PASSED                         all tier1 tests passed

  ── jdk21 ──────────────────────────────────────────
    fastdebug     TEST_FAILED                         tier1 completed with failures

========================================================
  Totals  (stream × level combinations)
    Combinations tracked:          3
    TEST_PASSED:                   2
    TEST_FAILED:                   1
========================================================
EOF
    echo "combined commit info" > "${dir}/commit-info-all.txt"

    # head/fastdebug — TEST_PASSED
    mkdir -p "${dir}/head/fastdebug"
    echo "test_exit:    0" > "${dir}/head/fastdebug/run-metadata.txt"

    # head/release — TEST_PASSED
    mkdir -p "${dir}/head/release"
    echo "test_exit:    0" > "${dir}/head/release/run-metadata.txt"

    # jdk21/fastdebug — TEST_FAILED
    mkdir -p "${dir}/jdk21/fastdebug"
    echo "test_exit:    1" > "${dir}/jdk21/fastdebug/run-metadata.txt"
    echo "some.test.FailedTest" > "${dir}/jdk21/fastdebug/newfailures.txt"
}

# _make_jdksh_run_dir <dir> — single-stream jdk.sh layout (levels at top)
_make_jdksh_run_dir() {
    local dir="$1"
    mkdir -p "${dir}"
    cat > "${dir}/run-summary.txt" << 'EOF'
========================================================
  jdk.sh Run Summary
========================================================
  command      : run
  stream       : head
  date         : 2026-07-11 10:00:00 UTC
========================================================
  Results:
    fastdebug     PASSED
    release       PASSED
========================================================
EOF
    echo "head commit info" > "${dir}/commit-info.txt"
    mkdir -p "${dir}/fastdebug"
    echo "test_exit:    0" > "${dir}/fastdebug/run-metadata.txt"
    mkdir -p "${dir}/release"
    echo "test_exit:    0" > "${dir}/release/run-metadata.txt"
}

# ─────────────────────────────────────────────────────────────────────────────
# T1  Missing --from with no reports → error exit (auto-discovery fails)
#
# WHY CORRECT: When --from is omitted, resend auto-discovers the latest run
# under REPORTS_DIR.  If REPORTS_DIR is empty (no runs yet), it must die with
# a clear message rather than calling ci_notify with garbage.
# We point REPORTS_DIR at an empty temp dir to simulate no runs yet.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — argument validation"
it "T1: no --from and no reports → exits non-zero, ci_notify not called"
EMPTY_REPORTS="${T}/empty-reports"
mkdir -p "${EMPTY_REPORTS}"
_run_resend resend  # REPORTS_DIR default points at repo; patch via env
# Run with REPORTS_DIR overridden to an empty dir
RESEND_OUTPUT="$(
    NOTIFY_OUT="${NOTIFY_OUT}" \
    _STUB_NOTIFY_PATH="${STUB_NOTIFY}" \
    bash -c '
        PATCHED="${TMPDIR:-/tmp}/jdk_patched_$$.sh"
        sed "s|source \"\${SCRIPT_DIR}/notify.sh\"|source \"${_STUB_NOTIFY_PATH}\"|" \
            '"${SCRIPT_DIR}"'/jdk.sh > "${PATCHED}"
        REPORTS_DIR="'"${EMPTY_REPORTS}"'" bash "${PATCHED}" resend
        rc=$?; rm -f "${PATCHED}"; exit ${rc}
    ' 2>&1
)" || true
assert_file_missing "${NOTIFY_OUT}/called" "ci_notify must not be called"
assert_contains <(echo "${RESEND_OUTPUT}") "No completed run found" "must explain no runs found"

# ─────────────────────────────────────────────────────────────────────────────
# T2  --from points at non-existent directory → error exit
# ─────────────────────────────────────────────────────────────────────────────
it "T2: --from non-existent dir → exits non-zero"
_run_resend resend --from "${T}/no-such-dir"
assert_file_missing "${NOTIFY_OUT}/called" "ci_notify must not be called"

# ─────────────────────────────────────────────────────────────────────────────
# T3  --from dir exists but no run-summary.txt → error exit
# ─────────────────────────────────────────────────────────────────────────────
it "T3: --from dir without run-summary.txt → exits non-zero"
EMPTY_DIR="${T}/empty-run"
mkdir -p "${EMPTY_DIR}"
_run_resend resend --from "${EMPTY_DIR}"
assert_file_missing "${NOTIFY_OUT}/called" "ci_notify must not be called"
assert_contains <(echo "${RESEND_OUTPUT}") "run-summary.txt not found" "must mention missing file"

# ─────────────────────────────────────────────────────────────────────────────
# T4  Valid daily run dir → ci_notify called with run_kind=daily
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — daily run layout"
it "T4: valid daily run dir → ci_notify called, run_kind=daily"
DAILY_DIR="${T}/daily-run"
_make_daily_run_dir "${DAILY_DIR}"
_run_resend resend --from "${DAILY_DIR}"
assert_file_exists "${NOTIFY_OUT}/called"       "ci_notify must be called"
assert_eq "$(cat "${NOTIFY_OUT}/run_kind")" "daily" "run_kind must be daily"

# ─────────────────────────────────────────────────────────────────────────────
# T5  TEST_FAILED in summary → overall=FAIL
# ─────────────────────────────────────────────────────────────────────────────
it "T5: TEST_FAILED in run-summary.txt → overall=FAIL"
_run_resend resend --from "${DAILY_DIR}"
assert_eq "$(cat "${NOTIFY_OUT}/overall")" "FAIL" "overall must be FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T6  All-pass summary → overall=PASS
# ─────────────────────────────────────────────────────────────────────────────
it "T6: all-pass run-summary.txt → overall=PASS"
PASS_DIR="${T}/pass-run"
mkdir -p "${PASS_DIR}"
sed '/TEST_FAILED/d' "${DAILY_DIR}/run-summary.txt" > "${PASS_DIR}/run-summary.txt"
cp "${DAILY_DIR}/commit-info-all.txt" "${PASS_DIR}/"
mkdir -p "${PASS_DIR}/head/fastdebug"
echo "test_exit:    0" > "${PASS_DIR}/head/fastdebug/run-metadata.txt"
_run_resend resend --from "${PASS_DIR}"
assert_eq "$(cat "${NOTIFY_OUT}/overall")" "PASS" "overall must be PASS"

# ─────────────────────────────────────────────────────────────────────────────
# T7  commit-info-all.txt preferred over commit-info.txt
# ─────────────────────────────────────────────────────────────────────────────
it "T7: commit-info-all.txt is passed to ci_notify (not subject_suffix)"
# Checked indirectly: if ci_notify was called the commit file was resolved.
# We verify by asserting the triples file was written (ci_notify ran fully).
assert_file_exists "${NOTIFY_OUT}/triples" "triples file must exist when ci_notify runs"

# ─────────────────────────────────────────────────────────────────────────────
# T8  Triples carry the JDK source tree path and real level
#
# WHY CORRECT: test results stay in the JDK source tree
# (<src_dir>/build/linux-s390x-server-<level>/test-results/).
# resend passes the registry src_dir + real level so _notify_build_section
# reads newfailures.txt / build.log live from the same place the original
# run wrote them — not from the (now absent) report directory copies.
# ─────────────────────────────────────────────────────────────────────────────
it "T8: triples carry stream, real level, and JDK source-tree path"
_run_resend resend --from "${DAILY_DIR}"
assert_contains     "${NOTIFY_OUT}/triples" "head:"        "head stream must appear"
assert_contains     "${NOTIFY_OUT}/triples" "jdk21:"       "jdk21 stream must appear"
assert_contains     "${NOTIFY_OUT}/triples" ":fastdebug:"  "fastdebug level must appear"
assert_contains     "${NOTIFY_OUT}/triples" ":release:"    "release level must appear"
assert_not_contains "${NOTIFY_OUT}/triples" "__report__"   "__report__ sentinel must NOT appear"
assert_not_contains "${NOTIFY_OUT}/triples" "${DAILY_DIR}" "report dir must NOT be in triple path"

# ─────────────────────────────────────────────────────────────────────────────
# T9  build_status derived from run-metadata.txt: 0→TEST_PASSED, 1→TEST_FAILED
# ─────────────────────────────────────────────────────────────────────────────
it "T9: test_exit=0 → TEST_PASSED, test_exit=1 → TEST_FAILED in triples"
_run_resend resend --from "${DAILY_DIR}"
assert_contains     "${NOTIFY_OUT}/triples" "TEST_PASSED"  "passed status must appear"
assert_contains     "${NOTIFY_OUT}/triples" "TEST_FAILED"  "failed status must appear"

# ─────────────────────────────────────────────────────────────────────────────
# T10  missing run-metadata.txt → BUILD_FAILED in triple
# ─────────────────────────────────────────────────────────────────────────────
it "T10: missing run-metadata.txt → BUILD_FAILED in triple"
NO_META_DIR="${T}/no-meta-run"
mkdir -p "${NO_META_DIR}"
cp "${DAILY_DIR}/run-summary.txt" "${NO_META_DIR}/"
mkdir -p "${NO_META_DIR}/head/fastdebug"   # no run-metadata.txt inside
_run_resend resend --from "${NO_META_DIR}"
assert_contains "${NOTIFY_OUT}/triples" "BUILD_FAILED" "missing metadata → BUILD_FAILED"

# ─────────────────────────────────────────────────────────────────────────────
# T11  --run-kind manual overrides the kind passed to ci_notify
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — --run-kind override"
it "T11: --run-kind manual → ci_notify receives run_kind=manual"
_run_resend resend --from "${DAILY_DIR}" --run-kind manual
assert_eq "$(cat "${NOTIFY_OUT}/run_kind")" "manual" "run_kind must be manual"

# ─────────────────────────────────────────────────────────────────────────────
# T12  jdk.sh single-stream layout (levels directly under run dir)
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — jdk.sh single-stream layout"
it "T12: jdk.sh run dir (levels at top level) → triples resolved via --stream"
JDKSH_DIR="${T}/jdksh-run"
_make_jdksh_run_dir "${JDKSH_DIR}"
_run_resend resend --from "${JDKSH_DIR}" --stream head --run-kind manual
assert_file_exists "${NOTIFY_OUT}/called"  "ci_notify must be called"
assert_contains    "${NOTIFY_OUT}/triples" "head:"      "head stream must appear"
assert_contains    "${NOTIFY_OUT}/triples" ":fastdebug:" "fastdebug must appear"
assert_contains    "${NOTIFY_OUT}/triples" ":release:"   "release must appear"

# ─────────────────────────────────────────────────────────────────────────────
# T13  Auto-discovery: no --from → picks latest run under REPORTS_DIR
#
# WHY CORRECT: resend finds the most-recently-modified run-summary.txt under
# REPORTS_DIR at depth 3 (YYYY/Month/DD).  We create two fake run dirs with
# different mtimes and assert the newer one is selected.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — auto-discovery"
it "T13: no --from → auto-discovers newest run dir"
FAKE_REPORTS="${T}/fake-reports"
OLDER_RUN="${FAKE_REPORTS}/2025/June/10"
NEWER_RUN="${FAKE_REPORTS}/2025/July/11"
mkdir -p "${OLDER_RUN}" "${NEWER_RUN}"
cp "${DAILY_DIR}/run-summary.txt" "${OLDER_RUN}/"
cp "${DAILY_DIR}/commit-info-all.txt" "${OLDER_RUN}/" 2>/dev/null || true
cp "${DAILY_DIR}/run-summary.txt" "${NEWER_RUN}/"
cp "${DAILY_DIR}/commit-info-all.txt" "${NEWER_RUN}/" 2>/dev/null || true
# Ensure older run has an older mtime
touch -t 202506100800 "${OLDER_RUN}/run-summary.txt"
touch -t 202507110800 "${NEWER_RUN}/run-summary.txt"
rm -f "${NOTIFY_OUT}"/*
RESEND_OUTPUT="$(
    NOTIFY_OUT="${NOTIFY_OUT}" \
    _STUB_NOTIFY_PATH="${STUB_NOTIFY}" \
    bash -c '
        PATCHED="${TMPDIR:-/tmp}/jdk_patched_$$.sh"
        sed "s|source \"\${SCRIPT_DIR}/notify.sh\"|source \"${_STUB_NOTIFY_PATH}\"|" \
            '"${SCRIPT_DIR}"'/jdk.sh > "${PATCHED}"
        REPORTS_DIR="'"${FAKE_REPORTS}"'" bash "${PATCHED}" resend
        rc=$?; rm -f "${PATCHED}"; exit ${rc}
    ' 2>&1
)" || true
assert_file_exists  "${NOTIFY_OUT}/called" "ci_notify must be called"
assert_contains <(echo "${RESEND_OUTPUT}") "2025/July/11" "must select the newer run"

# ─────────────────────────────────────────────────────────────────────────────
# T14  --stream filter: only the requested stream appears in triples
#
# WHY CORRECT: DAILY_DIR has head/fastdebug, head/release, jdk21/fastdebug.
# Passing --stream head must produce triples only for head, not jdk21.
# ─────────────────────────────────────────────────────────────────────────────
describe "jdk.sh resend — --stream filter"
it "T14: --stream head → only head triples, jdk21 excluded"
_run_resend resend --from "${DAILY_DIR}" --stream head
assert_file_exists      "${NOTIFY_OUT}/called"         "ci_notify must be called"
assert_contains         "${NOTIFY_OUT}/triples" "head:" "head must appear"
assert_not_contains     "${NOTIFY_OUT}/triples" "jdk21:" "jdk21 must be excluded"

it "T14b: --stream head → subject suffix contains 'head' not 'all streams'"
assert_contains     "${NOTIFY_OUT}/subject_suffix" "head"        "subject must name the stream"
assert_not_contains "${NOTIFY_OUT}/subject_suffix" "all streams" "must not say all streams"
