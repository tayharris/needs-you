#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class PeersTests: XCTestCase {
    static var allTests: [(String, (PeersTests) -> () throws -> Void)] = [
        ("testPeerInviteRequestBody", testPeerInviteRequestBody),
        ("testDecodesPeersTolerantly", testDecodesPeersTolerantly),
        ("testPeerStates", testPeerStates),
    ]
    static var asyncTests = [
        ("testCreatePeerInvite", testCreatePeerInvite),
        ("testListAndRemovePeers", testListAndRemovePeers),
    ]

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.recorded = []
    }

    private let hub = URL(string: "http://127.0.0.1:8765")!

    func testPeerInviteRequestBody() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PeerInviteRequest(name: " hub-b ", ttlHours: 99))) as? [String: Any]
        XCTAssertEqual(body?["name"] as? String, "hub-b")
        XCTAssertEqual(body?["role"] as? String, "peer")
        XCTAssertEqual(body?["uses"] as? Int, 1)
        XCTAssertEqual(body?["ttl_hours"] as? Int, 24)
        XCTAssertEqual(PeerInviteRequest(name: "x", ttlHours: 0).ttlHours, 1)
        XCTAssertEqual(PeerInviteRequest(name: "x").ttlHours, 1)
    }

    func testDecodesPeersTolerantly() throws {
        let json = #"""
        {"peers": [
          {"url": "http://hub-b.example.ts.net:8765", "hub_id": "hub-b", "name": "server", "source": "invite",
           "added_at": "2026-10-08T17:00:00.000Z", "outbox_pending": 2, "last_push_ok": "2026-10-08T17:01:00.000Z",
           "last_pull_ok": "2026-10-08T17:02:00.000Z", "last_error": null, "blocked": null, "skipped_push": 0},
          {"url": "http://hub-c.example.ts.net:8765", "hub_id": null, "source": "config", "outbox_pending": "x"},
          {"url": "http://hub-d.example.ts.net:8765", "source": "something-new"}
        ]}
        """#
        struct Body: Decodable { var peers: [PeerSummary] }
        let peers = try JSONDecoder().decode(Body.self, from: Data(json.utf8)).peers
        XCTAssertEqual(peers.count, 3)
        XCTAssertEqual(peers[0].hubID, "hub-b")
        XCTAssertEqual(peers[0].source, .invite)
        XCTAssertEqual(peers[0].outboxPending, 2)
        XCTAssertEqual(peers[0].lastSync, peers[0].lastPullOK)
        XCTAssertTrue(peers[0].removable)
        XCTAssertEqual(peers[0].displayName, "hub-b")
        XCTAssertEqual(peers[1].source, .config)
        XCTAssertFalse(peers[1].removable)
        XCTAssertEqual(peers[1].outboxPending, 0)
        XCTAssertEqual(peers[1].displayName, "hub-c.example.ts.net")
        XCTAssertNil(peers[2].source)
        XCTAssertFalse(peers[2].removable)
    }

    func testPeerStates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = "http://hub-b.example.ts.net:8765"
        XCTAssertEqual(PeerState(PeerSummary(url: url, addedAt: now), now: now), .waiting)
        XCTAssertEqual(PeerState(PeerSummary(url: url, addedAt: now, lastError: "URLError: refused"), now: now), .waiting)
        XCTAssertEqual(PeerState(PeerSummary(url: url, addedAt: now.addingTimeInterval(-600), lastError: "URLError: refused"), now: now),
                       .failing("URLError: refused", lastSync: nil))
        let synced = now.addingTimeInterval(-30)
        let ok = PeerState(PeerSummary(url: url, lastPullOK: synced), now: now)
        XCTAssertEqual(ok, .connected(lastSync: synced))
        XCTAssertTrue(ok.isHealthy)
        XCTAssertEqual(ok.label(now: now), "Connected, synced just now")
        // The Mac asleep, then back: writes queued for the server.
        let behind = PeerState(PeerSummary(url: url, outboxPending: 3, lastPushOK: now.addingTimeInterval(-120)), now: now)
        XCTAssertEqual(behind, .behind(pending: 3, lastSync: now.addingTimeInterval(-120)))
        XCTAssertEqual(behind.label(now: now), "Behind by 3 changes, synced 2m ago")
        // An error with a recent sync is a blip, not failing.
        XCTAssertEqual(PeerState(PeerSummary(url: url, lastPullOK: synced, lastError: "timeout"), now: now), .connected(lastSync: synced))
        let failing = PeerState(PeerSummary(url: url, outboxPending: 1, lastPushOK: now.addingTimeInterval(-3600),
                                            lastError: "HTTPError: HTTP Error 401: Unauthorized"), now: now)
        XCTAssertEqual(failing.label(now: now), "Can't reach it (HTTPError: HTTP Error 401: Unauthorized), synced 1h ago")
        XCTAssertEqual(PeerState(PeerSummary(url: url, blocked: "push token x"), now: now), .blocked("push token x"))
    }

    func testCreatePeerInvite() async throws {
        StubURLProtocol.handler = { _ in
            (201, Data(#"{"code":"nyi_c1","join_url":"http://mac.t.ts.net:8765/join/nyi_c1","role":"peer","uses":1,"install_command":"./scripts/install-hub.sh --user --join 'http://mac.t.ts.net:8765/join/nyi_c1'","expires_at":"2026-10-08T18:00:00.000Z"}"#.utf8))
        }
        let invite = try await InviteClient(session: StubURLProtocol.session())
            .createPeerInvite(PeerInviteRequest(name: "server"), hub: hub, token: "owner-tok")
        XCTAssertEqual(invite.hubInstallCommand, "./scripts/install-hub.sh --user --join 'http://mac.t.ts.net:8765/join/nyi_c1'")
        XCTAssertNil(invite.macURL)
        let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "http://127.0.0.1:8765/v1/invites")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-tok")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["role"] as? String, "peer")
        XCTAssertEqual(body["uses"] as? Int, 1)
    }

    func testListAndRemovePeers() async throws {
        StubURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { return (200, Data(#"{"removed":[{"url":"u","hub_id":"hub-b","name":"s"}]}"#.utf8)) }
            return (200, Data(#"{"peers":[{"url":"http://hub-b.example.ts.net:8765","hub_id":"hub-b","source":"invite","outbox_pending":0}]}"#.utf8))
        }
        let client = InviteClient(session: StubURLProtocol.session())
        let peers = try await client.listPeers(hub: hub, token: "owner-tok")
        XCTAssertEqual(peers.map(\.hubID), ["hub-b"])
        try await client.removePeer(hubID: "hub-b", hub: hub, token: "owner-tok")
        XCTAssertEqual(StubURLProtocol.recorded.map { $0.request.url?.absoluteString ?? "" },
                       ["http://127.0.0.1:8765/v1/peers", "http://127.0.0.1:8765/v1/peers/hub-b"])
        XCTAssertEqual(StubURLProtocol.recorded.last?.request.httpMethod, "DELETE")
        // A hub id is never a path: nothing is sent for one that isn't.
        do {
            try await client.removePeer(hubID: "../tokens/x", hub: hub, token: "owner-tok")
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
    }
}
