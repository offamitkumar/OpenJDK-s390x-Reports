#!/usr/bin/env bash
# =============================================================================
# config.sh — Central configuration for OpenJDK s390x CI/CD
#
# Source this file in every other script:
#   source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# =============================================================================

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

# Root of the OpenJDK source trees (parent dir holding jdk/, jdk21u-dev/, …)
: "${JDK_SOURCES_ROOT:=${HOME}/jdk-sources}"

# Scratch directory — wiped and re-populated on every run.
# Both the boot JDK and jtreg land here so nothing persists between runs.
: "${CI_TMP_DIR:=/tmp/openjdk-s390x-ci}"

# Where the Adoptium nightly boot JDK will be extracted (inside CI_TMP_DIR)
: "${BOOT_JDK_DIR:=${CI_TMP_DIR}/boot_jdk}"

# Where jtreg will be extracted (inside CI_TMP_DIR)
: "${JTREG_DIR:=${CI_TMP_DIR}/jtreg}"

# Where googletest lives (optional; only needed for hotspot tests)
: "${GTEST_DIR:=${HOME}/googletest}"

# Root of THIS reports repository (auto-detected)
REPORTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Where test-result artifacts land inside the reports repo
: "${REPORTS_DIR:=${REPORTS_REPO_ROOT}/reports}"

# ---------------------------------------------------------------------------
# JDK-head source repo
# ---------------------------------------------------------------------------

# The directory that contains the checked-out jdk/jdk mainline source
: "${HEAD_SRC_DIR:=${JDK_SOURCES_ROOT}/jdk}"
HEAD_GIT_URL="https://github.com/openjdk/jdk.git"

# ---------------------------------------------------------------------------
# Build configuration
# ---------------------------------------------------------------------------

# CPU count available to make (default: nproc)
: "${MAKE_JOBS:=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

# The two debug levels we build and test
BUILD_LEVELS=(fastdebug release)

# ---------------------------------------------------------------------------
# Adoptium nightly boot JDK download settings
# ---------------------------------------------------------------------------
# Architecture tag used in GitHub release asset names
ADOPTIUM_ARCH="s390x"
ADOPTIUM_OS="linux"
# The Adoptium public API — used only to resolve tip_version dynamically
ADOPTIUM_API_BASE="https://api.adoptium.net/v3"
# GitHub org that publishes per-version nightly EA binaries
ADOPTIUM_GITHUB_ORG="adoptium"

# ---------------------------------------------------------------------------
# JTREG download settings
# ---------------------------------------------------------------------------
# Latest successful build artifact base URL from ci.adoptium.net
JTREG_ARTIFACT_BASE="https://ci.adoptium.net/view/Dependencies/job/dependency_pipeline/lastSuccessfulBuild/artifact/jtreg"
# jtregtip.tar.gz is the rolling "tip" build — always the latest jtreg
JTREG_ARCHIVE_NAME="jtregtip.tar.gz"
JTREG_DOWNLOAD_URL="${JTREG_ARTIFACT_BASE}/${JTREG_ARCHIVE_NAME}"
JTREG_SHA256_URL="${JTREG_ARTIFACT_BASE}/${JTREG_ARCHIVE_NAME}.sha256sum.txt"

# ---------------------------------------------------------------------------
# Git settings
# ---------------------------------------------------------------------------
GIT_RESULTS_BRANCH="main"
GIT_COMMIT_AUTHOR_NAME="${GIT_COMMIT_AUTHOR_NAME:-OpenJDK s390x CI}"
GIT_COMMIT_AUTHOR_EMAIL="${GIT_COMMIT_AUTHOR_EMAIL:-ci@s390x}"
