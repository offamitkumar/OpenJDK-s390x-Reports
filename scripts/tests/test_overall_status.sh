#!/usr/bin/env bash
# =============================================================================
# test_overall_status.sh
#
# Tests for the  _overall  calculation in run_daily.sh main().
#
# THE LOGIC BEING TESTED
# ──────────────────────
# In main(), after process_streams():
#
#   local _overall="PASS"
#   for key in "${!STREAM_STATUS[@]}"; do
#       case "${STREAM_STATUS[${key}]}" in
#           BUILD_FAILED|TEST_FAILED|SKIPPED_BOOT_JDK_FAIL)
#               _overall="FAIL"; break ;;
#       esac
#   done
#
# _overall is then passed to ci_notify as the fourth argument, which controls
# the [PASS] / [FAIL] subject prefix and the ON_SUCCESS / ON_FAILURE guard.
#
# WHY THESE TESTS ARE CORRECT
# ────────────────────────────
# We test the exact  case  expression in isolation by extracting it into a
# helper function compute_overall() that mirrors the production logic exactly.
# Any change to which statuses trigger FAIL must be reflected here.
#
# INTENTIONAL CONTRADICTION IN T4
# ─────────────────────────────────
# TEST_SKIPPED_NO_JTREG does NOT set _overall=FAIL even though tests didn't
# run.  One might argue this is wrong — "no tests ran, that's a failure".
# The design intent is different: jtreg unavailability is a soft infrastructure
# issue, not a code defect.  The run summary marks it clearly as
# TEST_SKIPPED_NO_JTREG.  Making it FAIL would cause alert fatigue on hosts
# where jtreg is intermittently unavailable (e.g. network issues during dep
# download).  This test locks down that intentional decision.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Mirror of the _overall computation from run_daily.sh main().
# We test the logic, not the variable name.
# ---------------------------------------------------------------------------
declare -A STREAM_STATUS=()

record_status() {
    STREAM_STATUS["${1}/${2}"]="${3}"
}

compute_overall() {
    local _overall="PASS"
    for key in "${!STREAM_STATUS[@]}"; do
        case "${STREAM_STATUS[${key}]}" in
            BUILD_FAILED|TEST_FAILED|SKIPPED_BOOT_JDK_FAIL)
                _overall="FAIL"; break ;;
        esac
    done
    echo "${_overall}"
}

_reset() { STREAM_STATUS=(); }

# ─────────────────────────────────────────────────────────────────────────────
# T1  All TEST_PASSED → overall PASS
# ─────────────────────────────────────────────────────────────────────────────
describe "overall status — PASS conditions"
it "T1: all TEST_PASSED → PASS"
_reset
record_status "head"  "fastdebug" "TEST_PASSED"
record_status "head"  "release"   "TEST_PASSED"
record_status "jdk26" "fastdebug" "TEST_PASSED"
assert_eq "$(compute_overall)" "PASS"

# ─────────────────────────────────────────────────────────────────────────────
# T2  Any TEST_FAILED → FAIL
# ─────────────────────────────────────────────────────────────────────────────
describe "overall status — FAIL triggers"
it "T2: one TEST_FAILED among multiple PASS → FAIL"
_reset
record_status "head"  "fastdebug" "TEST_PASSED"
record_status "head"  "release"   "TEST_FAILED"   # ← the one failure
record_status "jdk26" "fastdebug" "TEST_PASSED"
assert_eq "$(compute_overall)" "FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T3  Any BUILD_FAILED → FAIL
# ─────────────────────────────────────────────────────────────────────────────
it "T3: one BUILD_FAILED → FAIL"
_reset
record_status "head"  "fastdebug" "TEST_PASSED"
record_status "jdk21" "fastdebug" "BUILD_FAILED"
assert_eq "$(compute_overall)" "FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T4  TEST_SKIPPED_NO_JTREG alone → PASS (intentional, see header)
# ─────────────────────────────────────────────────────────────────────────────
it "T4: TEST_SKIPPED_NO_JTREG alone → PASS (soft infra issue, not a code failure)"
_reset
record_status "head" "fastdebug" "TEST_SKIPPED_NO_JTREG"
record_status "head" "release"   "TEST_SKIPPED_NO_JTREG"
assert_eq "$(compute_overall)" "PASS" \
    "jtreg missing is infra noise — must not flip to FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T5  SKIPPED_EOL, SKIPPED_FILTER → PASS
#
# WHY CORRECT: Streams skipped because they are EOL or excluded by --stream
# filter represent intentional omissions, not failures.  If they set FAIL, a
# filter run (--stream head) would always show FAIL for all other streams,
# making the subject misleading.
# ─────────────────────────────────────────────────────────────────────────────
it "T5: SKIPPED_EOL and SKIPPED_FILTER do not set FAIL"
_reset
record_status "jdk17" "fastdebug" "SKIPPED_EOL"
record_status "jdk11" "fastdebug" "SKIPPED_FILTER"
record_status "head"  "fastdebug" "TEST_PASSED"
assert_eq "$(compute_overall)" "PASS"

# ─────────────────────────────────────────────────────────────────────────────
# T6  SKIPPED_BOOT_JDK_FAIL → FAIL
#
# WHY CORRECT: A missing boot JDK means NOTHING built and NO tests ran.  This
# is a hard infrastructure failure.  The engineer must be alerted.  Contrast
# with T4/T5 where only part of the run was skipped.
# ─────────────────────────────────────────────────────────────────────────────
it "T6: SKIPPED_BOOT_JDK_FAIL → FAIL (hard infra failure)"
_reset
for lbl in head jdk26 jdk21 jdk17 jdk11; do
    record_status "${lbl}" "fastdebug" "SKIPPED_BOOT_JDK_FAIL"
    record_status "${lbl}" "release"   "SKIPPED_BOOT_JDK_FAIL"
done
assert_eq "$(compute_overall)" "FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T7  SKIPPED_SOURCE_FAIL alone → PASS (currently, not a FAIL trigger)
#
# WHY CORRECT (and intentionally debatable):
# Source failure (git pull failed) is currently NOT a FAIL trigger.  This is
# arguably a design gap — if HEAD failed to clone, the run produced nothing
# useful.  However, the current logic only marks FAIL for BUILD_FAILED,
# TEST_FAILED, and SKIPPED_BOOT_JDK_FAIL.  We document this boundary
# explicitly so a future change to add SKIPPED_SOURCE_FAIL to the FAIL set
# is a conscious, visible decision.
# ─────────────────────────────────────────────────────────────────────────────
it "T7: SKIPPED_SOURCE_FAIL alone → PASS (current design; see comment for trade-off)"
_reset
record_status "head" "fastdebug" "SKIPPED_SOURCE_FAIL"
assert_eq "$(compute_overall)" "PASS" \
    "currently source-fail does not set FAIL — document if this changes"

# ─────────────────────────────────────────────────────────────────────────────
# T8  Empty STREAM_STATUS → PASS (no runs at all)
#
# WHY CORRECT: If no streams ran (e.g. all filtered out), there are no failures
# to report.  PASS with an empty run summary is correct and expected for a
# --dry-run invocation.  The run-summary.txt will show SKIPPED_DRY_RUN for
# every stream, making the "no real work done" status clear from the content.
# ─────────────────────────────────────────────────────────────────────────────
it "T8: empty STREAM_STATUS → PASS"
_reset
assert_eq "$(compute_overall)" "PASS" "no statuses means no failures"

# ─────────────────────────────────────────────────────────────────────────────
# T9  Mixed: PASS + FAIL → result is FAIL (not averaged, not best-case)
#
# WHY CORRECT: The overall status uses OR semantics: any failure = overall FAIL.
# This matches standard CI convention.  If we used best-case (any pass = PASS),
# a run with 5 passing streams and 1 failing stream would report PASS and the
# failure would be invisible in the email subject.
# ─────────────────────────────────────────────────────────────────────────────
it "T9: 5 PASS + 1 TEST_FAILED → FAIL (OR semantics, not averaging)"
_reset
record_status "head"  "fastdebug" "TEST_PASSED"
record_status "head"  "release"   "TEST_PASSED"
record_status "jdk26" "fastdebug" "TEST_PASSED"
record_status "jdk26" "release"   "TEST_PASSED"
record_status "jdk21" "fastdebug" "TEST_PASSED"
record_status "jdk21" "release"   "TEST_FAILED"   # ← one failure in 6
assert_eq "$(compute_overall)" "FAIL" "one failure out of six must set FAIL"
