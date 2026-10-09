#!/usr/bin/env python3
"""Cheap repo lints that CI runs on every push and PR (the `lint` job), and scripts/check.sh.

    python3 scripts/lint_repo.py                  # all checks
    python3 scripts/lint_repo.py --base origin/main

1. Hard rule 5, no personal hostnames: flags a *.ts.net name whose tailnet label isn't one of
   the made-up ones below, a tailnet address (100.64.0.0/10, fd7a:115c:a1e0::/48) that isn't a
   documented example, and anything matching a pattern in your local, untracked denylist (one
   regex per line, # comments): .git/info/leak-patterns, or the file NEEDS_YOU_LEAK_PATTERNS
   names. A committed list of real names would itself be the leak, so the repo only knows the
   fake ones. Scans every tracked and untracked-but-not-ignored text file, and the messages of
   the commits in the range below.
2. No AI attribution in commit messages: `Co-Authored-By:` trailers and "Generated with" lines
   in the commits of base..HEAD. The base is --base, else NEEDS_YOU_LINT_BASE (CI sets it to
   origin/<the PR's base branch>, or "none" on a push), else origin/main or main when they
   exist. "none" skips the commit checks.
3. A warning, not a failure: docs/API.md changed in the range but nothing under tests/ did.

Stdlib only, Python 3.9. Exits 1 when a check fails. Never prints a whole matching line, only
the match, so a leaked name isn't spread further than the file and line it's in.
"""
from __future__ import annotations

import argparse
import ipaddress
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Tailnet labels (the part right before .ts.net) that are obviously made up. "example" is the
# one docs should use (hub-a.example.ts.net); the rest are test fixtures and placeholders.
FAKE_TAILNETS = {
    "example", "tailnet", "other-tailnet", "t", "tail1", "tail1234",
    # Bare <name>.ts.net, used by tests as hosts that must be refused or as short fixtures.
    "a", "b", "h", "hub", "other", "evil",
}
# Tailnet addresses used as examples: Tailscale's own doc address, the range's ends, and small
# numbers nobody gets assigned by chance.
EXAMPLE_IPS = {
    "100.64.0.0", "100.64.0.1", "100.64.0.7", "100.64.0.9", "100.64.0.10", "100.64.1.2",
    "100.70.0.1", "100.101.102.103", "100.127.255.254",
    "fd7a:115c:a1e0::", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0::7",
}

TSNET_RE = re.compile(r"(?<![A-Za-z0-9-])((?:[A-Za-z0-9-]+\.)*([A-Za-z0-9-]+))\.ts\.net(?![A-Za-z0-9-])",
                      re.I)
IPV4_RE = re.compile(r"(?<![0-9.])100\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![0-9]|\.[0-9])")
IPV6_RE = re.compile(r"(?<![0-9A-Fa-f:])fd7a:115c:a1e0(?::[0-9A-Fa-f]{0,4})+", re.I)
TAILNET_V4 = ipaddress.ip_network("100.64.0.0/10")

# A Co-Authored-By trailer, or a "Generated with ..." line (with or without a leading emoji).
ATTRIBUTION_RE = re.compile(r"^\W*(co-authored-by\s*:|generated (with|by)\b)", re.I)


def git(*args, check=True):
    out = subprocess.run(["git", "-C", ROOT] + list(args), stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, universal_newlines=True)
    if check and out.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), out.stderr.strip()))
    return out


def local_patterns():
    """The untracked denylist's regexes, or [] when there's none."""
    path = os.environ.get("NEEDS_YOU_LEAK_PATTERNS")
    if not path:
        common = git("rev-parse", "--git-common-dir", check=False).stdout.strip()
        if not common:
            return []
        path = os.path.join(common if os.path.isabs(common) else os.path.join(ROOT, common),
                            "info", "leak-patterns")
    if not os.path.isfile(path):
        return []
    pats = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                pats.append(re.compile(line, re.I))
            except re.error as e:
                raise SystemExit("%s:%d: bad pattern (%s)" % (path, n, e))
    return pats


def leaks(text, patterns=()):
    """[(line number, what, match)] for every non-example tailnet name or address in text."""
    found = []
    for n, line in enumerate(text.splitlines(), 1):
        scan = re.sub(r"%2[Ff]", "/", line)  # a URL-encoded "//host" isn't part of the name
        for m in TSNET_RE.finditer(scan):
            if m.group(2).lower() not in FAKE_TAILNETS:
                found.append((n, "tailnet name", m.group(0)))
        for m in IPV4_RE.finditer(scan):
            if any(int(x) > 255 for x in m.groups()):
                continue
            if ipaddress.ip_address(m.group(0)) in TAILNET_V4 and m.group(0) not in EXAMPLE_IPS:
                found.append((n, "tailnet address", m.group(0)))
        for m in IPV6_RE.finditer(scan):
            addr = m.group(0).lower()
            if addr.endswith(":") and not addr.endswith("::"):
                addr = addr[:-1]
            if addr not in EXAMPLE_IPS:
                found.append((n, "tailnet address", m.group(0)))
        for p in patterns:
            for m in p.finditer(line):
                found.append((n, "local denylist", m.group(0)))
    return found


def attribution(message):
    """The lines of a commit message that credit an AI or a co-author."""
    return [line.strip() for line in message.splitlines()
            if ATTRIBUTION_RE.match(line)]


def repo_files():
    out = git("ls-files", "-z", "--cached", "--others", "--exclude-standard").stdout
    return sorted(p for p in set(out.split("\0")) if p and os.path.isfile(os.path.join(ROOT, p)))


def read_text(path):
    try:
        with open(os.path.join(ROOT, path), "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    if b"\0" in data[:8192]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def check_files(patterns):
    bad = 0
    for path in repo_files():
        text = read_text(path)
        if text is None:
            continue
        for n, what, match in leaks(text, patterns):
            print("%s:%d: %s %r: use hub-a.example.ts.net, <tailnet>, devbox (hard rule 5)"
                  % (path, n, what, match))
            bad += 1
    return bad


def resolve_base(arg):
    base = arg or os.environ.get("NEEDS_YOU_LINT_BASE", "")
    if base == "none":
        return None
    if base:
        if git("rev-parse", "--verify", "--quiet", base + "^{commit}", check=False).returncode != 0:
            raise SystemExit("lint_repo: base %r isn't a commit here (fetch it, or pass --base none)" % base)
        return base
    for ref in ("origin/main", "main"):
        if git("rev-parse", "--verify", "--quiet", ref + "^{commit}", check=False).returncode == 0:
            return ref
    return None


def check_commits(base, patterns):
    bad = 0
    shas = git("rev-list", "%s..HEAD" % base).stdout.split()
    for sha in shas:
        msg = git("log", "-1", "--format=%B", sha).stdout
        for line in attribution(msg):
            print("commit %s: %r: no AI or co-author attribution in commit messages" % (sha[:10], line))
            bad += 1
        for n, what, match in leaks(msg, patterns):
            print("commit %s: message line %d: %s %r (hard rule 5)" % (sha[:10], n, what, match))
            bad += 1
    changed = set(git("diff", "--name-only", "%s...HEAD" % base).stdout.split())
    if "docs/API.md" in changed and not any(p.startswith("tests/") for p in changed):
        print("warning: docs/API.md changed since %s but nothing under tests/ did "
              "(wire changes come with hub tests; see the api-change skill)" % base)
    return bad, len(shas)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--base", help='compare commits against this ref ("none" skips the commit checks)')
    args = ap.parse_args(argv)
    patterns = local_patterns()
    bad = check_files(patterns)
    base = resolve_base(args.base)
    if base is None:
        print("lint_repo: no base ref, commit messages not checked")
    else:
        n, count = check_commits(base, patterns)
        bad += n
        print("lint_repo: %d commit(s) since %s checked" % (count, base))
    if patterns:
        print("lint_repo: %d local denylist pattern(s) applied" % len(patterns))
    if bad:
        print("lint_repo: %d problem(s)" % bad)
        return 1
    print("lint_repo: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
