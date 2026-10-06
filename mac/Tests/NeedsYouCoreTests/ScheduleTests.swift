#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class ScheduleTests: XCTestCase {
    static var allTests = [
        ("testWorkHoursOnWeekdaysOnly", testWorkHoursOnWeekdaysOnly),
        ("testOverrideHoldsUntilNextBoundary", testOverrideHoldsUntilNextBoundary),
        ("testMorningSummaryFiresOncePerWeekday", testMorningSummaryFiresOncePerWeekday),
        ("testMorningSummaryAfterSleepingThrough", testMorningSummaryAfterSleepingThrough),
    ]

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Denver")!
        return c
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // October 2026: the 5th is a Monday, the 10th a Saturday.
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testWorkHoursOnWeekdaysOnly() {
        let s = WorkSchedule()
        XCTAssertEqual(s.context(at: at(6, 6, 59), calendar: cal), .personal)
        XCTAssertEqual(s.context(at: at(6, 7), calendar: cal), .work)
        XCTAssertEqual(s.context(at: at(6, 17, 59), calendar: cal), .work)
        XCTAssertEqual(s.context(at: at(6, 18), calendar: cal), .personal)
        XCTAssertEqual(s.context(at: at(10, 10), calendar: cal), .personal) // Saturday
    }

    func testOverrideHoldsUntilNextBoundary() {
        let s = WorkSchedule()
        let noon = at(6, 12)
        let boundary = s.nextBoundary(after: noon, calendar: cal)
        XCTAssertEqual(boundary, at(6, 18))
        let o = ContextOverride(context: .personal, until: boundary)
        XCTAssertEqual(ContextOverride.resolve(schedule: s, override: o, at: at(6, 13), calendar: cal), .personal)
        XCTAssertEqual(ContextOverride.resolve(schedule: s, override: o, at: at(6, 19), calendar: cal), .personal) // schedule says personal anyway
        XCTAssertEqual(ContextOverride.resolve(schedule: s, override: o, at: at(7, 9), calendar: cal), .work)      // override expired
        // Friday evening's next flip is Monday 07:00.
        XCTAssertEqual(s.nextBoundary(after: at(9, 19), calendar: cal), at(12, 7))
    }

    func testMorningSummaryFiresOncePerWeekday() {
        let m = MorningSummary()
        XCTAssertFalse(m.isDue(now: at(6, 7, 29), lastShown: nil, calendar: cal))
        XCTAssertTrue(m.isDue(now: at(6, 7, 30), lastShown: nil, calendar: cal))
        XCTAssertFalse(m.isDue(now: at(6, 9), lastShown: at(6, 7, 30), calendar: cal))
        XCTAssertTrue(m.isDue(now: at(7, 7, 31), lastShown: at(6, 7, 30), calendar: cal))
        XCTAssertFalse(m.isDue(now: at(10, 8), lastShown: nil, calendar: cal)) // Saturday
    }

    func testMorningSummaryAfterSleepingThrough() {
        let m = MorningSummary()
        // Asleep at 7:30; first wake at 9:10 still shows it.
        XCTAssertTrue(m.isDue(now: at(6, 9, 10), lastShown: at(5, 7, 30), calendar: cal))
        XCTAssertEqual(m.sinceYesterdayBoundary(now: at(6, 9, 10), lastShown: at(5, 7, 30), calendar: cal), at(5, 7, 30))
        XCTAssertEqual(m.sinceYesterdayBoundary(now: at(6, 9, 10), lastShown: nil, calendar: cal), at(5, 0))
    }
}
