#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// A hub that answers every answer the same way, and counts the calls.
private actor AnswerHub: ItemFeed {
    enum Reply { case outcome(AnswerOutcome), error(Error) }
    let reply: Reply
    private(set) var calls = 0

    init(_ reply: Reply) { self.reply = reply }

    func fetchOpen(since: Date?) async throws -> [Item] { [] }
    func patch(id: String, _ patch: ItemPatch) async throws {}
    func answer(id: String, _ answer: AnswerRequest) async throws -> AnswerOutcome {
        calls += 1
        switch reply {
        case .outcome(let o): return o
        case .error(let e): throw e
        }
    }
}

/// Hubs take typed answer `text` only from an owner token (403 `forbidden` otherwise,
/// docs/API.md): the Mac says so on the card instead of "no hub answered", tries its other
/// hubs (the token there may be an owner one), and stops offering Other… when it knows no
/// hub would take typed words.
final class TypedAnswerRefusalTests: XCTestCase {
    static var allTests = [
        ("testForbiddenIsTheHubsRefusalNotATokenError", testForbiddenIsTheHubsRefusalNotATokenError),
        ("testFailureTextSaysPickAnOption", testFailureTextSaysPickAnOption),
        ("testMayTypeFromKnownRoles", testMayTypeFromKnownRoles),
        ("testNoOtherButtonWhenNoHubTakesTypedWords", testNoOtherButtonWhenNoHubTakesTypedWords),
        ("testRefusedWordsAreDropped", testRefusedWordsAreDropped),
    ]
    static var asyncTests = [
        ("testFailoverTriesTheNextHubOnForbidden", testFailoverTriesTheNextHubOnForbidden),
        ("testForbiddenEverywhereIsTheOutcome", testForbiddenEverywhereIsTheOutcome),
    ]

    /// The hub's body for a typed answer from a reader token (hub/needs_you_hub.py).
    private let forbiddenBody = Data(#"{"error": "forbidden", "message": "typed answers (Other...) need an owner token (this one is a reader): pick one of the listed options instead, or answer from the owner's Mac"}"#.utf8)

    private let request = AnswerRequest(questionID: "t", contentUpdatedAt: "x",
                                        answers: [ItemAnswer(selected: [], text: "MySQL")])

    private let db = ItemQuestionItem(header: "Database", text: "Which database?",
                                      options: [ItemQuestionOption(label: "Postgres"), ItemQuestionOption(label: "SQLite")],
                                      allowOther: true)
    private let name = ItemQuestionItem(header: "Name", text: "What should it be called?", allowOther: true)

    private func item(_ q: ItemQuestion) -> Item {
        Item(id: "01A", key: "k", title: "Q", question: q, createdAt: Date(timeIntervalSince1970: 0),
             contentUpdatedAtRaw: "2026-10-06T17:04:05.123Z")
    }

    func testForbiddenIsTheHubsRefusalNotATokenError() throws {
        XCTAssertEqual(try HubClient.answerOutcome(status: 403, body: forbiddenBody), .refused(code: "forbidden"))
        // A 401, or a 403 that isn't the hub's `forbidden`, is still a token error.
        for (status, body) in [(401, forbiddenBody), (403, Data()), (403, Data(#"{"error":"unauthorized"}"#.utf8))] {
            var threw: Error?
            do { _ = try HubClient.answerOutcome(status: status, body: body) } catch { threw = error }
            XCTAssertEqual(threw as? HubError, .unauthorized, "\(status)")
        }
    }

    func testFailureTextSaysPickAnOption() {
        let typed = AnswerPolicy.failureText(code: "forbidden", typed: true)
        XCTAssertTrue(typed.contains("owner's Mac"), typed)
        XCTAssertTrue(typed.contains("Pick an option"), typed)
        XCTAssertFalse(typed.contains("no hub answered"))
        let picked = AnswerPolicy.failureText(code: "forbidden")
        XCTAssertFalse(picked.contains("typed"), picked)
        XCTAssertTrue(picked.contains("terminal"), picked)
        XCTAssertTrue(AnswerPolicy.hasText(request))
        XCTAssertFalse(AnswerPolicy.hasText(AnswerRequest(questionID: "t", contentUpdatedAt: "x",
                                                          answers: [ItemAnswer(selected: ["Postgres"])])))
    }

    func testMayTypeFromKnownRoles() {
        XCTAssertTrue(AnswerPolicy.mayType(roles: []))                 // the demo, no hubs
        XCTAssertTrue(AnswerPolicy.mayType(roles: [.owner]))
        XCTAssertTrue(AnswerPolicy.mayType(roles: [.reader, .owner]))
        XCTAssertTrue(AnswerPolicy.mayType(roles: [.reader, nil]))     // a hand-entered token: the hub decides
        XCTAssertFalse(AnswerPolicy.mayType(roles: [.reader]))
        XCTAssertFalse(AnswerPolicy.mayType(roles: [.reader, .reader]))
    }

    func testNoOtherButtonWhenNoHubTakesTypedWords() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(AnswerPolicy.otherTitle(db), "Other\u{2026}")
        XCTAssertNil(AnswerPolicy.otherTitle(db, mayType: false))
        XCTAssertNil(AnswerPolicy.otherTitle(name, mayType: false))
        // Options are still clickable; a question that only takes words is read-only.
        let withOptions = item(ItemQuestion(id: "t", items: [db], answerable: true))
        XCTAssertTrue(AnswerPolicy.canAnswer(withOptions, now: now, mayType: false))
        let wordsOnly = item(ItemQuestion(id: "t", items: [db, name], answerable: true))
        XCTAssertTrue(AnswerPolicy.canAnswer(wordsOnly, now: now))
        XCTAssertFalse(AnswerPolicy.canAnswer(wordsOnly, now: now, mayType: false))
    }

    func testRefusedWordsAreDropped() {
        var s = AnswerSelection()
        s.toggle(0, "Postgres", multiSelect: false)
        s.setText(1, "Otter", multiSelect: false)
        let left = s.withoutTexts()
        XCTAssertTrue(left.texts.isEmpty)
        XCTAssertTrue(left.isPicked(0, "Postgres"))
    }

    func testFailoverTriesTheNextHubOnForbidden() async throws {
        let a = AnswerHub(.outcome(.refused(code: "forbidden"))), b = AnswerHub(.outcome(.taken))
        let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: a), .init(name: "hub2", feed: b)])
        let outcome = try await feed.answer(id: "01A", request)
        XCTAssertEqual(outcome, .taken)
        let aCalls = await a.calls, bCalls = await b.calls
        XCTAssertEqual([aCalls, bCalls], [1, 1])

        // Another refusal from the next hub is its answer (the hub is up, it said no).
        let c = AnswerHub(.outcome(.refused(code: "already_answered")))
        let feed2 = FailoverFeed(hubs: [.init(name: "hub1", feed: a), .init(name: "hub3", feed: c)])
        let outcome2 = try await feed2.answer(id: "01A", request)
        XCTAssertEqual(outcome2, .refused(code: "already_answered"))
    }

    func testForbiddenEverywhereIsTheOutcome() async throws {
        let forbidden = AnswerHub(.outcome(.refused(code: "forbidden")))
        let down = AnswerHub(.error(URLError(.cannotConnectToHost)))
        let badToken = AnswerHub(.error(HubError.unauthorized))
        for others in [[forbidden], [down], [badToken]] {
            let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: forbidden)]
                                    + others.map { FailoverFeed.Hub(name: "hub2", feed: $0) })
            let outcome = try await feed.answer(id: "01A", request)
            XCTAssertEqual(outcome, .refused(code: "forbidden"))  // not "no hub answered"
        }
        // A token error first still stops there, as before.
        let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: badToken), .init(name: "hub2", feed: forbidden)])
        var threw: Error?
        do { _ = try await feed.answer(id: "01A", request) } catch { threw = error }
        XCTAssertEqual(threw as? HubError, .unauthorized)
    }
}
