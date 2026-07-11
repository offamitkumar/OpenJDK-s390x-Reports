#!/usr/bin/env bash
# =============================================================================
# pr_test.sh — Community PR tester for OpenJDK s390x CI
#
# Fetches an upstream OpenJDK pull request, builds it in fastdebug mode, runs
# the full tier1 test suite, and pushes the results to the ci-results-community
# branch under PRs/<number>/<YYYYMMDD_HHMMSS>/.
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
#     fastdebug/
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
#   # Test PR 31868 (full run, push results):
#   bash scripts/pr_test.sh --pr 31868
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

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OPT_PR=""
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
# Logging helpers
# ---------------------------------------------------------------------------
_ts()     { date -u '+%H:%M:%S'; }
log()     { echo "$(_ts) [pr]    $*"; }
info()    { echo "$(_ts) [INFO]  $*"; }
success() { echo "$(_ts) [OK]    $*"; }
warn()    { echo "$(_ts) [WARN]  $*" >&2; }
die()     { echo "$(_ts) [FATAL] $*" >&2; exit 1; }

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
# Banner
# ---------------------------------------------------------------------------
log "========================================================"
log "pr_test.sh — OpenJDK s390x Community PR Tester"
log "PR          : #${PR_NUMBER}"
log "PR URL      : https://github.com/openjdk/jdk/pull/${PR_NUMBER}"
log "level       : fastdebug (fixed)"
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

ensure_deps() {
    if ${OPT_SKIP_DEPS}; then
        if [[ ! -x "${BOOT_JDK_DIR}/bin/java" ]]; then
            die "Boot JDK not found at ${BOOT_JDK_DIR}. Remove --skip-deps to download it."
        fi
        info "Using cached boot JDK: $("${BOOT_JDK_DIR}/bin/java" -version 2>&1 | head -1)"
        if [[ ! -x "${JTREG_DIR}/bin/jtreg" ]]; then
            die "jtreg not found at ${JTREG_DIR}. Remove --skip-deps to download it."
        fi
        info "Using cached jtreg: ${JTREG_DIR}/bin/jtreg"
        JTREG_OK=true
        return
    fi

    if ${OPT_DRY_RUN}; then
        info "DRY-RUN: would download boot JDK and jtreg (stream=head)"
        JTREG_OK=true
        return
    fi

    log "Step 1: Downloading dependencies (stream=head) …"
    local deps_exit=0
    SETUP_DEPS_STREAM="head" bash "${SCRIPT_DIR}/setup_deps.sh" \
        --stream head || deps_exit=$?

    case "${deps_exit}" in
        0)
            JTREG_OK=true
            success "Boot JDK and jtreg ready."
            ;;
        1)
            [[ -f "${CI_TMP_DIR}/deps-failure.txt" ]] \
                && cat "${CI_TMP_DIR}/deps-failure.txt"
            die "Boot JDK download failed — cannot continue."
            ;;
        2)
            die "jtreg download failed — tier1 tests require jtreg."
            ;;
        *)
            die "setup_deps.sh exited with unexpected code ${deps_exit}."
            ;;
    esac
}

ensure_deps

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
# Step 3 — Build fastdebug + run tier1
# ---------------------------------------------------------------------------
LEVEL="fastdebug"
LEVEL_OUT="${OUT_BASE}/${LEVEL}"
mkdir -p "${LEVEL_OUT}"

run_pr_build_test() {
    log "Step 3: Build (fastdebug) + tier1 tests for PR #${PR_NUMBER} …"

    if ${OPT_DRY_RUN}; then
        info "DRY-RUN: would build ${LEVEL} and run tier1 in ${PR_WORKTREE}"
        return 0
    fi

    local exit_code=0
    build_and_test_jdk \
        "${PR_WORKTREE}" \
        "PR-${PR_NUMBER}" \
        "${LEVEL}" \
        "${LEVEL_OUT}" \
        "${JTREG_OK}" \
        "${BOOT_JDK_DIR}" \
        || exit_code=$?

    if [[ ${exit_code} -ne 0 ]]; then
        warn "Build failed for PR #${PR_NUMBER} (exit=${exit_code}) — recorded."
        PR_RESULT="BUILD_FAILED (exit=${exit_code})"
    else
        local test_exit_line
        test_exit_line="$(grep '^test_exit:' "${LEVEL_OUT}/run-metadata.txt" \
            2>/dev/null | awk '{print $2}' || echo "0")"
        case "${test_exit_line}" in
            0)          PR_RESULT="TEST_PASSED" ;;
            SKIPPED*)   PR_RESULT="BUILD_ONLY (jtreg not available)" ;;
            NO_BUILD*)  PR_RESULT="SKIPPED (no build found)" ;;
            *)          PR_RESULT="TEST_FAILURES (jtreg=${test_exit_line})" ;;
        esac
    fi

    log "PR #${PR_NUMBER} result: ${PR_RESULT}"
}

PR_RESULT="DRY_RUN"
run_pr_build_test

# ---------------------------------------------------------------------------
# Step 4 — Write run summary
# ---------------------------------------------------------------------------
write_pr_summary() {
    local summary="${OUT_BASE}/run-summary.txt"
    {
        echo "========================================================"
        echo "  pr_test.sh Run Summary"
        echo "========================================================"
        echo "  pr_number    : ${PR_NUMBER}"
        echo "  pr_url       : https://github.com/openjdk/jdk/pull/${PR_NUMBER}"
        echo "  level        : ${LEVEL}"
        echo "  test-target  : tier1"
        echo "  result       : ${PR_RESULT}"
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
        echo ""
        echo "  Artefacts:"
        echo "    run.log              — full run output"
        echo "    pr-info.txt          — PR number, URL, HEAD commit"
        echo "    ${LEVEL}/"
        echo "      build.log          — full make output"
        echo "      build-diagnosis.txt — last compiler cmd + first error lines"
        echo "      test-summary.txt   — jtreg pass/fail totals"
        echo "      newfailures.txt    — failing test names"
        echo "      other_errors.txt   — erroring test names"
        echo "      run-metadata.txt   — versions, exit codes, dates"
        echo "      test-passed.txt    — names of all passed tests"
        echo "      test-failed.txt    — names of all failed tests"
        echo "      test-skipped.txt   — names of all skipped tests"
        echo "      test-failure.log   — failure detail + hs_err notice"
        echo "      hs_err/<timestamp>/ — JVM crash logs (local only, not pushed)"
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
# Step 5 — Commit and push to ci-results-community
# ---------------------------------------------------------------------------
publish_pr_results() {
    if ${OPT_NO_PUSH} || ${OPT_DRY_RUN}; then
        info "Skipping git push (--no-push or --dry-run)."
        return 0
    fi

    log "Step 5: Publishing PR results → ${GIT_RESULTS_BRANCH_COMMUNITY} …"

    local wt_dir="${REPORTS_REPO_ROOT}/.ci-wt-community"

    cd "${REPORTS_REPO_ROOT}"
    git fetch origin "${GIT_RESULTS_BRANCH_COMMUNITY}" \
        || git fetch origin "${GIT_RESULTS_BRANCH_COMMUNITY}" 2>/dev/null \
        || true   # branch may not exist yet — handled by worktree add below

    if [[ -d "${wt_dir}/.git" || -f "${wt_dir}/.git" ]]; then
        git -C "${wt_dir}" pull --ff-only origin "${GIT_RESULTS_BRANCH_COMMUNITY}" \
            2>/dev/null || true
    else
        rm -rf "${wt_dir}"
        # If the branch doesn't exist yet, create it as an orphan from the
        # current HEAD so it's a clean branch with no shared history.
        if git ls-remote --exit-code --heads origin \
                "${GIT_RESULTS_BRANCH_COMMUNITY}" &>/dev/null; then
            git worktree add "${wt_dir}" "${GIT_RESULTS_BRANCH_COMMUNITY}"
        else
            info "Branch ${GIT_RESULTS_BRANCH_COMMUNITY} does not exist yet — creating …"
            git worktree add --orphan "${wt_dir}" "${GIT_RESULTS_BRANCH_COMMUNITY}"
            # Stage a minimal README so the initial commit isn't empty
            echo "# OpenJDK s390x CI — Community PR Results" \
                > "${wt_dir}/README.md"
        fi
    fi

    # Sync the entire PRs/ directory (minus local-only hs_err/) into the worktree.
    mkdir -p "${wt_dir}/PRs"
    rsync -a --delete \
        --exclude='hs_err/' \
        "${REPORTS_REPO_ROOT}/PRs/" "${wt_dir}/PRs/"

    cd "${wt_dir}"
    git add PRs/ README.md 2>/dev/null || git add PRs/

    if git diff --cached --quiet; then
        info "Nothing new to commit."
        git worktree remove --force "${wt_dir}" 2>/dev/null || true
        return 0
    fi

    local headline_icon="✅"
    if [[ "${PR_RESULT}" == BUILD_FAILED* || "${PR_RESULT}" == TEST_FAILURES* ]]; then
        headline_icon="❌"
    fi

    git \
        -c "user.name=${GIT_COMMIT_AUTHOR_NAME}" \
        -c "user.email=${GIT_COMMIT_AUTHOR_EMAIL}" \
        commit -m "${headline_icon} PR #${PR_NUMBER} tier1/fastdebug: ${PR_RESULT}

PR     : https://github.com/openjdk/jdk/pull/${PR_NUMBER}
Branch : ${GIT_RESULTS_BRANCH_COMMUNITY}
Level  : ${LEVEL}
Target : tier1
Result : ${PR_RESULT}
Host   : $(hostname)
Date   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Retention: PR results older than 30 days purged from repo.

Logs: PRs/${PR_NUMBER}/${_RUN_TS}/
"
    git push origin "${GIT_RESULTS_BRANCH_COMMUNITY}"
    success "Results pushed to origin/${GIT_RESULTS_BRANCH_COMMUNITY}."

    cd "${REPORTS_REPO_ROOT}"
    git worktree remove --force "${wt_dir}" 2>/dev/null || true
}

publish_pr_results

log "========================================================"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "PR      : #${PR_NUMBER}"
log "Result  : ${PR_RESULT}"
log "Output  : ${OUT_BASE}"
log "========================================================"
