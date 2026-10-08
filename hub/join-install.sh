#!/usr/bin/env bash
# needs-you installer for one machine. A hub generates this for one invite link:
#
#   curl -fsSL <join_url>/install.sh | bash -s -- --yes [options]
#
# The options are in usage() below (also: --help). The help is a heredoc, not this
# comment, because piped into bash there is no "$0" file to read it from.
set -euo pipefail

HUB_URL=__NY_HUB_URL__
CODE=__NY_CODE__
ROLE=__NY_ROLE__
INVITE_NAME=__NY_INVITE_NAME__
MAC_URL=__NY_MAC_URL__
USES_LEFT=__NY_USES_LEFT__
# "<file>=<sha256> ...": the hub's /dl files when it served this script (the join page and
# /dl/manifest.json list the same). Every download is checked against it.
SHA256S=__NY_CHECKSUMS__

YES=0
HOOKS=none
CODEX_HOOKS=none
GEMINI_HOOKS=none
COPILOT_HOOKS=none
OPENCODE=0
SKILL=0
ORCA=0
CONTEXT=""
HOST_NAME=""
SCHEDULE=1
FORCE=0
UNINSTALL=0
HUB_GIVEN=""
ALERTS=""
AGENT_LINK=""
ORCA_ENV=""
SSH_ALIAS=""
CONTEXT_ALERT=""
SET_PATH=1
AUTO_UPDATE=""

say() { printf '%s\n' "$*"; }
warn() { printf 'needs-you install: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
# verify NAME FILE: FILE's sha256 must equal NAME's entry in SHA256S (security audit #17:
# catches corrupt or partial downloads and binds the files to the page the user saw).
verify() {
  local want="" kv got
  for kv in $SHA256S; do
    [ "${kv%%=*}" = "$1" ] && want=${kv#*=}
  done
  if [ -z "$want" ]; then
    warn "the hub's install page lists no checksum for $1; not installing it"
    return 1
  fi
  got=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$2") || return 1
  if [ "$got" != "$want" ]; then
    warn "$1 doesn't match the sha256 on the hub's install page (got $got, expected $want): a corrupt or partial download, or the hub was updated since. Re-run the one line."
    return 1
  fi
}
usage() {
  cat <<'EOF'
needs-you installer for one machine:

  curl -fsSL <join_url>/install.sh | bash -s -- --yes [options]

Options:
  --yes                         don't ask for confirmation (needed when piped)
  --claude-hooks user|project|none
                                Claude Code hooks: post when a session waits on you
                                (project = the current directory's repo; default none)
  --codex-hooks user|none       OpenAI Codex CLI hooks in ~/.codex/hooks.json: post when
                                a Codex session asks for approval or finishes its turn
                                (trust them once with /hooks in Codex; default none)
  --gemini-hooks user|none      Gemini CLI hooks in ~/.gemini/settings.json: post when a
                                session asks to approve a tool call or finishes its turn
                                (default none)
  --opencode-plugin             opencode plugin in ~/.config/opencode/plugins: post when a
                                session asks for permission or a question, or goes idle
  --copilot-hooks user|none     GitHub Copilot CLI hooks in ~/.copilot/hooks/: post when a
                                session asks for permission or a question, or finishes
                                its turn (default none)
  --alerts                      turn the hooks on for every Claude Code, Codex, Gemini,
                                opencode and Copilot session here
                                (NEEDS_YOU_AGENT_ALERTS=1 in the env file);
                                without it they stay quiet except in Orca
  --skill                       install the needs-you skill to ~/.claude/skills
  --auto-update                 let `needs-you flush` run `needs-you update` once a day
                                (NEEDS_YOU_AUTO_UPDATE=1); updates come only from this hub
  --context-alert PCT           card suggesting /compact or /clear once a session's
                                context is PCT% full (default 80; 0 = off)
  --ssh-alias NAME              the name the Mac's ~/.ssh/config (VS Code Remote-SSH)
                                uses for this machine: cards get a Remote-SSH link
  --agent-link 'LABEL=URL'      one link template for agent cards instead of the
                                automatic editor links ({cwd} {host} {session} {handle};
                                'none' = no editor links)
  --orca-environment NAME       on a paired Orca server: its name in the Mac's Orca
  --orca                        write the Orca automation snippet and print the
                                block to paste into automation prompts
  --context work|personal       default context for this machine's items
  --host NAME                   this machine's name (default: short hostname)
  --hub URL                     use this URL for the hub (saved first in the hub list)
  --no-schedule                 don't add the 5-minute `needs-you flush`
  --no-path                     don't add ~/.local/bin to PATH in your shell profile
                                (prints the line to add instead)
  --force                       redeem again and replace an existing token
  --uninstall                   remove the CLI, config, flush schedule, skill and hooks
  -h, --help                    this help

Needs bash, curl and python3 3.9+. Writes only under $HOME (plus your crontab on
Linux, or a LaunchAgent on macOS, for the flush, and one tagged PATH line in your
shell profile). Re-running is safe and keeps the token; it works until the link
expires, even with no uses left. Settings you don't pass again are kept.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --claude-hooks) HOOKS=${2:-}; shift 2 || die "--claude-hooks needs user, project or none" ;;
    --claude-hooks=*) HOOKS=${1#*=}; shift ;;
    --codex-hooks) CODEX_HOOKS=${2:-}; shift 2 || die "--codex-hooks needs user or none" ;;
    --codex-hooks=*) CODEX_HOOKS=${1#*=}; shift ;;
    --gemini-hooks) GEMINI_HOOKS=${2:-}; shift 2 || die "--gemini-hooks needs user or none" ;;
    --gemini-hooks=*) GEMINI_HOOKS=${1#*=}; shift ;;
    --opencode-plugin) OPENCODE=1; shift ;;
    --copilot-hooks) COPILOT_HOOKS=${2:-}; shift 2 || die "--copilot-hooks needs user or none" ;;
    --copilot-hooks=*) COPILOT_HOOKS=${1#*=}; shift ;;
    --skill) SKILL=1; shift ;;
    --orca) ORCA=1; shift ;;
    --context) CONTEXT=${2:-}; shift 2 || die "--context needs work or personal" ;;
    --context=*) CONTEXT=${1#*=}; shift ;;
    --host) HOST_NAME=${2:-}; shift 2 || die "--host needs a name" ;;
    --hub) HUB_GIVEN=${2:-}; shift 2 || die "--hub needs a URL" ;;
    --hub=*) HUB_GIVEN=${1#*=}; shift ;;
    --no-schedule) SCHEDULE=0; shift ;;
    --no-path) SET_PATH=0; shift ;;
    --alerts) ALERTS=1; shift ;;
    --auto-update) AUTO_UPDATE=1; shift ;;
    --context-alert) CONTEXT_ALERT=${2:-}; shift 2 || die "--context-alert needs a percentage" ;;
    --context-alert=*) CONTEXT_ALERT=${1#*=}; shift ;;
    --ssh-alias) SSH_ALIAS=${2:-}; shift 2 || die "--ssh-alias needs a name" ;;
    --ssh-alias=*) SSH_ALIAS=${1#*=}; shift ;;
    --agent-link) AGENT_LINK=${2:-}; shift 2 || die "--agent-link needs 'Label=url'" ;;
    --agent-link=*) AGENT_LINK=${1#*=}; shift ;;
    --orca-environment) ORCA_ENV=${2:-}; shift 2 || die "--orca-environment needs a name" ;;
    --orca-environment=*) ORCA_ENV=${1#*=}; shift ;;
    --force) FORCE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

case "$HOOKS" in user|project|none) ;; *) die "--claude-hooks must be user, project or none" ;; esac
case "$CODEX_HOOKS" in user|none) ;; *) die "--codex-hooks must be user or none" ;; esac
case "$GEMINI_HOOKS" in user|none) ;; *) die "--gemini-hooks must be user or none" ;; esac
case "$COPILOT_HOOKS" in user|none) ;; *) die "--copilot-hooks must be user or none" ;; esac
case "$CONTEXT" in ""|work|personal) ;; *) die "--context must be work or personal" ;; esac
if [ -n "$HUB_GIVEN" ]; then
  case "$HUB_GIVEN" in http://*|https://*) ;; *) die "--hub must be an http:// or https:// URL" ;; esac
  # It is saved to the (sourceable) env file, so no shell syntax: scheme://host:port[/path].
  case "$HUB_GIVEN" in *[!]A-Za-z0-9.:/_~%@[-]*) die "--hub has characters that aren't allowed in a hub URL" ;; esac
  HUB_URL=$HUB_GIVEN
fi
HUB_URL=${HUB_URL%/}
if [ -n "$CONTEXT_ALERT" ]; then
  case "$CONTEXT_ALERT" in *[!0-9]*) die "--context-alert must be a whole number from 0 to 100" ;; esac
  [ "$CONTEXT_ALERT" -le 100 ] || die "--context-alert must be a whole number from 0 to 100"
fi
if [ -n "$SSH_ALIAS" ] && ! printf '%s' "$SSH_ALIAS" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$'; then
  die "--ssh-alias must be a host alias (letters, digits, . _ @ -)"
fi
if [ -n "$ORCA_ENV" ] && ! printf '%s' "$ORCA_ENV" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'; then
  die "--orca-environment must be an Orca environment name (letters, digits, spaces, . _ -)"
fi
if [ -n "$AGENT_LINK" ] && [ "$AGENT_LINK" != none ]; then
  case "$AGENT_LINK" in
    *=*://*) ;;
    *) die "--agent-link must look like 'Label=scheme://...' (or none)" ;;
  esac
  case "$AGENT_LINK" in *[\'\"\\\`\$]*) die "--agent-link can't contain quotes, backslashes, \` or \$" ;; esac
  [ "${#AGENT_LINK}" -le 500 ] || die "--agent-link is too long"
fi

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/needs-you"
ENV_FILE="$CONF_DIR/env"
BIN_DIR="${NEEDS_YOU_BIN_DIR:-$HOME/.local/bin}"
CLI="$BIN_DIR/needs-you"
SKILL_DIR="$HOME/.claude/skills/needs-you"
LABEL="io.needs-you.flush"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CRON_TAG="# needs-you-flush"
PATH_TAG="# added by needs-you"
OS=$(uname -s)

# ---------------------------------------------------------------- schedule
schedule_install() {
  if [ "$OS" = "Darwin" ]; then
    mkdir -p "$(dirname "$PLIST")"
    cat >"$PLIST.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$CLI</string><string>-q</string><string>flush</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
    mv -f "$PLIST.tmp" "$PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1; then
      say "flush: LaunchAgent $LABEL runs \`needs-you flush\` every 5 minutes"
    else
      warn "could not load $PLIST; it loads at next login"
    fi
  elif command -v crontab >/dev/null 2>&1; then
    line="*/5 * * * * \"$CLI\" -q flush >/dev/null 2>&1 $CRON_TAG"
    current=$(crontab -l 2>/dev/null || true)
    if printf '%s\n' "$current" | grep -qxF "$line"; then
      say "flush: crontab entry already present"
    else
      { printf "%s\n" "$current" | { grep -vF "$CRON_TAG" || true; } | sed "/^$/d"; printf "%s\n" "$line"; } | crontab -
      say "flush: crontab runs \`needs-you flush\` every 5 minutes"
    fi
  else
    warn "no crontab here; run \`$CLI flush\` periodically yourself (e.g. a systemd timer)"
  fi
}

schedule_remove() {
  if [ "$OS" = "Darwin" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST"
  elif command -v crontab >/dev/null 2>&1; then
    current=$(crontab -l 2>/dev/null || true)
    if printf '%s\n' "$current" | grep -qF "$CRON_TAG"; then
      printf "%s\n" "$current" | { grep -vF "$CRON_TAG" || true; } | sed "/^$/d" | crontab -
    fi
  fi
}

# ---------------------------------------------------------------- PATH
# One tagged line in the login shell's profile, so `needs-you` works in new shells.
profile_file() {
  case "${SHELL##*/}" in
    zsh) printf '%s' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ "$OS" = Darwin ]; then printf '%s' "$HOME/.bash_profile"; else printf '%s' "$HOME/.bashrc"; fi ;;
    *) printf '%s' "$HOME/.profile" ;;
  esac
}

path_setup() {
  case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac
  local shown=$BIN_DIR rc line
  case "$BIN_DIR" in "$HOME"/*) shown="\$HOME/${BIN_DIR#"$HOME"/}" ;; esac
  line="export PATH=\"$shown:\$PATH\""
  if [ "$SET_PATH" -eq 0 ]; then
    say "PATH: $BIN_DIR is not on PATH. Add this line to your shell profile:"
    say "  $line"
    return 0
  fi
  rc=$(profile_file)
  if [ -f "$rc" ] && awk -v a="$shown" -v b="$BIN_DIR" -v t="$PATH_TAG" \
      'index($0, t) || (!/^[[:space:]]*#/ && /PATH/ && (index($0, a) || index($0, b))) { f = 1 } END { exit !f }' "$rc"; then
    say "PATH: $rc already adds $shown"
  else
    printf '\n%s  %s\n' "$line" "$PATH_TAG" >>"$rc"
    say "PATH: added $shown to PATH in $rc"
  fi
  say "  (new shells pick it up; in this one run: $line)"
}

path_remove() {
  local rc
  for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$rc" ] && grep -qF "$PATH_TAG" "$rc" || continue
    # cat > keeps the file's inode, mode and any symlink (dotfile managers)
    { grep -vF "$PATH_TAG" "$rc" || true; } >"$rc.needs-you.tmp" && cat "$rc.needs-you.tmp" >"$rc"
    rm -f "$rc.needs-you.tmp"
  done
}

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" -eq 1 ]; then
  schedule_remove
  path_remove
  # The CLI removes every agent's hooks locally (Claude Code user level, this directory's
  # project and recorded project installs; Codex, Gemini CLI, the opencode plugin, Copilot CLI). A CLI
  # from before `uninstall-hooks` falls back to the installers from the hub.
  if [ -x "$CLI" ] && "$CLI" uninstall-hooks --help >/dev/null 2>&1; then
    "$CLI" uninstall-hooks || warn "some agent hooks were left in place (see above)"
  else
    if [ -f "$HOME/.claude/hooks/needs-you-hook.sh" ] && [ -f "$HOME/.claude/settings.json" ] &&
       command -v curl >/dev/null 2>&1; then
      tmp=$(mktemp -d)
      if curl -fsSL --noproxy '*' --max-time 20 "$HUB_URL/dl/install-hooks.sh" -o "$tmp/install-hooks.sh" &&
         verify install-hooks.sh "$tmp/install-hooks.sh"; then
        bash "$tmp/install-hooks.sh" --user --uninstall || warn "removing the Claude Code hooks failed"
      else
        warn "hub unreachable; remove the hooks with integrations/claude-code/install-hooks.sh --uninstall"
      fi
      rm -rf "$tmp"
    fi
    # Codex and Gemini CLI: <name> <its directory> <installer's flag for it>
    for spec in "codex ${CODEX_HOME:-$HOME/.codex} --codex-home" "gemini $HOME/.gemini --gemini-dir"; do
      set -- $spec
      if [ -f "$2/hooks/needs-you-hook.sh" ] && command -v curl >/dev/null 2>&1; then
        tmp=$(mktemp -d)
        if curl -fsSL --noproxy '*' --max-time 20 "$HUB_URL/dl/install-$1-hooks.sh" -o "$tmp/install-$1-hooks.sh" &&
           verify "install-$1-hooks.sh" "$tmp/install-$1-hooks.sh"; then
          bash "$tmp/install-$1-hooks.sh" "$3" "$2" --uninstall || warn "removing the $1 hooks failed"
        else
          warn "hub unreachable; remove the $1 hooks with integrations/$1/install-$1-hooks.sh --uninstall"
        fi
        rm -rf "$tmp"
      fi
    done
    OC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
    rm -f "$OC_DIR/plugins/needs-you.js" "$OC_DIR/hooks/needs-you-hook.sh"
    rmdir "$OC_DIR/plugins" "$OC_DIR/hooks" 2>/dev/null || true
    CP_DIR="${COPILOT_HOME:-$HOME/.copilot}"
    rm -f "$CP_DIR/hooks/needs-you.json" "$CP_DIR/hooks/needs-you-hook.sh"
    rmdir "$CP_DIR/hooks" 2>/dev/null || true
  fi
  rm -rf "$SKILL_DIR"
  rm -f "$CLI" "$ENV_FILE" "$CONF_DIR/orca-snippet.md"
  rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/needs-you"
  rmdir "$CONF_DIR" 2>/dev/null || true
  say "needs-you removed from this machine. Revoke its token in the Mac app (Settings → Machines) or on the hub."
  exit 0
fi

# ---------------------------------------------------------------- checks
if [ "$ROLE" != "sender" ]; then
  say "This invite ($INVITE_NAME, role $ROLE) is for the Mac app, not for a server."
  say "On the Mac, open it (or paste it into Settings → Other hubs (advanced)):"
  say "  $MAC_URL"
  exit 1
fi
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 3.9+ is required"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' ||
  die "python3 3.9+ is required (found $(python3 -V 2>&1))"
[ -n "$HOST_NAME" ] || HOST_NAME=$(hostname -s 2>/dev/null || hostname)
HOST_NAME=${HOST_NAME%%.*}

HAVE_TOKEN=0
if [ -f "$ENV_FILE" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_TOKEN=.' "$ENV_FILE"; then
  HAVE_TOKEN=1
fi

if { [ "$HAVE_TOKEN" -eq 0 ] || [ "$FORCE" -eq 1 ]; } && [ "$USES_LEFT" -le 0 ] 2>/dev/null; then
  die "invite $INVITE_NAME has no uses left, so it can't set up $HOST_NAME$([ "$FORCE" -eq 1 ] && printf ' again with --force'). Ask for a new link."
fi

say "needs-you: connect $HOST_NAME to $HUB_URL (invite $INVITE_NAME)"
say "  CLI     -> $CLI"
say "  config  -> $ENV_FILE$([ "$HAVE_TOKEN" -eq 1 ] && [ "$FORCE" -eq 0 ] && printf ' (already set up: keeping the token)')"
[ "$SCHEDULE" -eq 1 ] && say "  flush   -> every 5 minutes ($([ "$OS" = Darwin ] && echo LaunchAgent || echo crontab))"
[ "$HOOKS" != none ] && say "  hooks   -> Claude Code ($HOOKS level)$([ "$ALERTS" = 1 ] && printf ', on for every session')"
[ "$CODEX_HOOKS" != none ] && say "  hooks   -> Codex CLI (${CODEX_HOME:-~/.codex}/hooks.json)$([ "$ALERTS" = 1 ] && printf ', on for every session')"
[ "$OPENCODE" -eq 1 ] && say "  plugin  -> opencode (${XDG_CONFIG_HOME:-~/.config}/opencode/plugins/needs-you.js)"
[ "$GEMINI_HOOKS" != none ] && say "  hooks   -> Gemini CLI (~/.gemini/settings.json)$([ "$ALERTS" = 1 ] && printf ', on for every session')"
[ "$COPILOT_HOOKS" != none ] && say "  hooks   -> Copilot CLI (${COPILOT_HOME:-~/.copilot}/hooks/needs-you.json)$([ "$ALERTS" = 1 ] && printf ', on for every session')"
[ "$SKILL" -eq 1 ] && say "  skill   -> $SKILL_DIR"
[ "$ORCA" -eq 1 ] && say "  orca    -> $CONF_DIR/orca-snippet.md"
if [ "$YES" -ne 1 ]; then
  if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
    printf 'Continue? [y/N] ' >/dev/tty
    read -r answer </dev/tty || answer=""
    case "$answer" in y|Y|yes|YES) ;; *) die "cancelled" ;; esac
  else
    die "no terminal to confirm on; re-run with --yes"
  fi
fi

umask 077
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fetch() { curl -fsSL --noproxy '*' --max-time 30 "$HUB_URL/dl/$1" -o "$2" && verify "$1" "$2"; }

# ---------------------------------------------------------------- CLI
if ! curl -fsS --noproxy '*' --max-time 10 -o /dev/null "$HUB_URL/v1/health"; then
  warn "can't reach the hub at $HUB_URL, so nothing was installed. Check from this machine:"
  warn "  curl -sS --max-time 5 $HUB_URL/v1/health     (should print \"ok\":true)"
  warn "A timeout: the Mac is asleep, Tailscale is off on one of the two machines, or macOS"
  warn "blocked python3 (allow it when asked). \"Could not resolve host\": this machine isn't"
  warn "on the tailnet or MagicDNS is off: re-run with --hub and the hub's tailnet IP in place of"
  warn "its name (e.g. --hub http://100.x.y.z:8765; \`tailscale ip -4\` on the Mac prints it)."
  die "more: docs/guides/tailscale.md (Check reachability) in the needs-you repo"
fi
fetch needs-you "$TMP/needs-you" || die "could not download the CLI from $HUB_URL/dl/needs-you"
python3 - "$TMP/needs-you" <<'PY' || die "the downloaded CLI looks wrong; not installing it"
import sys
src = open(sys.argv[1], encoding="utf-8").read()
assert src.startswith("#!") and "needs-you" in src
compile(src, "needs-you", "exec")
PY
mkdir -p "$BIN_DIR"
cp "$TMP/needs-you" "$BIN_DIR/.needs-you.new"
chmod 755 "$BIN_DIR/.needs-you.new"
mv -f "$BIN_DIR/.needs-you.new" "$CLI"
say "installed $CLI"

# ---------------------------------------------------------------- token + config
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
if [ "$HAVE_TOKEN" -eq 0 ] || [ "$FORCE" -eq 1 ]; then
  python3 -c 'import json,sys; print(json.dumps({"code": sys.argv[1], "host": sys.argv[2]}))' \
    "$CODE" "$HOST_NAME" >"$TMP/req.json"
  status=$(curl -sS --noproxy '*' --max-time 30 -o "$TMP/resp.json" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data-binary @"$TMP/req.json" "$HUB_URL/v1/invites/redeem") ||
    die "could not reach $HUB_URL to redeem the invite"
  if [ "$status" != "200" ]; then
    msg=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("message",""))' "$TMP/resp.json" 2>/dev/null || true)
    die "the hub refused the invite (HTTP $status${msg:+: $msg}). Ask for a new link."
  fi
fi

# Rewrite the env file: keep unrelated lines, replace ours. The token never touches argv.
python3 - "$ENV_FILE" "$TMP/resp.json" "$CONTEXT" "$HUB_GIVEN" "$ALERTS" "$CONTEXT_ALERT" \
  "$SSH_ALIAS" "$AGENT_LINK" "$ORCA_ENV" "$AUTO_UPDATE" <<'PY'
import json, os, re, sys
path, resp_path, context, given, alerts, ctx_alert, ssh_alias, agent_link, orca_env, auto_update = sys.argv[1:11]
lines = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

def current(key):
    for line in lines:
        k, _, v = line.strip().partition("=")
        if k.replace("export ", "", 1).strip() == key:
            return v.strip().strip("'\"")
    return ""

updates = {}
urls = None
import re
# The env file is documented as sourceable (`. ~/.config/needs-you/env`), so nothing the hub
# sent may carry shell syntax into it: tokens and URLs must be plain.
SAFE_URL = re.compile(r"^https?://[A-Za-z0-9.:/_~%@\[\]-]+$")
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9._~+/=-]+$")
if os.path.exists(resp_path):
    resp = json.load(open(resp_path))
    urls = [u.rstrip("/") for u in resp.get("hub_urls") or [] if isinstance(u, str) and u]
    bad = [u for u in urls if not SAFE_URL.match(u)]
    if bad or not isinstance(resp.get("token"), str) or not SAFE_TOKEN.match(resp["token"]):
        sys.exit("needs-you install: the hub's answer has characters that don't belong in a "
                 "token or hub URL; not writing it to %s" % path)
    updates["NEEDS_YOU_TOKEN"] = resp["token"]
if given and not SAFE_URL.match(given):
    sys.exit("needs-you install: --hub %r has characters that aren't allowed in a hub URL" % given)
if given:  # --hub: this URL first, then the rest
    rest = urls if urls is not None else [u for u in current("NEEDS_YOU_URLS").split(",") if u]
    urls = [given.rstrip("/")] + [u for u in rest if u.rstrip("/") != given.rstrip("/")]
if urls is not None:
    updates["NEEDS_YOU_URLS"] = ",".join(urls)
    updates["NEEDS_YOU_URL"] = urls[0] if urls else ""
if context:
    updates["NEEDS_YOU_DEFAULT_CONTEXT"] = context
for k, v in (("NEEDS_YOU_AGENT_ALERTS", alerts), ("NEEDS_YOU_CONTEXT_ALERT_PCT", ctx_alert),
             ("NEEDS_YOU_SSH_ALIAS", ssh_alias), ("NEEDS_YOU_AGENT_LINK", agent_link),
             ("NEEDS_YOU_ORCA_ENVIRONMENT", orca_env), ("NEEDS_YOU_AUTO_UPDATE", auto_update)):
    if v:
        updates[k] = v if re.match(r"^[A-Za-z0-9._:/,@+%-]*$", v) else "'%s'" % v
out, seen = [], set()
for line in lines:
    k = line.strip()
    if k.startswith("export "):
        k = k[7:].strip()
    k = k.split("=", 1)[0].strip()
    if k in updates:
        if k not in seen:
            out.append("%s=%s" % (k, updates[k]))
            seen.add(k)
        continue
    out.append(line)
if not lines:
    out.insert(0, "# needs-you sender config (written by the invite installer)")
for k, v in updates.items():
    if k not in seen:
        out.append("%s=%s" % (k, v))
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
if "NEEDS_YOU_TOKEN" in updates:
    print("redeemed the invite: wrote %s (hubs: %s)" % (path, updates["NEEDS_YOU_URLS"]))
else:
    print("kept the existing token in %s (use --force to replace it)" % path)
    if "NEEDS_YOU_URLS" in updates:
        print("hubs: %s" % updates["NEEDS_YOU_URLS"])
PY

# ---------------------------------------------------------------- extras
[ "$SCHEDULE" -eq 1 ] && schedule_install
path_setup

if [ "$HOOKS" != none ]; then
  for f in install-hooks.sh needs-you-hook.sh hooks.json; do
    fetch "$f" "$TMP/$f" || die "could not download the Claude Code hooks ($f)"
  done
  if [ "$HOOKS" = user ]; then
    NEEDS_YOU_INSTALLER=1 bash "$TMP/install-hooks.sh" --user
    # Record which hooks.json the settings were merged from, as `needs-you update` does, so
    # `needs-you doctor` doesn't report the hooks we just installed as out of date.
    hj=""
    for kv in $SHA256S; do [ "${kv%%=*}" = hooks.json ] && hj=${kv#*=}; done
    if [ -n "$hj" ]; then
      python3 - "${XDG_STATE_HOME:-$HOME/.local/state}/needs-you" "$hj" <<'PY' || true
import json, os, sys
d, sha = sys.argv[1], sys.argv[2]
p = os.path.join(d, "update.json")
try:
    with open(p, encoding="utf-8") as fh:
        st = json.load(fh)
    st = st if isinstance(st, dict) else {}
except (OSError, ValueError):
    st = {}
st["hooks_json_sha256"] = sha
os.makedirs(d, mode=0o700, exist_ok=True)
fd = os.open(p + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(st, fh, sort_keys=True)
os.replace(p + ".tmp", p)
PY
    fi
  else
    NEEDS_YOU_INSTALLER=1 bash "$TMP/install-hooks.sh" --project "$PWD"
  fi
fi

# install_agent_hooks NAME DIR FLAG: Codex, Gemini CLI or Copilot CLI, the same hook as Claude Code's.
install_agent_hooks() {
  local f sha="" kv
  for f in "install-$1-hooks.sh" needs-you-hook.sh "$1-hooks.json"; do
    fetch "$f" "$TMP/$f" || die "could not download the $1 hooks ($f)"
  done
  NEEDS_YOU_INSTALLER=1 bash "$TMP/install-$1-hooks.sh" "$3" "$2"
  # As for Claude: record the snippet merged, so `needs-you doctor` and `update` don't call
  # these fresh entries out of date.
  for kv in $SHA256S; do [ "${kv%%=*}" = "$1-hooks.json" ] && sha=${kv#*=}; done
  [ -n "$sha" ] || return 0
  python3 - "${XDG_STATE_HOME:-$HOME/.local/state}/needs-you" "$1_hooks_json_sha256" "$sha" <<'PY' || true
import json, os, sys
d, key, sha = sys.argv[1], sys.argv[2], sys.argv[3]
p = os.path.join(d, "update.json")
try:
    with open(p, encoding="utf-8") as fh:
        st = json.load(fh)
    st = st if isinstance(st, dict) else {}
except (OSError, ValueError):
    st = {}
st[key] = sha
os.makedirs(d, mode=0o700, exist_ok=True)
fd = os.open(p + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(st, fh, sort_keys=True)
os.replace(p + ".tmp", p)
PY
}
[ "$CODEX_HOOKS" = user ] && install_agent_hooks codex "${CODEX_HOME:-$HOME/.codex}" --codex-home
[ "$GEMINI_HOOKS" = user ] && install_agent_hooks gemini "$HOME/.gemini" --gemini-dir
[ "$COPILOT_HOOKS" = user ] && install_agent_hooks copilot "${COPILOT_HOME:-$HOME/.copilot}" --copilot-home
if [ "$OPENCODE" -eq 1 ]; then
  for f in install-opencode-plugin.sh needs-you-hook.sh needs-you-opencode.js; do
    fetch "$f" "$TMP/$f" || die "could not download the opencode plugin ($f)"
  done
  bash "$TMP/install-opencode-plugin.sh"
fi

if [ "$SKILL" -eq 1 ]; then
  mkdir -p "$SKILL_DIR"
  fetch SKILL.md "$TMP/SKILL.md" || die "could not download the skill"
  chmod 644 "$TMP/SKILL.md"
  mv -f "$TMP/SKILL.md" "$SKILL_DIR/SKILL.md"
  say "installed the needs-you skill in $SKILL_DIR"
fi

if [ "$ORCA" -eq 1 ]; then
  fetch orca-snippet.md "$TMP/orca-snippet.md" || die "could not download the Orca snippet"
  chmod 644 "$TMP/orca-snippet.md"
  mv -f "$TMP/orca-snippet.md" "$CONF_DIR/orca-snippet.md"
  chmod 644 "$CONF_DIR/orca-snippet.md"
  say ""
  say "Orca: wrote $CONF_DIR/orca-snippet.md (needs-you update keeps it current)."
  say "Paste this block into each automation prompt (or the template they are rendered from):"
  say "------------------------------------------------------------------------"
  cat <<'EOF'
## Telling the user (needs-you)

Before you post to or resolve anything in needs-you, read
`~/.config/needs-you/orca-snippet.md` and follow it. It says when to tell the
user that only they can unblock this run, and exactly how.
EOF
  say "------------------------------------------------------------------------"
  if [ "$HOOKS" = none ]; then
    say "For Orca agent terminals, also re-run with --claude-hooks user (Orca sessions"
    say "are opted in automatically)."
  fi
fi

# ---------------------------------------------------------------- check + test
say ""
"$CLI" health || warn "no hub answered right now (asleep or offline?). Items queue and are sent by the 5-minute flush."
"$CLI" -q info --key "setup:$HOST_NAME:test" --title "needs-you is set up on $HOST_NAME" \
  --body "Test item from the invite installer. It expires on its own." --agent installer \
  --host "$HOST_NAME" || true
say ""
case ":$PATH:" in
  *":$BIN_DIR:"*) NY=needs-you ;;
  *) NY=$CLI ;;  # path_setup above said how to get it on PATH; until then, the full path works
esac
say "Done. Check the setup (every line should be OK or INFO):"
say "  $NY doctor"
say "Then post a test item and resolve it:"
say "  $NY add --key \"personal:test:$HOST_NAME\" --context personal --title \"Hello from $HOST_NAME\""
say "  $NY resolve --key \"personal:test:$HOST_NAME\""
