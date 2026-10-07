#!/usr/bin/env bash
# Make a local update feed to test the in-app updater without a real release.
#
#   mac/scripts/make-test-feed.sh --version 0.1.2 [--out DIR]   build the app as 0.1.2
#   mac/scripts/make-test-feed.sh --app PATH/NeedsYou.app [--out DIR]
#
# Writes DIR (default /tmp/needsyou-feed) with what a release carries for the updater:
#   NeedsYou-X.Y.Z-macos.zip, release-manifest.json (tests "success", built now) and
#   SHA256SUMS. Then point the app at it and check:
#
#   defaults write app.needsyou.mac updateFeedURL "file://DIR/"
#   (quit and reopen the app) → Settings → Updates shows "Test update source" → Check now
#
# A test feed never installs automatically; use Download and install now / Restart to
# update. Remove the override afterwards: defaults delete app.needsyou.mac updateFeedURL
# The manifest isn't signed and says tests passed: it's for this Mac only, never a release.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=""
VERSION=""
OUT=/tmp/needsyou-feed
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$APP" ]]; then
  [[ -n "$VERSION" ]] || { echo "give --version X.Y.Z or --app PATH" >&2; exit 2; }
  BUILD="$(mktemp -d)"
  NEEDS_YOU_VERSION="$VERSION" NEEDS_YOU_DIST="$BUILD" scripts/bundle.sh
  APP="$BUILD/NeedsYou.app"
fi
[[ -d "$APP" ]] || { echo "no app at $APP" >&2; exit 1; }
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

rm -rf "$OUT"
mkdir -p "$OUT"
chmod 700 "$OUT"
ZIP="NeedsYou-$V-macos.zip"
ditto -c -k --keepParent "$APP" "$OUT/$ZIP"
(
  cd "$OUT"
  /usr/bin/python3 - "$V" "$ZIP" >release-manifest.json <<'PY'
import hashlib, json, os, sys, time
v, z = sys.argv[1:3]
digest = hashlib.sha256(open(z, "rb").read()).hexdigest()
json.dump({"schema": 1, "version": v, "tag": "v" + v, "commit": "", "run_id": None, "tests": "success",
           "min_macos": "14.0", "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "assets": [{"name": z, "sha256": digest, "size": os.path.getsize(z)}], "test_feed": True},
          sys.stdout, indent=1, sort_keys=True)
PY
  shasum -a 256 "$ZIP" release-manifest.json >SHA256SUMS
)
echo "==> test feed for $V in $OUT"
echo "    defaults write app.needsyou.mac updateFeedURL \"file://$OUT/\""
