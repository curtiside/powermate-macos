#!/usr/bin/env python3
"""powermate-stats — usage/reach dashboard for the powermate-macos project.

Checks, best-effort, every channel that has a public signal:
  - GitHub repos (stars/forks/watchers/issues)   [public API]
  - GitHub traffic: views + unique clones        [needs GITHUB_TOKEN with
    push access to curtiside repos, e.g. a curtiside PAT; skipped otherwise]
  - Ask Different Q&A views + scores             [Stack Exchange public API]
  - Macintosh Garden entry download count        [page scrape, best-effort]

Not trackable (stated so you don't wonder): Homebrew tap installs — brew's
analytics only cover homebrew/core, never third-party taps; 68kMLA /
Macintosh Repository don't expose per-link counters.

Usage:  powermate-stats.py [--csv]      # --csv also appends a row to the log
Log:    ~/.local/share/powermate-stats.csv  (one row per run; trend over time)
"""

import csv
import gzip
import io
import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

REPOS = ["curtiside/powermate-macos", "curtiside/homebrew-tap"]
SE_QUESTION = 486710  # apple.stackexchange.com self-answered Q&A
GARDEN_URL = "https://macintoshgarden.org/apps/powermate-modern-macos-powermate-macos"
CSV_PATH = os.path.expanduser("~/.local/share/powermate-stats.csv")
UA = "powermate-stats/1.0 (github.com/curtiside/powermate-macos maintainer tool)"


def fetch(url, token=None):
    """GET url, return decoded text or None. Handles SE's forced gzip."""
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept-Encoding": "gzip"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = r.read()
            if r.headers.get("Content-Encoding") == "gzip" or data[:2] == b"\x1f\x8b":
                data = gzip.GzipFile(fileobj=io.BytesIO(data)).read()
            return data.decode("utf-8", "replace")
    except Exception as e:
        print(f"  (unreachable: {url.split('/')[2]} — {e})", file=sys.stderr)
        return None


def jfetch(url, token=None):
    text = fetch(url, token)
    return json.loads(text) if text else None


# 1Password item holding the curtiside PAT (personal account, vault Private —
# NOT the work account, which is op's default here). The field name varies by
# item category, so common ones are tried in order.
OP_ACCOUNT = "my.1password.com"
OP_ITEM = "op://Private/GitHub curtiside Personal Access Token"
OP_FIELDS = ["credential", "token", "password", "GITHUB_TOKEN"]


def op_token():
    """Pull the curtiside PAT from 1Password via `op read`; None if unavailable."""
    for field in OP_FIELDS:
        try:
            r = subprocess.run(["op", "read", "--account", OP_ACCOUNT,
                                f"{OP_ITEM}/{field}"],
                               capture_output=True, text=True, timeout=60)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except FileNotFoundError:
            return None  # op CLI not installed
        except subprocess.TimeoutExpired:
            print("  (1Password: op read timed out — locked vault?)", file=sys.stderr)
            return None
    print(f"  (1Password: no readable field on '{OP_ITEM}' — tried {', '.join(OP_FIELDS)})",
          file=sys.stderr)
    return None


def github(row):
    # POWERMATE_GITHUB_TOKEN (a curtiside PAT) wins; plain GITHUB_TOKEN is
    # usually a globally-exported work token for the wrong account, so it's
    # used only as a fallback and we always say whose token we ended up with.
    token = os.environ.get("POWERMATE_GITHUB_TOKEN") or op_token() or os.environ.get("GITHUB_TOKEN")
    print("== GitHub ==")
    if token and not token.isascii():
        print("  (token contains non-ASCII characters — looks like a pasted"
              " placeholder ('…'?); use the real PAT string)")
        token = None
    if token:
        who = jfetch("https://api.github.com/user", token)
        login = who.get("login", "?") if who else "?"
        print(f"  (token authenticated as: {login})")
        if login != "curtiside":
            print("  (traffic needs a curtiside token — set POWERMATE_GITHUB_TOKEN;"
                  " skipping traffic queries)")
            token = None
    for repo in REPOS:
        d = jfetch(f"https://api.github.com/repos/{repo}")
        if not d:
            continue
        name = repo.split("/")[1]
        print(f"  {name}: {d['stargazers_count']}★  {d['forks_count']} forks  "
              f"{d['subscribers_count']} watchers  {d['open_issues_count']} open issues")
        row[f"{name}_stars"] = d["stargazers_count"]
        row[f"{name}_forks"] = d["forks_count"]
        row[f"{name}_issues"] = d["open_issues_count"]
        if token:
            views = jfetch(f"https://api.github.com/repos/{repo}/traffic/views", token)
            clones = jfetch(f"https://api.github.com/repos/{repo}/traffic/clones", token)
            if views and "count" in views:
                print(f"    last 14d: {views['count']} views ({views['uniques']} unique), "
                      f"{clones['count']} clones ({clones['uniques']} unique)")
                row[f"{name}_views14d"] = views["count"]
                row[f"{name}_clones14d"] = clones["count"]
            else:
                print("    traffic: token lacks push access to this repo")
    if not token:
        print("  (traffic views/clones skipped — set POWERMATE_GITHUB_TOKEN to a"
              " curtiside PAT with repo access to enable)")


def stackexchange(row):
    print("== Ask Different ==")
    d = jfetch(f"https://api.stackexchange.com/2.3/questions/{SE_QUESTION}"
               f"?site=apple&filter=withbody")
    if not d or not d.get("items"):
        print("  (no data)")
        return
    q = d["items"][0]
    print(f"  Q{SE_QUESTION}: {q['view_count']} views  score {q['score']}  "
          f"answered={q['is_answered']}")
    row["se_views"] = q["view_count"]
    row["se_qscore"] = q["score"]
    a = jfetch(f"https://api.stackexchange.com/2.3/questions/{SE_QUESTION}"
               f"/answers?site=apple")
    if a and a.get("items"):
        top = max(a["items"], key=lambda x: x["score"])
        print(f"  answer: score {top['score']}  accepted={top['is_accepted']}")
        row["se_ascore"] = top["score"]


def garden(row):
    print("== Macintosh Garden ==")
    text = fetch(GARDEN_URL)
    if not text:
        return
    # Best-effort: Garden shows a per-file download counter; the markup has
    # shifted over the years, so try a few shapes and say so if none match.
    for pat in (r"[Dd]ownloaded\s+([\d,]+)\s+times",
                r"([\d,]+)\s+[Dd]ownloads",
                r"[Dd]ownloads?:\s*([\d,]+)"):
        m = re.search(pat, text)
        if m:
            n = int(m.group(1).replace(",", ""))
            print(f"  entry downloads: {n}")
            row["garden_downloads"] = n
            return
    print("  entry is up; no download counter found in page markup (scrape"
          " pattern may need updating)")


def main():
    row = {"date": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")}
    github(row)
    stackexchange(row)
    garden(row)
    print("== Not trackable ==")
    print("  Homebrew tap installs (brew analytics cover homebrew/core only);"
          " 68kMLA / Macintosh Repository expose no counters")
    if "--csv" in sys.argv:
        os.makedirs(os.path.dirname(CSV_PATH), exist_ok=True)
        exists = os.path.exists(CSV_PATH)
        fields = ["date", "powermate-macos_stars", "powermate-macos_forks",
                  "powermate-macos_issues", "powermate-macos_views14d",
                  "powermate-macos_clones14d", "homebrew-tap_stars",
                  "homebrew-tap_forks", "homebrew-tap_issues",
                  "homebrew-tap_views14d", "homebrew-tap_clones14d",
                  "se_views", "se_qscore", "se_ascore", "garden_downloads"]
        with open(CSV_PATH, "a", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fields, restval="")
            if not exists:
                w.writeheader()
            w.writerow({k: v for k, v in row.items() if k in fields})
        print(f"\nlogged -> {CSV_PATH}")


if __name__ == "__main__":
    main()
