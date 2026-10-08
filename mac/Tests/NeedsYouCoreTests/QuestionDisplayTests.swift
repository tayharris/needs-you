#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// An item's question on a card (QuestionDisplay): headings, the "Asks:" summary for the
/// compact card modes, the arrival preview's lines and height, the body without the hook's
/// copy of the question, and items without a question left as they were.
final class QuestionDisplayTests: XCTestCase {
    static var allTests = [
        ("testHeadings", testHeadings),
        ("testSummary", testSummary),
        ("testLimits", testLimits),
        ("testShowsAllAndExpand", testShowsAllAndExpand),
        ("testPreviewLines", testPreviewLines),
        ("testPreviewHeight", testPreviewHeight),
        ("testBodyLeavesOutTheQuestion", testBodyLeavesOutTheQuestion),
        ("testBodyWithoutQuestionIsUnchanged", testBodyWithoutQuestionIsUnchanged),
        ("testLegacyStepsKeepWorking", testLegacyStepsKeepWorking),
    ]

    private let db = ItemQuestionItem(header: "Database", text: "Which database should we use?",
                                      options: [ItemQuestionOption(label: "Postgres", detail: "Relational, robust"),
                                                ItemQuestionOption(label: "SQLite", detail: "Embedded, simple")])
    private let features = ItemQuestionItem(header: "Features", text: "Which features?",
                                            options: [ItemQuestionOption(label: "Auth", detail: "Login"),
                                                      ItemQuestionOption(label: "Search", detail: "Full text"),
                                                      ItemQuestionOption(label: "Export", detail: "CSV")],
                                            multiSelect: true)

    private func item(_ q: ItemQuestion?, body: String? = nil, steps: [ItemStep] = []) -> Item {
        Item(id: "01Q", key: "k", title: "Claude asks", body: body, steps: steps, question: q,
             createdAt: Date(timeIntervalSince1970: 0))
    }

    func testHeadings() {
        XCTAssertEqual(QuestionDisplay.heading(db, index: 0, count: 1), "Database · choose one")
        XCTAssertEqual(QuestionDisplay.heading(features, index: 1, count: 2), "Features · choose any")
        var bare = db
        bare.header = "  "
        XCTAssertEqual(QuestionDisplay.heading(bare, index: 0, count: 1), "Choose one")
        XCTAssertEqual(QuestionDisplay.heading(bare, index: 1, count: 3), "Question 2 · choose one")
        let free = ItemQuestionItem(header: "Name", text: "What should the file be called?")
        XCTAssertEqual(QuestionDisplay.heading(free, index: 0, count: 1), "Name · answer in the agent")
        XCTAssertEqual(QuestionDisplay.heading(ItemQuestionItem(text: "Why?"), index: 0, count: 1), "Answer in the agent")
    }

    func testSummary() {
        XCTAssertEqual(QuestionDisplay.summary(ItemQuestion(items: [db])),
                       "Asks: Which database should we use? · 2 choices")
        XCTAssertEqual(QuestionDisplay.summary(ItemQuestion(items: [db, features])),
                       "Asks: Which database should we use? and 1 more · 5 choices")
        XCTAssertEqual(QuestionDisplay.summary(ItemQuestion(items: [ItemQuestionItem(text: "Ok?", options: [ItemQuestionOption(label: "Yes")])])),
                       "Asks: Ok? · 1 choice")
        XCTAssertEqual(QuestionDisplay.summary(ItemQuestion(items: [ItemQuestionItem(text: "What should\nthe file be called?")])),
                       "Asks: What should the file be called?")
        let long = String(repeating: "word ", count: 40)
        let s = QuestionDisplay.summary(ItemQuestion(items: [ItemQuestionItem(text: long)]))
        XCTAssertEqual(s.count, "Asks: ".count + QuestionDisplay.summaryLength)
        XCTAssertTrue(s.hasSuffix("…"))
        XCTAssertEqual(QuestionDisplay.summary(ItemQuestion(items: [])), "Asks a question")
    }

    func testLimits() {
        // A newer hub's extra questions and options are left out, and not counted.
        let many = ItemQuestionItem(text: "Pick", options: (1...12).map { ItemQuestionOption(label: "O\($0)") })
        let q = ItemQuestion(items: Array(repeating: many, count: 6))
        XCTAssertEqual(QuestionDisplay.visible(q).count, 4)
        XCTAssertEqual(QuestionDisplay.visible(q).map { $0.options.count }, [8, 8, 8, 8])
        XCTAssertEqual(QuestionDisplay.choiceCount(q), 32)
        XCTAssertEqual(QuestionDisplay.summary(q), "Asks: Pick and 3 more · 32 choices")
    }

    func testShowsAllAndExpand() {
        XCTAssertTrue(QuestionDisplay.showsAll(.full, expanded: false))
        XCTAssertFalse(QuestionDisplay.showsAll(.preview, expanded: false))
        XCTAssertFalse(QuestionDisplay.showsAll(.hidden, expanded: false))
        XCTAssertTrue(QuestionDisplay.showsAll(.hidden, expanded: true))
        let i = item(ItemQuestion(items: [db]))
        XCTAssertFalse(QuestionDisplay.canExpand(i, mode: .full))
        XCTAssertTrue(QuestionDisplay.canExpand(i, mode: .preview))
        XCTAssertTrue(QuestionDisplay.canExpand(i, mode: .hidden))
        XCTAssertFalse(QuestionDisplay.canExpand(item(nil), mode: .hidden))
    }

    func testPreviewLines() {
        let q = ItemQuestion(items: [db, features])
        XCTAssertEqual(QuestionDisplay.previewQuestion(q), "Which database should we use? (+1 more)")
        XCTAssertEqual(QuestionDisplay.previewChoices(q), "Postgres · SQLite")
        let five = ItemQuestionItem(text: "Which region?", options: ["us-east", "us-west", "eu", "ap", "sa"].map { ItemQuestionOption(label: $0) })
        XCTAssertEqual(QuestionDisplay.previewQuestion(ItemQuestion(items: [five])), "Which region?")
        XCTAssertEqual(QuestionDisplay.previewChoices(ItemQuestion(items: [five])), "us-east · us-west · eu · +2 more")
        XCTAssertNil(QuestionDisplay.previewChoices(ItemQuestion(items: [ItemQuestionItem(text: "Why?")])))
        XCTAssertEqual(QuestionDisplay.previewRows(item(q)), 2)
        XCTAssertEqual(QuestionDisplay.previewRows(item(ItemQuestion(items: [ItemQuestionItem(text: "Why?")]))), 1)
        XCTAssertEqual(QuestionDisplay.previewRows(item(nil)), 0)
    }

    func testPreviewHeight() {
        let m = PanelStyle.regular
        let row = PreviewLayout.questionRowGap + PreviewLayout.questionRowHeight(m)
        XCTAssertEqual(PreviewLayout.questionRowHeight(m), 14)   // an 11 pt meta line
        XCTAssertEqual(PreviewLayout.height(m, titleLines: 1, hasLink: false, questionRows: 0), 52)
        XCTAssertEqual(PreviewLayout.height(m, titleLines: 1, hasLink: false, questionRows: 2), 52 + 2 * row)
        XCTAssertEqual(PreviewLayout.height(m, titleLines: 2, hasLink: true, questionRows: 1),
                       PreviewLayout.height(m, titleLines: 2, hasLink: true) + row)
        XCTAssertEqual(PreviewLayout.height(m, titleLines: 1, hasLink: false, questionRows: 9),
                       PreviewLayout.height(m, titleLines: 1, hasLink: false, questionRows: 2))
    }

    func testBodyLeavesOutTheQuestion() {
        // The body the Claude Code hook posts with the question field (tests/test_hook_events.py).
        let body = "**Database** · choose one\nWhich database should we use?\n- Postgres — Relational, robust\n- SQLite — Embedded, simple\n\n"
            + "**Features** · choose any\nWhich features?\n- Auth — Login\n- Search — Full text\n- Export — CSV\n\n"
            + "+3 more questions\n\nAnswer in Claude.\n\n`~/src/my-repo` on devbox"
        XCTAssertEqual(QuestionDisplay.body(item(ItemQuestion(items: [db, features]), body: body)),
                       "Answer in Claude.\n\n`~/src/my-repo` on devbox")
        // Only the questions it has: a paragraph quoting neither stays.
        XCTAssertEqual(QuestionDisplay.body(item(ItemQuestion(items: [features]), body: body)),
                       "**Database** · choose one\nWhich database should we use?\n- Postgres — Relational, robust\n- SQLite — Embedded, simple\n\nAnswer in Claude.\n\n`~/src/my-repo` on devbox")
        // Nothing left: no body.
        XCTAssertNil(QuestionDisplay.body(item(ItemQuestion(items: [db]), body: "Which database should we use?")))
        // A very short question text never matches by accident.
        let tiny = ItemQuestion(items: [ItemQuestionItem(text: "Ok?")])
        XCTAssertEqual(QuestionDisplay.body(item(tiny, body: "Ok? Ready.\n\nHost devbox")), "Ok? Ready.\n\nHost devbox")
    }

    func testBodyWithoutQuestionIsUnchanged() {
        let body = "Line one\n\n\nWhich database should we use?\n\n+2 more questions"
        XCTAssertEqual(QuestionDisplay.body(item(nil, body: body)), body)
        XCTAssertNil(QuestionDisplay.body(item(nil, body: "")))
        XCTAssertNil(QuestionDisplay.body(item(nil)))
    }

    func testLegacyStepsKeepWorking() {
        // Older hooks posted the choices as steps, without a question: the steps checklist
        // rules are unchanged, and nothing here applies.
        let steps = [ItemStep(text: "Database: Postgres — Relational"), ItemStep(text: "Database: SQLite — Embedded")]
        let i = item(nil, body: "Answer in Claude; the choices below are what it offered.", steps: steps)
        XCTAssertEqual(QuestionDisplay.previewRows(i), 0)
        XCTAssertFalse(QuestionDisplay.canExpand(i, mode: .hidden))
        XCTAssertTrue(StepsPolicy.canExpand(i, mode: .hidden))
        XCTAssertEqual(StepsPolicy.visible(i), steps)
        var ticks = StepTicks()
        ticks.toggle(i, 0)
        ticks.toggle(i, 1)
        XCTAssertTrue(ticks.allTicked(i))
    }
}
