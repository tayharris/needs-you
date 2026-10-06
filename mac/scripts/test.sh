#!/usr/bin/env bash
# Run the NeedsYouCore unit tests.
#
# `swift test` needs XCTest, which ships with Xcode but not with the Command Line Tools.
# Without it, the same test files run through `needsyou-selftest` (MiniXCTest).
# Force one path with NEEDS_YOU_TEST_RUNNER=xctest|selftest.
set -euo pipefail
cd "$(dirname "$0")/.."

runner="${NEEDS_YOU_TEST_RUNNER:-auto}"
if [[ "$runner" == auto ]]; then
  if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
    runner=xctest
  else
    runner=selftest
  fi
fi

if [[ "$runner" == xctest ]]; then
  echo "==> swift test (XCTest)"
  swift test
else
  echo "==> XCTest not available (Command Line Tools only); running the same tests via needsyou-selftest"
  swift run needsyou-selftest
fi
