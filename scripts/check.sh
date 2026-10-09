#!/usr/bin/env bash
# Run what CI (.github/workflows/ci.yml) runs, on this machine, so "passes here" means
# "passes CI". From the repo root or anywhere in it:
#
#   scripts/check.sh            # everything this OS can run
#   scripts/check.sh --no-mac   # skip the Mac app tests and build (macOS only; they're slow)
#
# Python suite on /usr/bin/python3 (3.9 on macOS, as CI checks), plus on $NEEDS_YOU_PYTHON39
# when set (a 3.9 on Linux: CI's macOS job runs 3.9, your Linux python3 is newer). shellcheck
# with CI's exact command. scripts/lint_repo.py (hard rule 5, commit attribution), against
# origin/main unless NEEDS_YOU_LINT_BASE says otherwise. On macOS with swift: the NeedsYouCore
# tests and the app bundle. tests/test_check_script.py keeps these commands identical to
# ci.yml's. Exits non-zero if any step fails; runs every step either way.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

mac=1
for arg in "$@"; do
  case "$arg" in
    --no-mac) mac=0 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

failed=()
step() {
  local name=$1
  shift
  printf '\n==> %s\n' "$name"
  if "$@"; then
    printf -- '--> %s: ok\n' "$name"
  else
    printf -- '--> %s: FAILED\n' "$name"
    failed+=("$name")
  fi
}

python_suite() {
  /usr/bin/python3 --version
  /usr/bin/python3 -m unittest discover -s tests
}

python39_suite() {
  "$NEEDS_YOU_PYTHON39" -c 'import sys; print(sys.version); assert sys.version_info[:2] == (3, 9), sys.version' &&
    "$NEEDS_YOU_PYTHON39" -m unittest discover -s tests
}

macos_python39() {
  /usr/bin/python3 -c 'import sys; print(sys.version); assert sys.version_info[:2] == (3, 9), sys.version'
}

shellcheck_all() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck isn't installed: apt install shellcheck, or brew install shellcheck" >&2
    return 1
  fi
  shellcheck --version | sed -n 2p
  # shellcheck disable=SC2046 # word splitting is the point, as in ci.yml
  shellcheck -S warning -f gcc $(git ls-files '*.sh')
}

lint() {
  /usr/bin/python3 scripts/lint_repo.py
}

mac_tests() { mac/scripts/test.sh; }
mac_bundle() { mac/scripts/bundle.sh; }

if [ "$(uname)" = Darwin ]; then
  step "Python is 3.9 (macOS)" macos_python39
fi
step "Python suite (/usr/bin/python3)" python_suite
if [ -n "${NEEDS_YOU_PYTHON39:-}" ]; then
  step "Python suite ($NEEDS_YOU_PYTHON39)" python39_suite
fi
step "shellcheck" shellcheck_all
step "lint (hostnames, commit messages)" lint
if [ "$(uname)" = Darwin ] && [ "$mac" = 1 ]; then
  if command -v swift >/dev/null 2>&1; then
    step "Mac tests" mac_tests
    step "Mac bundle" mac_bundle
  else
    echo "swift isn't installed: skipping the Mac tests and bundle (xcode-select --install)" >&2
  fi
fi

echo
if [ ${#failed[@]} -gt 0 ]; then
  printf 'check.sh: FAILED: %s\n' "${failed[*]}"
  exit 1
fi
echo "check.sh: all passed"
