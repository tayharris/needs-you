import Foundation
import MiniXCTest

// Runs Tests/NeedsYouCoreTests (symlinked into this target) without XCTest.
// `swift run needsyou-selftest`, or `scripts/test.sh` which picks XCTest when available.
// Add new test classes here as well as to the XCTest target.

let entries =
    testEntries(ItemStoreMergeTests.self, ItemStoreMergeTests.allTests)
    + testEntries(ItemStoreCountTests.self, ItemStoreCountTests.allTests)
    + testEntries(LinkPolicyTests.self, LinkPolicyTests.allTests)
    + testEntries(HubClientTests.self, HubClientTests.allTests)
    + testEntries(SupportTests.self, SupportTests.allTests)
    + testEntries(DemoFeedTests.self, DemoFeedTests.allTests, async: DemoFeedTests.asyncTests)
    + testEntries(ScheduleTests.self, ScheduleTests.allTests)
    + testEntries(FloatingPanelTests.self, FloatingPanelTests.allTests)

let code = await runTests(entries)
exit(code)
