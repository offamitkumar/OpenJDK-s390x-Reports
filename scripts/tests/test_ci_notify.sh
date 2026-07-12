#!/usr/bin/env bash
# =============================================================================
# test_ci_notify.sh
#
# Tests for ci_notify() in notify.sh.
#
# STRATEGY
# ────────
# ci_notify() ends by calling _notify_send, which calls the real  mail  or
# sendmail  binary.  We do NOT want to send real email in tests.  Instead we
# override _notify_send with a stub that writes its arguments to a file so we
# can assert on what would have been sent.
#
# This is the standard "seam" technique: inject a test double at the boundary
# between the unit under test (ci_notify) and the external system (mail).
#
# WHY THESE TESTS ARE CORRECT
# ────────────────────────────
# ci_notify has three clear responsibilities:
#   1. Guard: skip if CI_NOTIFY_EMAIL is empty, or if the success/failure
#      flags say to skip.
#   2. Build subject and body.
#   3. Hand off to _notify_send.
#
# Tests T1–T4 cover the guard logic.
# Tests T5–T8 cover the subject/body content.
# Tests T9–T10 cover edge-cases (no triples, empty commit-info).
#
# INTENTIONAL CONTRADICTION IN T3/T4
# ────────────────────────────────────
# T3 asserts that CI_NOTIFY_ON_SUCCESS=false suppresses notification on PASS.
# T4 asserts that CI_NOTIFY_ON_FAILURE=false suppresses notification on FAIL.
# One might argue "then no email is ever sent" — but that's wrong.  The flags
# are independent: you can set ON_SUCCESS=false while ON_FAILURE=true, which
# sends only failure emails.  T3 and T4 test each flag in isolation.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load config.sh for JDK_STREAMS / BUILD_LEVELS
source "${SCRIPT_DIR}/config.sh"

# Load notify.sh (defines ci_notify and helpers)
source "${SCRIPT_DIR}/notify.sh"

# ---------------------------------------------------------------------------
# Test double: override _notify_send so no real mail is sent.
# Records: subject, body, and first recipient in files under $T.
# ---------------------------------------------------------------------------
_notify_send() {
    local subject="$1"
    local body="$2"
    shift 2
    local recipients=("$@")
    echo "${subject}"        > "${T}/sent_subject"
    printf '%s' "${body}"    > "${T}/sent_body"
    echo "${recipients[0]}"  > "${T}/sent_recipient"
    echo "SENT"              > "${T}/send_called"
}

_reset_notify() {
    rm -f "${T}/sent_subject" "${T}/sent_body" \
          "${T}/sent_recipient" "${T}/send_called"
    # Reset to known defaults
    CI_NOTIFY_EMAIL="test@example.com"
    CI_NOTIFY_ON_SUCCESS="true"
    CI_NOTIFY_ON_FAILURE="true"
    CI_NOTIFY_FROM="ci@test"
}

# Minimal fake summary and commit-info files
SUMMARY_FILE="${T}/run-summary.txt"
COMMIT_FILE="${T}/commit-info.txt"
echo "Run summary content" > "${SUMMARY_FILE}"
echo "Commit info content" > "${COMMIT_FILE}"

# One fake triple: stream:src_dir:level:build_status
FAKE_TRIPLE="head:${T}/src:fastdebug:TEST_PASSED"

# ─────────────────────────────────────────────────────────────────────────────
# T1  Empty CI_NOTIFY_EMAIL → no email sent
#
# WHY CORRECT: An empty recipient list means the operator hasn't configured
# email yet.  Sending to an empty address would either error or deliver to
# nobody.  The correct behaviour is silence.  We assert _notify_send was NOT
# called (send_called file absent).
# ─────────────────────────────────────────────────────────────────────────────
describe "ci_notify — guard: CI_NOTIFY_EMAIL"
it "T1: empty CI_NOTIFY_EMAIL → _notify_send not called"
_reset_notify
CI_NOTIFY_EMAIL=""
ci_notify "daily" "test run" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_file_missing "${T}/send_called" "must not send when email not configured"

# ─────────────────────────────────────────────────────────────────────────────
# T2  Set CI_NOTIFY_EMAIL → email IS sent
#
# WHY CORRECT: This is the positive counterpart to T1.  Without T2, passing T1
# alone could mean _notify_send is broken and never gets called regardless of
# the email setting.  T2 confirms the happy path works.
# ─────────────────────────────────────────────────────────────────────────────
it "T2: set CI_NOTIFY_EMAIL → _notify_send called"
_reset_notify
ci_notify "daily" "test run" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_file_exists "${T}/send_called" "must send when email is configured"
assert_eq "$(cat "${T}/sent_recipient")" "test@example.com" "correct recipient"

# ─────────────────────────────────────────────────────────────────────────────
# T3  CI_NOTIFY_ON_SUCCESS=false suppresses PASS notifications
#
# WHY CORRECT: The flag's purpose is to allow "only email me on failures".
# We set overall_status=PASS and ON_SUCCESS=false and assert no send.
# Note: ON_FAILURE=true (default) — this only suppresses the success email,
# NOT failure emails.  The flags are orthogonal.
# ─────────────────────────────────────────────────────────────────────────────
describe "ci_notify — guard: ON_SUCCESS / ON_FAILURE"
it "T3: CI_NOTIFY_ON_SUCCESS=false suppresses PASS email"
_reset_notify
CI_NOTIFY_ON_SUCCESS="false"
ci_notify "daily" "test" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_file_missing "${T}/send_called" "PASS email must be suppressed"

# ─────────────────────────────────────────────────────────────────────────────
# T4  CI_NOTIFY_ON_FAILURE=false suppresses FAIL notifications
# ─────────────────────────────────────────────────────────────────────────────
it "T4: CI_NOTIFY_ON_FAILURE=false suppresses FAIL email"
_reset_notify
CI_NOTIFY_ON_FAILURE="false"
ci_notify "daily" "test" "${SUMMARY_FILE}" "FAIL" "" "${FAKE_TRIPLE}"
assert_file_missing "${T}/send_called" "FAIL email must be suppressed"

# ─────────────────────────────────────────────────────────────────────────────
# T5  PASS overall → subject contains [PASS]
#
# WHY CORRECT: The engineer reading the email inbox must be able to triage
# without opening each email.  The [PASS]/[FAIL] prefix in the subject is the
# primary signal.  We assert its presence for both overall statuses.
# ─────────────────────────────────────────────────────────────────────────────
describe "ci_notify — subject line"
it "T5: overall=PASS → subject contains [PASS]"
_reset_notify
ci_notify "daily" "head (2026-July-11)" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_contains "${T}/sent_subject" "[PASS]" "PASS subject prefix"
assert_not_contains "${T}/sent_subject" "[FAIL]" "must not contain FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T6  FAIL overall → subject contains [FAIL]
# ─────────────────────────────────────────────────────────────────────────────
it "T6: overall=FAIL → subject contains [FAIL]"
_reset_notify
ci_notify "daily" "head (2026-July-11)" "${SUMMARY_FILE}" "FAIL" "" "${FAKE_TRIPLE}"
assert_contains "${T}/sent_subject" "[FAIL]"
assert_not_contains "${T}/sent_subject" "[PASS]"

# ─────────────────────────────────────────────────────────────────────────────
# T7  run_kind label appears in subject
#
# WHY CORRECT: The engineer needs to know at a glance whether this is a daily
# automated run or a manual one.  "daily" → "Daily CI", "manual" → "Manual run",
# "pr" → "PR test".  We test all three kinds.
# ─────────────────────────────────────────────────────────────────────────────
it "T7a: run_kind=daily → 'Daily CI' in subject"
_reset_notify
ci_notify "daily" "suffix" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_contains "${T}/sent_subject" "Daily CI"

it "T7b: run_kind=manual → 'Manual run' in subject"
_reset_notify
ci_notify "manual" "suffix" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_contains "${T}/sent_subject" "Manual run"

it "T7c: run_kind=pr → 'PR test' in subject"
_reset_notify
ci_notify "pr" "PR #999" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_contains "${T}/sent_subject" "PR test"

# ─────────────────────────────────────────────────────────────────────────────
# T8  Summary file content appears in body
#
# WHY CORRECT: The summary is the main content of the email.  If it were
# missing, the email would be useless.  We write a unique sentinel string to
# the summary file and assert it appears in the email body.
# ─────────────────────────────────────────────────────────────────────────────
describe "ci_notify — body content"
it "T8: run-summary.txt content included in body"
_reset_notify
echo "UNIQUE_SENTINEL_12345" > "${SUMMARY_FILE}"
ci_notify "daily" "suffix" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_contains "${T}/sent_body" "UNIQUE_SENTINEL_12345" "summary must appear in body"

# ─────────────────────────────────────────────────────────────────────────────
# T9  commit_info_file=""  → body does not crash / Commit section absent
#
# WHY CORRECT: Daily runs build a combined commit-info file; PR runs use the
# pr-info.txt.  But for collect re-runs or edge cases the path might be "".
# We assert ci_notify does not crash when commit_info_file is empty, and that
# the "Commit Information" section is simply absent from the body.
# ─────────────────────────────────────────────────────────────────────────────
it "T9: empty commit_info_file does not crash; no Commit section in body"
_reset_notify
ci_notify "daily" "suffix" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_file_exists "${T}/send_called" "must still send"
assert_not_contains "${T}/sent_body" "Commit Information" \
    "Commit section must be absent when commit_info_file is empty"

# ─────────────────────────────────────────────────────────────────────────────
# T10  commit_info_file provided → Commit Information section present
#
# WHY CORRECT: The complement of T9.  When the file is provided and contains
# content, that content must appear in the body.  This is the normal daily-run
# path.  Without T10, T9 alone could mask a bug where the section is always
# absent.
# ─────────────────────────────────────────────────────────────────────────────
it "T10: non-empty commit_info_file → Commit Information in body"
_reset_notify
echo "git bisect start abc123 def456" > "${COMMIT_FILE}"
ci_notify "daily" "suffix" "${SUMMARY_FILE}" "PASS" "${COMMIT_FILE}" "${FAKE_TRIPLE}"
assert_contains "${T}/sent_body" "Commit Information" "section header must appear"
assert_contains "${T}/sent_body" "git bisect start" "commit content must appear"

# ─────────────────────────────────────────────────────────────────────────────
# T11  Missing summary file → body contains fallback message, not a crash
#
# WHY CORRECT: If the pipeline aborted before writing run-summary.txt (e.g. a
# die() call in an early stage), ci_notify is still called from the EXIT trap
# or post-run code.  It must not crash — it must include a "not found" notice
# in the body instead.
# ─────────────────────────────────────────────────────────────────────────────
it "T11: missing summary file → fallback text in body, no crash"
_reset_notify
ci_notify "daily" "suffix" "${T}/nonexistent-summary.txt" "FAIL" "" "${FAKE_TRIPLE}"
assert_file_exists "${T}/send_called" "email must still be sent"
assert_contains "${T}/sent_body" "not found" "fallback text must appear in body"

# ─────────────────────────────────────────────────────────────────────────────
# T12  Footer always present
#
# WHY CORRECT: The footer contains the hostname and UTC timestamp, which is
# essential for correlating the email with the pipeline.log on the server.
# We assert the footer sentinel "OpenJDK s390x CI" appears regardless of
# overall status or number of triples.
# ─────────────────────────────────────────────────────────────────────────────
it "T12: email body always ends with CI footer"
_reset_notify
ci_notify "daily" "suffix" "${SUMMARY_FILE}" "PASS" "" "${FAKE_TRIPLE}"
assert_contains "${T}/sent_body" "OpenJDK s390x CI" "footer must always appear"
