# CI Run — 2026-06-25

| Field | Value |
|---|---|
| Date | `2026-06-25` |
| Host | `t8360021.lnxne.boe` |
| Boot JDK | `openjdk version "28-beta" 2027-03-23` |
| jtreg | `jtreg 8.4-dev+0` |
| Reports path | `reports/2026/June/25` |

## Results

| Stream | Level | Status | Detail |
|---|---|---|---|
| `head` | `fastdebug` | ❌ `TEST_FAILED` | tier1 completed with failures/errors (jtreg exit=2); see newfailures.txt |
| `head` | `release` | ❌ `TEST_FAILED` | tier1 completed with failures/errors (jtreg exit=2); see newfailures.txt |
| `jdk11` | `fastdebug` | – `SKIPPED_FILTER` | Excluded by --stream head |
| `jdk11` | `release` | – `SKIPPED_FILTER` | Excluded by --stream head |
| `jdk17` | `fastdebug` | – `SKIPPED_FILTER` | Excluded by --stream head |
| `jdk17` | `release` | – `SKIPPED_FILTER` | Excluded by --stream head |
| `jdk21` | `fastdebug` | – `SKIPPED_FILTER` | Excluded by --stream head |
| `jdk21` | `release` | – `SKIPPED_FILTER` | Excluded by --stream head |
| `jdk25` | `fastdebug` | – `SKIPPED_FILTER` | Excluded by --stream head |
| `jdk25` | `release` | – `SKIPPED_FILTER` | Excluded by --stream head |
| `jdk26` | `fastdebug` | – `SKIPPED_FILTER` | Excluded by --stream head |
| `jdk26` | `release` | – `SKIPPED_FILTER` | Excluded by --stream head |

## Files in this directory

| File | Description |
|---|---|
| `pipeline.log` | Full timestamped run output |
| `run-summary.txt` | Machine-readable status (parsed by gen_status.py) |
| `deps-failure.txt` | Present only if a dependency download failed |
| `<stream>/top_commit` | HEAD commit that was built and tested |
| `<stream>/commit-info.txt` | Pre/post-pull commits + bisect command |
| `<stream>/<level>/build.log` | Full make output |
| `<stream>/<level>/test-summary.txt` | jtreg pass/fail totals |
| `<stream>/<level>/newfailures.txt` | Failing test names |
| `<stream>/<level>/run-metadata.txt` | Versions, exit codes, dates |
