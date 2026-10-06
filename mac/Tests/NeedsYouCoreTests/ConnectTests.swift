#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class ConnectLinkTests: XCTestCase {
    static var allTests = [
        ("testParsesNeedsYouLink", testParsesNeedsYouLink),
        ("testParsesJoinURL", testParsesJoinURL),
        ("testRejectsOtherSchemesAndHosts", testRejectsOtherSchemesAndHosts),
        ("testRejectsMissingOrBadCode", testRejectsMissingOrBadCode),
        ("testTransportPolicy", testTransportPolicy),
        ("testInviteTexts", testInviteTexts),
    ]

    func testParsesNeedsYouLink() throws {
        let link = try XCTUnwrap(ConnectLink.parse("needsyou://connect?hub=http%3A%2F%2Fhub1.example.ts.net%3A8765&code=Ab-12_x"))
        XCTAssertEqual(link.hub.absoluteString, "http://hub1.example.ts.net:8765")
        XCTAssertEqual(link.code, "Ab-12_x")
        // Case-insensitive scheme/host, trailing slash on the hub, surrounding whitespace.
        let other = try XCTUnwrap(ConnectLink.parse("  NeedsYou://Connect?code=xyz&hub=https%3A%2F%2Fhub.example.com%2Fneeds%2F \n"))
        XCTAssertEqual(other.hub.absoluteString, "https://hub.example.com/needs")
        XCTAssertEqual(other.code, "xyz")
    }

    func testParsesJoinURL() throws {
        let a = try XCTUnwrap(ConnectLink.parse("http://hub1.example.ts.net:8765/join/K7q9"))
        XCTAssertEqual(a.hub.absoluteString, "http://hub1.example.ts.net:8765")
        XCTAssertEqual(a.code, "K7q9")
        let b = try XCTUnwrap(ConnectLink.parse("https://example.com/needs/join/abc/"))
        XCTAssertEqual(b.hub.absoluteString, "https://example.com/needs")
        XCTAssertEqual(b.code, "abc")
    }

    func testRejectsOtherSchemesAndHosts() {
        XCTAssertNil(ConnectLink.parse("ftp://hub/join/abc"))
        XCTAssertNil(ConnectLink.parse("javascript:alert(1)"))
        XCTAssertNil(ConnectLink.parse("needsyou://evil?hub=http%3A%2F%2Fhub&code=abc"))
        XCTAssertNil(ConnectLink.parse("needsyou://connect/extra?hub=http%3A%2F%2Fhub&code=abc"))
        XCTAssertNil(ConnectLink.parse("needsyou://connect?hub=file%3A%2F%2F%2Fetc&code=abc"))
        XCTAssertNil(ConnectLink.parse("needsyou://connect?hub=notaurl&code=abc"))
        XCTAssertNil(ConnectLink.parse("https:///join/abc"))
        XCTAssertNil(ConnectLink.parse("https://hub.example.com/items/abc"))
        XCTAssertNil(ConnectLink.parse(""))
    }

    func testRejectsMissingOrBadCode() {
        XCTAssertNil(ConnectLink.parse("needsyou://connect?hub=http%3A%2F%2Fhub.ts.net"))
        XCTAssertNil(ConnectLink.parse("needsyou://connect?hub=http%3A%2F%2Fhub.ts.net&code="))
        XCTAssertNil(ConnectLink.parse("needsyou://connect?hub=http%3A%2F%2Fhub.ts.net&code=a%2Fb"))
        XCTAssertNil(ConnectLink.parse("https://hub.example.com/join/"))
        XCTAssertNil(ConnectLink.parse("https://hub.example.com/join"))
        XCTAssertNil(ConnectLink.parse("https://hub.example.com/join/a b"))
    }

    func testTransportPolicy() {
        func ok(_ s: String) -> Bool { HubTransportPolicy.allows(URL(string: s)!) }
        XCTAssertTrue(ok("https://hub.example.com"))
        XCTAssertTrue(ok("http://hub1.example.ts.net:8765"))
        XCTAssertTrue(ok("http://127.0.0.1:8765"))
        XCTAssertTrue(ok("http://localhost:8765"))
        XCTAssertTrue(ok("http://100.101.102.103:8765"))
        XCTAssertTrue(ok("http://mini.local:8765"))
        XCTAssertTrue(ok("http://hub:8765"))
        XCTAssertFalse(ok("http://hub.example.com:8765"))
        XCTAssertFalse(ok("ftp://hub.ts.net"))
    }

    func testInviteTexts() {
        let invite = InviteResponse(code: "c", joinURL: "http://mac.tail1.ts.net:8765/join/c", macURL: "needsyou://connect?x", expiresAt: nil)
        XCTAssertEqual(invite.agentPrompt, "Set up needs-you alerts on this machine: read http://mac.tail1.ts.net:8765/join/c and follow it.")
        XCTAssertEqual(invite.shellOneLiner, "curl -fsSL http://mac.tail1.ts.net:8765/join/c/install.sh | bash -s -- --yes")
        // uses are clamped to 1...20.
        XCTAssertEqual(InviteRequest(name: " box ", role: .sender, uses: 99, ttlHours: 24).uses, 20)
        XCTAssertEqual(InviteRequest(name: "box", role: .sender, uses: 0, ttlHours: 24).uses, 1)
        XCTAssertEqual(InviteRequest(name: " box ", role: .sender, uses: 1, ttlHours: 24).name, "box")
    }
}

final class HubListMergeTests: XCTestCase {
    static var allTests = [
        ("testNewHubFirstThenReturnedDeduped", testNewHubFirstThenReturnedDeduped),
        ("testExistingOrderKept", testExistingOrderKept),
        ("testSkipsBadAndExcludedURLs", testSkipsBadAndExcludedURLs),
        ("testRedeemResponseDecoding", testRedeemResponseDecoding),
    ]

    func testNewHubFirstThenReturnedDeduped() {
        let given = URL(string: "http://hub1.t.ts.net:8765")!
        let r = HubListMerge.merge(existing: [], given: given,
                                   returned: ["http://HUB2.t.ts.net:8765/", "http://hub1.t.ts.net:8765", "http://hub2.t.ts.net:8765"])
        XCTAssertEqual(r.hubs, ["http://hub1.t.ts.net:8765", "http://hub2.t.ts.net:8765"])
        XCTAssertEqual(r.tokenHubs.map(HubName.key), ["http://hub1.t.ts.net:8765", "http://hub2.t.ts.net:8765"])
        XCTAssertEqual(r.added.count, 2)
    }

    func testExistingOrderKept() {
        let given = URL(string: "http://hub2.t.ts.net:8765")!
        let r = HubListMerge.merge(existing: ["http://hub3.t.ts.net:8765", "http://hub2.t.ts.net:8765"], given: given,
                                   returned: ["http://hub1.t.ts.net:8765", "http://hub2.t.ts.net:8765"])
        XCTAssertEqual(r.hubs, ["http://hub3.t.ts.net:8765", "http://hub2.t.ts.net:8765", "http://hub1.t.ts.net:8765"])
        // The token goes to every hub the response named, including ones already listed.
        XCTAssertEqual(r.tokenHubs.map(HubName.key), ["http://hub2.t.ts.net:8765", "http://hub1.t.ts.net:8765"])
        XCTAssertEqual(r.added.map(HubName.key), ["http://hub1.t.ts.net:8765"])
    }

    func testSkipsBadAndExcludedURLs() {
        let given = URL(string: "https://hub.example.com")!
        let r = HubListMerge.merge(existing: [], given: given,
                                   returned: ["not a url", "http://plain.example.com:8765", "http://127.0.0.1:8765", "https://hub.example.com/"],
                                   exclude: [HubName.key(LocalHub.clientURL)])
        XCTAssertEqual(r.hubs, ["https://hub.example.com"])
        XCTAssertEqual(r.skipped, ["not a url", "http://plain.example.com:8765", "http://127.0.0.1:8765"])
    }

    func testRedeemResponseDecoding() throws {
        let json = #"{"token":"tok","role":"owner","name":"Taylor's Mac","hub_urls":["http://a.ts.net:8765"],"hub_id":"a","extra":1}"#
        let r = try JSONDecoder().decode(RedeemResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r, RedeemResponse(token: "tok", role: .owner, name: "Taylor's Mac", hubURLs: ["http://a.ts.net:8765"], hubID: "a"))
        // Unknown roles and missing optional fields don't fail the redeem.
        let lax = try JSONDecoder().decode(RedeemResponse.self, from: Data(#"{"token":"t","role":"admin"}"#.utf8))
        XCTAssertNil(lax.role)
        XCTAssertEqual(lax.hubURLs, [])
        XCTAssertTrue(HubRole.owner.canInvite && HubRole.owner.canRead)
        XCTAssertFalse(HubRole.sender.canRead)
        XCTAssertFalse(HubRole.reader.canInvite)
    }
}

// MARK: - Network, with a stubbed URLProtocol

/// Answers requests from a static handler; records what was sent.
final class StubURLProtocol: URLProtocol {
    struct Recorded {
        var request: URLRequest
        var body: Data
    }

    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var recorded: [Recorded] = []

    static func session() -> URLSession {
        let cfg = HubSession.makeConfiguration()
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.recorded.append(Recorded(request: request, body: body))
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class InviteClientTests: XCTestCase {
    static var allTests: [(String, (InviteClientTests) -> () throws -> Void)] = [
        ("testSessionHasNoCache", testSessionHasNoCache),
    ]
    static var asyncTests = [
        ("testRedeemSendsCodeAndHostWithoutAuth", testRedeemSendsCodeAndHostWithoutAuth),
        ("testRedeem404IsExpiredOrUsed", testRedeem404IsExpiredOrUsed),
        ("testRedeemUnreachable", testRedeemUnreachable),
        ("testRedeemPlainHTTPOffTailnetIsRefusedWithoutNetwork", testRedeemPlainHTTPOffTailnetIsRefusedWithoutNetwork),
        ("testCreateInvite", testCreateInvite),
    ]

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.recorded = []
    }

    private let link = ConnectLink(hub: URL(string: "http://hub1.t.ts.net:8765")!, code: "abc")

    func testSessionHasNoCache() {
        let cfg = HubSession.makeConfiguration()
        XCTAssertNil(cfg.urlCache)
        XCTAssertNil(cfg.httpCookieStorage)
        XCTAssertEqual(cfg.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(HubSession.shared.configuration.urlCache)
    }

    func testRedeemSendsCodeAndHostWithoutAuth() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"token":"tok","role":"reader","name":"mac","hub_urls":["http://hub1.t.ts.net:8765","http://hub2.t.ts.net:8765"],"hub_id":"hub1"}"#.utf8))
        }
        let response = try await InviteClient(session: StubURLProtocol.session()).redeem(link, host: "mac-a")
        XCTAssertEqual(response.token, "tok")
        XCTAssertEqual(response.role, .reader)
        XCTAssertEqual(response.hubURLs.count, 2)
        let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "http://hub1.t.ts.net:8765/v1/invites/redeem")
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: String])
        XCTAssertEqual(body, ["code": "abc", "host": "mac-a"])
    }

    func testRedeem404IsExpiredOrUsed() async {
        StubURLProtocol.handler = { _ in (404, Data(#"{"error":"not_found"}"#.utf8)) }
        do {
            _ = try await InviteClient(session: StubURLProtocol.session()).redeem(link, host: "h")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ConnectError, .expiredOrUsed)
        }
    }

    func testRedeemUnreachable() async {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await InviteClient(session: StubURLProtocol.session()).redeem(link, host: "h")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ConnectError, .unreachable(host: "hub1.t.ts.net:8765"))
        }
    }

    func testRedeemPlainHTTPOffTailnetIsRefusedWithoutNetwork() async {
        let bad = ConnectLink(hub: URL(string: "http://hub.example.com:8765")!, code: "abc")
        do {
            _ = try await InviteClient(session: StubURLProtocol.session()).redeem(bad, host: "h")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ConnectError, .httpNotAllowed(host: "hub.example.com"))
        }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testCreateInvite() async throws {
        StubURLProtocol.handler = { _ in
            (201, Data(#"{"code":"c1","join_url":"http://mac.t.ts.net:8765/join/c1","mac_url":"needsyou://connect?hub=x&code=c1","expires_at":"2026-10-07T17:00:00.000Z"}"#.utf8))
        }
        let invite = try await InviteClient(session: StubURLProtocol.session())
            .createInvite(InviteRequest(name: "build-box", role: .sender, uses: 3, ttlHours: 24),
                          hub: URL(string: "http://127.0.0.1:8765")!, token: "owner-tok")
        XCTAssertEqual(invite.code, "c1")
        XCTAssertEqual(invite.macURL, "needsyou://connect?hub=x&code=c1")
        let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "http://127.0.0.1:8765/v1/invites")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-tok")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "build-box")
        XCTAssertEqual(body["role"] as? String, "sender")
        XCTAssertEqual(body["uses"] as? Int, 3)
        XCTAssertEqual(body["ttl_hours"] as? Int, 24)

        StubURLProtocol.handler = { _ in (403, Data(#"{"error":"forbidden"}"#.utf8)) }
        do {
            _ = try await InviteClient(session: StubURLProtocol.session())
                .createInvite(InviteRequest(name: "x", role: .sender, uses: 1, ttlHours: 1), hub: URL(string: "http://127.0.0.1:8765")!, token: "reader")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ConnectError, .unauthorized)
        }
    }
}
