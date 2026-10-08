#!/usr/bin/env bash
# Build the release assets for the version in VERSION into an empty directory.
#
#   scripts/build-release.sh OUT_DIR
#
# Writes:
#   NeedsYou-X.Y.Z-macos.zip      the app, ad-hoc signed (mac/scripts/bundle.sh)
#   NeedsYou-X.Y.Z.dmg            the same app in a disk image with an Applications link
#                                 (needs hdiutil, so macOS only; skipped with a message elsewhere)
#   needs-you-server-X.Y.Z.tar.gz hub, CLI, scripts, deploy, integrations, docs (git archive HEAD)
#   needs-you-cli-X.Y.Z           the sender CLI, one file
#   release-manifest.json         version, commit, workflow run, test result, min macOS,
#                                 and each asset above with its sha256 and size. The Mac
#                                 app's updater installs only releases that carry it
#                                 (docs/roadmap/rollout-updates.md)
#   SHA256SUMS                    of the assets above and the manifest
#   NOTES.md                      release notes: the CHANGELOG section plus install steps
#                                 (not an asset, so not in SHA256SUMS)
#
# The release workflow (.github/workflows/release.yml) runs this on a tag. Locally it
# builds the same thing; it never tags, pushes or publishes.
#
#   NEEDS_YOU_SKIP_APP=1   skip the Mac app (tests, or a machine without Swift)
#   NEEDS_YOU_TAG=vX.Y.Z   fail unless the tag matches VERSION (the workflow sets it)
#   NEEDS_YOU_TESTS_RESULT the test job's result, recorded in the manifest (the workflow
#                          passes needs.test.result; "local" when unset)
#   GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_REPOSITORY, GITHUB_SHA: recorded when set
set -euo pipefail

die() { echo "build-release: $*" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-}
[ -n "$OUT" ] || die "usage: scripts/build-release.sh OUT_DIR"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
[ -z "$(ls -A "$OUT")" ] || die "$OUT is not empty"

V=$(tr -d '[:space:]' <"$ROOT/VERSION")
printf '%s' "$V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "VERSION is not X.Y.Z: $V"

# One version everywhere: the hub and CLI must work as single files outside the repo,
# so they carry their own copy, checked here (and by tests/test_release.py).
for f in hub/needs_you_hub.py cli/needs-you; do
  got=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$ROOT/$f")
  [ "$got" = "$V" ] || die "$f has VERSION $got, VERSION file has $V"
done
# The sender files the hub serves carry a version stamp too (needs-you update reports it).
for f in integrations/claude-code/needs-you-hook.sh integrations/claude-code/skill/needs-you/SKILL.md \
         integrations/orca/snippet.md integrations/claude-code/hooks.json \
         integrations/codex/codex-hooks.json integrations/codex/install-codex-hooks.sh \
         integrations/gemini/gemini-hooks.json integrations/gemini/install-gemini-hooks.sh \
         integrations/opencode/needs-you.js integrations/opencode/install-opencode-plugin.sh \
         integrations/copilot/copilot-hooks.json integrations/copilot/install-copilot-hooks.sh \
         integrations/kimi/kimi-hooks.toml integrations/kimi/install-kimi-hooks.sh \
         integrations/grok/grok-hooks.json integrations/grok/install-grok-hooks.sh \
         integrations/agent-instructions/needs-you.md; do
  got=$(sed -n 's/.*needs[-_]you[-_]version"\{0,1\}: *"\{0,1\}\([0-9][0-9.]*\).*/\1/p' "$ROOT/$f" | head -n 1)
  [ "$got" = "$V" ] || die "$f has version stamp ${got:-none}, VERSION file has $V"
done
if [ -n "${NEEDS_YOU_TAG:-}" ] && [ "$NEEDS_YOU_TAG" != "v$V" ]; then
  die "tag $NEEDS_YOU_TAG does not match VERSION $V"
fi

# Release notes come from CHANGELOG.md's "## [X.Y.Z]" section.
section=$(awk -v v="$V" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^## \[/ { exit }
  on { print }' "$ROOT/CHANGELOG.md")
[ -n "$(printf '%s' "$section" | tr -d '[:space:]')" ] ||
  die "CHANGELOG.md has no \"## [$V]\" section (rename [Unreleased] when you cut the release)"

if [ "${NEEDS_YOU_SKIP_APP:-}" != 1 ]; then
  build="$OUT/.app-build"
  NEEDS_YOU_VERSION="$V" NEEDS_YOU_DIST="$build" "$ROOT/mac/scripts/bundle.sh"
  ditto -c -k --keepParent "$build/NeedsYou.app" "$OUT/NeedsYou-$V-macos.zip"
  if command -v hdiutil >/dev/null 2>&1; then
    # The drag-to-install layout: the app next to a link to /Applications.
    stage="$OUT/.dmg-stage"
    mkdir -p "$stage"
    ditto "$build/NeedsYou.app" "$stage/NeedsYou.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname NeedsYou -srcfolder "$stage" -format UDZO -ov "$OUT/NeedsYou-$V.dmg"
    rm -rf "$stage"
  else
    echo "build-release: hdiutil not found (it ships with macOS), skipping NeedsYou-$V.dmg" >&2
  fi
  rm -rf "$build"
fi

git -C "$ROOT" archive --format=tar.gz --prefix="needs-you-$V/" -o "$OUT/needs-you-server-$V.tar.gz" HEAD \
  hub cli scripts deploy integrations docs README.md CHANGELOG.md VERSION LICENSE
cp "$ROOT/cli/needs-you" "$OUT/needs-you-cli-$V"
chmod 755 "$OUT/needs-you-cli-$V"

if command -v sha256sum >/dev/null 2>&1; then sum() { sha256sum "$@"; }; else sum() { shasum -a 256 "$@"; }; fi
min_macos=$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1/p' "$ROOT/mac/Package.swift" | head -n 1)
[ -n "$min_macos" ] || die "can't read the minimum macOS from mac/Package.swift"
commit=${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}
(
  cd "$OUT"
  assets=()
  for f in "NeedsYou-$V-macos.zip" "NeedsYou-$V.dmg" "needs-you-server-$V.tar.gz" "needs-you-cli-$V"; do
    [ -f "$f" ] && assets+=("$f")
  done
  # Written only here, after the release job's `needs: test`, and listing every asset, so
  # the updater checks a download against both this manifest and SHA256SUMS.
  python3 - "$V" "$commit" "$min_macos.0" "${NEEDS_YOU_TESTS_RESULT:-local}" "${assets[@]}" \
    >release-manifest.json <<'PY'
import hashlib, json, os, sys, time
version, commit, min_macos, tests = sys.argv[1:5]
assets = []
for name in sys.argv[5:]:
    h = hashlib.sha256()
    with open(name, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    assets.append({"name": name, "sha256": h.hexdigest(), "size": os.path.getsize(name)})
run_id = os.environ.get("GITHUB_RUN_ID") or ""
attempt = os.environ.get("GITHUB_RUN_ATTEMPT") or ""
json.dump({
    "schema": 1,
    "version": version,
    "tag": "v" + version,
    "commit": commit,
    "repository": os.environ.get("GITHUB_REPOSITORY") or "",
    "run_id": int(run_id) if run_id.isdigit() else None,
    "run_attempt": int(attempt) if attempt.isdigit() else None,
    "tests": tests,
    "min_macos": min_macos,
    "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "assets": assets,
}, sys.stdout, indent=1, sort_keys=True)
sys.stdout.write("\n")
PY
  sum "${assets[@]}" release-manifest.json >SHA256SUMS
)

{
  printf '%s\n\n' "$section" | sed -e '/./,$!d'
  cat <<EOF
## Install

**Mac app.** Download \`NeedsYou-$V.dmg\`, open it and drag \`NeedsYou.app\` onto the \`Applications\` link. Or download \`NeedsYou-$V-macos.zip\`, unzip it and drag \`NeedsYou.app\` to \`/Applications\`. Its built-in hub needs \`/usr/bin/python3\`, which comes with Apple's Command Line Tools. Without them, Settings says *Python 3 isn't available on this Mac*: run \`xcode-select --install\` in Terminal, wait for it to finish, then quit and reopen the app.

The app is **ad-hoc signed, not notarized**, so macOS blocks the first launch of a downloaded copy:

1. Open \`NeedsYou.app\` once. macOS says it can't verify the developer. Click **Done** (or **Cancel**).
2. **System Settings → Privacy & Security**, scroll to *"NeedsYou" was blocked*, click **Open Anyway**, and confirm. On macOS 14 and earlier, right-click the app → **Open** → **Open** works too.
3. Or, from Terminal: \`xattr -dr com.apple.quarantine /Applications/NeedsYou.app\`.

When the app first listens on your tailnet, the macOS firewall may ask whether \`python3\` (the app's built-in hub) may accept incoming connections. Allow it if servers should reach this Mac. The question can come back after an update, because an ad-hoc signature changes with every build.

Managed Macs: endpoint security (SentinelOne, CrowdStrike, Jamf Protect) may flag an ad-hoc signed app that listens on a port. Ask IT to allow the bundle id \`app.needsyou.mac\`, or build from source (\`mac/scripts/bundle.sh\`).

**Sender machines.** Use an invite link from the app (right-click the pill → **Settings…** → **Connect a machine**). To install only the CLI: download \`needs-you-cli-$V\`, \`chmod +x\` it and put it on your \`PATH\` as \`needs-you\`.

**Server hubs.** Unpack \`needs-you-server-$V.tar.gz\` and follow \`docs/HUB.md\`.

**Check the downloads:** \`shasum -a 256 -c SHA256SUMS\` (macOS) or \`sha256sum -c SHA256SUMS\` (Linux), in the folder you downloaded them to.
EOF
} >"$OUT/NOTES.md"

echo "build-release: needs-you $V in $OUT"
ls -l "$OUT"
