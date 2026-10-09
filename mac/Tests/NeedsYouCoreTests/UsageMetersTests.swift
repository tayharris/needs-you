#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Status records (docs/API.md "Status records") as the app reads them, and GET /v1/status.
final class StatusRecordTests: XCTestCase {
    static var allTests = [
        ("testDecodesUsageRecord", testDecodesUsageRecord),
        ("testLenientDecoding", testLenientDecoding),
        ("testStatusRequestAndOutcomes", testStatusRequestAndOutcomes),
    ]
    static var asyncTests = [
        ("testFailoverSendsETagOnlyToTheSameHub", testFailoverSendsETagOnlyToTheSameHub),
        ("testDemoFeedHasUsage", testDemoFeedHasUsage),
    ]

    func testDecodesUsageRecord() throws {
        let json = #"""
        {"statuses": [{"id": "st_1", "key": "usage:claude", "type": "usage", "label": "Claude",
          "state": null, "progress": null, "detail": "", "future_field": {"x": 1},
          "usage": {"provider": "claude", "account": "team-2", "windows": [
            {"name": "5h", "used_pct": 51, "resets_at": "2026-10-08T14:00:00.000Z"},
            {"name": "7d", "used_pct": 41.5, "resets_at": null}]},
          "source": {"host": "devbox", "agent": "claude-code"},
          "created_at": "2026-10-08T09:00:00.000Z", "updated_at": "2026-10-08T09:41:10.000Z",
          "expires_at": "2026-10-14T09:00:00.000Z"}], "server_time": "2026-10-08T09:41:12.000Z"}
        """#
        let list = try StatusRecord.decodeList(Data(json.utf8))
        XCTAssertEqual(list.count, 1)
        let s = list[0]
        XCTAssertEqual(s.id, "st_1")
        XCTAssertEqual(s.type, "usage")
        XCTAssertEqual(s.usage?.provider, "claude")
        XCTAssertEqual(s.usage?.account, "team-2")
        XCTAssertEqual(s.usage?.windows.map(\.name), ["5h", "7d"])
        XCTAssertEqual(s.usage?.windows.map(\.usedPct), [51, 41.5])
        XCTAssertEqual(s.usage?.windows.first?.resetsAt, HubJSON.parseDate("2026-10-08T14:00:00.000Z"))
        XCTAssertNil(s.usage?.windows.last?.resetsAt)
        XCTAssertEqual(s.source?.host, "devbox")
        XCTAssertEqual(s.updatedAt, HubJSON.parseDate("2026-10-08T09:41:10.000Z"))
        XCTAssertFalse(s.isExpired(at: HubJSON.parseDate("2026-10-10T00:00:00Z")!))
        XCTAssertTrue(s.isExpired(at: HubJSON.parseDate("2026-10-15T00:00:00Z")!))
    }

    func testLenientDecoding() throws {
        let json = #"""
        {"statuses": [
          {"id": "st_p", "type": "progress", "label": "nightly import", "state": "working", "progress": 40},
          {"id": "st_new", "type": "SomethingNew"},
          {"no_id": true},
          {"id": "st_bad", "type": "usage", "usage": {"windows": "nope"}},
          {"id": "st_w", "type": "usage", "usage": {"provider": "codex", "windows": [
             {"name": "5h", "used_pct": 140}, {"name": "7d"}, {"used_pct": 3}]}}]}
        """#
        let list = try StatusRecord.decodeList(Data(json.utf8))
        // The record without an id is skipped; the rest decode with defaults.
        XCTAssertEqual(list.map(\.id), ["st_p", "st_new", "st_bad", "st_w"])
        XCTAssertEqual(list[0].type, "progress")
        XCTAssertNil(list[0].usage)
        XCTAssertEqual(list[1].type, "somethingnew")
        XCTAssertNil(list[2].usage, "a usage without a provider is no usage")
        let w = try XCTUnwrap(list[3].usage)
        XCTAssertEqual(w.account, "")
        // Malformed windows are dropped; percentages are clamped to 0-100.
        XCTAssertEqual(w.windows.map(\.name), ["5h"])
        XCTAssertEqual(w.windows.first?.usedPct, 100)
    }

    func testStatusRequestAndOutcomes() throws {
        let base = URL(string: "http://hub-a.example.ts.net:8765")!
        let plain = HubClient.statusRequest(base: base, token: "t", etag: nil)
        XCTAssertEqual(plain.url?.absoluteString, "http://hub-a.example.ts.net:8765/v1/status")
        XCTAssertEqual(plain.httpMethod, "GET")
        XCTAssertNil(plain.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(plain.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let cond = HubClient.statusRequest(base: base, token: "t", etag: "\"abc\"")
        XCTAssertEqual(cond.value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")

        XCTAssertEqual(try HubClient.statusOutcome(status: 304, body: Data(), etag: nil), .unchanged)
        // A hub that predates statuses: none, and no ETag to send next time.
        XCTAssertEqual(try HubClient.statusOutcome(status: 404, body: Data(#"{"error":"not_found"}"#.utf8), etag: "x"),
                       .fresh([], etag: nil))
        let ok = try HubClient.statusOutcome(status: 200, body: Data(#"{"statuses":[{"id":"st_1","type":"usage"}]}"#.utf8),
                                             etag: "\"e1\"")
        guard case let .fresh(records, etag) = ok else { return XCTFail("expected fresh") }
        XCTAssertEqual(records.map(\.id), ["st_1"])
        XCTAssertEqual(etag, "\"e1\"")
        do {
            _ = try HubClient.statusOutcome(status: 401, body: Data(), etag: nil)
            XCTFail("401 must throw")
        } catch let e as HubError {
            XCTAssertEqual(e, .unauthorized)
        }
        do {
            _ = try HubClient.statusOutcome(status: 200, body: Data("not json".utf8), etag: nil)
            XCTFail("junk must throw")
        } catch let e as HubError {
            XCTAssertEqual(e, .invalidResponse)
        }
    }

    func testFailoverSendsETagOnlyToTheSameHub() async throws {
        let a = StatusHub(name: "a")
        let b = StatusHub(name: "b")
        let feed = FailoverFeed(hubs: [.init(name: "a", feed: a), .init(name: "b", feed: b)])
        // Before any items poll there is no hub to ask.
        let before = try await feed.fetchStatuses(etag: "stale")
        XCTAssertEqual(before, .fresh([], etag: nil))
        _ = try await feed.fetchPage(since: nil)
        _ = try await feed.fetchStatuses(etag: "e-old")   // first call to a: no ETag
        _ = try await feed.fetchStatuses(etag: "e-a")     // same hub: its ETag
        let seen = await a.etags
        XCTAssertEqual(seen, [nil, "e-a"])
        // a goes down: b answers the items, and gets no ETag of a's.
        await a.setFailing(true)
        _ = try await feed.fetchPage(since: nil)
        _ = try await feed.fetchStatuses(etag: "e-a")
        let seenB = await b.etags
        XCTAssertEqual(seenB, [nil])
    }

    func testDemoFeedHasUsage() async throws {
        let now = Date()
        guard case let .fresh(records, _) = try await DemoFeed(items: [], now: now).fetchStatuses(etag: nil) else {
            return XCTFail("expected fresh")
        }
        XCTAssertEqual(Set(records.compactMap { $0.usage?.provider }), ["claude", "codex"])
        let rows = UsageMeters.rows(records, prefs: UsagePrefs(), now: now)
        XCTAssertEqual(rows.map(\.title), ["Claude", "Codex"])
        // One bar past the default warning line, for the screenshots.
        XCTAssertTrue(rows.flatMap(\.bars).contains { $0.level == .warning })
    }
}

private actor StatusHub: ItemFeed, StatusFeed {
    let name: String
    var failing = false
    private(set) var etags: [String?] = []

    init(name: String) { self.name = name }

    func setFailing(_ value: Bool) { failing = value }

    func fetchOpen(since: Date?) async throws -> [Item] {
        if failing { throw URLError(.timedOut) }
        return []
    }

    func patch(id: String, _ patch: ItemPatch) async throws {}

    func fetchStatuses(etag: String?) async throws -> StatusFetch {
        etags.append(etag)
        return .fresh([], etag: "e-\(name)")
    }
}

/// UsageMeters and UsagePrefs: rows per provider and account, the filters, reset and levels.
final class UsageMetersTests: XCTestCase {
    static var allTests = [
        ("testNewestReportPerAccountWins", testNewestReportPerAccountWins),
        ("testWindowsOrderAndTitles", testWindowsOrderAndTitles),
        ("testResetWindowShowsZero", testResetWindowShowsZero),
        ("testFilters", testFilters),
        ("testLevels", testLevels),
        ("testResetText", testResetText),
        ("testPillBarsAreTheFullestPerWindow", testPillBarsAreTheFullestPerWindow),
        ("testIgnoresExpiredProgressAndUnknown", testIgnoresExpiredProgressAndUnknown),
        ("testPrefsDefaultsRoundTripAndFallback", testPrefsDefaultsRoundTripAndFallback),
    ]

    private let now = Date(timeIntervalSince1970: 1_791_280_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func usage(_ id: String, provider: String = "claude", account: String = "", host: String = "devbox",
                       updated: TimeInterval = -60, windows: [UsageWindow], expires: TimeInterval = 86_400,
                       type: String = "usage") -> StatusRecord {
        StatusRecord(id: id, key: "usage:\(provider)", type: type,
                     usage: StatusUsage(provider: provider, account: account, windows: windows),
                     source: ItemSource(host: host), updatedAt: now.addingTimeInterval(updated),
                     expiresAt: now.addingTimeInterval(expires))
    }

    private func w(_ name: String, _ pct: Double, resetsIn: TimeInterval? = nil) -> UsageWindow {
        UsageWindow(name: name, usedPct: pct, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    func testNewestReportPerAccountWins() {
        let rows = UsageMeters.rows([
            usage("a", host: "devbox", updated: -300, windows: [w("5h", 10)]),
            usage("b", host: "build-box", updated: -30, windows: [w("5h", 20)]),
            usage("c", account: "team-2", windows: [w("5h", 70)]),
            usage("d", provider: "codex", windows: [w("7d", 5)]),
        ], prefs: UsagePrefs(), now: now, timeZone: utc)
        XCTAssertEqual(rows.map(\.title), ["Claude", "Claude · team-2", "Codex"])
        XCTAssertEqual(rows[0].bars.first?.pct, 20)
        XCTAssertEqual(rows[0].host, "build-box")
    }

    func testWindowsOrderAndTitles() {
        let rows = UsageMeters.rows([usage("a", windows: [w("opus", 3), w("7d", 41), w("5h", 51)])],
                                    prefs: UsagePrefs(), now: now, timeZone: utc)
        XCTAssertEqual(rows.first?.bars.map(\.title), ["Session", "Weekly", "opus"])
        XCTAssertEqual(rows.first?.bars.map(\.pctText), ["51%", "41%", "3%"])
    }

    func testResetWindowShowsZero() {
        let bar = UsageMeters.rows([usage("a", windows: [w("5h", 97, resetsIn: -60)])],
                                   prefs: UsagePrefs(), now: now, timeZone: utc).first?.bars.first
        XCTAssertEqual(bar?.pct, 0)
        XCTAssertEqual(bar?.isReset, true)
        XCTAssertEqual(bar?.level, .normal)
        XCTAssertEqual(bar?.resetText, "reset")
    }

    func testFilters() {
        let statuses = [usage("a", windows: [w("5h", 51), w("7d", 12)]),
                        usage("b", provider: "codex", windows: [w("5h", 5), w("7d", 30)])]
        var prefs = UsagePrefs()
        prefs.windows = .session
        XCTAssertEqual(UsageMeters.rows(statuses, prefs: prefs, now: now).map { $0.bars.map(\.id) }, [["5h"], ["5h"]])
        prefs.windows = .weekly
        XCTAssertEqual(UsageMeters.rows(statuses, prefs: prefs, now: now).map { $0.bars.map(\.id) }, [["7d"], ["7d"]])
        prefs.windows = .both
        prefs.providers = ["codex"]
        XCTAssertEqual(UsageMeters.rows(statuses, prefs: prefs, now: now).map(\.provider), ["codex"])
        prefs.providers = []
        // Hide under 25%: Claude keeps its session bar, Codex its weekly one.
        prefs.hideUnderPct = 25
        XCTAssertEqual(UsageMeters.rows(statuses, prefs: prefs, now: now).map { $0.bars.map(\.id) }, [["5h"], ["7d"]])
        // A row with nothing left goes.
        prefs.hideUnderPct = 50
        XCTAssertEqual(UsageMeters.rows(statuses, prefs: prefs, now: now).map(\.provider), ["claude"])
        XCTAssertEqual(UsageMeters.providers(statuses, now: now), ["claude", "codex"])
    }

    func testLevels() {
        XCTAssertEqual(UsageMeters.level(79.9, warnPct: 80), .normal)
        XCTAssertEqual(UsageMeters.level(80, warnPct: 80), .warning)
        XCTAssertEqual(UsageMeters.level(100, warnPct: 80), .full)
        XCTAssertEqual(UsageMeters.level(60, warnPct: 50), .warning)
    }

    func testResetText() {
        let now = HubJSON.parseDate("2026-10-08T09:00:00Z")!   // a Thursday
        XCTAssertEqual(UsageMeters.resetText(HubJSON.parseDate("2026-10-08T14:00:00Z")!, now: now, timeZone: utc),
                       "resets 14:00")
        XCTAssertEqual(UsageMeters.resetText(HubJSON.parseDate("2026-10-13T09:30:00Z")!, now: now, timeZone: utc),
                       "resets Tue 09:30")
    }

    func testPillBarsAreTheFullestPerWindow() {
        let rows = UsageMeters.rows([usage("a", windows: [w("5h", 51), w("7d", 12)]),
                                     usage("b", provider: "codex", windows: [w("5h", 85), w("7d", 30), w("x", 99)])],
                                    prefs: UsagePrefs(), now: now)
        let bars = UsageMeters.pillBars(rows)
        XCTAssertEqual(bars.map(\.id), ["5h", "7d"])
        XCTAssertEqual(bars.map(\.pct), [85, 30])
        XCTAssertEqual(bars.first?.level, .warning)
        XCTAssertTrue(UsageMeters.summary(rows).hasPrefix("Claude session 51% · weekly 12%"))
        XCTAssertEqual(UsageMeters.pillBars([]), [])
    }

    func testIgnoresExpiredProgressAndUnknown() {
        let rows = UsageMeters.rows([
            usage("gone", windows: [w("5h", 50)], expires: -1),
            usage("p", windows: [w("5h", 50)], type: "progress"),
            usage("n", windows: [w("5h", 50)], type: "somethingnew"),
            StatusRecord(id: "nousage", key: "k", updatedAt: now),
        ], prefs: UsagePrefs(), now: now)
        XCTAssertEqual(rows, [])
    }

    func testPrefsDefaultsRoundTripAndFallback() {
        let suite = "needsyou-usageprefs-test-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer {
            store.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(suite).plist")
        }
        // The owner's defaults: panel and pill on, every provider, both windows, always shown.
        let fresh = UsagePrefs.load(from: store)
        XCTAssertEqual(fresh, UsagePrefs())
        XCTAssertTrue(fresh.inPanel && fresh.onPill && fresh.isShown)
        XCTAssertEqual(fresh.providers, [])
        XCTAssertEqual(fresh.windows, .both)
        XCTAssertEqual(fresh.hideUnderPct, 0)
        XCTAssertEqual(fresh.warnPct, 80)
        XCTAssertTrue((store.persistentDomain(forName: suite) ?? [:]).isEmpty, "load never writes")

        var p = fresh
        p.inPanel = false
        p.onPill = false
        p.providers = ["codex"]
        p.windows = .weekly
        p.hideUnderPct = 50
        p.warnPct = 90
        p.save(to: store, previous: fresh)
        XCTAssertEqual(UsagePrefs.load(from: store), p)
        XCTAssertFalse(p.isShown)
        XCTAssertFalse(p.shows(provider: "claude"))

        store.set("sometimes", forKey: UsagePrefs.Key.windows)
        store.set(33, forKey: UsagePrefs.Key.hideUnderPct)
        store.set(7, forKey: UsagePrefs.Key.warnPct)
        let back = UsagePrefs.load(from: store)
        XCTAssertEqual(back.windows, .both)
        XCTAssertEqual(back.hideUnderPct, 0)
        XCTAssertEqual(back.warnPct, 80)
    }
}
