#!/usr/bin/env python3
"""
resolve_streams.py — Filter the JDK stream registry to currently active versions.

Called by run_daily.sh:
    echo "${JDK_STREAMS[*]}" | python3 scripts/resolve_streams.py

Reads:  stdin  — one stream entry per line, pipe-separated
                 (same format as JDK_STREAMS in config.sh)
Writes: stdout — active entries, unchanged
        stderr — one status line per entry (ACTIVE / SKIPPED / FALLBACK)

Active-set definition
---------------------
We query:  https://api.adoptium.net/v3/info/available_releases

The relevant fields and what they mean:

  available_lts_releases      All LTS versions (past + present) that ever had
                              a GA release.  Currently: [8, 11, 17, 21, 25].
                              NOTE: this includes 8, which we exclude from the
                              registry manually (different build system).

  most_recent_feature_release The single current non-LTS feature release that
                              is still receiving updates.  Currently: 26.
                              Once 27 GAs, this becomes 27 and 26 is silently
                              dropped.

  available_releases          Every version that has *ever* shipped, including
                              EOL ones (23, 24, …).  We deliberately ignore
                              this field — it would re-activate dead streams.

  tip_version                 The current JDK HEAD version (28).  Not used
                              here; setup_deps.sh uses it to pick the boot JDK.

Active set = available_lts_releases ∪ {most_recent_feature_release}

HEAD (label "head") is always emitted, regardless of the API response.

Fallback behaviour
------------------
If the API is unreachable (network error, rate-limit, etc.) we emit ALL
registered streams unchanged.  This is intentionally conservative: it is
better to run an extra retired stream than to skip everything.
"""

import sys
import json
import urllib.request
import urllib.error
import re

ADOPTIUM_API = "https://api.adoptium.net/v3/info/available_releases"
TIMEOUT = 20


def fetch_active_versions():
    """
    Query the Adoptium API and return (lts_set, feature_release).
    Returns (None, None) on any failure.
    """
    try:
        req = urllib.request.Request(
            ADOPTIUM_API,
            headers={"User-Agent": "openjdk-s390x-ci/1.0"},
        )
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as exc:
        print(f"[resolve_streams] WARNING: Adoptium API unreachable: {exc}",
              file=sys.stderr)
        return None, None

    lts = set(data.get("available_lts_releases", []))
    feature = data.get("most_recent_feature_release", 0)

    print(
        f"[resolve_streams] API: LTS={sorted(lts)}  "
        f"feature={feature}  "
        f"tip={data.get('tip_version','?')}",
        file=sys.stderr,
    )
    return lts, feature


def version_from_label(label):
    """
    Extract the numeric JDK version from a stream label.
      'head'  → None   (special-cased: always active)
      'jdk21' → 21
      'jdk17' → 17
    Returns None for unrecognised labels (they will be skipped).
    """
    if label == "head":
        return None
    m = re.match(r"^jdk(\d+)", label)
    return int(m.group(1)) if m else None


def main():
    lines = [l.strip() for l in sys.stdin if l.strip()]

    lts_set, feature_release = fetch_active_versions()

    # ---- Fallback: API unreachable ----------------------------------------
    if lts_set is None:
        print(
            "[resolve_streams] FALLBACK: emitting all registered streams",
            file=sys.stderr,
        )
        for line in lines:
            print(line)
        return

    active_versions = lts_set | {feature_release}

    # ---- Filter -----------------------------------------------------------
    for line in lines:
        label = line.split("|")[0]
        ver = version_from_label(label)

        if ver is None and label == "head":
            print(line)
            print(f"[resolve_streams] ACTIVE  : {label} (always included)",
                  file=sys.stderr)

        elif ver is not None and ver in active_versions:
            print(line)
            print(
                f"[resolve_streams] ACTIVE  : {label} "
                f"(v{ver} ∈ LTS∪feature={sorted(active_versions)})",
                file=sys.stderr,
            )

        else:
            reason = (
                f"v{ver} ∉ active set {sorted(active_versions)}"
                if ver is not None
                else "unrecognised label"
            )
            print(f"[resolve_streams] SKIPPED : {label} ({reason})",
                  file=sys.stderr)


if __name__ == "__main__":
    main()
