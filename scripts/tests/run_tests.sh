#!/usr/bin/env bash
# =============================================================================
# run_tests.sh — Test runner
#
# Discovers and runs every test_*.sh file in this directory.
# Prints a PASS/FAIL summary and exits non-zero if any suite failed.
#
# Usage:
#   bash scripts/tests/run_tests.sh
# =============================================================================
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

passed=0
failed=0
failed_names=()

for suite in "${TESTS_DIR}"/test_*.sh; do
    name="$(basename "${suite}")"
    printf "  %-50s " "${name}"
    output="$(bash "${suite}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]]; then
        echo "PASS"
        (( passed++ )) || true
    else
        echo "FAIL (exit ${rc})"
        failed_names+=("${name}")
        (( failed++ )) || true
        # Re-print the failing output indented so it's visible in CI logs
        echo "${output}" | sed 's/^/    | /'
    fi
done

echo ""
echo "Results: ${passed} passed, ${failed} failed"

if [[ ${failed} -gt 0 ]]; then
    echo "FAILED suites:"
    for n in "${failed_names[@]}"; do echo "  - ${n}"; done
    exit 1
fi
exit 0
