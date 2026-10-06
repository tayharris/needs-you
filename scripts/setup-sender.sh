#!/usr/bin/env bash
# setup-sender.sh: make this machine a needs-you sender.
#
# What it does (each step is safe to re-run):
#   1. Optionally installs the `needs-you` CLI (a single Python 3 file) into
#      ~/.local/bin, copied from this repo checkout or downloaded from a URL.
#   2. Asks for the hub URL(s) (comma-separated failover list) and this
#      machine's token (hidden input), and writes ~/.config/needs-you/env
#      with mode 600.
#   3. Checks GET /v1/health on every hub.
#   4. Offers to post a test `info` item.
#
# Hard requirements: bash (3.2+ is fine), curl, python3 (3.9+). No package
# installs, no jq, and it never edits your shell dotfiles.
#
# Run with --help for flags. See docs/guides/add-a-sender.md.

set -euo pipefail
set -f  # no globbing: URL lists are split on commas, never expanded

PROG=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

CONFIG_DIR="$HOME/.config/needs-you"
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
    --non-interactive|--yes|-y) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
done

case "$TEST_CONTEXT" in work|personal) ;; *) die "--test-context must be work or personal" 2 ;; esac

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
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH. Add this to your shell profile:"
       printf '    export PATH="%s:$PATH"\n' "$BIN_DIR" >&2 ;;
  esac
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
    grep -v -E '^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_(URLS|URL|TOKEN)=' "$ENV_FILE" |
      grep -v -E '^# (needs-you sender config|NEEDS_YOU_URLS:|NEEDS_YOU_URL: )' || true
  fi
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

# ---------------------------------------------------------------- 4. test item
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
  info "Add 'needs-you flush' to cron if this machine runs jobs while hubs may be down."
else
  info "curl: . $ENV_FILE && curl -fsS \"\$NEEDS_YOU_URL/v1/health\""
fi
info "Claude Code alerts: integrations/claude-code/install-hooks.sh"
