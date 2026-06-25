#!/usr/bin/env python3
"""
gen_status.py — Generate GitHub-readable status pages from CI run artefacts.

Called by run_daily.sh after every pipeline run.

Usage:
    python3 scripts/gen_status.py <reports_dir> <repo_root>

Outputs (both paths relative to repo_root):
    STATUS.md
        Top-level dashboard: one row per stream×level combination showing
        current status, consecutive-failure count, last-pass date, last-fail
        date, and a mini history sparkline of the last 14 runs.

    reports/<YYYY>/<Month>/<DD>/run-summary.md
        Per-run Markdown report (GitHub renders it when you browse the folder).

    reports/<YYYY>/<Month>/<DD>/<stream>/<level>/test-passed.md
        Tests that passed in this run (one per line, formatted as Markdown).

    reports/<YYYY>/<Month>/<DD>/<stream>/<level>/test-failed.md
        Tests that failed in this run; each entry annotated with how many
        consecutive days this test has been failing (derived from history).

    reports/<YYYY>/<Month>/<DD>/<stream>/<level>/test-skipped.md
        Tests that were skipped / not-run in this run.

Retention policy:
    Day directories older than 90 days are deleted from disk and removed from
    the git index so they are wiped from GitHub on the next push.
    hs_err/ and test-support/ (*.jtr) subdirectories are also purged for any
    day directory that survives but crosses the 90-day threshold mid-run.

Exit codes:
    0  — both files written successfully
    1  — fatal error (e.g. reports_dir doesn't exist)
"""

import sys
import os
import re
import json
import shutil
import subprocess
from datetime import datetime, timezone, date as _date, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# Status vocabulary — maps the text written to run-metadata.txt / STREAM_STATUS
# to a symbol and a short description.
# ---------------------------------------------------------------------------
STATUS_ICON = {
    "TEST_PASSED":           "✅",
    "TEST_FAILED":           "❌",
    "TEST_SKIPPED_NO_JTREG": "⚠️",
    "BUILD_FAILED":          "🔴",
    "SKIPPED_SOURCE_FAIL":   "⚠️",
    "SKIPPED_BOOT_JDK_FAIL": "🔴",
    "SKIPPED_FILTER":        "–",
    "SKIPPED_DRY_RUN":       "–",
    "SKIPPED_EOL":           "–",
    "UNKNOWN":               "❓",
}

STATUS_LABEL = {
    "TEST_PASSED":           "Passed",
    "TEST_FAILED":           "Failed",
    "TEST_SKIPPED_NO_JTREG": "No jtreg",
    "BUILD_FAILED":          "Build failed",
    "SKIPPED_SOURCE_FAIL":   "Source fail",
    "SKIPPED_BOOT_JDK_FAIL": "Boot JDK fail",
    "SKIPPED_FILTER":        "Filtered",
    "SKIPPED_DRY_RUN":       "Dry run",
    "SKIPPED_EOL":           "EOL",
    "UNKNOWN":               "Unknown",
}

# Statuses that count as "failing" for the regression-detection logic
FAILING_STATUSES = {"TEST_FAILED", "BUILD_FAILED", "SKIPPED_SOURCE_FAIL",
                    "SKIPPED_BOOT_JDK_FAIL"}

# Statuses that count as "passing"
PASSING_STATUSES = {"TEST_PASSED"}


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
class RunRecord:
    """One stream×level result from one day's run."""
    __slots__ = ("date", "stream", "level", "status", "detail")

    def __init__(self, date, stream, level, status, detail=""):
        self.date = date        # datetime.date
        self.stream = stream
        self.level = level
        self.status = status
        self.detail = detail


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------
def _parse_run_summary(summary_path: Path, run_date):
    """
    Parse a run-summary.txt and return a list of RunRecord objects.

    The file format written by write_run_summary() in run_daily.sh looks like:

        ── head ──────────────────────────────────────────
          fastdebug     TEST_PASSED                   all tier1 tests passed
          release       TEST_FAILED                   tier1 completed with failures…
    """
    records = []
    current_stream = None

    with summary_path.open(errors="replace") as fh:
        for line in fh:
            # Stream header: "  ── head ──…"
            m = re.match(r"\s+──\s+(\S+)\s+──", line)
            if m:
                current_stream = m.group(1)
                continue

            # Result line: "    fastdebug     TEST_PASSED    detail…"
            if current_stream:
                m = re.match(r"\s{4}(\S+)\s{2,}(\S+)\s*(.*)", line)
                if m:
                    level, status, detail = m.group(1), m.group(2), m.group(3).strip()
                    records.append(RunRecord(run_date, current_stream, level, status, detail))

    return records


def collect_all_runs(reports_dir: Path):
    """
    Walk reports/<YYYY>/<Month>/<DD>/run-summary.txt and return a list of
    RunRecord objects sorted oldest-first.
    """
    MONTHS = {
        "January": 1, "February": 2, "March": 3, "April": 4,
        "May": 5, "June": 6, "July": 7, "August": 8,
        "September": 9, "October": 10, "November": 11, "December": 12,
    }

    all_records = []

    for year_dir in sorted(reports_dir.iterdir()):
        if not year_dir.is_dir() or not year_dir.name.isdigit():
            continue
        year = int(year_dir.name)

        for month_dir in sorted(year_dir.iterdir()):
            if not month_dir.is_dir():
                continue
            month_num = MONTHS.get(month_dir.name)
            if month_num is None:
                continue

            for day_dir in sorted(month_dir.iterdir()):
                if not day_dir.is_dir() or not day_dir.name.isdigit():
                    continue
                day = int(day_dir.name)

                summary = day_dir / "run-summary.txt"
                if not summary.exists():
                    continue

                try:
                    run_date = datetime(year, month_num, day,
                                        tzinfo=timezone.utc).date()
                    recs = _parse_run_summary(summary, run_date)
                    all_records.extend(recs)
                except Exception as exc:
                    print(f"[gen_status] WARNING: could not parse {summary}: {exc}",
                          file=sys.stderr)

    all_records.sort(key=lambda r: r.date)
    return all_records


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------
def build_key_history(all_records, lookback=14):
    """
    Returns a dict:
        key (stream/level) → {
            "history":           list of (date, status) newest-first, len ≤ lookback
            "current_status":    most recent status string
            "current_date":      most recent run date
            "last_pass_date":    date of most recent PASS, or None
            "last_fail_date":    date of most recent FAIL, or None
            "consec_fails":      consecutive failing runs (newest streak)
            "first_fail_date":   start of the current failing streak, or None
        }
    """
    # Group by key, newest-first
    from collections import defaultdict
    by_key = defaultdict(list)
    for r in reversed(all_records):
        by_key[f"{r.stream}/{r.level}"].append(r)

    result = {}
    for key, recs in by_key.items():
        history = [(r.date, r.status) for r in recs[:lookback]]
        current = recs[0]

        last_pass = next((d for d, s in history if s in PASSING_STATUSES), None)
        last_fail = next((d for d, s in history if s in FAILING_STATUSES), None)

        # Count consecutive failures from the top of history
        consec_fails = 0
        first_fail = None
        for d, s in history:
            if s in FAILING_STATUSES:
                consec_fails += 1
                first_fail = d
            else:
                break

        result[key] = {
            "history":        history,
            "current_status": current.status,
            "current_date":   current.date,
            "last_pass_date": last_pass,
            "last_fail_date": last_fail,
            "consec_fails":   consec_fails,
            "first_fail_date": first_fail,
        }

    return result


def sparkline(history):
    """
    Build a compact 14-char sparkline string from newest-to-oldest history.
    ✅ pass  ❌ fail  🔴 build  ⚠ warn  · skip/unknown
    """
    chars = []
    for _d, s in history:
        if s in PASSING_STATUSES:
            chars.append("🟢")
        elif s in FAILING_STATUSES:
            chars.append("🔴")
        elif s in ("TEST_SKIPPED_NO_JTREG", "SKIPPED_SOURCE_FAIL"):
            chars.append("🟡")
        else:
            chars.append("⬜")
    return "".join(chars)


# ---------------------------------------------------------------------------
# Markdown generation
# ---------------------------------------------------------------------------
def gen_status_md(key_history, reports_dir: Path, generated_at) -> str:
    """Return the full text of STATUS.md."""

    lines = []
    lines.append("# OpenJDK s390x CI — Build Status\n")
    lines.append(f"> Last updated: **{generated_at}**  \n")
    lines.append(f"> Reports directory: `{reports_dir.name}/`\n\n")

    # ---- Alert section: currently failing streams -----------------------
    failing = {k: v for k, v in key_history.items()
               if v["current_status"] in FAILING_STATUSES}
    if failing:
        lines.append("## 🚨 Currently Failing\n\n")
        for key, info in sorted(failing.items()):
            streak = info["consec_fails"]
            since = info["first_fail_date"]
            lp = info["last_pass_date"] or "never"
            icon = STATUS_ICON.get(info["current_status"], "❓")
            lines.append(
                f"- **`{key}`** {icon} `{info['current_status']}`  \n"
                f"  Failing since **{since}** ({streak} consecutive run{'s' if streak != 1 else ''})  \n"
                f"  Last passed: **{lp}**\n\n"
            )
    else:
        lines.append("## ✅ All streams passing\n\n")

    # ---- Full status table -----------------------------------------------
    lines.append("## Stream Status\n\n")
    lines.append("| Stream / Level | Status | Since | Consec. Fails | Last Pass | Last Fail | Recent (newest→oldest) |\n")
    lines.append("|---|---|---|---|---|---|---|\n")

    for key in sorted(key_history):
        info = key_history[key]
        icon = STATUS_ICON.get(info["current_status"], "❓")
        label = STATUS_LABEL.get(info["current_status"], info["current_status"])
        lp = str(info["last_pass_date"]) if info["last_pass_date"] else "–"
        lf = str(info["last_fail_date"]) if info["last_fail_date"] else "–"
        since = str(info["first_fail_date"]) if info["first_fail_date"] else "–"
        cf = str(info["consec_fails"]) if info["consec_fails"] > 0 else "–"
        spark = sparkline(info["history"])
        lines.append(
            f"| `{key}` | {icon} {label} | {since} | {cf} | {lp} | {lf} | {spark} |\n"
        )

    lines.append("\n")

    # ---- Legend ---------------------------------------------------------
    lines.append("<details><summary>Legend</summary>\n\n")
    lines.append("| Symbol | Meaning |\n|---|---|\n")
    lines.append("| 🟢 | Tier1 tests passed |\n")
    lines.append("| 🔴 | Build failed or boot JDK failed |\n")
    lines.append("| 🟡 | Tests skipped (jtreg missing) or source failure |\n")
    lines.append("| ⬜ | Skipped / filtered / EOL |\n")
    lines.append("\n**Status codes**\n\n")
    for code, desc in STATUS_LABEL.items():
        lines.append(f"- `{code}` — {desc}\n")
    lines.append("\n</details>\n\n")

    # ---- How to bisect a regression -------------------------------------
    lines.append("<details><summary>How to bisect a regression</summary>\n\n")
    lines.append("1. Find the stream's `reports/YYYY/Month/DD/head/commit-info.txt`\n")
    lines.append("   for the first failing day.\n")
    lines.append("2. That file contains:\n")
    lines.append("   ```\n")
    lines.append("   bisect_cmd: git bisect start <fail_commit> <last_good_commit>\n")
    lines.append("   ```\n")
    lines.append("3. Run that command in the JDK source tree and use\n")
    lines.append("   `make run-test-tier1` as the bisect test.\n")
    lines.append("\n</details>\n")

    return "".join(lines)


def gen_run_md(all_records_today, run_date, host, boot_jdk, jtreg_ver,
               reports_subpath) -> str:
    """Return per-run Markdown for reports/YYYY/Month/DD/run-summary.md."""

    lines = []
    lines.append(f"# CI Run — {run_date}\n\n")
    lines.append(f"| Field | Value |\n|---|---|\n")
    lines.append(f"| Date | `{run_date}` |\n")
    lines.append(f"| Host | `{host}` |\n")
    lines.append(f"| Boot JDK | `{boot_jdk}` |\n")
    lines.append(f"| jtreg | `{jtreg_ver}` |\n")
    lines.append(f"| Reports path | `{reports_subpath}` |\n\n")

    lines.append("## Results\n\n")
    lines.append("| Stream | Level | Status | Detail |\n|---|---|---|---|\n")

    for r in sorted(all_records_today, key=lambda x: (x.stream, x.level)):
        icon = STATUS_ICON.get(r.status, "❓")
        lines.append(f"| `{r.stream}` | `{r.level}` | {icon} `{r.status}` | {r.detail} |\n")

    lines.append("\n")

    # Link to full logs
    lines.append("## Files in this directory\n\n")
    lines.append("| File | Description |\n|---|---|\n")
    lines.append("| `pipeline.log` | Full timestamped run output |\n")
    lines.append("| `run-summary.txt` | Machine-readable status (parsed by gen_status.py) |\n")
    lines.append("| `deps-failure.txt` | Present only if a dependency download failed |\n")
    lines.append("| `<stream>/top_commit` | HEAD commit that was built and tested |\n")
    lines.append("| `<stream>/commit-info.txt` | Pre/post-pull commits + bisect command |\n")
    lines.append("| `<stream>/<level>/build.log` | Full make output |\n")
    lines.append("| `<stream>/<level>/test-summary.txt` | jtreg pass/fail totals |\n")
    lines.append("| `<stream>/<level>/newfailures.txt` | Failing test names |\n")
    lines.append("| `<stream>/<level>/run-metadata.txt` | Versions, exit codes, dates |\n")

    return "".join(lines)


# ---------------------------------------------------------------------------
# Per-test failure history: build a dict of test_name → days-failing
# by scanning historical test-failed.txt files
# ---------------------------------------------------------------------------
def build_test_failure_history(reports_dir: Path, stream: str, level: str,
                                cutoff_date) -> dict:
    """
    Walk all <stream>/<level>/test-failed.txt files older than cutoff_date
    and return a dict mapping test_name → first date it was seen failing
    (i.e. the start of its current failing streak).

    We stop counting a streak when a date gap appears (i.e. the test passed
    on a day that has a run directory but no entry in that day's failed list).
    """
    MONTHS = {
        "January": 1, "February": 2, "March": 3, "April": 4,
        "May": 5, "June": 6, "July": 7, "August": 8,
        "September": 9, "October": 10, "November": 11, "December": 12,
    }

    # Collect (date, set_of_failed_tests) pairs sorted oldest-first
    dated_failures: list[tuple] = []

    for year_dir in sorted(reports_dir.iterdir()):
        if not year_dir.is_dir() or not year_dir.name.isdigit():
            continue
        year = int(year_dir.name)
        for month_dir in sorted(year_dir.iterdir()):
            if not month_dir.is_dir():
                continue
            month_num = MONTHS.get(month_dir.name)
            if month_num is None:
                continue
            for day_dir in sorted(month_dir.iterdir()):
                if not day_dir.is_dir() or not day_dir.name.isdigit():
                    continue
                day = int(day_dir.name)
                try:
                    run_date = _date(year, month_num, day)
                except ValueError:
                    continue
                failed_txt = day_dir / stream / level / "test-failed.txt"
                if not failed_txt.exists():
                    # No failed.txt means either tests passed or no run that day.
                    # We record an empty set so streak detection can break.
                    dated_failures.append((run_date, set()))
                    continue
                tests = set()
                with failed_txt.open(errors="replace") as fh:
                    for ln in fh:
                        ln = ln.strip()
                        if ln and not ln.startswith("("):
                            tests.add(ln)
                dated_failures.append((run_date, tests))

    # For each test seen in the LATEST entry, walk backwards to find streak start
    if not dated_failures:
        return {}

    latest_failed = dated_failures[-1][1]
    first_seen: dict = {}
    for test_name in latest_failed:
        # Walk backward until the test is absent (streak break)
        streak_start = dated_failures[-1][0]
        for run_date, failed_set in reversed(dated_failures[:-1]):
            if test_name in failed_set:
                streak_start = run_date
            else:
                break
        first_seen[test_name] = streak_start

    return first_seen


def gen_test_result_md(level_dir: Path, stream: str, level: str,
                       reports_dir: Path, run_date) -> None:
    """
    Write test-passed.md, test-failed.md, and test-skipped.md into level_dir.

    test-failed.md includes an annotation of how many days each test has been
    failing, derived by scanning historical test-failed.txt files.
    """
    today = run_date  # already a date object (_date instance)

    def _read_list(fname: str) -> list:
        p = level_dir / fname
        if not p.exists():
            return []
        lines = []
        with p.open(errors="replace") as fh:
            for ln in fh:
                ln = ln.strip()
                if ln and not ln.startswith("("):
                    lines.append(ln)
        return lines

    passed  = _read_list("test-passed.txt")
    failed  = _read_list("test-failed.txt")
    skipped = _read_list("test-skipped.txt")

    run_date_str = str(today)

    # ---- test-passed.md -------------------------------------------------
    lines = [f"# ✅ Tier1 Tests Passed — {run_date_str}\n\n"]
    lines.append(f"**Stream:** `{stream}`  **Level:** `{level}`  "
                 f"**Date:** `{run_date_str}`\n\n")
    if passed:
        lines.append(f"**{len(passed)} test(s) passed.**\n\n")
        lines.append("| # | Test |\n|---|---|\n")
        for i, t in enumerate(sorted(passed), 1):
            lines.append(f"| {i} | `{t}` |\n")
    else:
        lines.append("_No passing tests recorded (tests may have been skipped or "
                     "the run did not produce .jtr files)._\n")
    (level_dir / "test-passed.md").write_text("".join(lines), encoding="utf-8")

    # ---- test-failed.md -------------------------------------------------
    # Build per-test "failing since" information
    first_seen = build_test_failure_history(reports_dir, stream, level, today)

    lines = [f"# ❌ Tier1 Tests Failed — {run_date_str}\n\n"]
    lines.append(f"**Stream:** `{stream}`  **Level:** `{level}`  "
                 f"**Date:** `{run_date_str}`\n\n")
    if failed:
        lines.append(f"**{len(failed)} test(s) failed.**\n\n")
        lines.append("| # | Test | Failing since | Days failing |\n|---|---|---|---|\n")
        for i, t in enumerate(sorted(failed), 1):
            since = first_seen.get(t)
            if since:
                delta = (today - since).days
                days_str = f"{delta} day{'s' if delta != 1 else ''}"
                since_str = str(since)
            else:
                days_str = "1 (first seen today)"
                since_str = run_date_str
            lines.append(f"| {i} | `{t}` | {since_str} | {days_str} |\n")
        lines.append("\n")
        lines.append("> hs_err files (JVM crash logs) are stored locally in "
                     "`hs_err/<run_timestamp>/` inside the level artefact directory.\n")
    else:
        lines.append("_No test failures recorded in this run._\n")
    (level_dir / "test-failed.md").write_text("".join(lines), encoding="utf-8")

    # ---- test-skipped.md ------------------------------------------------
    lines = [f"# ⏭️ Tier1 Tests Skipped — {run_date_str}\n\n"]
    lines.append(f"**Stream:** `{stream}`  **Level:** `{level}`  "
                 f"**Date:** `{run_date_str}`\n\n")
    if skipped:
        lines.append(f"**{len(skipped)} test(s) skipped / not-run.**\n\n")
        lines.append("| # | Test |\n|---|---|\n")
        for i, t in enumerate(sorted(skipped), 1):
            lines.append(f"| {i} | `{t}` |\n")
    else:
        lines.append("_No skipped tests recorded in this run._\n")
    (level_dir / "test-skipped.md").write_text("".join(lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# Retention purge — remove artefacts older than RETENTION_DAYS from disk
# and from the git index so they are wiped from GitHub on the next push.
#
# Two-level strategy:
#   1. Day directories whose date is > 90 days old are removed entirely
#      (all files including any hs_err/ and .jtr files inside them).
#   2. For day directories that are still within the 90-day window, any
#      surviving hs_err/ or test-support/ (*.jtr) subdirectories are removed
#      because those were explicitly excluded from earlier pushes but may
#      exist locally and should not linger beyond 90 days either.
#
# git rm is run in --cached mode (removes from index / GitHub, keeps no disk
# copy beyond what shutil.rmtree already deleted).  Errors from git rm are
# non-fatal — the directory may never have been tracked.
#
# Arguments:
#   reports_dir   — Path to the reports/ root
#   repo_root     — Path to the repository root (for git commands)
#   retention_days — integer, default 90
# ---------------------------------------------------------------------------
RETENTION_DAYS = 90

_MONTH_NUMS = {
    "January": 1, "February": 2, "March": 3,  "April": 4,
    "May":     5, "June":     6, "July":     7, "August": 8,
    "September": 9, "October": 10, "November": 11, "December": 12,
}


def _git_rm_cached(path: Path, repo_root: Path) -> None:
    """Stage a deletion in the git index (no-op if path was never tracked)."""
    rel = str(path.relative_to(repo_root))
    subprocess.run(
        ["git", "rm", "-r", "--cached", "--ignore-unmatch", "--quiet", rel],
        cwd=str(repo_root),
        check=False,
        capture_output=True,
    )


def purge_old_data(reports_dir: Path, repo_root: Path,
                   retention_days: int = RETENTION_DAYS) -> None:
    """
    Delete all report artefacts older than retention_days from both disk
    and the git index.  Also removes hs_err/ and test-support/ trees inside
    any day directory regardless of age (those are local-only by policy).
    """
    cutoff = _date.today() - timedelta(days=retention_days)
    removed_dirs: list[Path] = []
    local_only_dirs: list[Path] = []   # hs_err/ and test-support/ to nuke locally

    for year_dir in sorted(reports_dir.iterdir()):
        if not year_dir.is_dir() or not year_dir.name.isdigit():
            continue
        year = int(year_dir.name)

        for month_dir in sorted(year_dir.iterdir()):
            if not month_dir.is_dir():
                continue
            month_num = _MONTH_NUMS.get(month_dir.name)
            if month_num is None:
                continue

            for day_dir in sorted(month_dir.iterdir()):
                if not day_dir.is_dir() or not day_dir.name.isdigit():
                    continue
                day = int(day_dir.name)
                try:
                    run_date = _date(year, month_num, day)
                except ValueError:
                    continue

                if run_date < cutoff:
                    # Entire day directory is past retention — remove everything
                    removed_dirs.append(day_dir)
                else:
                    # Day is within retention window: only purge local-only dirs
                    for pattern in ("hs_err", "test-support"):
                        for local_dir in day_dir.rglob(pattern):
                            if local_dir.is_dir():
                                local_only_dirs.append(local_dir)

    # ---- Purge stale day directories (disk + git index) ------------------
    for day_dir in removed_dirs:
        rel = day_dir.relative_to(reports_dir)
        print(f"[gen_status] PURGE (>{retention_days}d): {rel}", file=sys.stderr)
        _git_rm_cached(day_dir, repo_root)
        shutil.rmtree(day_dir, ignore_errors=True)

    # Remove empty month/year parent directories left behind
    for year_dir in sorted(reports_dir.iterdir()):
        if not year_dir.is_dir() or not year_dir.name.isdigit():
            continue
        for month_dir in sorted(year_dir.iterdir()):
            if month_dir.is_dir() and not any(month_dir.iterdir()):
                month_dir.rmdir()
        if year_dir.is_dir() and not any(year_dir.iterdir()):
            year_dir.rmdir()

    # ---- Purge local-only subdirs (disk only — never in index) -----------
    for local_dir in local_only_dirs:
        rel = local_dir.relative_to(reports_dir)
        print(f"[gen_status] PURGE local-only: {rel}", file=sys.stderr)
        shutil.rmtree(local_dir, ignore_errors=True)

    total = len(removed_dirs) + len(local_only_dirs)
    if total == 0:
        print(f"[gen_status] Retention purge: nothing to remove "
              f"(cutoff={cutoff}, window={retention_days}d).", file=sys.stderr)
    else:
        print(f"[gen_status] Retention purge complete: "
              f"{len(removed_dirs)} day dir(s) removed from git+disk, "
              f"{len(local_only_dirs)} local-only dir(s) removed from disk.",
              file=sys.stderr)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main():
    # Optional --purge-only flag: run the retention purge and exit immediately
    # without regenerating any Markdown.  Used by run_daily.sh and jdk.sh to
    # fire the purge as an independent early stage before gen_status_pages.
    purge_only = "--purge-only" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--purge-only"]

    if len(args) < 2:
        print(f"Usage: {sys.argv[0]} <reports_dir> <repo_root> [--purge-only]",
              file=sys.stderr)
        sys.exit(1)

    reports_dir = Path(args[0]).resolve()
    repo_root   = Path(args[1]).resolve()

    if not reports_dir.is_dir():
        print(f"[gen_status] ERROR: reports_dir not found: {reports_dir}",
              file=sys.stderr)
        sys.exit(1)

    # ---- Retention purge (always runs; exits here when --purge-only) ------
    purge_old_data(reports_dir, repo_root)
    if purge_only:
        sys.exit(0)

    # ---- Collect all historical run records -----------------------------
    all_records = collect_all_runs(reports_dir)
    if not all_records:
        print("[gen_status] WARNING: no run-summary.txt files found — "
              "nothing to generate.", file=sys.stderr)
        sys.exit(0)

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    # ---- Build key history ----------------------------------------------
    key_history = build_key_history(all_records, lookback=14)

    # ---- Write STATUS.md ------------------------------------------------
    status_md_path = repo_root / "STATUS.md"
    status_md = gen_status_md(key_history, reports_dir, generated_at)
    status_md_path.write_text(status_md, encoding="utf-8")
    print(f"[gen_status] Written: {status_md_path}", file=sys.stderr)

    # ---- Write per-run run-summary.md -----------------------------------
    # Identify today's run: the most recent date in all_records
    latest_date = max(r.date for r in all_records)
    today_records = [r for r in all_records if r.date == latest_date]

    # Derive run-summary.md path from the first today record's date components
    # Path structure: reports/<YYYY>/<Month>/<DD>/
    # We need to find the matching directory under reports_dir
    MONTH_NAMES = {
        1: "January", 2: "February", 3: "March", 4: "April",
        5: "May", 6: "June", 7: "July", 8: "August",
        9: "September", 10: "October", 11: "November", 12: "December",
    }
    month_name = MONTH_NAMES[latest_date.month]
    today_dir = (reports_dir
                 / str(latest_date.year)
                 / month_name
                 / f"{latest_date.day:02d}")
    today_dir.mkdir(parents=True, exist_ok=True)

    # Read host/boot_jdk/jtreg from the existing run-summary.txt if present
    summary_txt = today_dir / "run-summary.txt"
    host = "unknown"
    boot_jdk = "unknown"
    jtreg_ver = "unknown"
    if summary_txt.exists():
        with summary_txt.open(errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("Host"):
                    host = line.split(":", 1)[-1].strip()
                elif line.startswith("Boot JDK"):
                    boot_jdk = line.split(":", 1)[-1].strip()
                elif line.startswith("jtreg"):
                    jtreg_ver = line.split(":", 1)[-1].strip()

    reports_subpath = str(today_dir.relative_to(repo_root))

    run_md = gen_run_md(
        today_records,
        latest_date,
        host, boot_jdk, jtreg_ver,
        reports_subpath,
    )
    run_md_path = today_dir / "run-summary.md"
    run_md_path.write_text(run_md, encoding="utf-8")
    print(f"[gen_status] Written: {run_md_path}", file=sys.stderr)

    # ---- Write per-stream/level test result Markdown pages --------------
    for rec in today_records:
        level_dir = today_dir / rec.stream / rec.level
        if level_dir.is_dir():
            try:
                gen_test_result_md(level_dir, rec.stream, rec.level,
                                   reports_dir, latest_date)
                print(f"[gen_status] Written test result MDs: {level_dir}",
                      file=sys.stderr)
            except Exception as exc:
                print(f"[gen_status] WARNING: could not write test MDs for "
                      f"{rec.stream}/{rec.level}: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
