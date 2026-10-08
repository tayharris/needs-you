#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Answering a question from its card (ADR 0009 B2): decoding `answerable`, `expires_at` and
/// the answer, the picks and the request they make, when a card can answer, the texts, the
/// hub's replies, and the demo feed playing the hub's rules.
final class AnswerPolicyTests: XCTestCase {
    static var allTests = [
        ("testDecodeAnswerFields", testDecodeAnswerFields),
        ("testRequestBody", testRequestBody),
        ("testSelection", testSelection),
        ("testCanAnswer", testCanAnswer),
        ("testClickSendsOnlyForOneSingleChoiceQuestion", testClickSendsOnlyForOneSingleChoiceQuestion),
        ("testTexts", testTexts),
        ("testTerminalLink", testTerminalLink),
        ("testHubOutcomes", testHubOutcomes),
    ]
    static var asyncTests = [
        ("testDemoFeedAnswers", testDemoFeedAnswers),
    ]

    private let head = #""id": "01A", "key": "k", "title": "Q", "status": "open", "created_at": "2026-10-06T17:04:05.123Z", "content_updated_at": "2026-10-06T17:04:05.123Z""#

    private func decode(_ json: String) throws -> Item {
        try HubJSON.makeDecoder().decode(Item.self, from: Data(json.utf8))
    }

    private let db = ItemQuestionItem(header: "Database", text: "Which database?",
                                      options: [ItemQuestionOption(label: "Postgres"), ItemQuestionOption(label: "SQLite")])
    private let extras = ItemQuestionItem(text: "Which extras?",
                                          options: [ItemQuestionOption(label: "Metrics"), ItemQuestionOption(label: "Tracing")],
                                          multiSelect: true)

    private func item(_ q: ItemQuestion?, answer: [ItemAnswer]? = nil, status: ItemStatus = .open,
                      links: [ItemLink] = []) -> Item {
        Item(id: "01A", key: "k", title: "Q", links: links, question: q, status: status,
             createdAt: Date(timeIntervalSince1970: 0), answer: answer,
             contentUpdatedAtRaw: "2026-10-06T17:04:05.123Z")
    }

    func testDecodeAnswerFields() throws {
        let i = try decode("""
        {\(head), "question": {"id": "toolu_1", "answerable": true, "expires_at": "2026-10-06T17:14:05.000Z",
          "items": [{"text": "Which?", "options": [{"label": "A"}]}]},
         "answer": [{"selected": ["A"], "x": 1}], "answered_at": "2026-10-06T17:05:00.000Z", "answered_by": "mac"}
        """)
        XCTAssertEqual(i.question?.answerable, true)
        XCTAssertEqual(i.question?.expiresAt, HubJSON.parseDate("2026-10-06T17:14:05.000Z"))
        XCTAssertEqual(i.answer, [ItemAnswer(selected: ["A"])])
        XCTAssertEqual(i.answeredBy, "mac")
        XCTAssertEqual(i.answeredAt, HubJSON.parseDate("2026-10-06T17:05:00.000Z"))
        XCTAssertEqual(i.contentUpdatedAtRaw, "2026-10-06T17:04:05.123Z")
        // B1 hubs: no answerable, no answer; junk never costs the item
        let old = try decode("{\(head), \"question\": {\"items\": [{\"text\": \"Which?\"}]}}")
        XCTAssertEqual(old.question?.answerable, false)
        XCTAssertNil(old.question?.expiresAt)
        XCTAssertNil(old.answer)
        let junk = try decode("{\(head), \"question\": {\"answerable\": \"yes\", \"items\": [{\"text\": \"W?\"}]}, \"answer\": \"A\"}")
        XCTAssertEqual(junk.question?.answerable, false)
        XCTAssertNil(junk.answer)
        // an answer without a question is ignored
        XCTAssertNil(try decode("{\(head), \"answer\": [{\"selected\": [\"A\"]}], \"answered_by\": \"mac\"}").answer)
    }

    func testRequestBody() throws {
        let r = AnswerRequest(questionID: nil, contentUpdatedAt: "2026-10-06T17:04:05.123Z",
                              answers: [ItemAnswer(selected: ["A", "B"])])
        let json = String(decoding: try HubJSON.makeEncoder().encode(r), as: UTF8.self)
        XCTAssertEqual(json, #"{"answers":[{"selected":["A","B"]}],"content_updated_at":"2026-10-06T17:04:05.123Z","question_id":null}"#)
    }

    func testSelection() {
        let q = ItemQuestion(id: "t", items: [db, extras], answerable: true)
        var s = AnswerSelection()
        XCTAssertNil(s.answers(for: q))
        s.toggle(0, "Postgres", multiSelect: false)
        s.toggle(0, "SQLite", multiSelect: false)           // single choice: replaces
        XCTAssertTrue(s.isPicked(0, "SQLite"))
        XCTAssertFalse(s.isPicked(0, "Postgres"))
        XCTAssertFalse(s.isComplete(for: q))
        s.toggle(1, "Tracing", multiSelect: true)
        s.toggle(1, "Metrics", multiSelect: true)
        // in the options' order, whatever the click order
        XCTAssertEqual(s.answers(for: q), [ItemAnswer(selected: ["SQLite"]), ItemAnswer(selected: ["Metrics", "Tracing"])])
        s.toggle(1, "Metrics", multiSelect: true)
        s.toggle(1, "Tracing", multiSelect: true)          // nothing left for question 2
        XCTAssertNil(s.answers(for: q))
        // a label that isn't offered (the question changed) never makes an answer
        var odd = AnswerSelection()
        odd.toggle(0, "MySQL", multiSelect: false)
        XCTAssertNil(odd.answers(for: ItemQuestion(items: [db], answerable: true)))
        var full = AnswerSelection()
        full.toggle(0, "SQLite", multiSelect: false)
        full.toggle(1, "Metrics", multiSelect: true)
        let r = AnswerPolicy.request(item(q), full)
        XCTAssertEqual(r, AnswerRequest(questionID: "t", contentUpdatedAt: "2026-10-06T17:04:05.123Z",
                                        answers: [ItemAnswer(selected: ["SQLite"]), ItemAnswer(selected: ["Metrics"])]))
    }

    func testCanAnswer() {
        let now = Date(timeIntervalSince1970: 1000)
        let q = ItemQuestion(id: "t", items: [db], answerable: true)
        XCTAssertTrue(AnswerPolicy.canAnswer(item(q), now: now))
        XCTAssertFalse(AnswerPolicy.canAnswer(item(ItemQuestion(items: [db])), now: now))           // read-only
        XCTAssertFalse(AnswerPolicy.canAnswer(item(q, answer: [ItemAnswer(selected: ["SQLite"])]), now: now))
        XCTAssertFalse(AnswerPolicy.canAnswer(item(q, status: .resolved), now: now))
        XCTAssertFalse(AnswerPolicy.canAnswer(item(nil), now: now))
        var expiring = q
        expiring.expiresAt = Date(timeIntervalSince1970: 999)
        XCTAssertFalse(AnswerPolicy.canAnswer(item(expiring), now: now))
        expiring.expiresAt = Date(timeIntervalSince1970: 1001)
        XCTAssertTrue(AnswerPolicy.canAnswer(item(expiring), now: now))
        let free = ItemQuestion(items: [db, ItemQuestionItem(text: "Name?")], answerable: true)
        XCTAssertFalse(AnswerPolicy.canAnswer(item(free), now: now))   // no free text from the card
        var noVersion = item(q)
        noVersion.contentUpdatedAtRaw = nil
        XCTAssertFalse(AnswerPolicy.canAnswer(noVersion, now: now))
    }

    func testClickSendsOnlyForOneSingleChoiceQuestion() {
        XCTAssertTrue(AnswerPolicy.sendsOnClick(ItemQuestion(items: [db], answerable: true)))
        XCTAssertFalse(AnswerPolicy.sendsOnClick(ItemQuestion(items: [extras], answerable: true)))
        XCTAssertFalse(AnswerPolicy.sendsOnClick(ItemQuestion(items: [db, db], answerable: true)))
        let q = ItemQuestion(id: "t", items: [db], answerable: true)
        XCTAssertEqual(AnswerPolicy.clickRequest(item(q), question: 0, label: "SQLite")?.answers,
                       [ItemAnswer(selected: ["SQLite"])])
        XCTAssertNil(AnswerPolicy.clickRequest(item(q), question: 0, label: "Oracle"))
    }

    func testTexts() {
        var i = item(ItemQuestion(items: [db, extras], answerable: true),
                     answer: [ItemAnswer(selected: ["SQLite"]), ItemAnswer(selected: ["Metrics", "Tracing"])])
        i.answeredBy = "work-mac"
        XCTAssertEqual(AnswerPolicy.answeredText(i), "Answered: SQLite · Metrics, Tracing (work-mac)")
        i.answeredBy = nil
        XCTAssertEqual(AnswerPolicy.answeredText(i), "Answered: SQLite · Metrics, Tracing")
        XCTAssertNil(AnswerPolicy.answeredText(item(nil)))
        XCTAssertEqual(AnswerPolicy.failureText(code: "already_answered"), "Already answered (another click got there first).")
        XCTAssertTrue(AnswerPolicy.failureText(code: nil).contains("answer in the terminal"))
        XCTAssertTrue(AnswerPolicy.failureText(code: "question_expired").contains("terminal"))
        XCTAssertTrue(AnswerPolicy.failureText(code: "weird").contains("weird"))
    }

    func testTerminalLink() {
        let web = ItemLink(label: "PR", url: "https://github.com/acme/app/pull/1")
        XCTAssertNil(AnswerPolicy.terminalLink(item(nil, links: [web])))
        let term = ItemLink(label: "Terminal", url: "needsyou://terminal/focus?app=wezterm&pane=1")
        XCTAssertNotNil(AppAction.parse(term.url))
        XCTAssertEqual(AnswerPolicy.terminalLink(item(nil, links: [web, term])), term)
    }

    func testHubOutcomes() throws {
        XCTAssertEqual(try HubClient.answerOutcome(status: 200, body: Data("{}".utf8)), .taken)
        XCTAssertEqual(try HubClient.answerOutcome(status: 409, body: Data(#"{"error":"already_answered"}"#.utf8)),
                       .refused(code: "already_answered"))
        XCTAssertEqual(try HubClient.answerOutcome(status: 429, body: Data("not json".utf8)), .refused(code: "http_429"))
        XCTAssertThrowsError(try HubClient.answerOutcome(status: 403, body: Data()))
        XCTAssertThrowsError(try HubClient.answerOutcome(status: 503, body: Data()))
    }

    func testDemoFeedAnswers() async throws {
        let q = ItemQuestion(id: "t", items: [db], answerable: true)
        let feed = DemoFeed(items: [item(q)])
        let bad = AnswerRequest(questionID: "t", contentUpdatedAt: "x", answers: [ItemAnswer(selected: ["Oracle"])])
        let badOutcome = try await feed.answer(id: "01A", bad)
        XCTAssertEqual(badOutcome, .refused(code: "invalid"))
        let changed = try await feed.answer(id: "01A", AnswerRequest(questionID: "other", contentUpdatedAt: "x",
                                                                   answers: [ItemAnswer(selected: ["SQLite"])]))
        XCTAssertEqual(changed, .refused(code: "question_changed"))
        let good = AnswerRequest(questionID: "t", contentUpdatedAt: "x", answers: [ItemAnswer(selected: ["SQLite"])])
        let first = try await feed.answer(id: "01A", good)
        XCTAssertEqual(first, .taken)
        let second = try await feed.answer(id: "01A", good)
        XCTAssertEqual(second, .refused(code: "already_answered"))
        let items = try await feed.fetchOpen(since: nil)
        XCTAssertEqual(items.first?.answer, [ItemAnswer(selected: ["SQLite"])])
    }
}
