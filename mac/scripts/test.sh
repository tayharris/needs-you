#!/usr/bin/env bash
# Run the NeedsTayCore unit tests.
#
# `swift test` needs XCTest, which ships with Xcode but not with the Command Line Tools.
# Without it, the same test files run through `needstay-selftest` (MiniXCTest).
# Force one path with NEEDS_TAY_TEST_RUNNER=xctest|selftest.
set -euo pipefail
cd "$(dirname "$0")/.."

runner="${NEEDS_TAY_TEST_RUNNER:-auto}"
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
  echo "==> XCTest not available (Command Line Tools only); running the same tests via needstay-selftest"
  swift run needstay-selftest
fi
