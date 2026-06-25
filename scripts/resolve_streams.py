#!/usr/bin/env python3
"""
resolve_streams.py — Determine which JDK streams are currently active.

Usage:
    python3 scripts/resolve_streams.py

Output (stdout): one line per active stream, pipe-separated, identical format
to JDK_STREAMS entries in config.sh:
    head|jdk|https://...|21|
    jdk21|jdk21u-dev|https://...|21|
    ...

Logic:
  - Queries the Adoptium API for currently active LTS versions and the
    most recent non-LTS feature release.
  - Reads the stream registry passed in on stdin (one entry per line,
    pipe-separated, same format as JDK_STREAMS in config.sh).
  - Emits only the streams whose version number is in the active set,
    plus HEAD (label "head") which is always included.
  - Exits 0 on success, 1 on API failure (caller should fall back to
    the full registry if desired).

Version extraction rule:
  - "head"       → always active
  - "jdkNN..."   → extract NN; active if NN is in lts_releases ∪ {most_recent_feature}
"""

import sys
import json
import urllib.request
import urllib.error
import re


ADOPTIUM_API = "https://api.adoptium.net/v3/info/available_releases"
TIMEOUT = 20


def fetch_active_versions():
    """Return (lts_set, feature_release) from the Adoptium API."""
    try:
        with urllib.request.urlopen(ADOPTIUM_API, timeout=TIMEOUT) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"[resolve_streams] WARNING: Adoptium API unreachable: {exc}",
              file=sys.stderr)
        return None, None

    lts = set(data.get("available_lts_releases", []))
    feature = data.get("most_recent_feature_release", 0)
    return lts, feature


def version_from_label(label):
    """
    Extract the numeric JDK version from a stream label.
    'head'  → None  (special: always active)
    'jdk21' → 21
    'jdk17' → 17
    """
    if label == "head":
        return None
    m = re.match(r"^jdk(\d+)", label)
    return int(m.group(1)) if m else None


def main():
    lts_set, feature_release = fetch_active_versions()

    # If API is unreachable, print all streams unchanged (safe fallback)
    if lts_set is None:
        print("[resolve_streams] Falling back: emitting all registered streams",
              file=sys.stderr)
        for line in sys.stdin:
            line = line.strip()
            if line:
                print(line)
        return

    active_versions = lts_set | {feature_release}

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        label = line.split("|")[0]
        ver = version_from_label(label)

        if ver is None:
            # HEAD — always emit
            print(line)
            print(f"[resolve_streams] ACTIVE  : {label} (always)", file=sys.stderr)
        elif ver in active_versions:
            print(line)
            print(f"[resolve_streams] ACTIVE  : {label} (v{ver} in {sorted(active_versions)})",
                  file=sys.stderr)
        else:
            print(f"[resolve_streams] SKIPPED : {label} (v{ver} not in active set {sorted(active_versions)})",
                  file=sys.stderr)


if __name__ == "__main__":
    main()
