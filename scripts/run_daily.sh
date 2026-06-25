#!/usr/bin/env bash
# =============================================================================
# run_daily.sh — Daily CI orchestrator for JDK-head tier1 on s390x
#
# What it does:
#   1. Refreshes boot JDK (Adoptium nightly) and jtreg (ci.adoptium.net)
#   2. Pulls the latest JDK-head (mainline) source
#   3. Builds fastdebug + release images
#   4. Runs tier1 tests for both configurations
#   5. Writes results under reports/YYYY/Month/DD/head/{fastdebug,release}/
#   6. Commits and pushes the new report files to the main branch
#
# Usage:
#   bash scripts/run_daily.sh
#
# Override any config variable by exporting it before calling:
#   HEAD_SRC_DIR=/custom/path bash scripts/run_daily.sh
#
# Exit codes:
#   0  — everything finished (test failures are recorded, not fatal)
#   1  — setup or build error (pipeline aborted)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/build_test.sh"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()     { echo "$(date -u '+%H:%M:%S') [RUN]   $*"; }
info()    { echo "$(date -u '+%H:%M:%S') [INFO]  $*"; }
success() { echo "$(date -u '+%H:%M:%S') [OK]    $*"; }
die()     { echo "$(date -u '+%H:%M:%S') [FATAL] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Trap: always return to reports repo root, even on error
# ---------------------------------------------------------------------------
cleanup() {
  cd "${REPORTS_REPO_ROOT}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1 — Refresh dependencies (boot JDK + jtreg)
# ---------------------------------------------------------------------------
refresh_deps() {
  log "Refreshing boot JDK and jtreg …"
  bash "${SCRIPT_DIR}/setup_deps.sh"
}

# ---------------------------------------------------------------------------
# Step 2 — Clone or pull JDK-head source
# ---------------------------------------------------------------------------
prepare_jdk_source() {
  log "Preparing JDK-head source at ${HEAD_SRC_DIR} …"

  if [[ -d "${HEAD_SRC_DIR}/.git" ]]; then
    info "  Existing repo found — pulling latest …"
    git -C "${HEAD_SRC_DIR}" fetch --prune origin
    git -C "${HEAD_SRC_DIR}" checkout master
    git -C "${HEAD_SRC_DIR}" pull --ff-only origin master
  else
    info "  No repo found — cloning ${HEAD_GIT_URL} …"
    mkdir -p "$(dirname "${HEAD_SRC_DIR}")"
    git clone --depth=1 "${HEAD_GIT_URL}" "${HEAD_SRC_DIR}"
  fi

  # Record the top commit
  git -C "${HEAD_SRC_DIR}" log -1 \
    --format="commit %H%nauthor %an <%ae>%ndate   %ad%n%n    %s" \
    --date=rfc
}

# ---------------------------------------------------------------------------
# Step 3 — Determine output directories for today's run
# ---------------------------------------------------------------------------
make_output_dirs() {
  local year month day
  year="$(date +%Y)"
  month="$(date +%B)"
  day="$(date +%d)"

  local base="${REPORTS_DIR}/${year}/${month}/${day}/head"
  mkdir -p "${base}/fastdebug" "${base}/release"

  echo "${base}"   # caller captures this
}

# ---------------------------------------------------------------------------
# Step 4 — Run build+test for a single debug level, tolerate test failures
# ---------------------------------------------------------------------------
run_level() {
  local debug_level="$1"
  local out_base="$2"
  local top_commit_file="$3"

  local out_dir="${out_base}/${debug_level}"
  mkdir -p "${out_dir}"

  # Save the top commit for this level's directory as well
  cp "${top_commit_file}" "${out_dir}/../top_commit" 2>/dev/null || true

  log "--- Starting build+test: head / ${debug_level} ---"

  # build_and_test_jdk runs in its own subshell; we capture its exit
  local exit_code=0
  build_and_test_jdk \
    "${HEAD_SRC_DIR}" \
    "head" \
    "${debug_level}" \
    "${out_dir}" || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    # A non-zero exit from build_and_test means a BUILD error (test failures
    # are tolerated inside the function). Record it and continue.
    echo "BUILD/SETUP ERROR — exit code ${exit_code}" >> "${out_dir}/build.log"
    echo "Build failed with exit ${exit_code}" > "${out_dir}/test-summary.txt"
  fi

  log "--- Finished: head / ${debug_level} (exit=${exit_code}) ---"
}

# ---------------------------------------------------------------------------
# Step 5 — Commit and push results
# ---------------------------------------------------------------------------
publish_results() {
  local report_dir="$1"

  log "Publishing results to git …"

  cd "${REPORTS_REPO_ROOT}"

  # Ensure we are on the results branch and up-to-date
  git fetch origin "${GIT_RESULTS_BRANCH}"
  git checkout "${GIT_RESULTS_BRANCH}"
  git pull --ff-only origin "${GIT_RESULTS_BRANCH}"

  # Stage only the new/changed report files
  git add "${REPORTS_DIR}/"

  if git diff --cached --quiet; then
    info "  Nothing new to commit."
    return 0
  fi

  local year month day
  year="$(date +%Y)"
  month="$(date +%B)"
  day="$(date +%d)"

  git \
    -c "user.name=${GIT_COMMIT_AUTHOR_NAME}" \
    -c "user.email=${GIT_COMMIT_AUTHOR_EMAIL}" \
    commit -m "report(head): tier1 results ${year}-${month}-${day}

Automated s390x CI run.
Stream: JDK head (mainline)
Tests:  tier1 (fastdebug + release)
Host:   $(hostname)
"

  git push origin "${GIT_RESULTS_BRANCH}"
  success "Results pushed to origin/${GIT_RESULTS_BRANCH}."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "============================================================"
  log "OpenJDK s390x CI — JDK-head tier1 daily run"
  log "$(date -u)"
  log "============================================================"

  # 1. Refresh tools
  refresh_deps

  # 2. Prepare source
  prepare_jdk_source

  # 3. Create output directories
  local out_base
  out_base="$(make_output_dirs)"
  log "Report directory: ${out_base}"

  # Save top commit once (shared by both levels)
  local top_commit_file="${out_base}/top_commit"
  git -C "${HEAD_SRC_DIR}" log -1 \
    --format="commit %H%nauthor %an <%ae>%ndate   %ad%n%n    %s" \
    --date=rfc > "${top_commit_file}"

  # 4. Build and test — both debug levels (failures are recorded, not fatal)
  run_level "fastdebug" "${out_base}" "${top_commit_file}"
  run_level "release"   "${out_base}" "${top_commit_file}"

  # 5. Publish
  publish_results "${out_base}"

  log "============================================================"
  log "Daily run complete."
  log "============================================================"
}

main "$@"
