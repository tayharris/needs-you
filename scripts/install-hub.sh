#!/usr/bin/env bash
# Install (or upgrade) an always-on needs-you hub on a Linux server. Optional: the Mac app
# runs its own hub; server hubs add redundancy and catch items while the Mac sleeps.
#
#   ./scripts/install-hub.sh --user [options]     no root: runs as a systemd --user service
#   sudo ./scripts/install-hub.sh [options]       system-wide: a `needs-you` system user
#   curl -fsSL <hub>/dl/install-hub.sh | sudo bash -s -- --join <link>   no checkout: the
#       code comes from that hub's /dl, each file checked against its /dl/manifest.json and
#       the GitHub release of the hub's version
#
# Options:
#   --user                 install under your home directory (recommended)
#   --bind ADDR            listen address, repeatable or comma-separated
#                          (default: 127.0.0.1 plus `tailscale ip -4`)
#   --port N               port (default 8765)
#   --hub-id ID            this hub's unique id (default: short hostname)
#   --public-url URL       how others reach this hub (default: http://<MagicDNS name>:PORT)
#   --peer URL             another hub's public URL (repeatable; replaces the peer list)
#   --peer-secret-file F   read the shared replication secret from a file
#   --peer-secret S        the shared secret (visible in `ps`; prefer the file)
#   --generate-peer-secret make a new secret and print it once (copy it to the other hub)
#   --join LINK            pair with another hub (the Mac's, or a server) by its peer invite
#                          (http(s)://<hub>/join/nyi_...): no secret to copy; it stays in the DB
#   --trust-hub-code       without a checkout: install the hub's code even if it can't be
#                          checked against the GitHub release of its version (a dev build)
#   --reconfigure          rebuild the config from defaults + flags (keeps the secret)
#   --no-start             install files and config, don't start the service
#   --no-invite            don't print an owner invite at the end
#   -h, --help             this help
#
# Re-running upgrades the code in place, keeps the config (flags you pass are applied to it)
# and the database, and restarts the service.
set -euo pipefail

MODE=system
BINDS=()
PORT=""
HUB_ID=""
PUBLIC_URL=""
PEERS=()
PEER_SECRET=""
GEN_SECRET=0
RECONFIGURE=0
START=1
INVITE=1
JOIN=""
TRUST_HUB_CODE=0

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "install-hub: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) MODE=user; shift ;;
    --system) MODE=system; shift ;;
    --bind) BINDS+=("${2:?--bind needs an address}"); shift 2 ;;
    --port) PORT=${2:?}; shift 2 ;;
    --hub-id) HUB_ID=${2:?}; shift 2 ;;
    --public-url) PUBLIC_URL=${2:?}; shift 2 ;;
    --peer) PEERS+=("${2:?--peer needs a URL}"); shift 2 ;;
    --peer-secret) PEER_SECRET=${2:?}; shift 2 ;;
    --peer-secret-file) PEER_SECRET=$(tr -d '\r\n' < "${2:?}"); shift 2 ;;
    --generate-peer-secret) GEN_SECRET=1; shift ;;
    --join) JOIN=${2:?--join needs the peer invite link}; shift 2 ;;
    --trust-hub-code) TRUST_HUB_CODE=1; shift ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --no-start) START=0; shift ;;
    --no-invite) INVITE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
if [ -n "$JOIN" ]; then
  case "$JOIN" in
    http://*/join/nyi_*|https://*/join/nyi_*) ;;
    *) die "--join takes a peer invite link: http(s)://<hub>/join/nyi_... (make one in the Mac app's Settings, or with needs-you-admin invite create NAME --role peer)" ;;
  esac
  INVITE=0  # the hub it joins already has the owner; its tokens replicate here
fi

PYTHON=/usr/bin/python3
[ -x "$PYTHON" ] || PYTHON=$(command -v python3 || true)
[ -n "$PYTHON" ] || die "python3 not found (apt install python3)"
"$PYTHON" -c 'import sys, sqlite3; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
  || die "python3 >= 3.9 with the sqlite3 module is required"

# Where the code comes from. Everything is installed from STAGE, a fresh private directory:
# - a checkout, when this script runs from a real file (piped, `curl ... | bash`, $0 is "bash",
#   and the directory around the caller must never be taken for one). As root (or with
#   NEEDS_YOU_INSTALL_CHECK_OWNERSHIP=1, a test switch that only adds checks) the files are
#   first copied into STAGE, refusing symlinks and anything (file or any directory above it)
#   others could write, and only that copy is installed, so nothing can change in between;
# - otherwise the hub the --join link names (/dl), each file checked against its
#   /dl/manifest.json and then against the GitHub release of the hub's version (SHA256SUMS,
#   release-manifest.json, and its build provenance when `gh` is installed). A hub whose code
#   doesn't match a release (a dev build) needs a checkout, or --trust-hub-code.
CHECKOUT=""
SELF=${BASH_SOURCE[0]:-}
if [ -n "$SELF" ] && [ -f "$SELF" ] && [ ! -L "$SELF" ]; then
  CHECKOUT=$(cd "$(dirname "$SELF")/.." 2>/dev/null && pwd -P || true)
  [ -f "$CHECKOUT/hub/needs_you_hub.py" ] || CHECKOUT=""
fi
STAGE=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/needs-you-hub-src.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
if [ -n "$CHECKOUT" ] && { [ "$(id -u)" -ne 0 ] && [ "${NEEDS_YOU_INSTALL_CHECK_OWNERSHIP:-}" != 1 ]; }; then
  SRC=$CHECKOUT
elif [ -n "$CHECKOUT" ]; then
  "$PYTHON" - "$CHECKOUT" "$STAGE" "${SUDO_UID:-$(id -u)}" <<'PY' || die "refusing to install as root from $CHECKOUT (above)"
import os, stat, sys
src, dest, uid = sys.argv[1], sys.argv[2], int(sys.argv[3])
owners = {0, uid}
bad, seen = [], {}

def check_dir_chain(path):
    """Every directory from / down to `path`: a real directory (no symlink), owned by root or
    the installing user, and not writable by others (a root-owned sticky dir like /tmp is fine)."""
    parts = os.path.abspath(path).split("/")
    cur = "/"
    for part in [""] + parts[1:]:
        cur = os.path.join(cur, part) if part else cur
        if cur in seen:
            continue
        st = os.lstat(cur)
        seen[cur] = True
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
            bad.append("%s is a symlink or not a directory" % cur)
        elif st.st_uid not in owners:
            bad.append("%s is owned by uid %d" % (cur, st.st_uid))
        elif stat.S_IMODE(st.st_mode) & 0o022 and not (st.st_uid == 0 and st.st_mode & stat.S_ISVTX):
            bad.append("%s is writable by others" % cur)

copies = []
for top in ("hub", "cli", "deploy", "scripts", "integrations"):
    for d, dirs, files in os.walk(os.path.join(src, top), followlinks=False):
        check_dir_chain(d)
        for n in dirs:
            if os.path.islink(os.path.join(d, n)):
                bad.append("%s is a symlink" % os.path.join(d, n))
        for n in files:
            if n.endswith((".pyc", ".DS_Store")):
                continue
            p = os.path.join(d, n)
            try:
                fd = os.open(p, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            except OSError:
                bad.append("%s is a symlink or can't be read" % p)
                continue
            with os.fdopen(fd, "rb") as fh:
                st = os.fstat(fh.fileno())  # the file actually opened, not its name
                if not stat.S_ISREG(st.st_mode):
                    bad.append("%s is not a regular file" % p)
                elif st.st_uid not in owners:
                    bad.append("%s is owned by uid %d" % (p, st.st_uid))
                elif stat.S_IMODE(st.st_mode) & 0o022:
                    bad.append("%s is writable by others" % p)
                else:
                    copies.append((os.path.relpath(p, src), fh.read(), st.st_mode & 0o111))
if bad:
    sys.stderr.write("install-hub: %s%s\n" % ("; ".join(bad[:5]), " ..." if len(bad) > 5 else ""))
    sys.exit(1)
for rel, data, exe in copies:
    target = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(target), mode=0o755, exist_ok=True)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o755 if exe else 0o644)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
PY
  SRC=$STAGE
else
  [ -n "$JOIN" ] || die "run this from a checkout of the needs-you repo, or with --join <peer invite link>"
  FROM_HUB=${JOIN%%/join/*}
  echo "fetching the hub's code from $FROM_HUB"
  "$PYTHON" - "$FROM_HUB" "$STAGE" "$TRUST_HUB_CODE" <<'PY' || die "nothing installed (above)"
import hashlib, json, os, re, shutil, stat, subprocess, sys, tarfile, tempfile, urllib.error, urllib.parse, urllib.request
base, dest, trust = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3] == "1"
REPO = "tayharris/needs-you"  # fixed here, never from the hub (the CLI's RELEASE_REPO)
WORKFLOW = REPO + "/.github/workflows/release.yml"
SLSA = "https://slsa.dev/provenance/v1"
GITHUB_HOSTS = {"github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"}
CAPS = {"SHA256SUMS": 64 << 10, "release-manifest.json": 1 << 20}
TAR_CAP = 64 << 20

def die(msg, code=1):
    sys.stderr.write("install-hub: %s\n" % msg)
    sys.exit(code)

# 1. the hub's files, each against the hub's own manifest (integrity)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None
hub = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
def hub_get(name):
    with hub.open(base + "/dl/" + name, timeout=30) as resp:
        return resp.read(TAR_CAP + 1)
try:
    manifest = json.loads(hub_get("manifest.json").decode("utf-8"))
    files = manifest.get("files") or {}
except (OSError, ValueError, AttributeError) as e:
    die("couldn't read %s/dl/manifest.json (%s); it may run a needs-you too old to serve its own code"
        % (base, type(e).__name__))
version = str(manifest.get("version") or "")
path_re = re.compile(r"^(?:[A-Za-z0-9_][A-Za-z0-9._-]*/)*[A-Za-z0-9_][A-Za-z0-9._-]*$")
got = {}
for name, entry in sorted(files.items()):
    path = entry.get("path") if isinstance(entry, dict) else None
    if not isinstance(path, str) or not path_re.match(path) or ".." in path.split("/"):
        die("the hub's manifest has no usable path for %s" % name)
    try:
        data = hub_get(name)
    except OSError as e:
        die("couldn't download %s from the hub (%s)" % (name, type(e).__name__))
    if hashlib.sha256(data).hexdigest() != str(entry.get("sha256") or "").lower():
        die("%s doesn't match the hub's manifest; nothing installed" % name)
    got[path] = data
for need in ("hub/needs_you_hub.py", "hub/needs_you_admin.py", "hub/join-install.sh", "cli/needs-you",
             "deploy/needs-you-admin.sh", "deploy/needs-you-hub.service", "deploy/needs-you-hub.user.service"):
    if need not in got:
        die("that hub doesn't serve %s; update it (the Mac app), or install from a checkout" % need)

# 2. the same bytes in the GitHub release of the hub's version (authenticity)
def release_files(v, tmp):
    """SHA256SUMS, the server tarball and release-manifest.json of release vV, with gh when
    installed, else over https to GitHub only. Returns (dir, gh or None); exits 4 if
    GitHub can't be reached."""
    names = ["SHA256SUMS", "needs-you-server-%s.tar.gz" % v, "release-manifest.json"]
    forced = os.environ.get("NEEDS_YOU_GH")
    gh = (forced if forced != "none" and os.access(forced, os.X_OK) else None) if forced else shutil.which("gh")
    if gh:
        args = [gh, "release", "download", "v" + v, "--repo", REPO, "--dir", tmp]
        for n in names:
            args += ["--pattern", n]
        try:
            r = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300)
        except (OSError, subprocess.SubprocessError) as e:
            die("gh failed (%s)" % type(e).__name__, 4)
        if r.returncode != 0:
            die("gh couldn't download release v%s of %s (%s)" % (v, REPO, (r.stderr.strip().splitlines() or [""])[-1][:200]), 4)
        return gh
    if os.environ.get("NEEDS_YOU_RELEASE_OFFLINE") == "1":  # tests: GitHub is unreachable
        die("GitHub isn't reachable (NEEDS_YOU_RELEASE_OFFLINE=1)", 4)
    class GitHubOnly(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            u = urllib.parse.urlsplit(newurl)
            if u.scheme != "https" or u.hostname not in GITHUB_HOSTS or u.port not in (None, 443) \
                    or u.username or u.password:
                raise urllib.error.HTTPError(newurl, code, "redirect off GitHub refused", headers, fp)
            return urllib.request.HTTPRedirectHandler.redirect_request(self, req, fp, code, msg, headers, newurl)
    opener = urllib.request.build_opener(GitHubOnly())
    for n in names:
        cap = CAPS.get(n, TAR_CAP)
        try:
            with opener.open("https://github.com/%s/releases/download/v%s/%s" % (REPO, v, n), timeout=60) as resp:
                data = resp.read(cap + 1)
        except (OSError, ValueError) as e:
            die("couldn't download %s of release v%s from GitHub (%s)" % (n, v, type(e).__name__), 4)
        if len(data) > cap:
            die("%s of release v%s is larger than expected" % (n, v), 3)
        with open(os.path.join(tmp, n), "wb") as fh:
            fh.write(data)
    return None

def provenance(gh, path, sha, v):
    if not gh:
        return "build provenance not checked (install gh to check it)"
    r = subprocess.run([gh, "attestation", "verify", path, "--repo", REPO, "--signer-workflow", WORKFLOW,
                        "--source-ref", "refs/tags/v" + v, "--predicate-type", SLSA,
                        "--deny-self-hosted-runners", "--format", "json"],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
    if r.returncode == 0:
        try:
            for e in json.loads(r.stdout):
                vr = e["verificationResult"]
                st, cert = vr["statement"], vr["signature"]["certificate"]
                digests = {str((s.get("digest") or {}).get("sha256") or "").lower() for s in st.get("subject") or []}
                if (sha in digests and st.get("predicateType") == SLSA
                        and cert.get("sourceRepositoryURI") == "https://github.com/" + REPO
                        and cert.get("sourceRepositoryRef") == "refs/tags/v" + v
                        and str(cert.get("buildSignerURI") or "").startswith("https://github.com/%s@" % WORKFLOW)
                        and cert.get("runnerEnvironment") == "github-hosted"):
                    return "build provenance verified"
        except (ValueError, KeyError, TypeError, AttributeError):
            pass
        die("release v%s's build provenance doesn't fit; nothing installed" % v, 3)
    p = subprocess.run([gh, "api", "repos/" + REPO, "--jq", ".private"],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    if p.returncode == 0 and p.stdout.strip() == "true":
        return "no build provenance to check (%s is private)" % REPO
    die("release v%s has no valid build provenance; nothing installed" % v, 3)

def sha_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

if trust:
    sys.stderr.write("\nWARNING: --trust-hub-code: installing the hub's code (to run as a service) WITHOUT\n"
                     "checking it against a GitHub release. Only the hub's own checksums were checked.\n\n")
else:
    if not re.match(r"^\d{1,6}\.\d{1,6}\.\d{1,6}$", version):
        die("the hub's version %r isn't X.Y.Z" % version[:40], 3)
    tmp = tempfile.mkdtemp(prefix="needs-you-release-")
    try:
        gh = release_files(version, tmp)
        tarball = "needs-you-server-%s.tar.gz" % version
        sums = {}
        with open(os.path.join(tmp, "SHA256SUMS"), "r", encoding="utf-8") as fh:
            for line in fh:
                p = line.split()
                if len(p) == 2:
                    sums[p[1].lstrip("*")] = p[0].lower()
        tar_path, rm_path = os.path.join(tmp, tarball), os.path.join(tmp, "release-manifest.json")
        if os.path.getsize(tar_path) > TAR_CAP or sha_file(tar_path) != sums.get(tarball):
            die("release v%s's %s doesn't match its SHA256SUMS" % (version, tarball), 3)
        rm_sha = sha_file(rm_path)
        if rm_sha != sums.get("release-manifest.json"):
            die("release v%s's release-manifest.json doesn't match its SHA256SUMS" % version, 3)
        with open(rm_path, "r", encoding="utf-8") as fh:
            rm = json.load(fh)
        listed = {str(a.get("name")): str(a.get("sha256") or "").lower() for a in rm.get("assets") or []}
        if rm.get("version") != version or listed.get(tarball) != sums.get(tarball):
            die("release v%s's release-manifest.json doesn't list this %s" % (version, tarball), 3)
        note = provenance(gh, rm_path, rm_sha, version)
        with tarfile.open(tar_path, "r:gz") as tf:
            for path, data in sorted(got.items()):
                try:
                    member = tf.extractfile("needs-you-%s/%s" % (version, path))
                except KeyError:
                    member = None
                if member is None or hashlib.sha256(member.read()).hexdigest() != hashlib.sha256(data).hexdigest():
                    die("%s from the hub doesn't match release v%s on GitHub; nothing installed. Install from a "
                        "checkout, or pass --trust-hub-code if you trust this hub's code (a dev build)" % (path, version), 3)
        print("the hub's code matches release v%s on GitHub (%s)" % (version, note))
    except (OSError, ValueError, AttributeError, TypeError, tarfile.TarError) as e:
        die("couldn't check release v%s (%s); nothing installed" % (version, type(e).__name__), 3)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

# 3. lay it out, only now
for path, data in got.items():
    target = os.path.join(dest, path)
    os.makedirs(os.path.dirname(target), mode=0o755, exist_ok=True)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
PY
  SRC=$STAGE
  for f in hub/needs_you_hub.py hub/needs_you_admin.py hub/join-install.sh cli/needs-you \
           deploy/needs-you-admin.sh deploy/needs-you-hub.service deploy/needs-you-hub.user.service; do
    [ -f "$SRC/$f" ] || die "that hub doesn't serve $f; update it (the Mac app), or install from a checkout"
  done
fi

if [ "$MODE" = user ]; then
  [ "$(id -u)" -ne 0 ] || die "--user installs for the current user; don't run it as root"
  PREFIX="$HOME/.local/share/needs-you"
  CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/needs-you"
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/needs-you"
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  ADMIN_BIN="$HOME/.local/bin/needs-you-admin"
else
  [ "$(id -u)" -eq 0 ] || die "a system install needs root (sudo), or use --user"
  PREFIX=/opt/needs-you
  CONF_DIR=/etc/needs-you
  STATE_DIR=/var/lib/needs-you
  UNIT_DIR=/etc/systemd/system
  ADMIN_BIN=/usr/local/bin/needs-you-admin
  SVC_USER=needs-you
fi
CONF="$CONF_DIR/hub.json"
if [ "$START" -eq 1 ]; then
  [ "$(uname -s)" = "Linux" ] || die "the service needs Linux with systemd (use --no-start to only install files)"
  command -v systemctl >/dev/null || die "systemd is required (or pass --no-start)"
fi

# Defaults that need tailscale: only computed for a new config or when not given.
TS_IP=""; TS_NAME=""
if command -v tailscale >/dev/null 2>&1; then
  TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  TS_NAME=$(tailscale status --json 2>/dev/null | "$PYTHON" -c \
    'import json,sys; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))' 2>/dev/null || true)
fi
DEFAULT_BIND="127.0.0.1${TS_IP:+,$TS_IP}"
for b in "${BINDS[@]+"${BINDS[@]}"}"; do
  case "$b" in 0.0.0.0|::|"[::]") die "refusing to bind to all interfaces; use 127.0.0.1 and the tailnet IP" ;; esac
done
HOST_SHORT=$(hostname -s 2>/dev/null || hostname)
[ -n "$HUB_ID" ] || HUB_ID_DEFAULT=$HOST_SHORT
GENERATED=""
if [ "$GEN_SECRET" -eq 1 ]; then
  GENERATED=$("$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(32))')
  PEER_SECRET=$GENERATED
fi

# 1. directories and code (upgrade in place)
if [ "$MODE" = system ]; then
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$STATE_DIR" --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
  fi
  install -d -m 0755 "$PREFIX"
  install -d -m 0750 -o root -g "$SVC_USER" "$CONF_DIR"
  install -d -m 0700 -o "$SVC_USER" -g "$SVC_USER" "$STATE_DIR"
else
  install -d -m 0700 "$PREFIX" "$CONF_DIR" "$STATE_DIR"
  install -d -m 0755 "$(dirname "$ADMIN_BIN")" "$UNIT_DIR"
fi
install -d -m 0755 "$PREFIX/hub" "$PREFIX/cli" "$PREFIX/integrations/claude-code/skill/needs-you"
install -m 0644 "$SRC/hub/needs_you_hub.py" "$SRC/hub/needs_you_admin.py" "$SRC/hub/join-install.sh" "$PREFIX/hub/"
install -m 0755 "$SRC/cli/needs-you" "$PREFIX/cli/needs-you"
install -m 0644 "$SRC/integrations/claude-code/needs-you-hook.sh" "$SRC/integrations/claude-code/install-hooks.sh" \
  "$SRC/integrations/claude-code/hooks.json" "$PREFIX/integrations/claude-code/"
install -m 0644 "$SRC/integrations/claude-code/skill/needs-you/SKILL.md" "$PREFIX/integrations/claude-code/skill/needs-you/"
for agent in codex gemini copilot grok cursor; do
  install -d -m 0755 "$PREFIX/integrations/$agent"
  install -m 0644 "$SRC/integrations/$agent/install-$agent-hooks.sh" "$SRC/integrations/$agent/$agent-hooks.json" \
    "$PREFIX/integrations/$agent/"
done
install -d -m 0755 "$PREFIX/integrations/kimi"
install -m 0644 "$SRC/integrations/kimi/install-kimi-hooks.sh" "$SRC/integrations/kimi/kimi-hooks.toml" \
  "$PREFIX/integrations/kimi/"
install -d -m 0755 "$PREFIX/integrations/opencode"
install -m 0644 "$SRC/integrations/opencode/needs-you.js" "$SRC/integrations/opencode/install-opencode-plugin.sh" \
  "$PREFIX/integrations/opencode/"
install -d -m 0755 "$PREFIX/integrations/cline" "$PREFIX/integrations/aider"
install -m 0644 "$SRC/integrations/cline/install-cline-hooks.sh" "$PREFIX/integrations/cline/"
install -m 0644 "$SRC/integrations/aider/install-aider-notifications.sh" "$PREFIX/integrations/aider/"
echo "installed code in $PREFIX"

# 2. config: create, or apply only the flags that were passed
NEW_CONFIG=0
[ -f "$CONF" ] || NEW_CONFIG=1
umask 077
NY_CONF="$CONF" NY_NEW="$NEW_CONFIG" NY_RECONF="$RECONFIGURE" NY_DB="$STATE_DIR/hub.db" \
NY_BIND="$(IFS=,; echo "${BINDS[*]+"${BINDS[*]}"}")" NY_DEFAULT_BIND="$DEFAULT_BIND" \
NY_PORT="$PORT" NY_HUB_ID="$HUB_ID" NY_HUB_ID_DEFAULT="${HUB_ID_DEFAULT:-}" \
NY_PUBLIC_URL="$PUBLIC_URL" NY_TS_NAME="$TS_NAME" NY_HOST="$HOST_SHORT" NY_SECRET="$PEER_SECRET" \
"$PYTHON" - "${PEERS[@]+"${PEERS[@]}"}" > "$CONF.tmp" <<'PY'
import json, os, sys
e = os.environ
old = {}
if e["NY_NEW"] != "1":
    with open(e["NY_CONF"]) as fh:
        old = json.load(fh)
cfg = dict(old) if e["NY_RECONF"] != "1" else {}
if e["NY_RECONF"] == "1" and old.get("peer_secret"):
    cfg["peer_secret"] = old["peer_secret"]
fresh = not cfg
def put(key, value, default=None):
    if value not in (None, ""):
        cfg[key] = value
    elif key not in cfg and default not in (None, ""):
        cfg[key] = default
binds = [b for b in e["NY_BIND"].split(",") if b]
put("bind", binds or None, [b for b in e["NY_DEFAULT_BIND"].split(",") if b])
put("port", int(e["NY_PORT"]) if e["NY_PORT"] else None, 8765)
put("db", None, e["NY_DB"])
put("hub_id", e["NY_HUB_ID"], e["NY_HUB_ID_DEFAULT"])
port = cfg.get("port", 8765)
# this machine's name, whatever --hub-id says (that names the hub, not the host)
host = e["NY_TS_NAME"] or e["NY_HOST"] or "localhost"
put("public_url", e["NY_PUBLIC_URL"].rstrip("/"), "http://%s:%d" % (host, port))
put("freebind", None, True)
if sys.argv[1:]:
    cfg["peers"] = [p.rstrip("/") for p in sys.argv[1:]]
cfg.setdefault("peers", [])
put("peer_secret", e["NY_SECRET"])
if cfg["peers"] and len(cfg.get("peer_secret") or "") < 16:
    sys.exit("install-hub: peers are set but there is no peer secret; pass --peer-secret-file "
             "(the other hub's secret) or --generate-peer-secret")
cfg.setdefault("retention_days", 7)
print(json.dumps(cfg, indent=2))
PY
if [ "$MODE" = system ]; then
  chown root:"$SVC_USER" "$CONF.tmp"
  chmod 0640 "$CONF.tmp"
else
  chmod 0600 "$CONF.tmp"
fi
if [ -f "$CONF" ] && cmp -s "$CONF" "$CONF.tmp"; then
  rm -f "$CONF.tmp"; echo "config unchanged: $CONF"
else
  mv "$CONF.tmp" "$CONF"; echo "wrote $CONF"
fi
cfg_get() { "$PYTHON" -c 'import json,sys; c=json.load(open(sys.argv[1])); v=c.get(sys.argv[2]); print(",".join(v) if isinstance(v, list) else ("" if v is None else v))' "$CONF" "$1"; }

# 3. admin wrapper
if [ "$MODE" = user ]; then
  cat > "$ADMIN_BIN.tmp" <<EOF
#!/bin/sh
# needs-you-admin (user install): manage tokens and invites on this hub.
exec "$PYTHON" "$PREFIX/hub/needs_you_admin.py" --config "\${NEEDS_YOU_HUB_CONFIG:-$CONF}" "\$@"
EOF
  chmod 0755 "$ADMIN_BIN.tmp"
  mv -f "$ADMIN_BIN.tmp" "$ADMIN_BIN"
else
  install -m 0755 "$SRC/deploy/needs-you-admin.sh" "$ADMIN_BIN"
fi

# 3b. pair with the hub whose peer invite this is (before the service starts, so it starts
#     replicating with it at once). The secret goes into the database, never to the terminal.
JOINED=""
if [ -n "$JOIN" ]; then
  if ! JOINED=$("$ADMIN_BIN" peer join "$JOIN"); then
    die "couldn't join with that link (above). The hub is installed; make a new peer invite and re-run with --join, or run: needs-you-admin peer join <link>"
  fi
  echo "$JOINED"
fi

# 4. service
if [ "$MODE" = user ]; then
  # The paths this install used, quoted for systemd (which also expands % and $).
  "$PYTHON" - "$SRC/deploy/needs-you-hub.user.service" "$PYTHON" "$PREFIX/hub/needs_you_hub.py" "$CONF" \
    > "$UNIT_DIR/needs-you-hub.service.tmp" <<'PY'
import sys
tmpl, python, hub, conf = sys.argv[1:5]
q = lambda p: '"%s"' % p.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$")
with open(tmpl) as fh:
    sys.stdout.write(fh.read().replace("@PYTHON@", q(python)).replace("@HUB@", q(hub)).replace("@CONF@", q(conf)))
PY
  mv -f "$UNIT_DIR/needs-you-hub.service.tmp" "$UNIT_DIR/needs-you-hub.service"
  SYSTEMCTL=(systemctl --user)
  JOURNAL="journalctl --user -u needs-you-hub"
else
  install -m 0644 "$SRC/deploy/needs-you-hub.service" "$UNIT_DIR/needs-you-hub.service"
  SYSTEMCTL=(systemctl)
  JOURNAL="journalctl -u needs-you-hub"
fi
if [ "$START" -eq 1 ]; then
  "${SYSTEMCTL[@]}" daemon-reload
  "${SYSTEMCTL[@]}" enable needs-you-hub.service >/dev/null
  "${SYSTEMCTL[@]}" restart needs-you-hub.service
  first_bind=$(cfg_get bind | cut -d, -f1)
  port=$(cfg_get port)
  ok=0
  for _ in $(seq 1 20); do
    if "$PYTHON" -c 'import sys,urllib.request as u; u.build_opener(u.ProxyHandler({})).open("http://%s:%s/v1/health" % (sys.argv[1], sys.argv[2]), timeout=2)' "$first_bind" "$port" 2>/dev/null; then
      ok=1; break
    fi
    sleep 0.5
  done
  if [ "$ok" -eq 1 ]; then
    echo "needs-you-hub is up: $(cfg_get public_url) (hub_id $(cfg_get hub_id))"
  else
    echo "needs-you-hub did not answer yet; check: $JOURNAL -n 50" >&2
  fi
  if [ "$MODE" = user ]; then
    linger=$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null || echo unknown)
    if [ "$linger" != "yes" ]; then
      echo
      echo "IMPORTANT: lingering is off, so the hub stops when you log out and won't start at boot."
      echo "Run this once (it needs sudo):"
      echo "  sudo loginctl enable-linger $(id -un)"
    fi
  fi
else
  echo "not started (--no-start). Run it with: $PYTHON $PREFIX/hub/needs_you_hub.py --config $CONF"
fi

if [ -n "$GENERATED" ]; then
  echo
  echo "Peer secret (shown once). Copy it to the other hub and install there with"
  echo "--peer-secret-file <file holding it>. Keep it out of git and chat logs:"
  echo "  $GENERATED"
fi

# 5. first owner invite, so the Mac can connect
if [ "$INVITE" -eq 1 ] && [ "$NEW_CONFIG" -eq 1 ]; then
  echo
  echo "Connect a Mac to this hub with this link. (To pair this hub with a Mac app's built-in hub instead,"
  echo "make a link in its Settings -> Built-in hub -> Always-on hub and re-run this with --join <link>.)"
  "$ADMIN_BIN" invite create mac --role owner --uses 1 --ttl 72 | sed 's/^/  /'
fi
if [ -n "$JOINED" ]; then
  echo
  echo "This hub now replicates with the hub that invited it: items posted to either show on both,"
  echo "and sender invites made there list this hub too. Check it: needs-you-admin peer list"
fi
cat <<EOF

Next:
  needs-you-admin invite create my-server --role sender --uses 3   # a link for servers/agents
  needs-you-admin invite list
  needs-you-admin token list
Upgrade later with: git pull && $0 $([ "$MODE" = user ] && echo --user)
EOF
