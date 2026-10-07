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
    + testEntries(FailoverFeedTests.self, FailoverFeedTests.allTests, async: FailoverFeedTests.asyncTests)
    + testEntries(ConnectLinkTests.self, ConnectLinkTests.allTests)
    + testEntries(HubListMergeTests.self, HubListMergeTests.allTests)
    + testEntries(InviteClientTests.self, InviteClientTests.allTests, async: InviteClientTests.asyncTests)
    + testEntries(LocalHubTests.self, LocalHubTests.allTests)
    + testEntries(PruningTests.self, PruningTests.allTests)
    + testEntries(TokenStoreTests.self, TokenStoreTests.allTests)
    + testEntries(MenuBarTests.self, MenuBarTests.allTests)
    + testEntries(PanelPositionTests.self, PanelPositionTests.allTests)
    + testEntries(PrefsMigrationTests.self, PrefsMigrationTests.allTests)
    + testEntries(OrcaJumpTests.self, OrcaJumpTests.allTests)
    + testEntries(PanelStyleTests.self, PanelStyleTests.allTests)
    + testEntries(UIPrefsTests.self, UIPrefsTests.allTests)
    + testEntries(AlertStyleTests.self, AlertStyleTests.allTests)
    + testEntries(CardLayoutTests.self, CardLayoutTests.allTests)
    + testEntries(HotKeyComboTests.self, HotKeyComboTests.allTests)

let code = await runTests(entries)
exit(code)
