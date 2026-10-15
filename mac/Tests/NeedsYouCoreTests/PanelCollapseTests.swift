#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// While the panel shows the notes only the person closes it, and it reopens on them.
final class PanelCollapseTests: XCTestCase {
    static var allTests = [
        ("testExplicitAlwaysCollapses", testExplicitAlwaysCollapses),
        ("testNotesStayOpenOnClickElsewhere", testNotesStayOpenOnClickElsewhere),
        ("testNotesStayOpenAfterOpeningALink", testNotesStayOpenAfterOpeningALink),
        ("testNotesStayOpenWhenTheLaunchTimerRunsOut", testNotesStayOpenWhenTheLaunchTimerRunsOut),
        ("testCardsKeepTheirCollapseRules", testCardsKeepTheirCollapseRules),
        ("testReopenRemembersNotes", testReopenRemembersNotes),
        ("testOpeningAtACardShowsTheCards", testOpeningAtACardShowsTheCards),
        ("testAutomaticOpenShowsTheCards", testAutomaticOpenShowsTheCards),
        ("testAutomaticExpandNeverLeavesOpenNotes", testAutomaticExpandNeverLeavesOpenNotes),
        ("testEscapeElsewhereLeavesNotesOpen", testEscapeElsewhereLeavesNotesOpen),
        ("testEscapeHotkeyOnlyOverTheNotes", testEscapeHotkeyOnlyOverTheNotes),
        ("testEscapeWithTheCardsIsUnchanged", testEscapeWithTheCardsIsUnchanged),
    ]

    private func collapses(_ t: CollapseTrigger, notes: Bool, setting: Bool = true, launch: Bool = false) -> Bool {
        PanelCollapse.collapses(t, notesMode: notes, collapseOnClickOutside: setting, openedAtLaunch: launch)
    }

    func testExplicitAlwaysCollapses() {
        for notes in [true, false] {
            for setting in [true, false] {
                for launch in [true, false] {
                    XCTAssertTrue(collapses(.explicit, notes: notes, setting: setting, launch: launch))
                }
            }
        }
    }

    func testNotesStayOpenOnClickElsewhere() {
        XCTAssertFalse(collapses(.clickElsewhere, notes: true, setting: true))
        XCTAssertFalse(collapses(.clickElsewhere, notes: true, setting: true, launch: true))
        XCTAssertFalse(collapses(.clickElsewhere, notes: true, setting: false))
    }

    func testNotesStayOpenAfterOpeningALink() {
        XCTAssertFalse(collapses(.openedLink, notes: true, setting: true))
    }

    func testNotesStayOpenWhenTheLaunchTimerRunsOut() {
        XCTAssertFalse(collapses(.launchTimer, notes: true, launch: true))
    }

    func testCardsKeepTheirCollapseRules() {
        XCTAssertTrue(collapses(.clickElsewhere, notes: false, setting: true))
        XCTAssertFalse(collapses(.clickElsewhere, notes: false, setting: false))
        XCTAssertTrue(collapses(.clickElsewhere, notes: false, setting: false, launch: true))
        XCTAssertTrue(collapses(.openedLink, notes: false, setting: true))
        XCTAssertFalse(collapses(.openedLink, notes: false, setting: false))
        XCTAssertTrue(collapses(.launchTimer, notes: false, launch: true))
    }

    func testReopenRemembersNotes() {
        // The pill, the shortcut or the menu's Open Panel: the view the person last chose.
        XCTAssertTrue(PanelCollapse.showsNotes(current: false, remembered: true, alreadyExpanded: false,
                                               byUser: true, focusingCard: false))
        XCTAssertFalse(PanelCollapse.showsNotes(current: true, remembered: false, alreadyExpanded: false,
                                                byUser: true, focusingCard: false))
    }

    func testOpeningAtACardShowsTheCards() {
        XCTAssertFalse(PanelCollapse.showsNotes(current: true, remembered: true, alreadyExpanded: false,
                                                byUser: true, focusingCard: true))
        XCTAssertFalse(PanelCollapse.showsNotes(current: true, remembered: true, alreadyExpanded: true,
                                                byUser: true, focusingCard: true))
    }

    func testAutomaticOpenShowsTheCards() {
        // The launch open and the morning summary are there to show the items.
        XCTAssertFalse(PanelCollapse.showsNotes(current: true, remembered: true, alreadyExpanded: false,
                                                byUser: false, focusingCard: false))
    }

    func testAutomaticExpandNeverLeavesOpenNotes() {
        // The morning summary while the notes are open, or the menu's "more…".
        XCTAssertTrue(PanelCollapse.showsNotes(current: true, remembered: true, alreadyExpanded: true,
                                               byUser: false, focusingCard: false))
        XCTAssertTrue(PanelCollapse.showsNotes(current: true, remembered: false, alreadyExpanded: true,
                                               byUser: true, focusingCard: false))
        XCTAssertFalse(PanelCollapse.showsNotes(current: false, remembered: true, alreadyExpanded: true,
                                                byUser: false, focusingCard: false))
    }

    func testEscapeElsewhereLeavesNotesOpen() {
        // Typing in Claude Code (pointer away from the panel): Escape is Claude's.
        XCTAssertFalse(PanelCollapse.escapeCollapses(notesMode: true, hovering: false))
        XCTAssertTrue(PanelCollapse.escapeCollapses(notesMode: true, hovering: true))
    }

    func testEscapeHotkeyOnlyOverTheNotes() {
        for released in [true, false] {
            XCTAssertFalse(PanelCollapse.swallowsEscape(expandedByUser: true, notesMode: true,
                                                        hovering: false, released: released))
            XCTAssertTrue(PanelCollapse.swallowsEscape(expandedByUser: true, notesMode: true,
                                                       hovering: true, released: released))
            XCTAssertFalse(PanelCollapse.swallowsEscape(expandedByUser: false, notesMode: true,
                                                        hovering: true, released: released))
        }
    }

    func testEscapeWithTheCardsIsUnchanged() {
        XCTAssertTrue(PanelCollapse.escapeCollapses(notesMode: false, hovering: false))
        XCTAssertTrue(PanelCollapse.swallowsEscape(expandedByUser: true, notesMode: false,
                                                   hovering: false, released: false))
        XCTAssertFalse(PanelCollapse.swallowsEscape(expandedByUser: true, notesMode: false,
                                                    hovering: false, released: true))
        XCTAssertFalse(PanelCollapse.swallowsEscape(expandedByUser: false, notesMode: false,
                                                    hovering: true, released: false))
    }
}
