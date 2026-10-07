#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Request update (Settings → Access / Machines): `update_requested_at` in GET /v1/tokens,
/// which rows get the button, and the request/clear calls.
final class MachineUpdateTests: XCTestCase {
    static var allTests = [
        ("testDecodesUpdateRequestedAt", testDecodesUpdateRequestedAt),
        ("testStates", testStates),
        ("testRequestedLabel", testRequestedLabel),
    ]
    static var asyncTests = [
        ("testRequestAndClearCalls", testRequestAndClearCalls),
    ]

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.recorded = []
    }

    func testDecodesUpdateRequestedAt() throws {
        let json = """
        {"tokens":[{"id":"1","name":"devbox","role":"sender","update_requested_at":"2026-10-07T09:12:00.000Z"},
                   {"id":"2","name":"ci","role":"sender","update_requested_at":null},
                   {"id":"3","name":"old-hub","role":"sender"},
                   {"id":"4","name":"odd","role":"sender","update_requested_at":7}]}
        """
        struct Body: Decodable { var tokens: [TokenSummary] }
        let tokens = try JSONDecoder().decode(Body.self, from: Data(json.utf8)).tokens
        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(tokens[0].updateRequestedAt, HubJSON.parseDate("2026-10-07T09:12:00.000Z"))
        XCTAssertNil(tokens[1].updateRequestedAt)
        XCTAssertNil(tokens[2].updateRequestedAt)
        XCTAssertNil(tokens[3].updateRequestedAt)   // a wrong type drops the field, not the token
    }

    private func token(role: HubRole? = .sender, cli: String? = nil, requested: Date? = nil) -> TokenSummary {
        TokenSummary(id: "t", name: "t", role: role, client: cli.map { ["cli": $0] } ?? [:], updateRequestedAt: requested)
    }

    func testStates() {
        let target = SemVer(0, 2, 0)
        XCTAssertEqual(MachineUpdateState(token: token(cli: "0.1.9"), target: target), .outdated(reported: "0.1.9"))
        XCTAssertEqual(MachineUpdateState(token: token(cli: "0.2.0"), target: target), .current)
        XCTAssertEqual(MachineUpdateState(token: token(cli: "0.3.0"), target: target), .current)
        // Never reported (an old CLI, or not seen yet), or "unknown": offer it.
        XCTAssertEqual(MachineUpdateState(token: token(), target: target), .outdated(reported: nil))
        XCTAssertEqual(MachineUpdateState(token: token(cli: "unknown"), target: target), .outdated(reported: "unknown"))
        XCTAssertTrue(MachineUpdateState(token: token(), target: target).canRequest)
        // A pending request wins, whatever the version.
        XCTAssertEqual(MachineUpdateState(token: token(cli: "0.1.0", requested: now), target: target), .requested(now))
        XCTAssertFalse(MachineUpdateState(token: token(cli: "0.1.0", requested: now), target: target).canRequest)
        // The Mac and readers don't run the CLI.
        XCTAssertEqual(MachineUpdateState(token: token(role: .owner, cli: "0.0.1"), target: target), .notApplicable)
        XCTAssertEqual(MachineUpdateState(token: token(role: .reader), target: target), .notApplicable)
        XCTAssertEqual(MachineUpdateState(token: token(role: nil), target: target), .notApplicable)
        // A dev build has no version: only unknown versions get the button.
        XCTAssertEqual(MachineUpdateState(token: token(cli: "0.1.0"), target: nil), .notApplicable)
        XCTAssertEqual(MachineUpdateState(token: token(), target: nil), .outdated(reported: nil))
    }

    func testRequestedLabel() {
        XCTAssertEqual(MachineUpdateState.requestedLabel(now.addingTimeInterval(-10), now: now), "Update requested just now")
        XCTAssertEqual(MachineUpdateState.requestedLabel(now.addingTimeInterval(-300), now: now), "Update requested 5m ago")
        XCTAssertEqual(MachineUpdateState.requestedLabel(now.addingTimeInterval(-7200), now: now), "Update requested 2h ago")
    }

    func testRequestAndClearCalls() async throws {
        let hub = URL(string: "http://127.0.0.1:8765")!
        let client = InviteClient(session: StubURLProtocol.session())
        StubURLProtocol.handler = { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/v1/tokens/01T/request-update"):
                return (200, Data(#"{"id":"01T","name":"devbox","update_requested_at":"2026-10-07T09:12:00.000Z","new":1}"#.utf8))
            case ("DELETE", "/v1/tokens/01T/request-update"):
                return (200, Data(#"{"id":"01T","name":"devbox","update_requested_at":null}"#.utf8))
            default:
                return (404, Data(#"{"error":"not_found"}"#.utf8))
            }
        }
        let at = try await client.requestUpdate(id: "01T", hub: hub, token: "owner-tok")
        XCTAssertEqual(at, HubJSON.parseDate("2026-10-07T09:12:00.000Z"))
        try await client.clearUpdateRequest(id: "01T", hub: hub, token: "owner-tok")
        XCTAssertEqual(StubURLProtocol.recorded.map { $0.request.httpMethod ?? "" }, ["POST", "DELETE"])
        XCTAssertTrue(StubURLProtocol.recorded.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer owner-tok" })
        do {
            try await client.requestUpdate(id: "gone", hub: hub, token: "owner-tok")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ConnectError, .http(status: 404, message: "not on this hub, or the hub is too old to request updates"))
        }
    }
}
