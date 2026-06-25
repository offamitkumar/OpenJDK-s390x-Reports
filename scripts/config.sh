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

# Parent directory that holds all JDK source checkouts on the test machine.
# Layout expected:
#   ${JDK_SOURCES_ROOT}/jdk          ← HEAD (mainline)
#   ${JDK_SOURCES_ROOT}/jdk21u-dev   ← JDK 21 update repo
#   ${JDK_SOURCES_ROOT}/jdk17u-dev   ← JDK 17 update repo
#   … etc.
: "${JDK_SOURCES_ROOT:=${HOME}/head}"

# Scratch directory — wiped and re-populated on every setup_deps.sh run.
# Both the boot JDK and jtreg land here; nothing persists between runs.
: "${CI_TMP_DIR:=/tmp/openjdk-s390x-ci}"

# Where the Adoptium nightly boot JDK is extracted (inside CI_TMP_DIR)
: "${BOOT_JDK_DIR:=${CI_TMP_DIR}/boot_jdk}"

# Where jtreg is extracted (inside CI_TMP_DIR)
: "${JTREG_DIR:=${CI_TMP_DIR}/jtreg}"

# Where googletest lives — optional, only used for hotspot tests
: "${GTEST_DIR:=${HOME}/googletest}"

# Root of THIS reports repository (auto-detected from script location)
REPORTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Where test-result artifacts land inside the reports repo
: "${REPORTS_DIR:=${REPORTS_REPO_ROOT}/reports}"

# ---------------------------------------------------------------------------
# Build configuration
# ---------------------------------------------------------------------------

# Parallel make jobs (defaults to all logical CPUs)
: "${MAKE_JOBS:=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

# Debug levels to build and test for every stream
BUILD_LEVELS=(fastdebug release)

# ---------------------------------------------------------------------------
# Stream registry
# ---------------------------------------------------------------------------
# Each stream is defined by five pipe-separated fields:
#
#   LABEL | SRC_SUBDIR | GIT_REPO_URL | MIN_JDK_VERSION | EXTRA_CONFIGURE_FLAGS
#
#   LABEL               — used in report paths and log messages
#   SRC_SUBDIR          — subdirectory name under JDK_SOURCES_ROOT
#   GIT_REPO_URL        — upstream git remote to pull from
#   MIN_JDK_VERSION     — minimum JDK version that can build this stream
#                         (used to pick the right boot JDK; currently all
#                          streams use the same nightly HEAD boot JDK)
#   EXTRA_CONFIGURE_FLAGS — space-separated extra flags appended to configure
#                           (use "" for none)
#
# How versioned streams are managed automatically:
#   resolve_streams.py queries the Adoptium API for available_lts_releases
#   plus most_recent_feature_release and emits the active subset.
#   HEAD is always included unconditionally.
#   Streams present in this registry but no longer in that active set are
#   skipped at runtime — no manual deletion required.
#
# To add a new stream: add a row here.
# To retire a stream: simply remove its row (or let resolve_streams.py skip it).

# Active set rule (enforced by resolve_streams.py at runtime):
#   active = available_lts_releases  ∪  {most_recent_feature_release}
#
# Current picture (from api.adoptium.net/v3/info/available_releases):
#   LTS              : 11, 17, 21, 25
#   Feature release  : 26  (most_recent_feature_release)
#   HEAD / tip       : 28  (tip_version — always tested, never filtered)
#   EOL / excluded   : 8 (different build system), 23, 24 (superseded)
#
# To add a new stream: append a row.  resolve_streams.py will start
# including it automatically once it appears in the Adoptium API.
# To retire a stream: remove its row (or leave it — the resolver will
# skip it once it drops from the API's active set).

JDK_STREAMS=(
  # HEAD — always tested regardless of API response
  "head|jdk|https://github.com/openjdk/jdk.git|21|"

  # Active LTS streams
  "jdk25|jdk25u|https://github.com/openjdk/jdk25u.git|21|"
  "jdk21|jdk21u-dev|https://github.com/openjdk/jdk21u-dev.git|21|"
  "jdk17|jdk17u-dev|https://github.com/openjdk/jdk17u-dev.git|17|"
  "jdk11|jdk11u-dev|https://github.com/openjdk/jdk11u-dev.git|11|--disable-warnings-as-errors"

  # Current non-LTS feature release
  # resolve_streams.py keeps this active while it equals most_recent_feature_release
  # and drops it automatically once the next release supersedes it.
  "jdk26|jdk26u|https://github.com/openjdk/jdk26u.git|21|"
)

# ---------------------------------------------------------------------------
# Adoptium nightly boot JDK download settings
# ---------------------------------------------------------------------------
# Architecture tag used in GitHub release asset names
ADOPTIUM_ARCH="s390x"
ADOPTIUM_OS="linux"
# The Adoptium public API — used to resolve tip_version and active releases
ADOPTIUM_API_BASE="https://api.adoptium.net/v3"
# GitHub org that publishes per-version nightly EA binaries
ADOPTIUM_GITHUB_ORG="adoptium"

# ---------------------------------------------------------------------------
# JTREG download settings
# ---------------------------------------------------------------------------
JTREG_ARTIFACT_BASE="https://ci.adoptium.net/view/Dependencies/job/dependency_pipeline/lastSuccessfulBuild/artifact/jtreg"
# jtregtip.tar.gz is the rolling tip — always the latest jtreg build
JTREG_ARCHIVE_NAME="jtregtip.tar.gz"
JTREG_DOWNLOAD_URL="${JTREG_ARTIFACT_BASE}/${JTREG_ARCHIVE_NAME}"
JTREG_SHA256_URL="${JTREG_ARTIFACT_BASE}/${JTREG_ARCHIVE_NAME}.sha256sum.txt"

# ---------------------------------------------------------------------------
# Git / reporting settings
# ---------------------------------------------------------------------------
GIT_RESULTS_BRANCH="main"
GIT_COMMIT_AUTHOR_NAME="${GIT_COMMIT_AUTHOR_NAME:-OpenJDK s390x CI}"
GIT_COMMIT_AUTHOR_EMAIL="${GIT_COMMIT_AUTHOR_EMAIL:-ci@s390x}"
