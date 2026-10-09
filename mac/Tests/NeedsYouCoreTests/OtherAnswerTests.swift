#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Typed answers ("Other…", ADR 0009 amendment 2026-10-09): decoding `allow_other` and an
/// answer's `text`, the request body, the selection with words in it, what the answer window
/// accepts, the card's texts, and the demo feed playing the hub's rules.
final class OtherAnswerTests: XCTestCase {
    static var allTests = [
        ("testDecode", testDecode),
        ("testRequestBodyCarriesTextOnlyWhenTyped", testRequestBodyCarriesTextOnlyWhenTyped),
        ("testSelectionWithWords", testSelectionWithWords),
        ("testWordsOnlyWhereAllowed", testWordsOnlyWhereAllowed),
        ("testCanAnswerAFreeTextQuestion", testCanAnswerAFreeTextQuestion),
        ("testWithTextSaysWhenTheAnswerIsWhole", testWithTextSaysWhenTheAnswerIsWhole),
        ("testTypedAnswer", testTypedAnswer),
        ("testTexts", testTexts),
        ("testWindowSaysWhoAsksAndWarns", testWindowSaysWhoAsksAndWarns),
    ]
    static var asyncTests = [
        ("testDemoFeedTakesWords", testDemoFeedTakesWords),
    ]

    private let head = #""id": "01A", "key": "k", "title": "Q", "status": "open", "created_at": "2026-10-06T17:04:05.123Z", "content_updated_at": "2026-10-06T17:04:05.123Z""#

    private let db = ItemQuestionItem(header: "Database", text: "Which database?",
                                      options: [ItemQuestionOption(label: "Postgres"), ItemQuestionOption(label: "SQLite")],
                                      allowOther: true)
    private let extras = ItemQuestionItem(text: "Which extras?",
                                          options: [ItemQuestionOption(label: "Metrics"), ItemQuestionOption(label: "Tracing")],
                                          multiSelect: true, allowOther: true)
    private let name = ItemQuestionItem(header: "Name", text: "What should it be called?", allowOther: true)
    private let ship = ItemQuestionItem(text: "Ship it?", options: [ItemQuestionOption(label: "Yes"), ItemQuestionOption(label: "No")])

    private func item(_ q: ItemQuestion?, answer: [ItemAnswer]? = nil) -> Item {
        Item(id: "01A", key: "k", title: "Q", question: q, createdAt: Date(timeIntervalSince1970: 0), answer: answer,
             contentUpdatedAtRaw: "2026-10-06T17:04:05.123Z")
    }

    func testDecode() throws {
        let i = try HubJSON.makeDecoder().decode(Item.self, from: Data("""
        {\(head), "question": {"id": "t", "answerable": true, "items": [
          {"text": "Which?", "allow_other": true, "options": [{"label": "A"}]},
          {"text": "Name?", "allow_other": "yes"}]},
         "answer": [{"selected": [], "text": "MySQL"}, {"text": "Otter"}]}
        """.utf8))
        XCTAssertEqual(i.question?.items.map(\.allowOther), [true, false])   // junk is false
        XCTAssertEqual(i.answer, [ItemAnswer(selected: [], text: "MySQL"), ItemAnswer(selected: [], text: "Otter")])
        // older hubs: no allow_other, no text
        let old = try HubJSON.makeDecoder().decode(Item.self, from: Data("""
        {\(head), "question": {"items": [{"text": "Which?", "options": [{"label": "A"}]}]}, "answer": [{"selected": ["A"]}]}
        """.utf8))
        XCTAssertEqual(old.question?.items.first?.allowOther, false)
        XCTAssertEqual(old.answer, [ItemAnswer(selected: ["A"])])
        XCTAssertNil(old.answer?.first?.text)
    }

    func testRequestBodyCarriesTextOnlyWhenTyped() throws {
        let r = AnswerRequest(questionID: "t", contentUpdatedAt: "2026-10-06T17:04:05.123Z",
                              answers: [ItemAnswer(selected: [], text: "MySQL"), ItemAnswer(selected: ["A"])])
        let json = String(decoding: try HubJSON.makeEncoder().encode(r), as: UTF8.self)
        XCTAssertEqual(json, #"{"answers":[{"selected":[],"text":"MySQL"},{"selected":["A"]}],"content_updated_at":"2026-10-06T17:04:05.123Z","question_id":"t"}"#)
    }

    func testSelectionWithWords() {
        let q = ItemQuestion(id: "t", items: [db, extras], answerable: true)
        var s = AnswerSelection()
        s.toggle(0, "SQLite", multiSelect: false)
        s.setText(0, "MySQL", multiSelect: false)           // single choice: the words replace the pick
        XCTAssertFalse(s.isPicked(0, "SQLite"))
        XCTAssertEqual(s.texts[0], "MySQL")
        s.toggle(1, "Tracing", multiSelect: true)
        s.setText(1, "Logs", multiSelect: true)             // multi-select: the words go with the picks
        XCTAssertTrue(s.isPicked(1, "Tracing"))
        XCTAssertEqual(s.answers(for: q), [ItemAnswer(selected: [], text: "MySQL"),
                                           ItemAnswer(selected: ["Tracing"], text: "Logs")])
        s.toggle(0, "Postgres", multiSelect: false)         // and a pick replaces the words
        XCTAssertNil(s.texts[0])
        XCTAssertEqual(s.answers(for: q)?.first, ItemAnswer(selected: ["Postgres"]))
        s.setText(1, nil, multiSelect: true)
        XCTAssertEqual(s.answers(for: q)?.last, ItemAnswer(selected: ["Tracing"]))
        s.toggle(1, "Tracing", multiSelect: true)
        XCTAssertNil(s.answers(for: q))                     // nothing left for question 2
        s.setText(1, "", multiSelect: true)                 // empty words are none
        XCTAssertNil(s.answers(for: q))
    }

    func testWordsOnlyWhereAllowed() {
        var s = AnswerSelection()
        s.setText(0, "Maybe", multiSelect: false)
        XCTAssertNil(s.answers(for: ItemQuestion(id: "t", items: [ship], answerable: true)))
        XCTAssertNil(AnswerPolicy.withText(item(ItemQuestion(id: "t", items: [ship], answerable: true)),
                                           AnswerSelection(), question: 0, text: "Maybe"))
        XCTAssertNil(AnswerPolicy.otherTitle(ship))
        XCTAssertEqual(AnswerPolicy.otherTitle(db), "Other\u{2026}")
        XCTAssertEqual(AnswerPolicy.otherTitle(name), "Answer\u{2026}")
    }

    func testCanAnswerAFreeTextQuestion() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(AnswerPolicy.canAnswer(item(ItemQuestion(id: "t", items: [name], answerable: true)), now: now))
        var plain = name
        plain.allowOther = false
        XCTAssertFalse(AnswerPolicy.canAnswer(item(ItemQuestion(id: "t", items: [plain], answerable: true)), now: now))
        XCTAssertFalse(AnswerPolicy.canAnswer(item(ItemQuestion(id: "t", items: [name])), now: now))  // read-only
        XCTAssertEqual(QuestionDisplay.heading(name, index: 0, count: 1, answering: true), "Name · type an answer")
        XCTAssertEqual(QuestionDisplay.heading(name, index: 0, count: 1), "Name · answer in the agent")
    }

    func testWithTextSaysWhenTheAnswerIsWhole() {
        let one = item(ItemQuestion(id: "t", items: [db], answerable: true))
        let r = AnswerPolicy.withText(one, AnswerSelection(), question: 0, text: "MySQL")
        XCTAssertEqual(r?.complete, true)                   // the window's button says Send
        XCTAssertEqual(r.flatMap { AnswerPolicy.request(one, $0.selection) }?.answers,
                       [ItemAnswer(selected: [], text: "MySQL")])
        let two = item(ItemQuestion(id: "t", items: [db, ship], answerable: true))
        let partial = AnswerPolicy.withText(two, AnswerSelection(), question: 0, text: "MySQL")
        XCTAssertEqual(partial?.complete, false)            // Use: the card's Send waits for "Ship it?"
        var s = partial!.selection
        s.toggle(1, "Yes", multiSelect: false)
        XCTAssertEqual(AnswerPolicy.request(two, s)?.answers,
                       [ItemAnswer(selected: [], text: "MySQL"), ItemAnswer(selected: ["Yes"])])
        XCTAssertNil(AnswerPolicy.withText(two, AnswerSelection(), question: 5, text: "x"))
    }

    func testTypedAnswer() {
        XCTAssertEqual(AnswerPolicy.typedAnswer("  MySQL, the team knows it \n"), .ok("MySQL, the team knows it"))
        XCTAssertEqual(AnswerPolicy.typedAnswer("two\nlines\r\nand\ta tab"), .ok("two lines  and a tab"))
        XCTAssertEqual(AnswerPolicy.typedAnswer("a\u{2028}b"), .ok("a b"))
        // what the person typed goes as typed: nothing token-shaped is redacted
        XCTAssertEqual(AnswerPolicy.typedAnswer("use sk-ant-0123456789abcdef"), .ok("use sk-ant-0123456789abcdef"))
        XCTAssertEqual(AnswerPolicy.typedAnswer("👩‍💻 ok"), .ok("👩‍💻 ok"))   // a ZWJ emoji is fine
        for bad in ["", "   ", "\n\n", "a\u{07}b", "a\u{202E}b", "a\u{2066}b", "a\u{9B}b",
                    String(repeating: "é", count: 1001)] {
            if case .ok = AnswerPolicy.typedAnswer(bad) { XCTFail("took \(bad.debugDescription)") }
        }
        XCTAssertEqual(AnswerPolicy.typedAnswer(String(repeating: "é", count: 1000)), .ok(String(repeating: "é", count: 1000)))
        // scalars, as the hub counts: a flag is two
        if case .ok = AnswerPolicy.typedAnswer(String(repeating: "🇫🇷", count: 501)) { XCTFail("1002 scalars taken") }
    }

    func testTexts() {
        var i = item(ItemQuestion(items: [db, extras], answerable: true),
                     answer: [ItemAnswer(selected: [], text: "MySQL"), ItemAnswer(selected: ["Tracing"], text: "Logs")])
        i.answeredBy = "work-mac"
        XCTAssertEqual(AnswerPolicy.answeredText(i), "Answered: \u{201C}MySQL\u{201D} · Tracing, \u{201C}Logs\u{201D} (work-mac)")
    }

    /// The answer window names the agent, the machine and the project (each one cleaned
    /// line), and always says not to type a password or token.
    func testWindowSaysWhoAsksAndWarns() {
        var i = item(ItemQuestion(items: [db], answerable: true))
        i.source = ItemSource(host: "devbox", agent: "claude-code", project: "acme-web")
        XCTAssertEqual(AnswerPolicy.windowTitle(i), "Answer claude-code on devbox \u{00B7} acme-web")
        i.source = ItemSource(host: "dev\u{202E}box", agent: "", project: String(repeating: "p", count: 90))
        let t = AnswerPolicy.windowTitle(i)
        XCTAssertTrue(t.hasPrefix("Answer the agent on dev box \u{00B7} "), t)
        XCTAssertTrue(t.count <= 100, t)
        XCTAssertTrue(AnswerPolicy.windowWarning.contains("password"))
    }

    func testDemoFeedTakesWords() async throws {
        let feed = DemoFeed(items: [item(ItemQuestion(id: "t", items: [db, ship], answerable: true))])
        let notAllowed = AnswerRequest(questionID: "t", contentUpdatedAt: "x",
                                       answers: [ItemAnswer(selected: ["SQLite"]), ItemAnswer(selected: [], text: "Maybe")])
        let refused = try await feed.answer(id: "01A", notAllowed)
        XCTAssertEqual(refused, .refused(code: "invalid"))
        let both = AnswerRequest(questionID: "t", contentUpdatedAt: "x",
                                 answers: [ItemAnswer(selected: ["SQLite"], text: "MySQL"), ItemAnswer(selected: ["Yes"])])
        let refusedBoth = try await feed.answer(id: "01A", both)
        XCTAssertEqual(refusedBoth, .refused(code: "invalid"))
        let good = AnswerRequest(questionID: "t", contentUpdatedAt: "x",
                                 answers: [ItemAnswer(selected: [], text: "MySQL"), ItemAnswer(selected: ["Yes"])])
        let taken = try await feed.answer(id: "01A", good)
        XCTAssertEqual(taken, .taken)
        let items = try await feed.fetchOpen(since: nil)
        XCTAssertEqual(items.first?.answer?.first?.text, "MySQL")
    }
}
