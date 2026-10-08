#!/usr/bin/env bash
# setup-sender.sh: make this machine a needs-you sender.
#
# What it does (each step is safe to re-run):
#   1. Optionally installs the `needs-you` CLI (a single Python 3 file) into
#      ~/.local/bin, copied from this repo checkout or downloaded from a URL.
#   2. Asks for the hub URL(s) (comma-separated failover list) and this
#      machine's token (hidden input), and writes ~/.config/needs-you/env
#      ($XDG_CONFIG_HOME/needs-you/env when that is set) with mode 600.
#   3. Checks GET /v1/health on every hub.
#   4. Schedules `needs-you flush` every 5 minutes (crontab on Linux, a
#      LaunchAgent on macOS), like the invite installer.
#   5. Puts the CLI's directory on PATH with one tagged line in your login
#      shell's profile (--no-path prints the line instead).
#   6. Offers to post a test `info` item.
#
# Hard requirements: bash (3.2+ is fine), curl, python3 (3.9+). No package
# installs, no jq.
#
# Run with --help for flags. See docs/guides/add-a-sender.md.

set -euo pipefail
set -f  # no globbing: URL lists are split on commas, never expanded

PROG=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/needs-you"  # where the CLI and the hooks look
ENV_FILE="$CONFIG_DIR/env"
BIN_DIR="$HOME/.local/bin"

# Flags
NON_INTERACTIVE=0
URLS=""
TOKEN=""
TOKEN_FROM_STDIN=0
TEST_MODE=""            # "" = ask (interactive) / skip (non-interactive); "yes" | "no"
TEST_CONTEXT="personal"
CLI_MODE=""             # "" = ask/auto; "skip"; "path"; "url"
CLI_SOURCE=""
REQUIRE_HEALTH=0
SCHEDULE=1
SET_PATH=1
ALERTS=""
CONTEXT_ALERT=""
SSH_ALIAS=""
AGENT_LINK=""
ORCA_ENV=""
AUTO_UPDATE=""          # "" = 1 unless the env file already has a value; "1" | "0"

usage() {
  cat <<EOF
Usage: $PROG [options]

Interactive by default. Every prompt has a flag, so it also runs unattended.

Hub and token:
  --url URLS             Hub URL(s), comma-separated, in failover order.
                         e.g. http://hub-a.tailnet.ts.net:8765,http://hub-b.tailnet.ts.net:8765
  --token-stdin          Read the token from stdin (preferred for automation:
                         it keeps the token out of 'ps' and shell history).
  --token TOKEN          Token on the command line (visible in 'ps'; avoid).
                         NEEDS_YOU_TOKEN in the environment works too.

CLI install:
  --install-cli [SRC]    Install the needs-you CLI into $BIN_DIR. SRC is a local
                         file path or an http(s) URL to the raw 'needs-you'
                         file. Without SRC, uses cli/needs-you from this repo.
  --no-install-cli       Don't install or update the CLI.
  --bin-dir DIR          Install the CLI here instead of $BIN_DIR.

Checks:
  --test                 Post a test 'info' item after the health check.
  --no-test              Don't post a test item.
  --test-context CTX     Context for the test item: work | personal (default: personal).
  --require-health       Exit 3 if no hub answers /v1/health (default: warn only).
  --no-schedule          Don't schedule the 5-minute 'needs-you flush'.
  --no-path              Don't edit your shell profile; print the PATH line instead.
  --no-auto-update       Don't let the flush run 'needs-you update' once a day. It's on
                         by default (NEEDS_YOU_AUTO_UPDATE=1): updates come only from the
                         first hub, checked against the GitHub release.
  --auto-update          Turn it back on after --no-auto-update.

Claude Code hook settings (written to the env file; see
integrations/claude-code/README.md):
  --alerts               Hooks on for every session here (NEEDS_YOU_AGENT_ALERTS=1).
  --context-alert PCT    Card suggesting /compact or /clear at PCT% context (default 80; 0 = off).
  --ssh-alias NAME       This host's alias in the Mac's ~/.ssh/config: Remote-SSH links.
  --agent-link 'L=URL'   One link template instead of the automatic editor links ('none' = off).
  --orca-environment N   On a paired Orca server: its name in the Mac's Orca.

Mode:
  --non-interactive      Never prompt. Needs --url and a token (flag, stdin or
                         env) unless an existing env file already has them.
  -h, --help             Show this help.

Files:
  $ENV_FILE  (mode 600)
EOF
}

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

# ---------------------------------------------------------------- args
while [ $# -gt 0 ]; do
  case "$1" in
    --url) [ $# -ge 2 ] || die "--url needs a value"; URLS=$2; shift 2 ;;
    --url=*) URLS=${1#*=}; shift ;;
    --token) [ $# -ge 2 ] || die "--token needs a value"; TOKEN=$2; shift 2 ;;
    --token=*) TOKEN=${1#*=}; shift ;;
    --token-stdin) TOKEN_FROM_STDIN=1; shift ;;
    --install-cli)
      CLI_MODE="repo"
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then CLI_SOURCE=$2; shift; fi
      shift ;;
    --install-cli=*) CLI_MODE="repo"; CLI_SOURCE=${1#*=}; shift ;;
    --no-install-cli) CLI_MODE="skip"; shift ;;
    --bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a value"; BIN_DIR=$2; shift 2 ;;
    --bin-dir=*) BIN_DIR=${1#*=}; shift ;;
    --test) TEST_MODE="yes"; shift ;;
    --no-test) TEST_MODE="no"; shift ;;
    --test-context) [ $# -ge 2 ] || die "--test-context needs a value"; TEST_CONTEXT=$2; shift 2 ;;
    --test-context=*) TEST_CONTEXT=${1#*=}; shift ;;
    --require-health) REQUIRE_HEALTH=1; shift ;;
    --no-schedule) SCHEDULE=0; shift ;;
    --no-path) SET_PATH=0; shift ;;
    --auto-update) AUTO_UPDATE=1; shift ;;
    --no-auto-update) AUTO_UPDATE=0; shift ;;
    --alerts) ALERTS=1; shift ;;
    --context-alert) [ $# -ge 2 ] || die "--context-alert needs a value"; CONTEXT_ALERT=$2; shift 2 ;;
    --context-alert=*) CONTEXT_ALERT=${1#*=}; shift ;;
    --ssh-alias) [ $# -ge 2 ] || die "--ssh-alias needs a value"; SSH_ALIAS=$2; shift 2 ;;
    --ssh-alias=*) SSH_ALIAS=${1#*=}; shift ;;
    --agent-link) [ $# -ge 2 ] || die "--agent-link needs a value"; AGENT_LINK=$2; shift 2 ;;
    --agent-link=*) AGENT_LINK=${1#*=}; shift ;;
    --orca-environment) [ $# -ge 2 ] || die "--orca-environment needs a value"; ORCA_ENV=$2; shift 2 ;;
    --orca-environment=*) ORCA_ENV=${1#*=}; shift ;;
    --non-interactive|--yes|-y) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
done

case "$TEST_CONTEXT" in work|personal) ;; *) die "--test-context must be work or personal" 2 ;; esac
# Absolute: it goes into the crontab line and the shell profile, which don't run from here.
case "$BIN_DIR" in /*) ;; *) BIN_DIR="$PWD/$BIN_DIR" ;; esac
# It goes into crontab and the shell profile inside double quotes: nothing in it may end the
# quotes or expand later.
NL=$'\n'
case "$BIN_DIR" in
  *[\"\$\`\\]*|*"$NL"*) die "--bin-dir must not contain a quote, \$, a backtick, a backslash or a newline" ;;
esac
if [ -n "$CONTEXT_ALERT" ]; then
  case "$CONTEXT_ALERT" in *[!0-9]*) die "--context-alert must be a whole number from 0 to 100" 2 ;; esac
  [ "$CONTEXT_ALERT" -le 100 ] || die "--context-alert must be a whole number from 0 to 100" 2
fi
if [ -n "$SSH_ALIAS" ] && ! printf '%s' "$SSH_ALIAS" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$'; then
  die "--ssh-alias must be a host alias (letters, digits, . _ @ -)" 2
fi
if [ -n "$ORCA_ENV" ] && ! printf '%s' "$ORCA_ENV" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'; then
  die "--orca-environment must be an Orca environment name (letters, digits, spaces, . _ -)" 2
fi
if [ -n "$AGENT_LINK" ] && [ "$AGENT_LINK" != none ]; then
  case "$AGENT_LINK" in *=*://*) ;; *) die "--agent-link must look like 'Label=scheme://...' (or none)" 2 ;; esac
  case "$AGENT_LINK" in *[\'\"\\\`\$]*) die "--agent-link can't contain quotes, backslashes, \` or \$" 2 ;; esac
  [ "${#AGENT_LINK}" -le 500 ] || die "--agent-link is too long" 2
fi

# Interactive prompts read from the terminal, not stdin, so --token-stdin and
# prompts can be mixed. If there is no terminal, fall back to non-interactive.
if [ "$NON_INTERACTIVE" -eq 0 ] && ! { : </dev/tty; } 2>/dev/null; then
  warn "no terminal available; continuing as --non-interactive"
  NON_INTERACTIVE=1
fi

ask() { # ask "Prompt" default -> echoes answer
  local prompt=$1 default=${2:-} reply
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
  else
    printf '%s: ' "$prompt" >/dev/tty
  fi
  IFS= read -r reply </dev/tty || reply=""
  [ -n "$reply" ] || reply=$default
  printf '%s' "$reply"
}

ask_secret() { # ask_secret "Prompt" -> echoes answer, no echo on screen
  local prompt=$1 reply
  printf '%s: ' "$prompt" >/dev/tty
  # -s hides input; restore the terminal even on Ctrl-C.
  trap 'stty echo </dev/tty 2>/dev/null || true' INT TERM
  IFS= read -r -s reply </dev/tty || reply=""
  trap - INT TERM
  printf '\n' >/dev/tty
  printf '%s' "$reply"
}

confirm() { # confirm "Question" default(y|n)
  local q=$1 def=${2:-n} hint reply
  if [ "$def" = y ]; then hint="Y/n"; else hint="y/N"; fi
  printf '%s [%s]: ' "$q" "$hint" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  [ -n "$reply" ] || reply=$def
  case "$reply" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- prerequisites
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (3.9+; macOS ships /usr/bin/python3)"
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
  warn "python3 is $(python3 -V 2>&1); needs-you expects 3.9 or newer"
fi

HOST_SHORT=$(hostname -s 2>/dev/null || hostname)
HOST_SHORT=${HOST_SHORT%%.*}

# ---------------------------------------------------------------- existing config
# The env file is KEY=value lines, sourceable by sh and easy for the CLI to
# parse. We own NEEDS_YOU_URL, NEEDS_YOU_URLS and NEEDS_YOU_TOKEN and keep any
# other lines the user added.
read_env_value() { # read_env_value KEY -> value from the existing env file
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "$ENV_FILE" | tail -n 1 |
    sed -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/'
}

OLD_URLS=$(read_env_value NEEDS_YOU_URLS)
[ -n "$OLD_URLS" ] || OLD_URLS=$(read_env_value NEEDS_YOU_URL)
OLD_TOKEN=$(read_env_value NEEDS_YOU_TOKEN)

say "needs-you sender setup on $HOST_SHORT"
[ -f "$ENV_FILE" ] && info "existing config: $ENV_FILE (values you don't change are kept)"

# ---------------------------------------------------------------- 1. CLI install
install_cli() {
  local src=$1 dest="$BIN_DIR/needs-you" tmp
  mkdir -p "$BIN_DIR"
  tmp=$(mktemp "$BIN_DIR/.needs-you.XXXXXX")
  case "$src" in
    http://*|https://*)
      info "downloading $src"
      if ! curl -fsSL --max-time 30 -o "$tmp" "$src"; then
        rm -f "$tmp"; die "download failed: $src"
      fi ;;
    *)
      [ -f "$src" ] || { rm -f "$tmp"; die "CLI file not found: $src"; }
      cp "$src" "$tmp" ;;
  esac
  # Sanity check: a Python 3 script that parses. Catches HTML error pages and
  # truncated downloads before they replace a working CLI.
  if ! head -n 1 "$tmp" | grep -q 'python'; then
    rm -f "$tmp"; die "$src does not look like the needs-you CLI (no python shebang)"
  fi
  if ! python3 - "$tmp" <<'PY'
import ast, sys
with open(sys.argv[1], "rb") as f:
    ast.parse(f.read(), sys.argv[1])
PY
  then
    rm -f "$tmp"; die "$src is not valid Python 3"
  fi
  chmod 755 "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"; info "CLI already up to date: $dest"
  else
    mv -f "$tmp" "$dest"; info "installed CLI: $dest"
  fi
}

REPO_CLI="$REPO_DIR/cli/needs-you"
if [ -z "$CLI_MODE" ]; then
  if [ -f "$REPO_CLI" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      CLI_MODE="skip"
      info "CLI: not installing (pass --install-cli to install $REPO_CLI)"
    elif confirm "Install or update the needs-you CLI in $BIN_DIR from this repo?" y; then
      CLI_MODE="repo"
    else
      CLI_MODE="skip"
    fi
  else
    CLI_MODE="skip"
    if ! command -v needs-you >/dev/null 2>&1; then
      info "CLI: $REPO_CLI not found; skipping (re-run with --install-cli <path-or-url>)"
    fi
  fi
fi
if [ "$CLI_MODE" = "repo" ]; then
  [ -n "$CLI_SOURCE" ] || CLI_SOURCE=$REPO_CLI
  install_cli "$CLI_SOURCE"
fi

# ---------------------------------------------------------------- 2. URLs and token
if [ "$TOKEN_FROM_STDIN" -eq 1 ]; then
  IFS= read -r TOKEN || true
fi
[ -n "$TOKEN" ] || TOKEN=${NEEDS_YOU_TOKEN:-}

if [ "$NON_INTERACTIVE" -eq 1 ]; then
  [ -n "$URLS" ] || URLS=$OLD_URLS
  [ -n "$TOKEN" ] || TOKEN=$OLD_TOKEN
  [ -n "$URLS" ] || die "--url is required with --non-interactive (no existing config)" 2
  [ -n "$TOKEN" ] || die "a token is required with --non-interactive (--token-stdin, --token or NEEDS_YOU_TOKEN)" 2
else
  if [ -z "$URLS" ]; then
    say ""
    say "Hub URL(s). Use MagicDNS names, comma-separated in failover order,"
    say "e.g. http://hub-a.example.ts.net:8765,http://hub-b.example.ts.net:8765"
    URLS=$(ask "Hub URL(s)" "$OLD_URLS")
  fi
  if [ -z "$TOKEN" ]; then
    if [ -n "$OLD_TOKEN" ]; then
      TOKEN=$(ask_secret "Token for $HOST_SHORT (input hidden; Enter keeps the saved one)")
      [ -n "$TOKEN" ] || TOKEN=$OLD_TOKEN
    else
      TOKEN=$(ask_secret "Token for $HOST_SHORT (input hidden)")
    fi
  fi
  [ -n "$URLS" ] || die "no hub URL given"
  [ -n "$TOKEN" ] || die "no token given"
fi

# Normalise the URL list: trim spaces, drop empties and trailing slashes,
# require http(s)://, reject characters that would break the env file.
# url_list prints a comma-separated list one URL per line, whitespace removed.
url_list() { printf '%s\n' "$1" | tr ',' '\n' | tr -d ' \t\r'; }

NORMALISED=""
for u in $(url_list "$URLS"); do
  [ -n "$u" ] || continue
  while [ "${u%/}" != "$u" ]; do u=${u%/}; done
  case "$u" in
    http://*|https://*) ;;
    *) die "hub URL must start with http:// or https://: $u" 2 ;;
  esac
  case "$u" in
    *[!A-Za-z0-9.:/_~%@-]*) die "hub URL has characters that aren't allowed (expected scheme://host:port[/path]): $u" 2 ;;
  esac
  case ",$NORMALISED," in *",$u,"*) continue ;; esac
  NORMALISED=${NORMALISED:+$NORMALISED,}$u
done
[ -n "$NORMALISED" ] || die "no usable hub URL in: $URLS" 2
URLS=$NORMALISED
FIRST_URL=${URLS%%,*}

case "$TOKEN" in
  *[!A-Za-z0-9._~+/=-]*) die "token has unexpected characters (expected letters, digits and ._~+/=-)" 2 ;;
esac

# ---------------------------------------------------------------- write env file
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

# Hook settings passed as flags replace the same keys in the file; the rest stay.
SETTINGS=""
OWNED="URLS|URL|TOKEN"
add_setting() { # add_setting KEY VALUE (no-op for an empty value)
  [ -n "$2" ] || return 0
  local v=$2
  case "$v" in *[!A-Za-z0-9._:/,@+%-]*) v="'$v'" ;; esac
  SETTINGS="$SETTINGS$1=$v
"
  OWNED="$OWNED|${1#NEEDS_YOU_}"
}
add_setting NEEDS_YOU_AGENT_ALERTS "$ALERTS"
add_setting NEEDS_YOU_CONTEXT_ALERT_PCT "$CONTEXT_ALERT"
add_setting NEEDS_YOU_SSH_ALIAS "$SSH_ALIAS"
add_setting NEEDS_YOU_AGENT_LINK "$AGENT_LINK"
add_setting NEEDS_YOU_ORCA_ENVIRONMENT "$ORCA_ENV"
# Daily updates: on by default; a value already in the file is kept unless a flag says otherwise.
if [ -z "$AUTO_UPDATE" ] && ! { [ -f "$ENV_FILE" ] &&
     grep -Eq '^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_AUTO_UPDATE=' "$ENV_FILE"; }; then
  AUTO_UPDATE=1
fi
add_setting NEEDS_YOU_AUTO_UPDATE "$AUTO_UPDATE"
case "$AUTO_UPDATE" in
  1) info "daily updates: on, run by the flush (--no-auto-update turns them off)" ;;
  0) info "daily updates: off (run 'needs-you update' by hand)" ;;
esac
if [ "$SCHEDULE" -eq 0 ] && [ "$AUTO_UPDATE" != 0 ]; then
  warn "--no-schedule: daily updates run from the 5-minute flush, so they won't run until you schedule 'needs-you flush' yourself"
fi

TMP_ENV=$(umask 077; mktemp "$CONFIG_DIR/.env.XXXXXX")
trap 'rm -f "$TMP_ENV"' EXIT
{
  printf '# needs-you sender config, written by setup-sender.sh. Keep this file private (mode 600).\n'
  printf '# NEEDS_YOU_URLS: every hub, in failover order (the CLI tries them in turn).\n'
  printf '# NEEDS_YOU_URL:  the first hub, for plain curl.\n'
  printf 'NEEDS_YOU_URLS=%s\n' "$URLS"
  printf 'NEEDS_YOU_URL=%s\n' "$FIRST_URL"
  printf 'NEEDS_YOU_TOKEN=%s\n' "$TOKEN"
  if [ -f "$ENV_FILE" ]; then
    # Keep any extra settings the user added (e.g. NEEDS_YOU_AGENT_CONTEXT).
    grep -v -E "^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_($OWNED)=" "$ENV_FILE" |
      grep -v -E '^# (needs-you sender config|NEEDS_YOU_URLS:|NEEDS_YOU_URL: )' || true
  fi
  printf '%s' "$SETTINGS"
} >"$TMP_ENV"
chmod 600 "$TMP_ENV"
if [ -f "$ENV_FILE" ] && cmp -s "$TMP_ENV" "$ENV_FILE"; then
  rm -f "$TMP_ENV"
  info "config unchanged: $ENV_FILE"
else
  mv -f "$TMP_ENV" "$ENV_FILE"
  info "wrote $ENV_FILE (mode 600)"
fi
chmod 600 "$ENV_FILE"
trap - EXIT

# ---------------------------------------------------------------- 3. health checks
# Token goes to curl through a header file, never through argv.
AUTH_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/needs-you-auth.XXXXXX")
trap 'rm -f "$AUTH_FILE"' EXIT
printf 'Authorization: Bearer %s\n' "$TOKEN" >"$AUTH_FILE"

say ""
say "Checking hubs"
HEALTHY=""
for u in $(url_list "$URLS"); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    -H "@$AUTH_FILE" "$u/v1/health" 2>/dev/null) || code="000"
  case "$code" in
    2??) info "ok    $u"; [ -n "$HEALTHY" ] || HEALTHY=$u ;;
    000) info "FAIL  $u (unreachable: is this machine on the tailnet, and is the hub running?)" ;;
    *)   info "FAIL  $u (HTTP $code)" ;;
  esac
done

if [ -z "$HEALTHY" ]; then
  warn "no hub answered /v1/health. The CLI will queue items in its outbox until one does."
  [ "$REQUIRE_HEALTH" -eq 0 ] || exit 3
fi

# ---------------------------------------------------------------- 4. flush schedule
# Same schedule as the invite installer (hub/join-install.sh), so `needs-you
# flush` sends queued items and resolves cards of Claude sessions that died.
OS=$(uname -s)
FLUSH_LABEL="io.needs-you.flush"
PLIST="$HOME/Library/LaunchAgents/$FLUSH_LABEL.plist"
CRON_TAG="# needs-you-flush"
CLI_PATH=""
if [ -x "$BIN_DIR/needs-you" ]; then
  CLI_PATH="$BIN_DIR/needs-you"
elif command -v needs-you >/dev/null 2>&1; then
  CLI_PATH=$(command -v needs-you)
fi

# cron and launchd start the flush without the login shell's environment: where this
# machine keeps needs-you's files, when that isn't the default, is passed on explicitly
# (else the flush finds no config or outbox and sends nothing, every 5 minutes, quietly).
SCHED_VARS="XDG_CONFIG_HOME XDG_STATE_HOME NEEDS_YOU_CONFIG NEEDS_YOU_OUTBOX CODEX_HOME"
sched_cron_env() {  # "NAME='value' " for each one set
  local v val out=""
  for v in $SCHED_VARS; do
    val=${!v:-}
    [ -n "$val" ] || continue
    case "$val" in
      *"'"*|*%*|*"
"*) warn "$v has a ' or % in it; the flush schedule can't pass it on (set it in ~/.profile)" ; continue ;;
    esac
    out="$out$v='$val' "
  done
  printf '%s' "$out"
}
sched_plist_env() {  # an EnvironmentVariables entry, or nothing
  local v val out=""
  for v in $SCHED_VARS; do
    val=${!v:-}
    [ -n "$val" ] || continue
    val=$(printf '%s' "$val" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    out="$out<key>$v</key><string>$val</string>"
  done
  [ -z "$out" ] || printf '  <key>EnvironmentVariables</key><dict>%s</dict>\n' "$out"
}

schedule_install() {
  local cli=$1
  if [ "$OS" = "Darwin" ]; then
    mkdir -p "$(dirname "$PLIST")"
    cat >"$PLIST.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$FLUSH_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$cli</string><string>-q</string><string>flush</string></array>
$(sched_plist_env)
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
    if [ -f "$PLIST" ] && cmp -s "$PLIST.tmp" "$PLIST"; then
      rm -f "$PLIST.tmp"
      info "flush: LaunchAgent $FLUSH_LABEL already set up"
      return 0
    fi
    mv -f "$PLIST.tmp" "$PLIST"
    launchctl bootout "gui/$(id -u)/$FLUSH_LABEL" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1; then
      info "flush: LaunchAgent $FLUSH_LABEL runs 'needs-you flush' every 5 minutes"
    else
      warn "could not load $PLIST; it loads at next login"
    fi
  elif command -v crontab >/dev/null 2>&1; then
    local line current
    line="*/5 * * * * $(sched_cron_env)\"$cli\" -q flush >/dev/null 2>&1 $CRON_TAG"
    current=$(crontab -l 2>/dev/null || true)
    if printf '%s\n' "$current" | grep -qxF "$line"; then
      info "flush: crontab entry already present"
    else
      # The rest of the crontab as it was, blank lines too (none for an empty one).
      { [ -z "$current" ] || printf '%s\n' "$current" | { grep -vF "$CRON_TAG" || true; }; printf '%s\n' "$line"; } | crontab -
      info "flush: crontab runs 'needs-you flush' every 5 minutes"
    fi
  else
    warn "no crontab here; run '$cli flush' every few minutes yourself (e.g. a systemd timer)"
  fi
}

if [ "$SCHEDULE" -eq 1 ]; then
  if [ -n "$CLI_PATH" ]; then
    schedule_install "$CLI_PATH"
  else
    info "flush: not scheduled (no needs-you CLI found; re-run with --install-cli)"
  fi
fi

# ---------------------------------------------------------------- 5. PATH
PATH_TAG="# added by needs-you"
profile_file() {
  case "${SHELL##*/}" in
    zsh) printf '%s' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ "$OS" = Darwin ]; then printf '%s' "$HOME/.bash_profile"; else printf '%s' "$HOME/.bashrc"; fi ;;
    *) printf '%s' "$HOME/.profile" ;;
  esac
}
if [ -x "$BIN_DIR/needs-you" ]; then
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      SHOWN=$BIN_DIR
      case "$BIN_DIR" in "$HOME"/*) SHOWN="\$HOME/${BIN_DIR#"$HOME"/}" ;; esac
      PATH_LINE="export PATH=\"$SHOWN:\$PATH\""
      if [ "$SET_PATH" -eq 0 ]; then
        warn "$BIN_DIR is not on your PATH. Add this line to your shell profile:"
        printf '    %s\n' "$PATH_LINE" >&2
      else
        RC=$(profile_file)
        if [ -f "$RC" ] && awk -v a="$SHOWN" -v b="$BIN_DIR" -v t="$PATH_TAG" \
            'index($0, t) || (!/^[[:space:]]*#/ && /PATH/ && (index($0, a) || index($0, b))) { f = 1 } END { exit !f }' "$RC"; then
          info "PATH: $RC already adds $SHOWN"
        else
          if [ -s "$RC" ]; then printf '\n%s  %s\n' "$PATH_LINE" "$PATH_TAG" >>"$RC"
          else printf '%s  %s\n' "$PATH_LINE" "$PATH_TAG" >>"$RC"; fi
          info "PATH: added $SHOWN to PATH in $RC (new shells pick it up; in this one run: $PATH_LINE)"
        fi
      fi ;;
  esac
fi

# ---------------------------------------------------------------- 6. test item
if [ -z "$TEST_MODE" ]; then
  if [ "$NON_INTERACTIVE" -eq 1 ] || [ -z "$HEALTHY" ]; then
    TEST_MODE="no"
  elif confirm "Post a test 'info' item (shows under Recent on the Mac, expires in 24 h)?" y; then
    TEST_MODE="yes"
  else
    TEST_MODE="no"
  fi
fi

if [ "$TEST_MODE" = "yes" ]; then
  if [ -z "$HEALTHY" ]; then
    warn "skipping test item: no hub is reachable"
  else
    BODY=$(python3 - "$HOST_SHORT" "$TEST_CONTEXT" <<'PY'
import json, sys
host, context = sys.argv[1], sys.argv[2]
print(json.dumps({
    "key": "setup:%s:test" % host,
    "context": context,
    "kind": "info",
    "priority": "low",
    "title": "needs-you test from %s" % host,
    "body": "If you can read this on the Mac, `%s` can send. Nothing to do." % host,
    "source": {"host": host, "agent": "setup-sender", "project": "needs-you"},
}))
PY
)
    RESP_FILE=$(mktemp "${TMPDIR:-/tmp}/needs-you-resp.XXXXXX")
    code=$(curl -sS -o "$RESP_FILE" -w '%{http_code}' --connect-timeout 5 --max-time 10 \
      -X POST -H "@$AUTH_FILE" -H 'Content-Type: application/json' \
      --data-binary "$BODY" "$HEALTHY/v1/items" 2>/dev/null) || code="000"
    case "$code" in
      2??) info "posted test item to $HEALTHY (key setup:$HOST_SHORT:test)" ;;
      401|403) warn "test item refused (HTTP $code): the token isn't valid on $HEALTHY" ;;
      *) warn "test item failed (HTTP $code): $(head -c 300 "$RESP_FILE" 2>/dev/null)" ;;
    esac
    rm -f "$RESP_FILE"
  fi
fi

say ""
say "Done. Next:"
if command -v needs-you >/dev/null 2>&1 || [ -x "$BIN_DIR/needs-you" ]; then
  info "needs-you add --key \"personal:$HOST_SHORT:hello\" --context personal --title \"Hello from $HOST_SHORT\""
  info "needs-you resolve --key \"personal:$HOST_SHORT:hello\""
else
  info "curl: . $ENV_FILE && curl -fsS \"\$NEEDS_YOU_URL/v1/health\""
fi
if [ -n "$ALERTS" ]; then
  info "Claude Code alerts (on for every session here): integrations/claude-code/install-hooks.sh"
else
  info "Claude Code alerts: integrations/claude-code/install-hooks.sh, then re-run this with --alerts"
fi
