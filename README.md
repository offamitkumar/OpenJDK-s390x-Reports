# OpenJDK s390x CI

Automated build and tier1 test pipeline for **OpenJDK on Linux/s390x (IBM Z)**.

The CI pipeline downloads a fresh [Adoptium Temurin nightly](https://adoptium.net/en-GB/temurin/nightly/)
boot JDK and the [latest jtreg](https://ci.adoptium.net/view/Dependencies/job/dependency_pipeline/lastSuccessfulBuild/artifact/jtreg/)
on every run, builds JDK head from source, runs `tier1` tests in both
`fastdebug` and `release` configurations, and sends an email summary.

---

## Repository layout

```
scripts/
  config.sh           # Central configuration — edit paths here
  setup_deps.sh       # Downloads / refreshes boot JDK and jtreg
  build_test.sh       # Build + test functions (sourced by other scripts)
  run_daily.sh        # Automated daily CI orchestrator
  jdk.sh              # Human-facing CLI for manual build/test runs
  pr_test.sh          # Community PR tester (fastdebug tier1 for a given PR)
  notify.sh           # Email notification helper
  resolve_streams.py  # Filters stream registry against Adoptium API
  gen_status.py       # Parses build results for reporting

PRs/
  <number>/
    <YYYYMMDD_HHMMSS>/      # One directory per test run (removed after 30 days)
      run.log               # Full run output
      pr-info.txt           # PR number, URL, HEAD commit fetched
      fastdebug/
        build.log
        build-diagnosis.txt
        test-summary.txt
        newfailures.txt
        other_errors.txt
        run-metadata.txt
```

Build and test results are stored directly in the JDK source tree under
`~/jdk-sources/<stream>/build/linux-s390x-server-<level>/` — the native
OpenJDK output location — rather than a separate reports directory.

---

## One-time setup

### 1. Clone this repository on the s390x machine

```bash
git clone git@github.com:offamitkumar/OpenJDK-s390x-Reports.git
cd OpenJDK-s390x-Reports
```

### 2. Configure paths

Open [`scripts/config.sh`](scripts/config.sh) and adjust the following variables
to match your environment.  Every variable has a sensible default you can
override by exporting it in your shell **before** running any script — no file
editing is needed for quick one-off overrides.

| Variable | Default | Description |
|---|---|---|
| `JDK_SOURCES_ROOT` | `$HOME/jdk-sources` | Parent directory for JDK source trees |
| `BOOT_JDK_DIR` | `$HOME/boot_jdk_nightly` | Where the nightly boot JDK is installed |
| `JTREG_DIR` | `$HOME/jtreg` | Where jtreg is installed |
| `GTEST_DIR` | `$HOME/googletest` | Google Test (optional, for hotspot tests) |
| `MAKE_JOBS` | `nproc` result | Parallel make jobs |

### 3. Install prerequisites

The following packages are required on the s390x host:

```bash
# Fedora / RHEL / CentOS
sudo dnf install -y git curl unzip make autoconf zip \
  gcc gcc-c++ libX11-devel libXtst-devel libXrender-devel \
  libXrandr-devel libXi-devel fontconfig-devel cups-devel \
  alsa-lib-devel freetype-devel file

# Ubuntu / Debian
sudo apt-get install -y git curl unzip make autoconf zip \
  gcc g++ libx11-dev libxext-dev libxrender-dev libxtst-dev \
  libxi-dev libxrandr-dev libfontconfig1-dev libcups2-dev \
  libasound2-dev libfreetype-dev file
```

### 4. Bootstrap the boot JDK and jtreg

```bash
bash scripts/setup_deps.sh
```

This downloads the latest Adoptium Temurin nightly for s390x and the latest
jtreg. Re-running it always fetches the freshest versions.

---

## Running the CI pipeline manually

```bash
bash scripts/run_daily.sh
```

The script runs the following stages:

| Stage | Description |
|---|---|
| 1 | Download fresh Adoptium nightly boot JDK + latest jtreg |
| 2 | Query Adoptium API for active JDK streams |
| 3 | For each active stream: git pull, configure, build, tier1 test |
| 4 | Print run summary to stdout and send email notification |

Build errors abort the affected configuration but do **not** abort the other
one — both results are always collected.

Results stay in the JDK source tree at
`~/jdk-sources/<stream>/build/linux-s390x-server-<level>/` so you can inspect
`build.log`, `test-results/`, and `run-metadata.txt` directly without navigating
a separate report directory.

### Flags

```bash
# Build release only (skip fastdebug):
bash scripts/run_daily.sh --level release

# Skip tests (build only):
bash scripts/run_daily.sh --skip-tests

# Dry run — see what would happen without building anything:
bash scripts/run_daily.sh --dry-run

# Restrict to a single stream:
bash scripts/run_daily.sh --stream head
```

---

## Using the manual CLI (`jdk.sh`)

[`scripts/jdk.sh`](scripts/jdk.sh) is the human-facing entry point for
ad-hoc builds, tests, and email re-sends.

```
bash scripts/jdk.sh <command> [options]
```

### Commands

| Command | Description |
|---|---|
| `run` | git pull + build + tier1 test (same as daily cron) |
| `build` | Configure + make images only. No tests. |
| `test` | Re-use an existing build. Run tests without rebuilding. |
| `clean` | Remove the build output directory for the chosen stream + level. |
| `collect` | Re-collect artefacts from an already-finished test run and re-send email. |
| `resend` | Re-send the notification email using current results in the build tree. |

### Common options

| Option | Description |
|---|---|
| `--stream LABEL` | Target one stream: `head` `jdk26` `jdk25` `jdk21` `jdk17` `jdk11` (default: `head`) |
| `--level LEVEL` | `fastdebug` \| `release` \| `both` (default: `both`) |
| `--test-target GROUP` | jtreg group or path, e.g. `tier1`, `tier2`, `test/jdk`. Use `all` to run tier1–tier4 in order. |
| `--jvm-flags "FLAGS"` | Extra JVM flags injected into every jtreg run. |
| `--skip-deps` | Skip boot JDK + jtreg download (use cached). |
| `--no-push` | Do not git commit/push. |
| `--dry-run` | Print what would happen; do nothing. |
| `--run-kind KIND` | Override email subject label: `daily` \| `manual` \| `pr` (resend/collect only). |

### Examples

```bash
# Full default run (same as cron):
bash scripts/jdk.sh run

# Build only, fastdebug:
bash scripts/jdk.sh build --level fastdebug

# Wipe the prior build before building fresh:
bash scripts/jdk.sh clean && bash scripts/jdk.sh build --level fastdebug

# Re-run tier1 tests without rebuilding:
bash scripts/jdk.sh test

# Run all tiers (tier1–tier4) for head:
bash scripts/jdk.sh test --test-target all

# Run a specific jtreg group:
bash scripts/jdk.sh test --test-target test/jdk/java/lang

# Run tier1 with interpreter-only mode:
bash scripts/jdk.sh test --test-target tier1 --jvm-flags "-Xint"

# Re-send email using current results in the build tree:
bash scripts/jdk.sh resend

# Re-send with manual run-kind label:
bash scripts/jdk.sh resend --run-kind manual
```

---

## Testing a community PR

Use [`scripts/pr_test.sh`](scripts/pr_test.sh) to build and test any upstream
OpenJDK pull request on s390x in fastdebug mode against the tier1 test suite.
Results are written under `PRs/<number>/<YYYYMMDD_HHMMSS>/`.
PR result directories older than **30 days** are automatically purged.

### Syntax

```bash
bash scripts/pr_test.sh --pr <NUMBER_OR_URL> [options]
```

| Option | Description |
|---|---|
| `--pr NUMBER\|URL` | PR number or full GitHub URL. **Required.** |
| `--skip-deps` | Skip boot JDK + jtreg download (use cached). |
| `--no-push` | Write reports locally but do not `git push`. |
| `--dry-run` | Print what would happen; do nothing. |

### Examples

```bash
# Test PR 31868 — fetch, build fastdebug, run tier1:
bash scripts/pr_test.sh --pr 31868

# Quick local check — no push, use cached deps:
bash scripts/pr_test.sh --pr 31868 --skip-deps --no-push
```

### What it does

1. **Downloads** the latest Adoptium nightly boot JDK + jtreg (unless `--skip-deps`).
2. **Fetches** `refs/pull/<number>/head` from `github.com/openjdk/jdk` into a
   temporary git worktree so the main `head` source checkout is not disturbed.
3. **Builds** the PR in `fastdebug` mode (`configure` + `make images`).
4. **Runs** the full `tier1` test suite with jtreg.
5. **Writes** all artefacts under `PRs/<number>/<YYYYMMDD_HHMMSS>/`.
6. **Purges** any PR run directories older than 30 days.
7. **Cleans up** the temporary PR worktree unconditionally.

---

## Scheduling with cron

Add the following to `crontab -e` on the s390x machine to run every day at
**02:00 UTC**:

```cron
# OpenJDK s390x CI — daily tier1 run
0 2 * * * /bin/bash /home/amit/OpenJDK-s390x-Reports/scripts/run_daily.sh \
  >> /home/amit/ci-logs/run_daily.log 2>&1
```

Create the log directory once:

```bash
mkdir -p ~/ci-logs
```

---

## Build artefacts explained

Results live in the JDK source tree at
`~/jdk-sources/<stream>/build/linux-s390x-server-<level>/`.

| File | Contents |
|---|---|
| `build.log` | Full OpenJDK build log |
| `build-diagnosis.txt` | Last compiler command + first error lines |
| `test-results/` | jtreg output tree per test suite |
| `test-results/<suite>/newfailures.txt` | Tests that newly failed |
| `test-results/<suite>/other_errors.txt` | Tests that errored |
| `run-metadata.txt` | Boot JDK version, jtreg version, dates, exit code |

Commit info for each stream is written to `~/jdk-sources/<stream>/commit-info.txt`.

---

## License

Scripts are released under the [MIT License](LICENSE).
