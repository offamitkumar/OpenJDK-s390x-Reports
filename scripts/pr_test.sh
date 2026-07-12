#!/usr/bin/env bash
# =============================================================================
# pr_test.sh — Community PR tester for OpenJDK s390x CI
#
# Fetches an upstream OpenJDK pull request, builds it in fastdebug mode (or
# release, or both), runs the full tier1 test suite, and stores the results
# under PRs/<number>/<YYYYMMDD_HHMMSS>/.
#
# USAGE
# ─────
#   bash scripts/pr_test.sh --pr <NUMBER_OR_URL> [options]
#
# OPTIONS
# ───────
#   --pr NUMBER|URL   PR number (e.g. 31868) or full GitHub URL
#                     (e.g. https://github.com/openjdk/jdk/pull/31868).
#                     Required.
#
#   --level LEVEL     Build / test level: fastdebug | release | both
#                     Default: fastdebug
#
#   --skip-deps       Skip boot JDK + jtreg download (use cached).
#
#   --no-push         Write report files locally but do not git commit/push.
#
#   --dry-run         Print what would happen; do nothing.
#
# OUTPUT LAYOUT
# ─────────────
#   PRs/<number>/<YYYYMMDD_HHMMSS>/
#     run.log               — full run output (tee'd here)
#     pr-info.txt           — PR number, URL, HEAD commit fetched
#     fastdebug/            — (present when level is fastdebug or both)
#       build.log
#       build-diagnosis.txt
#       test-summary.txt
#       newfailures.txt
#       other_errors.txt
#       run-metadata.txt
#       test-passed.txt
#       test-failed.txt
#       test-skipped.txt
#       test-failure.log
#       hs_err/<timestamp>/  (local only — not pushed)
#     release/              — (present when level is release or both)
#       (same layout as fastdebug/)
#
# RETENTION
# ─────────
#   PR result directories older than 30 days are automatically purged from
#   both disk and the git index (wiped from GitHub on next push).
#
# BRANCHES
# ────────
#   Results are pushed to: ci-results-community
#
# EXAMPLES
# ────────
#   # Test PR 31868 (fastdebug, full run):
#   bash scripts/pr_test.sh --pr 31868
#
#   # Test PR 31868 in release mode:
#   bash scripts/pr_test.sh --pr 31868 --level release
#
#   # Test both fastdebug and release:
#   bash scripts/pr_test.sh --pr 31868 --level both
#
#   # Test by URL, skip dep download, no push:
#   bash scripts/pr_test.sh \
#       --pr https://github.com/openjdk/jdk/pull/31868 \
#       --skip-deps --no-push
#
#   # Dry run — see what would happen:
#   bash scripts/pr_test.sh --pr 31868 --dry-run
#
# EXIT CODES
# ──────────
#   0  All requested work completed (test failures are recorded, not fatal)
#   1  Infrastructure/build failure or bad arguments
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/build_test.sh"
source "${SCRIPT_DIR}/notify.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OPT_PR=""
OPT_LEVEL="fastdebug"
OPT_SKIP_DEPS=false
OPT_NO_PUSH=false
OPT_DRY_RUN=false

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# USAGE/,/^# =/{ /^# =/d; s/^# \{0,1\}//; p }' "$0"
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    echo "[pr_test.sh] ERROR: --pr <NUMBER_OR_URL> is required." >&2
    echo "             Run 'bash scripts/pr_test.sh --help' for usage." >&2
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)
            OPT_PR="$2"; shift 2 ;;
        --level)
            case "${2:-}" in
                fastdebug|release|both) OPT_LEVEL="$2"; shift 2 ;;
                *) echo "[pr_test.sh] ERROR: --level must be fastdebug, release, or both (got: ${2:-})" >&2
                   exit 1 ;;
            esac ;;
        --skip-deps)
            OPT_SKIP_DEPS=true; shift ;;
        --no-push)
            OPT_NO_PUSH=true; shift ;;
        --dry-run)
            OPT_DRY_RUN=true; shift ;;
        --help|-h)
            usage 0 ;;
        *)
            echo "[pr_test.sh] ERROR: unknown argument: $1" >&2
            echo "             Run 'bash scripts/pr_test.sh --help' for usage." >&2
            exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Extract PR number from URL or bare number
# ---------------------------------------------------------------------------
if [[ -z "${OPT_PR}" ]]; then
    echo "[pr_test.sh] ERROR: --pr is required." >&2
    exit 1
fi

# Strip URL prefix if the user passed a full GitHub URL
PR_NUMBER="${OPT_PR}"
if [[ "${PR_NUMBER}" =~ ^https?:// ]]; then
    PR_NUMBER="$(echo "${PR_NUMBER}" | grep -oE '[0-9]+$')"
fi

if [[ -z "${PR_NUMBER}" ]] || ! [[ "${PR_NUMBER}" =~ ^[0-9]+$ ]]; then
    echo "[pr_test.sh] ERROR: could not determine a numeric PR number from: ${OPT_PR}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Output directory layout
#   PRs/<number>/<YYYYMMDD_HHMMSS>/
# Inside the REPORTS_REPO_ROOT so it can be committed like regular reports.
# ---------------------------------------------------------------------------
_RUN_TS="$(date '+%Y%m%d_%H%M%S')"
PR_DIR="${REPORTS_REPO_ROOT}/PRs/${PR_NUMBER}"
OUT_BASE="${PR_DIR}/${_RUN_TS}"
mkdir -p "${OUT_BASE}"

# Tee all output to a run log
RUN_LOG="${OUT_BASE}/run.log"
exec > >(tee -a "${RUN_LOG}") 2>&1

# ---------------------------------------------------------------------------
# Resolve effective level(s) to build
# ---------------------------------------------------------------------------
EFFECTIVE_LEVELS=()
case "${OPT_LEVEL}" in
    both)       EFFECTIVE_LEVELS=("fastdebug" "release") ;;
    fastdebug)  EFFECTIVE_LEVELS=("fastdebug") ;;
    release)    EFFECTIVE_LEVELS=("release") ;;
esac

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
log "========================================================"
log "pr_test.sh — OpenJDK s390x Community PR Tester"
log "PR          : #${PR_NUMBER}"
log "PR URL      : https://github.com/openjdk/jdk/pull/${PR_NUMBER}"
log "level(s)    : ${EFFECTIVE_LEVELS[*]}"
log "test-target : tier1 (fixed)"
log "push branch : ${GIT_RESULTS_BRANCH_COMMUNITY}"
${OPT_SKIP_DEPS} && log "deps        : skipped (--skip-deps)"
${OPT_NO_PUSH}   && log "push        : disabled (--no-push)"
${OPT_DRY_RUN}   && log "mode        : DRY-RUN"
log "output dir  : ${OUT_BASE}"
log "run log     : ${RUN_LOG}"
log "========================================================"

# ---------------------------------------------------------------------------
# Trap: always return to repo root on exit
# ---------------------------------------------------------------------------
trap 'cd "${REPORTS_REPO_ROOT}"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — Download / verify dependencies
# ---------------------------------------------------------------------------
JTREG_OK=false

if ${OPT_DRY_RUN}; then
    info "DRY-RUN: would download boot JDK and jtreg (stream=head)"
    JTREG_OK=true
else
    log "Step 1: Downloading dependencies (stream=head) …"
    ensure_deps "head" "${OPT_SKIP_DEPS}"
    # pr_test always requires jtreg; abort if it failed
    if [[ "${JTREG_OK}" != "true" ]]; then
        die "jtreg is required for PR testing but is not available."
    fi
fi

# ---------------------------------------------------------------------------
# Step 2 — Fetch the PR branch into a temporary git worktree
#
# Strategy:
#   The canonical HEAD source is at $JDK_SOURCES_ROOT/jdk.
#   We create a temporary worktree at $JDK_SOURCES_ROOT/jdk-pr-<number>
#   so the main checkout is never disturbed.  The worktree is detached
#   at the PR's merge commit (refs/pull/<number>/head).
#   The worktree is removed in the EXIT trap.
# ---------------------------------------------------------------------------
HEAD_SRC="${JDK_SOURCES_ROOT}/jdk"
PR_WORKTREE="${JDK_SOURCES_ROOT}/jdk-pr-${PR_NUMBER}"
PR_REF="refs/pull/${PR_NUMBER}/head"
PR_REMOTE_REF="pull/${PR_NUMBER}/head"

# Write pr-info.txt header (commit will be filled in after fetch)
{
    echo "pr_number  : ${PR_NUMBER}"
    echo "pr_url     : https://github.com/openjdk/jdk/pull/${PR_NUMBER}"
    echo "run_ts     : ${_RUN_TS}"
    echo "date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "host       : $(hostname)"
} > "${OUT_BASE}/pr-info.txt"

fetch_pr_worktree() {
    if ${OPT_DRY_RUN}; then
        info "DRY-RUN: would fetch ${PR_REF} and create worktree at ${PR_WORKTREE}"
        return 0
    fi

    log "Step 2: Fetching PR #${PR_NUMBER} …"

    # Ensure the HEAD source repo exists — clone it if needed
    if [[ ! -d "${HEAD_SRC}/.git" ]]; then
        info "  HEAD source not found — cloning from upstream …"
        mkdir -p "${JDK_SOURCES_ROOT}"
        git clone --depth=1 \
            "https://github.com/openjdk/jdk.git" \
            "${HEAD_SRC}"
    fi

    # Fetch the PR ref into the repo (shallow: only the tip commit)
    info "  Fetching ${PR_REF} …"
    git -C "${HEAD_SRC}" fetch --depth=1 origin "${PR_REMOTE_REF}:${PR_REF}" \
        || die "git fetch of PR #${PR_NUMBER} failed. " \
               "Does the PR exist? https://github.com/openjdk/jdk/pull/${PR_NUMBER}"

    local pr_commit
    pr_commit="$(git -C "${HEAD_SRC}" rev-parse "${PR_REF}")"
    info "  PR HEAD commit: ${pr_commit}"

    # Append commit info to pr-info.txt
    {
        echo "pr_commit  : ${pr_commit}"
        echo ""
        git -C "${HEAD_SRC}" log -1 \
            --format='commit %H%nauthor %an <%ae>%ndate   %ad%n%n    %s%n%n    %b' \
            --date=rfc "${pr_commit}" 2>/dev/null || true
    } >> "${OUT_BASE}/pr-info.txt"

    # Remove any stale worktree at that path
    if [[ -d "${PR_WORKTREE}" ]]; then
        warn "  Stale PR worktree found at ${PR_WORKTREE} — removing …"
        git -C "${HEAD_SRC}" worktree remove --force "${PR_WORKTREE}" 2>/dev/null || true
        rm -rf "${PR_WORKTREE}"
    fi

    # Create a detached worktree at the PR commit
    info "  Creating worktree at ${PR_WORKTREE} …"
    git -C "${HEAD_SRC}" worktree add --detach "${PR_WORKTREE}" "${pr_commit}"
    success "  Worktree ready: ${PR_WORKTREE}"
    success "  PR #${PR_NUMBER} HEAD: $(git -C "${PR_WORKTREE}" log -1 --oneline)"
}

# Remove the PR worktree on any exit (success or failure)
_cleanup_worktree() {
    if ${OPT_DRY_RUN}; then return; fi
    if [[ -d "${PR_WORKTREE}" ]]; then
        info "Cleaning up PR worktree: ${PR_WORKTREE}"
        git -C "${HEAD_SRC}" worktree remove --force "${PR_WORKTREE}" 2>/dev/null || true
        rm -rf "${PR_WORKTREE}"
    fi
    cd "${REPORTS_REPO_ROOT}"
}
# Chain onto existing EXIT trap
trap '_cleanup_worktree' EXIT

fetch_pr_worktree

# ---------------------------------------------------------------------------
# Step 3 — Build + run tier1 for each effective level
# ---------------------------------------------------------------------------

# PR_LEVEL_RESULTS maps level -> result string (BUILD_FAILED|TEST_PASSED|TEST_FAILED)
declare -A PR_LEVEL_RESULTS=()

run_pr_build_test() {
    local level="$1"
    local level_out="${OUT_BASE}/${level}"
    mkdir -p "${level_out}"

    log "Step 3 [${level}]: Build + tier1 tests for PR #${PR_NUMBER} …"

    if ${OPT_DRY_RUN}; then
        info "DRY-RUN: would build ${level} and run tier1 in ${PR_WORKTREE}"
        PR_LEVEL_RESULTS["${level}"]="DRY_RUN"
        return 0
    fi

    local exit_code=0
    build_and_test_jdk \
        "${PR_WORKTREE}" \
        "PR-${PR_NUMBER}" \
        "${level}" \
        "${level_out}" \
        "${JTREG_OK}" \
        "${BOOT_JDK_DIR}" \
        || exit_code=$?

    local result
    if [[ ${exit_code} -ne 0 ]]; then
        warn "Build failed for PR #${PR_NUMBER} [${level}] (exit=${exit_code}) — recorded."
        result="BUILD_FAILED (exit=${exit_code})"
    else
        local test_exit_line
        test_exit_line="$(grep '^test_exit:' "${level_out}/run-metadata.txt" \
            2>/dev/null | awk '{print $2}' || echo "0")"
        case "${test_exit_line}" in
            0)          result="TEST_PASSED" ;;
            SKIPPED*)   result="BUILD_ONLY (jtreg not available)" ;;
            NO_BUILD*)  result="SKIPPED (no build found)" ;;
            *)          result="TEST_FAILURES (jtreg=${test_exit_line})" ;;
        esac
    fi

    PR_LEVEL_RESULTS["${level}"]="${result}"
    log "PR #${PR_NUMBER} [${level}] result: ${result}"
}

for _level in "${EFFECTIVE_LEVELS[@]}"; do
    run_pr_build_test "${_level}"
done

# ---------------------------------------------------------------------------
# Step 4 — Write run summary
# ---------------------------------------------------------------------------

# Compute overall result across all levels
_pr_overall="PASS"
_pr_summary_results=()
for _level in "${EFFECTIVE_LEVELS[@]}"; do
    _res="${PR_LEVEL_RESULTS[${_level}]:-UNKNOWN}"
    _pr_summary_results+=("  ${_level}: ${_res}")
    if [[ "${_res}" == BUILD_FAILED* || "${_res}" == TEST_FAILURES* ]]; then
        _pr_overall="FAIL"
    fi
done

write_pr_summary() {
    local summary="${OUT_BASE}/run-summary.txt"
    {
        echo "========================================================"
        echo "  pr_test.sh Run Summary"
        echo "========================================================"
        echo "  pr_number    : ${PR_NUMBER}"
        echo "  pr_url       : https://github.com/openjdk/jdk/pull/${PR_NUMBER}"
        echo "  level(s)     : ${EFFECTIVE_LEVELS[*]}"
        echo "  test-target  : tier1"
        echo "  overall      : ${_pr_overall}"
        for _line in "${_pr_summary_results[@]}"; do echo "${_line}"; done
        echo "  date         : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "  host         : $(hostname)"
        if [[ -x "${BOOT_JDK_DIR}/bin/java" ]]; then
            echo "  boot-jdk     : $("${BOOT_JDK_DIR}/bin/java" -version 2>&1 | head -1)"
        fi
        if [[ -x "${JTREG_DIR}/bin/jtreg" ]]; then
            echo "  jtreg        : $(JAVA_HOME="${BOOT_JDK_DIR}" \
                                       "${JTREG_DIR}/bin/jtreg" -version 2>/dev/null \
                                     | head -1 || echo 'n/a')"
        fi
        echo "  output dir   : ${OUT_BASE}"
        echo "========================================================"
    } > "${summary}"
    echo ""
    cat "${summary}"
    echo ""
    success "Summary written to: ${summary}"
}

write_pr_summary

# ---------------------------------------------------------------------------
# Step 4b — Retention purge: remove PR results older than 30 days
# ---------------------------------------------------------------------------
purge_old_pr_results() {
    log "Step 4b: PR retention purge (>30 days) …"

    if ${OPT_DRY_RUN}; then
        info "DRY-RUN: would purge PR results older than 30 days"
        return 0
    fi

    if ! python3 "${SCRIPT_DIR}/gen_status.py" \
            "${REPORTS_REPO_ROOT}/PRs" "${REPORTS_REPO_ROOT}" \
            --purge-pr --pr-retention-days 30 2>&1; then
        warn "PR retention purge failed — continuing."
    else
        success "PR retention purge complete."
    fi
}

purge_old_pr_results

# ---------------------------------------------------------------------------
# Email notification — one quad per level
# ---------------------------------------------------------------------------
_notify_quads=()
for _level in "${EFFECTIVE_LEVELS[@]}"; do
    _res="${PR_LEVEL_RESULTS[${_level}]:-UNKNOWN}"
    _bst=""
    if   [[ "${_res}" == BUILD_FAILED*   ]]; then _bst="BUILD_FAILED"
    elif [[ "${_res}" == TEST_FAILURES*  ]]; then _bst="TEST_FAILED"
    else                                          _bst="TEST_PASSED"
    fi
    # <level_out> has flat copies of newfailures.txt + other_errors.txt made by
    # build_and_test_jdk().  Use __report__ sentinel so notify.sh reads them directly.
    _notify_quads+=("PR-${PR_NUMBER}:${OUT_BASE}/${_level}:__report__:${_bst}")
done

_subject_levels="${EFFECTIVE_LEVELS[*]}"   # e.g. "fastdebug" or "fastdebug release"
[[ "${#EFFECTIVE_LEVELS[@]}" -gt 1 ]] && _subject_levels="both"

ci_notify "pr" "PR #${PR_NUMBER} ${_subject_levels}/tier1" \
    "${OUT_BASE}/run-summary.txt" "${_pr_overall}" \
    "${OUT_BASE}/pr-info.txt" \
    "${_notify_quads[@]}"

log "========================================================"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "PR      : #${PR_NUMBER}"
for _level in "${EFFECTIVE_LEVELS[@]}"; do
    log "Result [${_level}]: ${PR_LEVEL_RESULTS[${_level}]:-UNKNOWN}"
done
log "Output  : ${OUT_BASE}"
log "========================================================"
