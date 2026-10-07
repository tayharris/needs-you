#!/usr/bin/env bash
# Build the release assets for the version in VERSION into an empty directory.
#
#   scripts/build-release.sh OUT_DIR
#
# Writes:
#   NeedsYou-X.Y.Z-macos.zip      the app, ad-hoc signed (mac/scripts/bundle.sh)
#   needs-you-server-X.Y.Z.tar.gz hub, CLI, scripts, deploy, integrations, docs (git archive HEAD)
#   needs-you-cli-X.Y.Z           the sender CLI, one file
#   SHA256SUMS                    of the three above
#   NOTES.md                      release notes: the CHANGELOG section plus install steps
#                                 (not an asset, so not in SHA256SUMS)
#
# The release workflow (.github/workflows/release.yml) runs this on a tag. Locally it
# builds the same thing; it never tags, pushes or publishes.
#
#   NEEDS_YOU_SKIP_APP=1   skip the Mac app (tests, or a machine without Swift)
#   NEEDS_YOU_TAG=vX.Y.Z   fail unless the tag matches VERSION (the workflow sets it)
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
  rm -rf "$build"
fi

git -C "$ROOT" archive --format=tar.gz --prefix="needs-you-$V/" -o "$OUT/needs-you-server-$V.tar.gz" HEAD \
  hub cli scripts deploy integrations docs README.md CHANGELOG.md VERSION LICENSE
cp "$ROOT/cli/needs-you" "$OUT/needs-you-cli-$V"
chmod 755 "$OUT/needs-you-cli-$V"

if command -v sha256sum >/dev/null 2>&1; then sum() { sha256sum "$@"; }; else sum() { shasum -a 256 "$@"; }; fi
(
  cd "$OUT"
  assets=()
  for f in "NeedsYou-$V-macos.zip" "needs-you-server-$V.tar.gz" "needs-you-cli-$V"; do
    [ -f "$f" ] && assets+=("$f")
  done
  sum "${assets[@]}" >SHA256SUMS
)

{
  printf '%s\n\n' "$section" | sed -e '/./,$!d'
  cat <<EOF
## Install

**Mac app.** Download \`NeedsYou-$V-macos.zip\`, unzip it and drag \`NeedsYou.app\` to \`/Applications\`. Its built-in hub needs \`/usr/bin/python3\`, which comes with Apple's Command Line Tools. Without them, Settings says *Python 3 isn't available on this Mac*: run \`xcode-select --install\` in Terminal, wait for it to finish, then quit and reopen the app.

The app is **ad-hoc signed, not notarized**, so macOS blocks the first launch of a downloaded copy:

1. Open \`NeedsYou.app\` once. macOS says it can't verify the developer. Click **Done** (or **Cancel**).
2. **System Settings → Privacy & Security**, scroll to *"NeedsYou" was blocked*, click **Open Anyway**, and confirm. On macOS 14 and earlier, right-click the app → **Open** → **Open** works too.
3. Or, from Terminal: \`xattr -dr com.apple.quarantine /Applications/NeedsYou.app\`.

When the app first listens on your tailnet, the macOS firewall may ask whether \`python3\` (the app's built-in hub) may accept incoming connections. Allow it if servers should reach this Mac. The question can come back after an update, because an ad-hoc signature changes with every build.

Managed Macs: endpoint security (SentinelOne, CrowdStrike, Jamf Protect) may flag an ad-hoc signed app that listens on a port. Ask IT to allow the bundle id \`app.needsyou.mac\`, or build from source (\`mac/scripts/bundle.sh\`).

**Sender machines.** Use an invite link from the app (right-click the pill → **Settings…** → **Invite a machine**). To install only the CLI: download \`needs-you-cli-$V\`, \`chmod +x\` it and put it on your \`PATH\` as \`needs-you\`.

**Server hubs.** Unpack \`needs-you-server-$V.tar.gz\` and follow \`docs/HUB.md\`.

**Check the downloads:** \`shasum -a 256 -c SHA256SUMS\` (macOS) or \`sha256sum -c SHA256SUMS\` (Linux), in the folder you downloaded them to.
EOF
} >"$OUT/NOTES.md"

echo "build-release: needs-you $V in $OUT"
ls -l "$OUT"
