#!/usr/bin/env bash
# =============================================================================
# harness.sh — Shared test helpers sourced by every test_*.sh suite.
#
# Provides:
#   assert_eq       VAL EXPECTED  [MSG]
#   assert_ne       VAL UNEXPECTED [MSG]
#   assert_contains FILE PATTERN  [MSG]
#   assert_not_contains FILE PATTERN [MSG]
#   assert_file_exists   PATH [MSG]
#   assert_file_missing  PATH [MSG]
#   assert_exit_zero     CMD... [-- MSG]
#   assert_exit_nonzero  CMD... [-- MSG]
#   pass MSG
#   fail MSG
#
# Each suite gets an isolated temp directory: $T  (auto-cleaned on EXIT).
#
# Usage in a test file:
#   source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
#   describe "my feature"
#   it "does something"
#   assert_eq "$(some_func)" "expected"
# =============================================================================

# Require bash 4+ for associative arrays
if (( BASH_VERSINFO[0] < 4 )); then
    echo "SKIP: bash 4+ required (have ${BASH_VERSION})" >&2
    exit 0
fi

set -euo pipefail

# ---------------------------------------------------------------------------
# Isolated temp directory — cleaned on EXIT
# ---------------------------------------------------------------------------
T="$(mktemp -d)"
_HARNESS_CLEANUP() { rm -rf "${T}"; }
trap _HARNESS_CLEANUP EXIT

# ---------------------------------------------------------------------------
# Test accounting
# ---------------------------------------------------------------------------
_SUITE_PASS=0
_SUITE_FAIL=0
_CURRENT_DESCRIBE=""
_CURRENT_IT=""

describe() { _CURRENT_DESCRIBE="$*"; }
it()       { _CURRENT_IT="$*"; }

# ---------------------------------------------------------------------------
# Internal: record a result
# ---------------------------------------------------------------------------
_pass() {
    _SUITE_PASS=$(( _SUITE_PASS + 1 ))
}

_fail() {
    local msg="$1"
    _SUITE_FAIL=$(( _SUITE_FAIL + 1 ))
    local loc="${_CURRENT_DESCRIBE:+${_CURRENT_DESCRIBE} > }${_CURRENT_IT:+${_CURRENT_IT}: }"
    echo "  FAIL: ${loc}${msg}" >&2
}

# ---------------------------------------------------------------------------
# At EXIT: report and propagate failure
# ---------------------------------------------------------------------------
_HARNESS_EXIT() {
    local rc=$?
    # If the script itself errored (set -e), count that as one extra failure
    if [[ ${rc} -ne 0 && ${_SUITE_FAIL} -eq 0 ]]; then
        echo "  FAIL: unexpected exit ${rc} (set -e triggered?)" >&2
        _SUITE_FAIL=$(( _SUITE_FAIL + 1 ))
    fi
    rm -rf "${T}"
    if [[ ${_SUITE_FAIL} -gt 0 ]]; then
        echo "  ${_SUITE_PASS} passed, ${_SUITE_FAIL} FAILED" >&2
        exit 1
    fi
    exit 0
}
# Replace the simple cleanup trap with the reporting one
trap _HARNESS_EXIT EXIT

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# assert_eq VAL EXPECTED [MSG]
assert_eq() {
    local val="$1" expected="$2" msg="${3:-}"
    if [[ "${val}" == "${expected}" ]]; then
        _pass
    else
        _fail "${msg:+${msg} — }got $(printf '%q' "${val}"), want $(printf '%q' "${expected}")"
    fi
}

# assert_ne VAL UNEXPECTED [MSG]
assert_ne() {
    local val="$1" unexpected="$2" msg="${3:-}"
    if [[ "${val}" != "${unexpected}" ]]; then
        _pass
    else
        _fail "${msg:+${msg} — }value should not be $(printf '%q' "${unexpected}")"
    fi
}

# assert_contains FILE PATTERN [MSG]
# PATTERN is a grep -F literal string
assert_contains() {
    local file="$1" pattern="$2" msg="${3:-}"
    if grep -qF "${pattern}" "${file}" 2>/dev/null; then
        _pass
    else
        _fail "${msg:+${msg} — }pattern $(printf '%q' "${pattern}") not found in ${file}"
    fi
}

# assert_not_contains FILE PATTERN [MSG]
assert_not_contains() {
    local file="$1" pattern="$2" msg="${3:-}"
    if ! grep -qF "${pattern}" "${file}" 2>/dev/null; then
        _pass
    else
        _fail "${msg:+${msg} — }pattern $(printf '%q' "${pattern}") should NOT be in ${file}"
    fi
}

# assert_file_exists PATH [MSG]
assert_file_exists() {
    local path="$1" msg="${2:-}"
    if [[ -e "${path}" ]]; then
        _pass
    else
        _fail "${msg:+${msg} — }expected file/dir: ${path}"
    fi
}

# assert_file_missing PATH [MSG]
assert_file_missing() {
    local path="$1" msg="${2:-}"
    if [[ ! -e "${path}" ]]; then
        _pass
    else
        _fail "${msg:+${msg} — }expected ${path} to not exist"
    fi
}

# assert_exit_zero CMD [args...]
# Runs CMD; asserts exit 0.
assert_exit_zero() {
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ ${rc} -eq 0 ]]; then
        _pass
    else
        _fail "expected exit 0 from: $* (got ${rc})"
    fi
}

# assert_exit_nonzero CMD [args...]
# Runs CMD; asserts exit != 0.
assert_exit_nonzero() {
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        _pass
    else
        _fail "expected non-zero exit from: $* (got 0)"
    fi
}

# pass MSG  — unconditional pass (for documenting intentional behaviour)
pass() { _pass; }

# fail MSG  — unconditional fail
fail() { _fail "${1:-unconditional fail}"; }
