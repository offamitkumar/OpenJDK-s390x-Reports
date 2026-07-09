# OpenJDK s390x CI — Build Status
> Last updated: **2026-07-09 15:20 UTC**  
> Reports directory: `reports/`

## 🚨 Currently Failing

- **`head/fastdebug`** ❌ `TEST_FAILED`  
  Failing since **2026-06-25** (1 consecutive run)  
  Last passed: **never**

- **`head/release`** ❌ `TEST_FAILED`  
  Failing since **2026-06-25** (1 consecutive run)  
  Last passed: **never**

## Stream Status

| Stream / Level | Status | Since | Consec. Fails | Last Pass | Last Fail | Recent (newest→oldest) |
|---|---|---|---|---|---|---|
| `head/fastdebug` | ❌ Failed | 2026-06-25 | 1 | – | 2026-06-25 | 🔴 |
| `head/release` | ❌ Failed | 2026-06-25 | 1 | – | 2026-06-25 | 🔴 |
| `jdk11/fastdebug` | – Filtered | – | – | – | – | ⬜ |
| `jdk11/release` | – Filtered | – | – | – | – | ⬜ |
| `jdk17/fastdebug` | – Filtered | – | – | – | – | ⬜ |
| `jdk17/release` | – Filtered | – | – | – | – | ⬜ |
| `jdk21/fastdebug` | – Filtered | – | – | – | – | ⬜ |
| `jdk21/release` | – Filtered | – | – | – | – | ⬜ |
| `jdk25/fastdebug` | – Filtered | – | – | – | – | ⬜ |
| `jdk25/release` | – Filtered | – | – | – | – | ⬜ |
| `jdk26/fastdebug` | – Filtered | – | – | – | – | ⬜ |
| `jdk26/release` | – Filtered | – | – | – | – | ⬜ |

<details><summary>Legend</summary>

| Symbol | Meaning |
|---|---|
| 🟢 | Tier1 tests passed |
| 🔴 | Build failed or boot JDK failed |
| 🟡 | Tests skipped (jtreg missing) or source failure |
| ⬜ | Skipped / filtered / EOL |

**Status codes**

- `TEST_PASSED` — Passed
- `TEST_FAILED` — Failed
- `TEST_SKIPPED_NO_JTREG` — No jtreg
- `BUILD_FAILED` — Build failed
- `SKIPPED_SOURCE_FAIL` — Source fail
- `SKIPPED_BOOT_JDK_FAIL` — Boot JDK fail
- `SKIPPED_FILTER` — Filtered
- `SKIPPED_DRY_RUN` — Dry run
- `SKIPPED_EOL` — EOL
- `UNKNOWN` — Unknown

</details>

<details><summary>How to bisect a regression</summary>

1. Find the stream's `reports/YYYY/Month/DD/head/commit-info.txt`
   for the first failing day.
2. That file contains:
   ```
   bisect_cmd: git bisect start <fail_commit> <last_good_commit>
   ```
3. Run that command in the JDK source tree and use
   `make run-test-tier1` as the bisect test.

</details>
