# OpenJDK s390x CI Reports

Automated build and tier1 test reports for **OpenJDK on Linux/s390x (IBM Z)**.

The CI pipeline downloads a fresh [Adoptium Temurin nightly](https://adoptium.net/en-GB/temurin/nightly/)
boot JDK and the [latest jtreg](https://ci.adoptium.net/view/Dependencies/job/dependency_pipeline/lastSuccessfulBuild/artifact/jtreg/)
on every run, builds JDK head from source, runs `tier1` tests in both
`fastdebug` and `release` configurations, and commits the results to this
repository.

---

## Repository layout

```
scripts/
  config.sh        # Central configuration — edit paths here
  setup_deps.sh    # Downloads / refreshes boot JDK and jtreg
  build_test.sh    # Reusable build + test function (sourced, not run directly)
  run_daily.sh     # Orchestrator — the only script you invoke

reports/
  YYYY/Month/DD/
    head/
      top_commit          # Git log -1 of the JDK HEAD commit tested
      fastdebug/
        build.log
        test-summary.txt
        newfailures.txt
        other_errors.txt
        run-metadata.txt
      release/
        build.log
        test-summary.txt
        newfailures.txt
        other_errors.txt
        run-metadata.txt
```

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
| `HEAD_SRC_DIR` | `$JDK_SOURCES_ROOT/jdk` | JDK mainline source checkout |
| `BOOT_JDK_DIR` | `$HOME/boot_jdk_nightly` | Where the nightly boot JDK is installed |
| `JTREG_DIR` | `$HOME/jtreg` | Where jtreg is installed |
| `GTEST_DIR` | `$HOME/googletest` | Google Test (optional, for hotspot tests) |
| `REPORTS_DIR` | `<repo>/reports` | Where report artefacts are written |
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

The script:
1. Refreshes the boot JDK and jtreg.
2. Clones (first run) or pulls (subsequent runs) JDK mainline.
3. Builds `fastdebug` and `release` images.
4. Runs `make run-test-tier1` for both configurations.
5. Writes artefacts under `reports/YYYY/Month/DD/head/`.
6. Commits and pushes the results to the `main` branch.

Build errors abort the affected configuration but do **not** abort the other
one — both results are always collected.

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

> **Tip:** Set `GIT_SSH_COMMAND` or configure SSH agent forwarding so the cron
> job can push to GitHub without a passphrase prompt:
> ```bash
> # In ~/.ssh/config
> Host github.com
>   IdentityFile ~/.ssh/id_ed25519
>   IdentitiesOnly yes
> ```

---

## Overriding configuration at runtime

All `config.sh` variables can be overridden without editing any file:

```bash
# Run with a custom boot JDK
BOOT_JDK_DIR=/opt/my-jdk bash scripts/run_daily.sh

# Skip the dependency refresh (useful when deps are already current)
# Edit run_daily.sh and comment out the refresh_deps call,
# or simply run build_test directly (advanced use).
```

---

## Report artefacts explained

| File | Contents |
|---|---|
| `top_commit` | `git log -1` of the JDK commit tested |
| `build.log` | Full OpenJDK build log |
| `test-summary.txt` | Pass/fail totals from jtreg for all tier1 suites |
| `newfailures.txt` | Tests that failed in this run |
| `other_errors.txt` | Tests that errored (not a clean pass/fail) |
| `run-metadata.txt` | Boot JDK version, jtreg version, dates, exit code |

---

## Extending to other JDK streams

Open [`scripts/config.sh`](scripts/config.sh) and add a new source directory
variable (e.g. `JDK21_SRC_DIR`).  Then call `build_and_test_jdk` from
`run_daily.sh` in the same pattern as the head stream — the function is fully
parameterised by stream label, debug level, and output directory.

---

## License

Scripts are released under the [MIT License](LICENSE).
