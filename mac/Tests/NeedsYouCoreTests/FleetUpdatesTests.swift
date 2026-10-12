#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Settings → Updates → Machines and hubs (ADR 0013): GET/POST /v1/hub/update decoding and
/// calls, which hubs are listed with which token, each hub row's state, and Update all.
final class FleetUpdatesTests: XCTestCase {
    static var allTests = [
        ("testDecodesHubUpdateStatus", testDecodesHubUpdateStatus),
        ("testNewestTarget", testNewestTarget),
        ("testPlanListsPeersAndOwnerHubsOnce", testPlanListsPeersAndOwnerHubsOnce),
        ("testHubStates", testHubStates),
        ("testDetail", testDetail),
        ("testSummaryAndUpdateAll", testSummaryAndUpdateAll),
    ]
    static var asyncTests = [
        ("testHubUpdateCalls", testHubUpdateCalls),
    ]

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hubURL = URL(string: "http://hub-a.example.ts.net:8765")!

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.recorded = []
    }

    func testDecodesHubUpdateStatus() throws {
        let json = """
        {"version":"0.5.1","available":true,"auto_update":true,"channel":"stable","reason":null,
         "state":"updated","requested_at":null,"requested":true,"started_at":"2026-10-12T09:00:01.000Z",
         "finished_at":"2026-10-12T09:01:30.000Z","from_version":"0.5.0","target":"0.5.1",
         "message":"upgraded the hub from 0.5.0 to 0.5.1","next_request_at":null,"new_field":[1]}
        """
        let s = try JSONDecoder().decode(HubUpdateStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.version, "0.5.1")
        XCTAssertTrue(s.available)
        XCTAssertEqual(s.state, .updated)
        XCTAssertTrue(s.requested)
        XCTAssertEqual(s.fromVersion, "0.5.0")
        XCTAssertEqual(s.finishedAt, HubJSON.parseDate("2026-10-12T09:01:30.000Z"))
        // Unknown states and wrong types are tolerated.
        let odd = try JSONDecoder().decode(HubUpdateStatus.self, from: Data(#"{"state":"rebooting","available":"yes","version":5}"#.utf8))
        XCTAssertEqual(odd.state, .idle)
        XCTAssertFalse(odd.available)
        XCTAssertNil(odd.version)
        XCTAssertEqual(try JSONDecoder().decode(HubUpdateStatus.self, from: Data(#"{"state":"up_to_date"}"#.utf8)).state, .upToDate)
    }

    func testNewestTarget() {
        XCTAssertEqual(FleetTarget.newest(app: SemVer(0, 5, 1), seen: SemVer(0, 5, 2)), SemVer(0, 5, 2))
        XCTAssertEqual(FleetTarget.newest(app: SemVer(0, 5, 1), seen: SemVer(0, 4, 0)), SemVer(0, 5, 1))
        XCTAssertEqual(FleetTarget.newest(app: nil, seen: SemVer(0, 5, 2)), SemVer(0, 5, 2))
        XCTAssertNil(FleetTarget.newest(app: nil, seen: nil))
        XCTAssertEqual(UpdateDecision.skipped(SemVer(0, 6, 0), "you chose Skip").seenVersion, SemVer(0, 6, 0))
        XCTAssertNil(UpdateDecision.upToDate.seenVersion)
        XCTAssertNil(UpdateDecision.blocked(nil, "no manifest").seenVersion)
    }

    func testPlanListsPeersAndOwnerHubsOnce() {
        let peers = [PeerSummary(url: "http://hub-a.example.ts.net:8765", hubID: "hub-a"),
                     PeerSummary(url: "http://hub-b.example.ts.net:8765", hubID: "hub-b"),
                     PeerSummary(url: "not a url")]
        let owners = [HubConfig(baseURL: LocalHub.clientURL, token: "local"),
                      HubConfig(baseURL: URL(string: "http://HUB-B.example.ts.net:8765/")!, token: "b-own"),
                      HubConfig(baseURL: URL(string: "https://hub-c.example.com")!, token: "c-own")]
        let plan = FleetHubEndpoint.plan(peers: peers, ownerHubs: owners, localToken: "local")
        XCTAssertEqual(plan.map(\.name), ["hub-a", "hub-b", "hub-c"])
        XCTAssertEqual(plan.map(\.token), ["local", "b-own", "c-own"])
        // Without the local hub's token its peers can't be asked.
        XCTAssertEqual(FleetHubEndpoint.plan(peers: peers, ownerHubs: [], localToken: nil), [])
    }

    private func hub(_ version: String?, _ status: HubUpdateStatus? = nil, error: String? = nil) -> FleetHub {
        FleetHub(url: hubURL, name: "hub-a", version: version, status: status, error: error)
    }

    func testHubStates() {
        let target = SemVer(0, 5, 2)
        XCTAssertEqual(HubUpdateState(hub: hub("0.5.2", HubUpdateStatus(version: "0.5.2", available: true)), target: target), .current)
        XCTAssertEqual(HubUpdateState(hub: hub("0.5.1", HubUpdateStatus(version: "0.5.1", available: true)), target: target), .outdated)
        XCTAssertTrue(HubUpdateState(hub: hub("0.5.1", HubUpdateStatus(version: "0.5.1", available: true)), target: target).canRequest)
        let off = HubUpdateStatus(version: "0.5.1", available: false, reason: "automatic updates are off on this hub")
        XCTAssertEqual(HubUpdateState(hub: hub("0.5.1", off), target: target), .unavailable("automatic updates are off on this hub"))
        XCTAssertFalse(HubUpdateState(hub: hub("0.5.1", off), target: target).canRequest)
        let asked = HubUpdateStatus(version: "0.5.1", available: true, state: .requested, requestedAt: now)
        XCTAssertEqual(HubUpdateState(hub: hub("0.5.1", asked), target: target), .requested(now))
        let running = HubUpdateStatus(version: "0.5.1", available: true, state: .updating, target: "0.5.2")
        XCTAssertEqual(HubUpdateState(hub: hub("0.5.1", running), target: target), .working("Updating to 0.5.2…"))
        let failed = HubUpdateStatus(version: "0.5.1", available: true, state: .failed, message: "no valid build provenance")
        XCTAssertEqual(HubUpdateState(hub: hub("0.5.1", failed), target: target), .failed("no valid build provenance"))
        XCTAssertTrue(HubUpdateState(hub: hub("0.5.1", failed), target: target).canRequest)
        // A failure that left it current is just current.
        XCTAssertEqual(HubUpdateState(hub: hub("0.5.2", HubUpdateStatus(version: "0.5.2", available: true, state: .failed)), target: target), .current)
        // An old hub: version only. Unreachable: the error.
        XCTAssertEqual(HubUpdateState(hub: hub("0.4.0"), target: target), .tooOld)
        XCTAssertEqual(HubUpdateState(hub: hub(nil, error: "Couldn't reach"), target: target), .unknown("Couldn't reach"))
        // No target (a dev build): never behind.
        XCTAssertEqual(HubUpdateState(hub: hub("0.0.1", HubUpdateStatus(version: "0.0.1", available: true)), target: nil), .current)
    }

    func testDetail() {
        let updated = HubUpdateStatus(version: "0.5.2", available: true, state: .updated, target: "0.5.2",
                                      finishedAt: now.addingTimeInterval(-7200), fromVersion: "0.5.1")
        XCTAssertEqual(hub("0.5.2", updated).detail(now: now), "Hub 0.5.2 · updated from 0.5.1 2h ago")
        let pre = HubUpdateStatus(version: "0.5.2", available: true, state: .upToDate, finishedAt: now.addingTimeInterval(-10),
                                  channel: "prerelease")
        XCTAssertEqual(hub("0.5.2", pre).detail(now: now), "Hub 0.5.2 · prerelease channel · checked just now")
        XCTAssertEqual(hub(nil, error: "x").detail(now: now), "Version unknown")
    }

    func testSummaryAndUpdateAll() {
        let seen = now.addingTimeInterval(-3600)
        let tokens = [
            TokenSummary(id: "1", name: "old", role: .sender, client: ["cli": "0.5.0"], lastSeenAt: seen),
            TokenSummary(id: "2", name: "new", role: .sender, client: ["cli": "0.5.1"], lastSeenAt: seen),
            TokenSummary(id: "3", name: "asked", role: .sender, client: ["cli": "0.5.0"], lastSeenAt: seen, updateRequestedAt: seen),
            TokenSummary(id: "4", name: "gone", role: .sender, client: ["cli": "0.1.0"], lastSeenAt: now.addingTimeInterval(-30 * 86_400)),
            TokenSummary(id: "5", name: "mac", role: .owner, current: true),
        ]
        let hubs = [
            FleetHub(url: URL(string: "http://hub-a.example.ts.net:8765")!, name: "hub-a",
                     status: HubUpdateStatus(version: "0.5.1", available: true)),
            FleetHub(url: URL(string: "http://hub-b.example.ts.net:8765")!, name: "hub-b",
                     status: HubUpdateStatus(version: "0.5.2", available: true)),
            FleetHub(url: URL(string: "http://hub-c.example.ts.net:8765")!, name: "hub-c",
                     status: HubUpdateStatus(version: "0.5.0", available: false, reason: "off")),
        ]
        let s = FleetSummary(tokens: tokens, senderTarget: SemVer(0, 5, 1), hubs: hubs, hubTarget: SemVer(0, 5, 2), now: now)
        XCTAssertEqual(s.text, "2 of 3 machines out of date; 2 of 3 hubs out of date.")
        XCTAssertEqual(s.tokensToAsk.map(\.name), ["old"])
        XCTAssertEqual(s.hubsToAsk.map(\.name), ["hub-a"])
        XCTAssertEqual(s.updateAllCount, 2)
        let none = FleetSummary(tokens: [], senderTarget: nil, hubs: [], hubTarget: nil, now: now)
        XCTAssertEqual(none.text, "No sender machines seen in the last 14 days, and no server hubs.")
        let fine = FleetSummary(tokens: [tokens[1]], senderTarget: SemVer(0, 5, 1), hubs: [hubs[1]], hubTarget: SemVer(0, 5, 2), now: now)
        XCTAssertEqual(fine.text, "1 machine up to date; 1 hub up to date.")
    }

    func testHubUpdateCalls() async throws {
        let client = InviteClient(session: StubURLProtocol.session())
        StubURLProtocol.handler = { request in
            switch (request.httpMethod ?? "", request.url?.host ?? "", request.url?.path ?? "") {
            case ("GET", "hub-a.example.ts.net", "/v1/hub/update"):
                return (200, Data(#"{"version":"0.5.1","available":true,"state":"idle"}"#.utf8))
            case ("POST", "hub-a.example.ts.net", "/v1/hub/update"):
                return (202, Data(#"{"version":"0.5.1","available":true,"state":"requested","requested_at":"2026-10-12T09:00:00.000Z"}"#.utf8))
            case ("GET", "old.example.ts.net", "/v1/health"):
                return (200, Data(#"{"ok":true,"version":"0.4.0"}"#.utf8))
            default:
                return (404, Data(#"{"error":"not_found"}"#.utf8))
            }
        }
        let status = try await client.hubUpdateStatus(hub: hubURL, token: "owner-tok")
        XCTAssertEqual(status.state, .idle)
        let asked = try await client.requestHubUpdate(hub: hubURL, token: "owner-tok")
        XCTAssertEqual(asked.state, .requested)
        let post = StubURLProtocol.recorded.first { $0.request.httpMethod == "POST" }
        XCTAssertNotNil(post)
        XCTAssertEqual(post?.request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-tok")
        // The request names nothing: no body at all.
        XCTAssertTrue((post?.body ?? Data()).isEmpty)
        let old = URL(string: "http://old.example.ts.net:8765")!
        do {
            _ = try await client.hubUpdateStatus(hub: old, token: "owner-tok")
            XCTFail("expected hubTooOld")
        } catch {
            XCTAssertEqual(error as? ConnectError, .hubTooOld)
        }
        let version = try await client.hubVersion(hub: old)
        XCTAssertEqual(version, "0.4.0")
        XCTAssertNil(StubURLProtocol.recorded.last?.request.value(forHTTPHeaderField: "Authorization"))
    }
}
