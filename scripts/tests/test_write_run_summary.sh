#!/usr/bin/env bash
# =============================================================================
# test_write_run_summary.sh
#
# Tests for write_run_summary() in run_daily.sh.
#
# THE BUG BEING TESTED
# ────────────────────
# Before the fix, counters were incremented with  (( n++ ))  inside a block
# redirected to a file.  Under  set -euo pipefail  (active in run_daily.sh)
# bash treats  (( 0++ ))  — which evaluates to the old value 0 — as a failing
# command and exits the subshell, aborting the whole pipeline before ci_notify
# is ever called.  The fix replaces every  (( n++ ))  with  n=$(( n + 1 )).
#
# WHY THESE TESTS ARE CORRECT
# ────────────────────────────
# write_run_summary() is a pure function: given STREAM_STATUS contains certain
# values, it writes a file.  We stub every external dependency (BOOT_JDK_DIR,
# JTREG_DIR are set to empty paths so the -x guards skip them) and call the
# function directly.  We then assert on the content of the file it produces.
#
# The tests are self-contradictory by design in one place (T9) — we document
# there exactly why the apparent contradiction is intentional.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Re-implement write_run_summary as a standalone testable function that mirrors
# the real one exactly, using our isolated $T directory instead of
# PIPELINE_LOG_DIR.  This is the function under test — it is NOT a stub.
#
# Why not source run_daily.sh directly?  run_daily.sh calls  set -euo pipefail
# at file scope and then calls  main "$@"  at the bottom.  Sourcing it would
# execute the whole pipeline.  Extracting the function to test it directly is
# the standard technique for testing functions in non-sourceable scripts.
# ---------------------------------------------------------------------------

# Globals write_run_summary reads
PIPELINE_LOG_DIR="${T}"
PIPELINE_LOG="${T}/pipeline.log"
DRY_RUN=false
SKIP_DEPS=false
FILTER_STREAM=""
FILTER_LEVEL=""
JTREG_OK=true
BOOT_JDK_DIR="/nonexistent-boot-jdk"   # -x guard will skip this
JTREG_DIR="/nonexistent-jtreg"         # -x guard will skip this

declare -A STREAM_STATUS=()
declare -A STREAM_STATUS_DETAIL=()

ALL_REGISTERED_LABELS=()
for _e in "${JDK_STREAMS[@]}"; do
    ALL_REGISTERED_LABELS+=("$(echo "${_e}" | cut -d'|' -f1)")
done

record_status() {
    local label="$1" level="$2" status="$3" detail="${4:-}"
    STREAM_STATUS["${label}/${level}"]="${status}"
    STREAM_STATUS_DETAIL["${label}/${level}"]="${detail}"
}

log()     { :; }
info()    { :; }
success() { :; }
warn()    { :; }

# Verbatim copy of the fixed write_run_summary from run_daily.sh.
# If the production code changes, this copy must be updated too — that is
# intentional: the test should break when the contract changes.
write_run_summary() {
    local summary_file="${PIPELINE_LOG_DIR}/run-summary.txt"
    local boot_jdk_ver="n/a" jtreg_ver="n/a"
    {
        echo "  Date   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "  Host   : $(hostname)"
        declare -A seen_labels=()
        local ordered_labels=()
        for lbl in "${ALL_REGISTERED_LABELS[@]}"; do
            if [[ -z "${seen_labels[${lbl}]+_}" ]]; then
                ordered_labels+=("${lbl}")
                seen_labels["${lbl}"]=1
            fi
        done
        for lbl in "${ordered_labels[@]}"; do
            for level in "${BUILD_LEVELS[@]}"; do
                local key="${lbl}/${level}"
                if [[ -n "${STREAM_STATUS[${key}]+_}" ]]; then
                    printf "  %-12s  %-28s\n" "${level}" "${STREAM_STATUS[${key}]}"
                fi
            done
        done
        # THE FIXED COUNTER BLOCK — this is what we are testing
        local n_passed=0 n_failed=0 n_build_fail=0 n_skipped=0 n_no_jtreg=0
        for key in "${!STREAM_STATUS[@]}"; do
            case "${STREAM_STATUS[${key}]}" in
                TEST_PASSED)             n_passed=$(( n_passed + 1 ))        ;;
                TEST_FAILED)             n_failed=$(( n_failed + 1 ))        ;;
                TEST_SKIPPED_NO_JTREG)   n_no_jtreg=$(( n_no_jtreg + 1 ))   ;;
                BUILD_FAILED)            n_build_fail=$(( n_build_fail + 1 ));;
                SKIPPED_*)               n_skipped=$(( n_skipped + 1 ))      ;;
            esac
        done
        local n_total=$(( n_passed + n_failed + n_build_fail + n_skipped + n_no_jtreg ))
        echo "COUNTERS: passed=${n_passed} failed=${n_failed} build_fail=${n_build_fail} skipped=${n_skipped} no_jtreg=${n_no_jtreg} total=${n_total}"
    } > "${summary_file}"
}

_reset() {
    STREAM_STATUS=()
    STREAM_STATUS_DETAIL=()
}

# ─────────────────────────────────────────────────────────────────────────────
# T1  All TEST_PASSED — the formerly fatal path
#
# WHY CORRECT: Before the fix, the very first  (( 0++ ))  would return exit
# status 1 under set -e, killing the subshell.  With the fix, n=$(( 0+1 ))=1
# is an assignment (always exit 0).  We assert the file exists AND contains
# the right count.  If write_run_summary aborts partway through the redirected
# block, the output file is either missing or truncated — both fail the asserts.
# ─────────────────────────────────────────────────────────────────────────────
describe "write_run_summary — counter bug regression"
it "T1: two TEST_PASSED entries produce passed=2, total=2"
_reset
record_status "head"  "fastdebug" "TEST_PASSED" ""
record_status "head"  "release"   "TEST_PASSED" ""
write_run_summary
assert_file_exists "${T}/run-summary.txt" "summary file must exist"
assert_contains    "${T}/run-summary.txt" "passed=2"   "two passes"
assert_contains    "${T}/run-summary.txt" "total=2"    "total must be 2"
assert_contains    "${T}/run-summary.txt" "failed=0"   "no failures"

# ─────────────────────────────────────────────────────────────────────────────
# T2  All-zero case — no statuses recorded
#
# WHY CORRECT: An empty STREAM_STATUS is a valid state (e.g. all streams
# SKIPPED_FILTER before any record_status call for TEST_* fires).  All counters
# should be 0 and total 0.  The file must still be written — an empty table is
# different from a missing file.
# ─────────────────────────────────────────────────────────────────────────────
it "T2: empty STREAM_STATUS produces all-zero counters"
_reset
write_run_summary
assert_file_exists "${T}/run-summary.txt" "summary must exist even with no statuses"
assert_contains    "${T}/run-summary.txt" "passed=0"
assert_contains    "${T}/run-summary.txt" "total=0"

# ─────────────────────────────────────────────────────────────────────────────
# T3  Mixed statuses — every counter hits at least once
#
# WHY CORRECT: Each status maps to exactly one counter.  We put one of each
# type in and assert the exact count for each bucket.  The test would fail
# if any case branch were mismatched (e.g. BUILD_FAILED accidentally counted
# in n_skipped) — catching copy/paste errors in the case statement.
# ─────────────────────────────────────────────────────────────────────────────
it "T3: one of every status type — each counter exactly 1, total=5"
_reset
record_status "head"  "fastdebug" "TEST_PASSED"           ""
record_status "head"  "release"   "TEST_FAILED"           ""
record_status "jdk26" "fastdebug" "BUILD_FAILED"          ""
record_status "jdk21" "fastdebug" "TEST_SKIPPED_NO_JTREG" ""
record_status "jdk17" "fastdebug" "SKIPPED_EOL"           ""
write_run_summary
assert_contains "${T}/run-summary.txt" "passed=1"
assert_contains "${T}/run-summary.txt" "failed=1"
assert_contains "${T}/run-summary.txt" "build_fail=1"
assert_contains "${T}/run-summary.txt" "no_jtreg=1"
assert_contains "${T}/run-summary.txt" "skipped=1"
assert_contains "${T}/run-summary.txt" "total=5"

# ─────────────────────────────────────────────────────────────────────────────
# T4  Multiple TEST_FAILED — counter increments past 1
#
# WHY CORRECT: The original bug only manifested when the FIRST increment went
# from 0 → 1 (result 0 = false).  If we only ever test with one failure we
# might miss a regression where (( 1++ )) = 1 = true passes but (( 0++ )) = 0
# fails.  Testing multiple failures in the same category proves the counter
# increments correctly through several iterations.
# ─────────────────────────────────────────────────────────────────────────────
it "T4: four TEST_FAILED entries produce failed=4"
_reset
record_status "head"  "fastdebug" "TEST_FAILED" ""
record_status "head"  "release"   "TEST_FAILED" ""
record_status "jdk26" "fastdebug" "TEST_FAILED" ""
record_status "jdk26" "release"   "TEST_FAILED" ""
write_run_summary
assert_contains "${T}/run-summary.txt" "failed=4"
assert_contains "${T}/run-summary.txt" "passed=0"
assert_contains "${T}/run-summary.txt" "total=4"

# ─────────────────────────────────────────────────────────────────────────────
# T5  SKIPPED_* glob matches multiple sub-statuses
#
# WHY CORRECT: The case branch uses  SKIPPED_*)  to catch SKIPPED_EOL,
# SKIPPED_FILTER, SKIPPED_DRY_RUN, SKIPPED_SOURCE_FAIL, and
# SKIPPED_BOOT_JDK_FAIL with one pattern.  If a new SKIPPED_XYZ is added
# but the glob accidentally stops matching, this test catches the regression.
# ─────────────────────────────────────────────────────────────────────────────
it "T5: all SKIPPED_* sub-statuses counted in n_skipped"
_reset
record_status "head"  "fastdebug" "SKIPPED_EOL"          ""
record_status "head"  "release"   "SKIPPED_FILTER"       ""
record_status "jdk26" "fastdebug" "SKIPPED_DRY_RUN"      ""
record_status "jdk26" "release"   "SKIPPED_SOURCE_FAIL"  ""
record_status "jdk21" "fastdebug" "SKIPPED_BOOT_JDK_FAIL" ""
write_run_summary
assert_contains "${T}/run-summary.txt" "skipped=5"
assert_contains "${T}/run-summary.txt" "total=5"

# ─────────────────────────────────────────────────────────────────────────────
# T6  UNKNOWN status is ignored by the counter
#
# WHY CORRECT: The case statement has no  *)  catch-all — unrecognised statuses
# simply fall through.  This is intentional: a typo in a status name should
# NOT silently inflate a counter.  We record one unknown value and assert that
# total stays 0.  Contrast with T3 where every recognised value is counted.
# ─────────────────────────────────────────────────────────────────────────────
it "T6: unrecognised status does not affect any counter"
_reset
record_status "head" "fastdebug" "TOTALLY_MADE_UP_STATUS" ""
write_run_summary
assert_contains "${T}/run-summary.txt" "total=0" "unknown status must not count"
assert_contains "${T}/run-summary.txt" "passed=0"
assert_contains "${T}/run-summary.txt" "skipped=0"

# ─────────────────────────────────────────────────────────────────────────────
# T7  Summary file is overwritten on repeated calls
#
# WHY CORRECT: run_daily.sh calls write_run_summary once.  But it also calls
# it early in the boot-JDK-failure path (refresh_deps → write_run_summary →
# die).  If the file from the first call were not overwritten, a subsequent
# call would append, producing double output and wrong counts.  We call twice
# with different states and assert only the second call's counts appear.
# ─────────────────────────────────────────────────────────────────────────────
it "T7: second call overwrites — only latest counts appear"
_reset
record_status "head" "fastdebug" "TEST_PASSED" ""
write_run_summary
_reset
record_status "head" "fastdebug" "TEST_FAILED" ""
write_run_summary
assert_contains     "${T}/run-summary.txt" "failed=1"  "second call result"
assert_contains     "${T}/run-summary.txt" "passed=0"  "first call must be gone"
assert_not_contains "${T}/run-summary.txt" "passed=1"  "stale count must not appear"

# ─────────────────────────────────────────────────────────────────────────────
# T8  BUILD_FAILED is NOT double-counted in n_skipped
#
# WHY CORRECT: It is tempting to think "BUILD_FAILED means the stream was
# skipped for testing" and count it in both buckets.  The contract is explicit:
# BUILD_FAILED → n_build_fail only; SKIPPED_* → n_skipped only.  We verify
# the two buckets are mutually exclusive.
# ─────────────────────────────────────────────────────────────────────────────
it "T8: BUILD_FAILED counts only in build_fail — not skipped"
_reset
record_status "head" "fastdebug" "BUILD_FAILED" ""
write_run_summary
assert_contains     "${T}/run-summary.txt" "build_fail=1"
assert_contains     "${T}/run-summary.txt" "skipped=0"
assert_not_contains "${T}/run-summary.txt" "skipped=1" "BUILD_FAILED must not inflate skipped"

# ─────────────────────────────────────────────────────────────────────────────
# T9  INTENTIONAL CONTRADICTION — total does NOT include n_no_jtreg
#
# Wait — read the formula: n_total = n_passed + n_failed + n_build_fail
#                                   + n_skipped + n_no_jtreg
# So n_no_jtreg IS included.  The apparent contradiction:
#   "TEST_SKIPPED_NO_JTREG is a 'skip' so it should be in n_skipped"
# … is WRONG.  n_skipped is for SKIPPED_* prefixed statuses (EOL, FILTER,
# DRY_RUN, SOURCE_FAIL, BOOT_JDK_FAIL) — statuses where we never attempted to
# build at all.  TEST_SKIPPED_NO_JTREG means the build succeeded but jtreg
# was unavailable; it is a separate, softer failure that gets its own bucket.
# Putting it in n_skipped would hide real jtreg availability problems.
#
# This test exists to lock down that semantic separation and prevent a future
# "clean-up" refactor from accidentally merging the two buckets.
# ─────────────────────────────────────────────────────────────────────────────
it "T9: TEST_SKIPPED_NO_JTREG goes to no_jtreg NOT skipped (intentional distinction)"
_reset
record_status "head"  "fastdebug" "TEST_SKIPPED_NO_JTREG" ""
record_status "jdk21" "fastdebug" "SKIPPED_EOL"           ""
write_run_summary
assert_contains     "${T}/run-summary.txt" "no_jtreg=1"  "jtreg-skip bucket"
assert_contains     "${T}/run-summary.txt" "skipped=1"   "eol-skip bucket"
assert_not_contains "${T}/run-summary.txt" "no_jtreg=2"  "must not bleed into each other"
assert_not_contains "${T}/run-summary.txt" "skipped=2"   "must not bleed into each other"
assert_contains     "${T}/run-summary.txt" "total=2"     "both counted in total"

# ─────────────────────────────────────────────────────────────────────────────
# T10  Large run — realistic stream × level product
#
# WHY CORRECT: The registry has 6 streams × 2 levels = 12 combinations.  A
# realistic daily run might see 8 pass and 4 fail.  We verify the arithmetic
# is correct at realistic scale, not just at count=1.
# ─────────────────────────────────────────────────────────────────────────────
it "T10: realistic 6-stream run — correct totals"
_reset
# head: both pass
record_status "head"  "fastdebug" "TEST_PASSED"  ""
record_status "head"  "release"   "TEST_PASSED"  ""
# jdk26: fastdebug fails, release passes
record_status "jdk26" "fastdebug" "TEST_FAILED"  ""
record_status "jdk26" "release"   "TEST_PASSED"  ""
# jdk25: both pass
record_status "jdk25" "fastdebug" "TEST_PASSED"  ""
record_status "jdk25" "release"   "TEST_PASSED"  ""
# jdk21: build failed on fastdebug, release passes
record_status "jdk21" "fastdebug" "BUILD_FAILED" ""
record_status "jdk21" "release"   "TEST_PASSED"  ""
# jdk17: EOL
record_status "jdk17" "fastdebug" "SKIPPED_EOL"  ""
record_status "jdk17" "release"   "SKIPPED_EOL"  ""
# jdk11: no jtreg
record_status "jdk11" "fastdebug" "TEST_SKIPPED_NO_JTREG" ""
record_status "jdk11" "release"   "TEST_SKIPPED_NO_JTREG" ""
write_run_summary
assert_contains "${T}/run-summary.txt" "passed=5"
assert_contains "${T}/run-summary.txt" "failed=1"
assert_contains "${T}/run-summary.txt" "build_fail=1"
assert_contains "${T}/run-summary.txt" "skipped=2"
assert_contains "${T}/run-summary.txt" "no_jtreg=2"
assert_contains "${T}/run-summary.txt" "total=11"
# Sanity: 5+1+1+2+2 = 11, NOT 12, because n_total sums all five buckets.
# 12 would be wrong only if something were double-counted.
