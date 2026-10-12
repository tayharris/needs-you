#!/usr/bin/env python3
"""Automatic updates for a server hub installed by scripts/install-hub.sh.

Run by the needs-you-hub-update timer (every 6 hours). Each run:

1. reads hub-update.json next to hub.json (install-hub.sh writes it: on or off, the channel,
   the soak time, which gh);
2. asks GitHub, through `gh`, for this repo's releases and takes the newest X.Y.Z on the
   channel ("stable": not a pre-release; "prerelease": either), newer than the installed hub and
   published at least `soak_hours` ago;
3. downloads that release's install-hub.sh, SHA256SUMS and release-manifest.json and checks
   them: the installer against SHA256SUMS and the manifest, the manifest against SHA256SUMS and
   the tag, and the installer's build provenance (`gh attestation verify`: this repo's release
   workflow, that tag, a GitHub-hosted runner). Nothing is installed without provenance: a
   missing or too-old gh stops the update and says so;
4. runs that installer the way the hub was installed (--user or system), which installs the
   release's code (checking it again), keeps hub.json and the database, and restarts the hub;
5. checks the hub answers /v1/health with the new version, and if it doesn't within a minute
   stops it, puts the previous code back (and, if the new version had already migrated the
   database, the hub's own pre-migration backup of it), restarts it and checks it answers. A
   release that failed is remembered and not tried again; a newer one is.

Asked to update now (ADR 0013): the owner's POST /v1/hub/update makes the hub drop a flag,
hub-update-request, next to its database; the needs-you-hub-update.path unit starts this
updater when it appears (the timer finds it too). Nothing in the flag is read: this updater
only checks that it exists and removes it, and a requested run is the same run with the soak
time skipped, every check kept. At most one requested run per 10 minutes. Each run writes what
it did to hub-update-status.json next to hub.json, which the hub shows the owner.

Never touches the database or the config itself. Logs go to stdout (the journal); no token,
secret or invite code is ever read or printed. Exit 0: up to date, waiting out the soak, off,
or updated; 1: an update was refused or failed (the timer shows it as failed).

    needs_you_hub_update.py --mode user [--check]      # --check: say what it would do, change nothing

Standard library only, Python 3.9.
"""
from __future__ import annotations

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

REPO = "tayharris/needs-you"  # fixed here, never from a hub, a setting or the release list
WORKFLOW = REPO + "/.github/workflows/release.yml"
SLSA = "https://slsa.dev/provenance/v1"
SETTINGS_FILE = "hub-update.json"
CHANNELS = ("stable", "prerelease")
DEFAULT_SOAK_HOURS = 24
MAX_SOAK_HOURS = 24 * 30
CAPS = {"install-hub.sh": 1 << 20, "SHA256SUMS": 64 << 10, "release-manifest.json": 1 << 20}
VERSION_RE = re.compile(r"^(\d{1,6})\.(\d{1,6})\.(\d{1,6})$")
TAG_RE = re.compile(r"^v(\d{1,6}\.\d{1,6}\.\d{1,6})$")
HEALTH_WAIT = 60.0
FAILED_FILE = "hub-update-failed.json"
STATUS_FILE = "hub-update-status.json"     # written here, read by the hub (GET /v1/hub/update)
REQUEST_FILE = "hub-update-request"        # dropped by the hub next to its database, never read
REQUEST_MIN_INTERVAL = 600                 # seconds between requested runs honoured


class Refused(Exception):
    """An update that must not go ahead; the message says why, in plain words."""


_last_log = [""]


def log(msg: str) -> None:
    _last_log[0] = msg
    sys.stdout.write("needs-you-hub-update: %s\n" % msg)
    sys.stdout.flush()


def parse_version(v: Any) -> Optional[Tuple[int, int, int]]:
    m = VERSION_RE.match(v) if isinstance(v, str) else None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else None


def parse_time(s: Any) -> Optional[datetime.datetime]:
    if not isinstance(s, str):
        return None
    m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?Z$", s)
    if not m:
        return None
    try:
        return datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


def load_settings(conf_dir: str) -> Dict[str, Any]:
    """hub-update.json, with defaults for what's missing. Anything malformed turns updates off
    (the strict reading of a file we can't trust)."""
    path = os.path.join(conf_dir, SETTINGS_FILE)
    out = {"auto_update": False, "channel": "stable", "soak_hours": DEFAULT_SOAK_HOURS, "gh": ""}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except FileNotFoundError:
        out["why_off"] = "%s doesn't exist (re-run install-hub.sh to create it)" % path
        return out
    except (OSError, ValueError):
        out["why_off"] = "%s can't be read as JSON" % path
        return out
    if not isinstance(raw, dict):
        out["why_off"] = "%s isn't a JSON object" % path
        return out
    ok = True
    if raw.get("channel", "stable") not in CHANNELS:
        ok = False
    soak = raw.get("soak_hours", DEFAULT_SOAK_HOURS)
    if isinstance(soak, bool) or not isinstance(soak, (int, float)) or not 0 <= soak <= MAX_SOAK_HOURS:
        ok = False
    gh = raw.get("gh", "")
    if not isinstance(gh, str) or (gh and not os.path.isabs(gh)):
        ok = False
    if not ok:
        out["why_off"] = "%s has a bad channel, soak_hours or gh" % path
        return out
    out.update(auto_update=raw.get("auto_update") is True, channel=raw.get("channel", "stable"),
               soak_hours=soak, gh=gh)
    if not out["auto_update"]:
        out["why_off"] = "automatic updates are off in %s" % path
    return out


def installed_version(prefix: str) -> Optional[str]:
    try:
        with open(os.path.join(prefix, "hub", "needs_you_hub.py"), "r", encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r'^VERSION = "([^"]*)"', line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def pick_release(releases: Any, channel: str, current: Optional[str], soak_hours: float,
                 now: datetime.datetime) -> Tuple[Optional[Dict[str, Any]], str]:
    """The release to install, or None and why not. Only published X.Y.Z tags count; the newest
    on the channel wins, and it must be newer than `current` and past its soak."""
    cur = parse_version(current)
    best = None
    for r in releases if isinstance(releases, list) else []:
        if not isinstance(r, dict) or r.get("draft") is not False:
            continue
        if r.get("prerelease") is not False and channel != "prerelease":
            continue
        m = TAG_RE.match(r.get("tag_name") or "") if isinstance(r.get("tag_name"), str) else None
        published = parse_time(r.get("published_at"))
        if not m or published is None:
            continue
        v = parse_version(m.group(1))
        if best is None or v > best[0]:
            best = (v, m.group(1), published, r)
    if best is None:
        return None, "no published release on the %s channel" % channel
    v, version, published, _ = best
    if cur is not None and v <= cur:
        return None, "up to date (%s; newest on the %s channel is %s)" % (current, channel, version)
    ready = published + datetime.timedelta(hours=soak_hours)
    if now < ready:
        return None, "%s is out; waiting until %s (soak %s h) before installing it" % (
            version, ready.strftime("%Y-%m-%d %H:%M UTC"), ("%g" % soak_hours))
    return {"version": version, "published_at": published}, "installing %s" % version


def find_gh(settings: Dict[str, Any]) -> Optional[str]:
    forced = os.environ.get("NEEDS_YOU_GH") or settings.get("gh") or ""
    if forced:
        return forced if os.access(forced, os.X_OK) else None
    path = os.environ.get("PATH", "") + os.pathsep + os.pathsep.join(
        [os.path.expanduser("~/.local/bin"), "/usr/local/bin", "/usr/bin", "/bin"])
    return shutil.which("gh", path=path)


def run_gh(gh: str, args: List[str], timeout: float = 120) -> subprocess.CompletedProcess:
    try:
        return subprocess.run([gh] + args, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        raise Refused("gh failed (%s)" % type(e).__name__)


def gh_attests(gh: str) -> bool:
    """`gh attestation verify` with --source-ref and --deny-self-hosted-runners (gh 2.64+)."""
    try:
        r = run_gh(gh, ["attestation", "verify", "--help"], timeout=30)
    except Refused:
        return False
    text = r.stdout + r.stderr
    return r.returncode == 0 and "--source-ref" in text and "--deny-self-hosted-runners" in text


def last_line(r: subprocess.CompletedProcess) -> str:
    return ((r.stderr or "").strip().splitlines() or [""])[-1][:200]


def list_releases(gh: str) -> Any:
    r = run_gh(gh, ["api", "repos/%s/releases?per_page=30" % REPO])
    if r.returncode != 0:
        raise Refused("couldn't list the releases of %s (%s)" % (REPO, last_line(r)))
    try:
        return json.loads(r.stdout)
    except ValueError:
        raise Refused("GitHub's release list isn't JSON")


def sha_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_provenance(gh: str, path: str, sha: str, version: str) -> None:
    r = run_gh(gh, ["attestation", "verify", path, "--repo", REPO, "--signer-workflow", WORKFLOW,
                    "--source-ref", "refs/tags/v" + version, "--predicate-type", SLSA,
                    "--deny-self-hosted-runners", "--format", "json"])
    if r.returncode != 0:
        raise Refused("release v%s's install-hub.sh has no valid build provenance (%s)" % (version, last_line(r)))
    try:
        for e in json.loads(r.stdout):
            vr = e["verificationResult"]
            st, cert = vr["statement"], vr["signature"]["certificate"]
            digests = {str((s.get("digest") or {}).get("sha256") or "").lower() for s in st.get("subject") or []}
            if (sha in digests and st.get("predicateType") == SLSA
                    and cert.get("sourceRepositoryURI") == "https://github.com/" + REPO
                    and cert.get("sourceRepositoryRef") == "refs/tags/v" + version
                    and str(cert.get("buildSignerURI") or "").startswith("https://github.com/%s@" % WORKFLOW)
                    and cert.get("runnerEnvironment") == "github-hosted"):
                return
    except (ValueError, KeyError, TypeError, AttributeError):
        pass
    raise Refused("release v%s's build provenance doesn't fit its install-hub.sh" % version)


def fetch_installer(gh: str, version: str, tmp: str) -> str:
    """Downloads and checks release v<version>'s install-hub.sh; returns its path."""
    names = ["install-hub.sh", "SHA256SUMS", "release-manifest.json"]
    args = ["release", "download", "v" + version, "--repo", REPO, "--dir", tmp]
    for n in names:
        args += ["--pattern", n]
    r = run_gh(gh, args, timeout=300)
    if r.returncode != 0:
        raise Refused("gh couldn't download release v%s (%s)" % (version, last_line(r)))
    for n in names:
        p = os.path.join(tmp, n)
        if not os.path.isfile(p) or os.path.islink(p):
            raise Refused("release v%s has no %s" % (version, n))
        if os.path.getsize(p) > CAPS[n]:
            raise Refused("release v%s's %s is larger than expected" % (version, n))
    sums = {}
    with open(os.path.join(tmp, "SHA256SUMS"), "r", encoding="utf-8") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) == 2:
                sums[parts[1].lstrip("*")] = parts[0].lower()
    inst = os.path.join(tmp, "install-hub.sh")
    inst_sha = sha_file(inst)
    if inst_sha != sums.get("install-hub.sh"):
        raise Refused("release v%s's install-hub.sh doesn't match its SHA256SUMS" % version)
    rm_path = os.path.join(tmp, "release-manifest.json")
    if sha_file(rm_path) != sums.get("release-manifest.json"):
        raise Refused("release v%s's release-manifest.json doesn't match its SHA256SUMS" % version)
    try:
        with open(rm_path, "r", encoding="utf-8") as fh:
            rm = json.load(fh)
        listed = {str(a.get("name")): str(a.get("sha256") or "").lower() for a in rm.get("assets") or []}
    except (ValueError, AttributeError, TypeError):
        raise Refused("release v%s's release-manifest.json can't be read" % version)
    if rm.get("version") != version or listed.get("install-hub.sh") != inst_sha:
        raise Refused("release v%s's manifest isn't for v%s or doesn't list this install-hub.sh" % (version, version))
    with open(inst, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if not re.search(r"^INSTALLER_VERSION=%s(\s|$)" % re.escape(version), text, re.M):
        raise Refused("release v%s's install-hub.sh isn't the v%s installer" % (version, version))
    verify_provenance(gh, inst, inst_sha, version)
    return inst


def hub_health(conf_dir: str) -> Optional[str]:
    """The version the hub answers /v1/health with, on its first bind address; None if it
    doesn't answer."""
    try:
        with open(os.path.join(conf_dir, "hub.json"), "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
        bind = cfg.get("bind") or ["127.0.0.1"]
        host = (bind[0] if isinstance(bind, list) else str(bind).split(",")[0]) or "127.0.0.1"
        port = int(cfg.get("port") or 8765)
    except (OSError, ValueError, TypeError, AttributeError):
        return None
    if ":" in host and not host.startswith("["):
        host = "[%s]" % host
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open("http://%s:%d/v1/health" % (host, port), timeout=3) as resp:
            data = json.loads(resp.read(1 << 16).decode("utf-8"))
        v = data.get("version")
        return v if isinstance(v, str) else ""
    except Exception:  # noqa: BLE001 - anything at all means "not answering yet"
        return None


def db_path(conf_dir: str) -> Optional[str]:
    try:
        with open(os.path.join(conf_dir, "hub.json"), "r", encoding="utf-8") as fh:
            db = json.load(fh).get("db")
        return db if isinstance(db, str) and os.path.isabs(db) else None
    except (OSError, ValueError, AttributeError):
        return None


def schema_version(db: Optional[str]) -> Optional[int]:
    """The database's PRAGMA user_version, read-only; None if there's no database."""
    if not db or not os.path.isfile(db):
        return None
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=10)
        try:
            return int(conn.execute("PRAGMA user_version").fetchone()[0])
        finally:
            conn.close()
    except (sqlite3.Error, ValueError, TypeError):
        return None


def failed_versions(state_dir: str) -> List[str]:
    try:
        with open(os.path.join(state_dir, FAILED_FILE), "r", encoding="utf-8") as fh:
            v = json.load(fh).get("failed")
        return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []
    except (OSError, ValueError, AttributeError):
        return []


def remember_failed(state_dir: str, version: str) -> None:
    failed = failed_versions(state_dir)
    if version not in failed:
        failed.append(version)
    tmp = os.path.join(state_dir, FAILED_FILE + ".tmp")
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump({"failed": failed[-20:]}, fh)
        os.replace(tmp, os.path.join(state_dir, FAILED_FILE))
    except OSError as e:
        log("couldn't record that %s failed (%s)" % (version, type(e).__name__))


def request_path(conf_dir: str) -> Optional[str]:
    """Where the hub drops its update request: next to its database."""
    db = db_path(conf_dir)
    return os.path.join(os.path.dirname(db), REQUEST_FILE) if db else None


def take_request(conf_dir: str) -> bool:
    """True when the hub left an update request; removes it either way. The file is in the
    hub's own directory, so it's never opened or followed: only lstat and unlink."""
    path = request_path(conf_dir)
    if not path:
        return False
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if stat.S_ISDIR(st.st_mode):
        log("%s is a directory, not a request; ignoring it" % path)
        return False
    try:
        os.unlink(path)
    except OSError as e:
        log("couldn't remove the update request %s (%s)" % (path, type(e).__name__))
    return stat.S_ISREG(st.st_mode)


def read_status(conf_dir: str) -> Dict[str, Any]:
    try:
        with open(os.path.join(conf_dir, STATUS_FILE), "r", encoding="utf-8") as fh:
            raw = json.load(fh)
        return raw if isinstance(raw, dict) else {}
    except (OSError, ValueError):
        return {}


def write_status(args: argparse.Namespace, state: str, target: Optional[str] = None,
                 message: str = "", finished: bool = False) -> None:
    """hub-update-status.json next to hub.json: what this run is doing or did, for the hub to
    show (GET /v1/hub/update). Versions, times and one log line: nothing secret. A system
    install's is 644 in root's /etc/needs-you, which the hub (group needs-you) can read."""
    if args.check:
        return
    now = int(time.time() * 1000)
    rec = {"state": state, "requested": bool(getattr(args, "requested", False)),
           "started_at": getattr(args, "started_at", now), "finished_at": now if finished else None,
           "from_version": getattr(args, "from_version", None), "target": target,
           "message": message[:300]}
    try:
        fd, tmp = tempfile.mkstemp(prefix=".hub-update-status.", dir=args.conf_dir)
        with os.fdopen(fd, "w") as fh:
            json.dump(rec, fh)
        os.chmod(tmp, 0o644 if args.mode == "system" else 0o600)
        os.replace(tmp, os.path.join(args.conf_dir, STATUS_FILE))
    except OSError as e:
        log("couldn't write %s (%s)" % (STATUS_FILE, type(e).__name__))


def run_once(args: argparse.Namespace) -> int:
    """One update run, with its status written before and after."""
    args.requested = False if args.check else take_request(args.conf_dir)
    if args.requested:
        prev = read_status(args.conf_dir)
        last = prev.get("started_at") if prev.get("requested") is True else None
        if isinstance(last, int) and time.time() * 1000 - last < REQUEST_MIN_INTERVAL * 1000:
            log("asked to update again within %d minutes of the last request; running as on the timer"
                % (REQUEST_MIN_INTERVAL // 60))
            args.requested = False
    args.started_at = int(time.time() * 1000)
    args.from_version = installed_version(args.prefix)
    args.outcome = None
    args.target = None
    write_status(args, "checking",
                 message="asked to update now" if args.requested else "checking for a newer release")
    try:
        rc = update(args)
    except Refused as e:
        log("%s; nothing changed" % e if "rolled back" not in str(e) else str(e))
        write_status(args, "failed", target=args.target, message=str(e), finished=True)
        return 1
    state, target, message = args.outcome or (("up_to_date" if rc == 0 else "failed"), None, _last_log[0])
    write_status(args, state, target=target, message=message, finished=True)
    return rc


def systemctl(mode: str) -> List[str]:
    return ["systemctl", "--user"] if mode == "user" else ["systemctl"]


def update(args: argparse.Namespace) -> int:
    settings = load_settings(args.conf_dir)
    current = installed_version(args.prefix)
    if current is None:
        log("no hub installed in %s; nothing to update" % args.prefix)
        return 1
    if not settings["auto_update"] and not args.check:
        log("%s; nothing to do" % settings["why_off"])
        args.outcome = ("off", None, settings["why_off"])
        return 0
    gh = find_gh(settings)
    if not gh:
        raise Refused("automatic hub updates need gh 2.64 or later, logged in (`gh auth login`), to check "
                      "each release's build provenance; none found (set its path with "
                      "install-hub.sh --update-gh PATH)")
    if not gh_attests(gh):
        raise Refused("automatic hub updates need gh 2.64 or later to check build provenance; %s is too old" % gh)
    now = datetime.datetime.now(datetime.timezone.utc)
    if os.environ.get("NEEDS_YOU_HUB_UPDATE_NOW"):  # tests: a fixed clock
        now = parse_time(os.environ["NEEDS_YOU_HUB_UPDATE_NOW"]) or now
    soak = 0 if getattr(args, "requested", False) else settings["soak_hours"]
    if soak != settings["soak_hours"]:
        log("asked to update now: not waiting out the soak (every other check stays)")
    target, why = pick_release(list_releases(gh), settings["channel"], current, soak, now)
    if target is None:
        log(why)
        args.outcome = ("up_to_date", None, why)
        return 0
    version = target["version"]
    if version in failed_versions(args.state_dir):
        log("%s failed to install here before and is skipped until a newer release is out "
            "(delete %s to try it again)" % (version, os.path.join(args.state_dir, FAILED_FILE)))
        args.outcome = ("failed", version, "%s failed to install here before and is skipped until a newer "
                                           "release is out" % version)
        return 1
    if args.check:
        log("would install %s (installed: %s, channel %s)%s" % (
            version, current, settings["channel"], "" if settings["auto_update"] else "; automatic updates are off"))
        return 0
    # The installer goes one level down in a private directory: run from a real file, it looks
    # for a checkout in the directory above its own, which must be this one (no hub/ in it).
    tmp = tempfile.mkdtemp(prefix="needs-you-hub-update-")
    os.chmod(tmp, 0o700)
    dl = os.path.join(tmp, "release")
    os.mkdir(dl, 0o700)
    previous = args.prefix.rstrip("/") + ".previous"
    args.target = version
    try:
        inst = fetch_installer(gh, version, dl)
        write_status(args, "updating", target=version, message="installing %s" % version)
        log("release v%s checked (SHA256SUMS, manifest, build provenance); upgrading from %s" % (version, current))
        shutil.rmtree(previous, ignore_errors=True)
        shutil.copytree(args.prefix, previous, symlinks=True)
        db = db_path(args.conf_dir)
        schema_before = schema_version(db)
        cmd = ["bash", inst, "--no-invite"] + (["--user"] if args.mode == "user" else [])
        if args.no_start:
            cmd.append("--no-start")
        env = dict(os.environ, NEEDS_YOU_GH=gh)
        env.pop("NEEDS_YOU_HUB_UPDATE_NOW", None)
        try:
            r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                               timeout=900, env=env, cwd=tmp)
        except (OSError, subprocess.SubprocessError) as e:
            r = None
            failure = type(e).__name__
        else:
            failure = (last_line(r) or "install-hub.sh exited %d" % r.returncode) if r.returncode != 0 else ""
        for line in ((r.stdout if r else "") or "").splitlines():
            if line.strip() and "invite" not in line.lower():  # never relay an invite line
                log("  " + line[:300])
        installed = installed_version(args.prefix)
        healthy = installed == version
        if healthy and not failure and not args.no_start:
            deadline = time.monotonic() + HEALTH_WAIT
            while True:
                answered = hub_health(args.conf_dir)
                if answered == version:
                    break
                if time.monotonic() > deadline:
                    healthy = False
                    failure = "the hub didn't answer /v1/health as %s within %d s" % (version, HEALTH_WAIT)
                    break
                time.sleep(1)
        if failure or not healthy:
            log("upgrade to %s failed (%s); putting %s back" % (version, failure or "wrong version installed", current))
            remember_failed(args.state_dir, version)
            if not rollback(args, previous, db, schema_before, current):
                raise Refused("upgrade to %s failed, and putting %s back didn't bring the hub up: re-run "
                              "install-hub.sh by hand" % (version, current))
            raise Refused("upgrade to %s failed and was rolled back to %s" % (version, current))
        log("upgraded the hub from %s to %s (the previous code is in %s)" % (current, version, previous))
        args.outcome = ("updated", version, "upgraded the hub from %s to %s" % (current, version))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def rollback(args: argparse.Namespace, previous: str, db: Optional[str], schema_before: Optional[int],
             current: str) -> bool:
    """Stops the hub, puts the previous code back (a rename, so the code is never half there),
    restores the pre-migration database backup if the new version migrated it, and restarts.
    True when the hub then answers as `current` (or, without systemd, the code is back)."""
    if not os.path.isdir(previous):
        log("no previous code to put back")
        return False
    if not args.no_start:
        subprocess.run(systemctl(args.mode) + ["stop", "needs-you-hub.service"],
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
    failed = args.prefix.rstrip("/") + ".failed"
    shutil.rmtree(failed, ignore_errors=True)
    try:
        if os.path.isdir(args.prefix):
            os.rename(args.prefix, failed)
        os.rename(previous, args.prefix)
    except OSError as e:
        log("couldn't put the previous code back (%s)" % type(e).__name__)
        return False
    shutil.rmtree(failed, ignore_errors=True)
    schema_now = schema_version(db)
    if db and schema_before is not None and schema_now is not None and schema_now > schema_before:
        # The new version migrated the database, which the old one refuses to open. The hub
        # copied it to <db>.bak-<old schema> first: put that back (writes since are lost here;
        # peers replicate them back).
        backup = "%s.bak-%d" % (db, schema_before)
        if not os.path.isfile(backup):
            log("the database was migrated to schema %d and there's no %s to restore" % (schema_now, backup))
            return False
        try:
            shutil.copyfile(backup, db)  # into the existing file: keeps its owner and mode
            for extra in (db + "-wal", db + "-shm"):
                if os.path.exists(extra):
                    os.remove(extra)
        except OSError as e:
            log("couldn't restore %s (%s)" % (backup, type(e).__name__))
            return False
        log("restored the database from %s (schema %d)" % (backup, schema_before))
    if args.no_start:
        return installed_version(args.prefix) == current
    subprocess.run(systemctl(args.mode) + ["start", "needs-you-hub.service"],
                   stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
    deadline = time.monotonic() + HEALTH_WAIT
    while time.monotonic() <= deadline:
        if hub_health(args.conf_dir) == current:
            log("put back %s; the hub is up" % current)
            return True
        time.sleep(1)
    log("put back %s, but the hub doesn't answer /v1/health" % current)
    return False


def default_dirs(mode: str) -> Tuple[str, str, str]:
    if mode == "user":
        home = os.path.expanduser("~")
        conf = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
        state = os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state")
        return (os.path.join(home, ".local", "share", "needs-you"), os.path.join(conf, "needs-you"),
                os.path.join(state, "needs-you"))
    return "/opt/needs-you", "/etc/needs-you", "/var/lib/needs-you"


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Update a server hub to the newest checked release.")
    ap.add_argument("--mode", choices=("user", "system"), required=True,
                    help="how install-hub.sh installed this hub (--user, or system-wide)")
    ap.add_argument("--prefix", help="the hub's code directory (default: by --mode)")
    ap.add_argument("--conf-dir", help="where hub.json and hub-update.json are (default: by --mode)")
    ap.add_argument("--state-dir", help="where the lock goes (default: by --mode)")
    ap.add_argument("--check", action="store_true", help="say what would be installed; change nothing")
    ap.add_argument("--no-start", action="store_true", help=argparse.SUPPRESS)  # tests: no systemd
    args = ap.parse_args(argv)
    prefix, conf_dir, state_dir = default_dirs(args.mode)
    args.prefix = os.path.abspath(args.prefix or prefix)
    args.conf_dir = os.path.abspath(args.conf_dir or conf_dir)
    args.state_dir = os.path.abspath(args.state_dir or state_dir)
    if args.mode == "system" and os.geteuid() != 0 and not args.check:
        log("a system-wide hub is updated as root")
        return 1
    # System installs keep the lock and the failed-release record in root's /etc/needs-you,
    # not the service user's state directory.
    if args.mode == "system":
        args.state_dir = args.conf_dir
    if args.check and not os.access(args.state_dir, os.W_OK):
        try:
            args.requested = False
            return update(args)
        except Refused as e:
            log(str(e))
            return 1
    try:
        os.makedirs(args.state_dir, mode=0o700, exist_ok=True)
        lock = open(os.path.join(args.state_dir, "hub-update.lock"), "a")
    except OSError as e:
        log("can't open the lock file in %s (%s)" % (args.state_dir, type(e).__name__))
        return 1
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        log("another update is running")
        return 0
    try:
        rc = run_once(args)
        # A request that came in while this run held the lock (its .path start merged into this
        # run): honour it now rather than at the next timer run.
        path = request_path(args.conf_dir)
        if not args.check and not args.requested and path and os.path.lexists(path):
            rc = run_once(args)
        return rc
    finally:
        lock.close()


if __name__ == "__main__":
    sys.exit(main())
