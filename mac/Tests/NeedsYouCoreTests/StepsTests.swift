#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Item steps: decoding (with, without, unknown and malformed fields), the local tick
/// state, the card's summary/list rules and the step links' scheme policy.
final class StepsTests: XCTestCase {
    static var allTests = [
        ("testDecodeWithoutSteps", testDecodeWithoutSteps),
        ("testDecodeWithStepsAndUnknownFields", testDecodeWithStepsAndUnknownFields),
        ("testMalformedStepsNeverCostTheItem", testMalformedStepsNeverCostTheItem),
        ("testStepsAreAVisibleChange", testStepsAreAVisibleChange),
        ("testTicks", testTicks),
        ("testTicksFollowTheStepText", testTicksFollowTheStepText),
        ("testTicksArePruned", testTicksArePruned),
        ("testLayoutModes", testLayoutModes),
        ("testSummaryAndLabels", testSummaryAndLabels),
        ("testStepLinkPolicy", testStepLinkPolicy),
    ]

    private func decode(_ json: String) throws -> Item {
        try HubJSON.makeDecoder().decode(Item.self, from: Data(json.utf8))
    }

    private let head = #""id": "01A", "key": "k", "title": "Ship it", "status": "open", "created_at": "2026-10-06T17:04:05.123Z""#

    private func item(_ steps: [ItemStep], id: String = "01A", body: String? = nil) -> Item {
        Item(id: id, key: "k", title: "t", body: body, steps: steps, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testDecodeWithoutSteps() throws {
        let i = try decode("{\(head)}")
        XCTAssertEqual(i.steps, [])
        XCTAssertEqual(try decode("{\(head), \"steps\": null}").steps, [])
        XCTAssertEqual(try decode("{\(head), \"steps\": []}").steps, [])
    }

    func testDecodeWithStepsAndUnknownFields() throws {
        let i = try decode("""
        {\(head), "future_field": {"x": 1}, "steps": [
          {"text": "Approve **prod**", "link": {"label": "CI", "url": "https://ci/9", "icon": "rocket"}, "done": false, "owner": "x"},
          {"text": "Tell the team", "done": true},
          {"text": "No done field"}
        ]}
        """)
        XCTAssertEqual(i.steps, [
            ItemStep(text: "Approve **prod**", link: ItemLink(label: "CI", url: "https://ci/9")),
            ItemStep(text: "Tell the team", done: true),
            ItemStep(text: "No done field"),
        ])
        // and it round-trips through the app's own encoder (the cache)
        let again = try HubJSON.makeDecoder().decode(Item.self, from: try HubJSON.makeEncoder().encode(i))
        XCTAssertEqual(again.steps, i.steps)
    }

    func testMalformedStepsNeverCostTheItem() throws {
        XCTAssertEqual(try decode("{\(head), \"steps\": \"do it\"}").steps, [])
        XCTAssertEqual(try decode("{\(head), \"steps\": [\"do it\"]}").steps, [])
        let i = try decode("""
        {\(head), "steps": [{"text": "ok", "link": "https://not-an-object", "done": "yes"}, {"text": "  "}, {"done": true}]}
        """)
        XCTAssertEqual(i.title, "Ship it")
        XCTAssertEqual(i.steps, [ItemStep(text: "ok")])  // bad link and done dropped; blank steps skipped
    }

    func testStepsAreAVisibleChange() {
        let a = item([ItemStep(text: "one")])
        var b = a
        XCTAssertFalse(b.hasVisibleChange(from: a))
        b.steps[0].done = true
        XCTAssertTrue(b.hasVisibleChange(from: a))
        b.steps = []
        XCTAssertTrue(b.hasVisibleChange(from: a))
    }

    func testTicks() {
        let i = item([ItemStep(text: "a"), ItemStep(text: "b", done: true), ItemStep(text: "c")])
        var t = StepTicks()
        XCTAssertTrue(t.isEmpty)
        XCTAssertFalse(t.isTicked(i, 0))
        XCTAssertTrue(t.isTicked(i, 1))            // the sender's done shows ticked
        XCTAssertFalse(t.canToggle(i, 1))          // and can't be unticked here
        XCTAssertEqual(t.tickedCount(i), 1)
        t.toggle(i, 1)
        XCTAssertTrue(t.isTicked(i, 1))
        t.toggle(i, 0)
        XCTAssertTrue(t.isTicked(i, 0))
        XCTAssertFalse(t.allTicked(i))
        t.toggle(i, 2)
        XCTAssertTrue(t.allTicked(i))              // the card offers Done
        t.toggle(i, 2)
        XCTAssertFalse(t.allTicked(i))
        XCTAssertFalse(t.isTicked(i, 2))
        // out of range is harmless
        t.toggle(i, 9)
        XCTAssertFalse(t.isTicked(i, 9))
        XCTAssertFalse(t.canToggle(i, -1))
        // no steps: never "all ticked"
        XCTAssertFalse(StepTicks().allTicked(item([])))
        // per item
        XCTAssertFalse(t.isTicked(item(i.steps, id: "01B"), 0))
    }

    func testTicksFollowTheStepText() {
        var t = StepTicks()
        let before = item([ItemStep(text: "a"), ItemStep(text: "b")])
        t.toggle(before, 0)
        // the sender re-posts with a step inserted first: the tick doesn't move to it
        let after = item([ItemStep(text: "new first"), ItemStep(text: "a"), ItemStep(text: "b")])
        XCTAssertFalse(t.isTicked(after, 0))
        // the same list again keeps it
        XCTAssertTrue(t.isTicked(before, 0))
    }

    func testTicksArePruned() {
        var t = StepTicks()
        let a = item([ItemStep(text: "x")], id: "01A")
        let b = item([ItemStep(text: "x")], id: "01B")
        t.toggle(a, 0)
        t.toggle(b, 0)
        t.retain(itemIDs: ["01B"])
        XCTAssertFalse(t.isTicked(a, 0))
        XCTAssertTrue(t.isTicked(b, 0))
        t.retain(itemIDs: [])
        XCTAssertTrue(t.isEmpty)
    }

    func testLayoutModes() {
        XCTAssertTrue(StepsPolicy.showsList(.full, expanded: false))
        XCTAssertFalse(StepsPolicy.showsList(.preview, expanded: false))
        XCTAssertFalse(StepsPolicy.showsList(.hidden, expanded: false))
        XCTAssertTrue(StepsPolicy.showsList(.preview, expanded: true))
        XCTAssertTrue(StepsPolicy.showsList(.hidden, expanded: true))

        let steps = item([ItemStep(text: "a")])
        XCTAssertFalse(StepsPolicy.canExpand(steps, mode: .full))
        XCTAssertTrue(StepsPolicy.canExpand(steps, mode: .preview))   // summarised: expandable
        XCTAssertTrue(StepsPolicy.canExpand(steps, mode: .hidden))
        // without steps it's the body's rule, unchanged
        XCTAssertFalse(StepsPolicy.canExpand(item([], body: "short"), mode: .preview))
        XCTAssertTrue(StepsPolicy.canExpand(item([], body: "short"), mode: .hidden))
        XCTAssertFalse(StepsPolicy.canExpand(item([]), mode: .hidden))

        let many = item((0..<14).map { ItemStep(text: "s\($0)") })
        XCTAssertEqual(StepsPolicy.visible(many).count, StepsPolicy.maxSteps)
    }

    func testSummaryAndLabels() {
        XCTAssertEqual(StepsPolicy.summary(total: 1, ticked: 0), "1 step")
        XCTAssertEqual(StepsPolicy.summary(total: 3, ticked: 0), "3 steps")
        XCTAssertEqual(StepsPolicy.summary(total: 3, ticked: 2), "2 of 3 done")
        XCTAssertEqual(StepsPolicy.number(0), "1.")
        XCTAssertEqual(StepsPolicy.number(9), "10.")
        XCTAssertEqual(StepsPolicy.linkTitle(ItemLink(label: "  ", url: "https://x")), "Open")
        XCTAssertEqual(StepsPolicy.linkTitle(ItemLink(label: "CI", url: "https://x")), "CI")
        let long = StepsPolicy.linkTitle(ItemLink(label: "A very long label for one step", url: "https://x"))
        XCTAssertEqual(long.count, LinkRowPolicy.compactLabelLength)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testStepLinkPolicy() throws {
        // step links get exactly the item links' allow-list
        let i = try decode("""
        {\(head), "steps": [
          {"text": "a", "link": {"label": "ok", "url": "https://ci/9"}},
          {"text": "b", "link": {"label": "no", "url": "http://ci/9"}},
          {"text": "c", "link": {"label": "no", "url": "javascript:alert(1)"}},
          {"text": "d", "link": {"label": "term", "url": "needsyou://orca/terminal?handle=term_ab12cd34"}},
          {"text": "e", "link": {"label": "no", "url": "needsyou://connect?hub=x&code=y"}},
          {"text": "f", "link": {"label": "ok", "url": "slack://channel?team=T&id=C"}}
        ]}
        """)
        let allowed = i.steps.map { LinkPolicy.isAllowed($0.link?.url ?? "") }
        XCTAssertEqual(allowed, [true, false, false, true, false, true])
        // markdown links inside step text are filtered like bodies
        let rendered = LimitedMarkdown.render("see [bad](http://x) and [good](https://y)")
        let links = rendered.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://y"])
    }
}
