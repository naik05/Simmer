import XCTest
@testable import SimmerCore

final class SchedulerTests: XCTestCase {
    /// Gregorian calendar in a fixed UTC+1 zone without daylight saving.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        return calendar
    }()

    /// November 2026: the 9th is a Monday, the 14th a Saturday, the 15th a Sunday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0, month: Int = 11, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private let weekdays: Set<Int> = [2, 3, 4, 5, 6]

    private func rule(
        _ weekdays: Set<Int>? = nil, _ hour: Int = 7, _ minute: Int = 30,
        enabled: Bool = true, action: ScheduleAction = .topUp
    ) -> ScheduleRule {
        ScheduleRule(isEnabled: enabled, weekdays: weekdays ?? self.weekdays, hour: hour, minute: minute, action: action)
    }

    private func due(_ rules: [ScheduleRule], _ lastCheck: Date, _ now: Date) -> [ScheduleRule] {
        Scheduler.dueRules(rules, after: lastCheck, upTo: now, calendar: calendar)
    }

    func testFixtureWeekdays() {
        XCTAssertEqual(calendar.component(.weekday, from: date(9, 12, 0)), 2)
        XCTAssertEqual(calendar.component(.weekday, from: date(14, 12, 0)), 7)
        XCTAssertEqual(calendar.component(.weekday, from: date(15, 12, 0)), 1)
    }

    // MARK: dueRules

    func testRuleIsDueWhenItsTimeFallsIntoTheWindow() {
        let weekday = rule()
        XCTAssertEqual(due([weekday], date(9, 7, 29, 55), date(9, 7, 30, 0)), [weekday], "upper bound is inclusive")
        XCTAssertEqual(due([weekday], date(9, 7, 29, 55), date(9, 7, 30, 3)), [weekday])
        XCTAssertEqual(due([weekday], date(9, 7, 29, 50), date(9, 7, 29, 59)), [], "not yet")
        XCTAssertEqual(due([weekday], date(9, 7, 30, 0), date(9, 7, 30, 5)), [], "lower bound is exclusive")
    }

    func testRuleFiresExactlyOnceWhilePolling() {
        let weekday = rule()
        var lastCheck = date(9, 7, 28, 57)
        var fired: [Date] = []
        // Poll every 5 s for five minutes around the fire time.
        for _ in 0..<60 {
            let now = lastCheck.addingTimeInterval(5)
            if !due([weekday], lastCheck, now).isEmpty { fired.append(now) }
            lastCheck = now
        }
        XCTAssertEqual(fired, [date(9, 7, 30, 2)])
    }

    func testRuleFiresOnEachSelectedWeekdayOnly() {
        let weekday = rule()
        let firedDays = (9...16).filter { day in
            !due([weekday], date(day, 7, 29), date(day, 7, 31)).isEmpty
        }
        XCTAssertEqual(firedDays, [9, 10, 11, 12, 13, 16], "Mon–Fri, not on the weekend")
    }

    func testTimeMustMatch() {
        let evening = rule([2], 22, 15)
        XCTAssertEqual(due([evening], date(9, 7, 29), date(9, 7, 31)), [])
        XCTAssertEqual(due([evening], date(9, 22, 14), date(9, 22, 16)), [evening])
        XCTAssertEqual(due([evening], date(10, 22, 14), date(10, 22, 16)), [], "Tuesday")
    }

    func testMidnightRule() {
        let midnight = rule([3], 0, 0)   // Tuesday 00:00
        XCTAssertEqual(due([midnight], date(9, 23, 59, 30), date(10, 0, 0, 30)), [midnight])
        XCTAssertEqual(due([midnight], date(8, 23, 59, 30), date(9, 0, 0, 30)), [])
    }

    func testGraceWindowDropsStaleOccurrences() {
        let weekday = rule()
        // Mac slept from 06:00 to noon: the 07:30 rule is not replayed.
        XCTAssertEqual(due([weekday], date(9, 6, 0), date(9, 12, 0)), [])
        // Woke up 10 minutes late: still honoured.
        XCTAssertEqual(due([weekday], date(9, 6, 0), date(9, 7, 40)), [weekday])
        XCTAssertEqual(due([weekday], date(9, 6, 0), date(9, 7, 44, 59)), [weekday])
        // More than 15 minutes late: dropped.
        XCTAssertEqual(due([weekday], date(9, 6, 0), date(9, 7, 46)), [])
    }

    func testGraceWindowIsConfigurable() {
        let weekday = rule()
        let sixHours = Scheduler.dueRules(
            [weekday], after: date(9, 6, 0), upTo: date(9, 12, 0), calendar: calendar, grace: 6 * 3600
        )
        XCTAssertEqual(sixHours, [weekday])
        let oneMinute = Scheduler.dueRules(
            [weekday], after: date(9, 6, 0), upTo: date(9, 7, 32), calendar: calendar, grace: 60
        )
        XCTAssertEqual(oneMinute, [])
    }

    func testDisabledRulesNeverFire() {
        XCTAssertEqual(due([rule(enabled: false)], date(9, 7, 29), date(9, 7, 31)), [])
    }

    func testRulesWithoutWeekdaysNeverFire() {
        let never = rule([])
        XCTAssertEqual(due([never], date(9, 7, 29), date(9, 7, 31)), [])
        XCTAssertNil(Scheduler.nextFireDate(for: never, after: date(9, 0, 0), calendar: calendar))
    }

    func testEmptyOrBackwardsWindowYieldsNothing() {
        let weekday = rule()
        XCTAssertEqual(due([weekday], date(9, 7, 30), date(9, 7, 30)), [])
        XCTAssertEqual(due([weekday], date(9, 7, 31), date(9, 7, 29)), [])
        XCTAssertEqual(due([], date(9, 7, 29), date(9, 7, 31)), [])
    }

    func testOnlyMatchingRulesAreReturnedInOrder() {
        let topUp = rule(action: .topUp)
        let later = rule([2], 9, 0, action: .startDischarge)
        let limit = rule([2], 7, 30, action: .setLimit(60))
        let disabled = rule(enabled: false, action: .returnToNormal)
        let tuesday = rule([3], 7, 30, action: .startCalibration)
        let result = due([topUp, later, limit, disabled, tuesday], date(9, 7, 29), date(9, 7, 31))
        XCTAssertEqual(result, [topUp, limit])
    }

    // MARK: nextFireDate

    private func next(_ rule: ScheduleRule, after date: Date) -> Date? {
        Scheduler.nextFireDate(for: rule, after: date, calendar: calendar)
    }

    func testNextFireDateLaterTheSameDay() {
        XCTAssertEqual(next(rule(), after: date(9, 6, 0)), date(9, 7, 30))
        XCTAssertEqual(next(rule(), after: date(9, 7, 29, 59)), date(9, 7, 30))
    }

    func testNextFireDateIsStrictlyAfter() {
        XCTAssertEqual(next(rule(), after: date(9, 7, 30)), date(10, 7, 30))
        XCTAssertEqual(next(rule(), after: date(9, 7, 30, 1)), date(10, 7, 30))
    }

    func testNextFireDateSkipsTheWeekend() {
        XCTAssertEqual(next(rule(), after: date(13, 7, 30)), date(16, 7, 30), "Friday → Monday")
        XCTAssertEqual(next(rule(), after: date(14, 12, 0)), date(16, 7, 30))
        XCTAssertEqual(next(rule(), after: date(15, 23, 59)), date(16, 7, 30))
    }

    func testNextFireDateForSingleWeekdayWrapsAFullWeek() {
        let sunday = rule([1], 8, 0)
        XCTAssertEqual(next(sunday, after: date(15, 7, 0)), date(15, 8, 0))
        XCTAssertEqual(next(sunday, after: date(15, 8, 0)), date(22, 8, 0))
        XCTAssertEqual(next(sunday, after: date(9, 0, 0)), date(15, 8, 0))
    }

    func testNextFireDateAcrossMonthAndYearBoundaries() {
        // 30 Nov 2026 is a Monday.
        XCTAssertEqual(next(rule([2], 6, 45), after: date(24, 12, 0)), date(30, 6, 45))
        XCTAssertEqual(next(rule([3], 6, 45), after: date(30, 12, 0)), date(1, 6, 45, month: 12))
        // 31 Dec 2026 is a Thursday, 1 Jan 2027 a Friday.
        XCTAssertEqual(
            next(rule([6], 0, 5), after: date(31, 23, 0, month: 12)),
            date(1, 0, 5, month: 1, year: 2027)
        )
    }

    func testNextFireDateWithInvalidWeekdayIsNil() {
        XCTAssertNil(next(rule([9]), after: date(9, 0, 0)))
    }

    // MARK: Model types

    func testRuleDefaultsAndCodableRoundTrip() throws {
        let defaults = ScheduleRule()
        XCTAssertTrue(defaults.isEnabled)
        XCTAssertEqual(defaults.weekdays, [2, 3, 4, 5, 6])
        XCTAssertEqual([defaults.hour, defaults.minute], [7, 30])
        XCTAssertEqual(defaults.action, .topUp)

        let actions: [ScheduleAction] = [.topUp, .setLimit(65), .startDischarge, .returnToNormal, .startCalibration]
        let rules = actions.map { rule([1, 7], 23, 59, enabled: false, action: $0) }
        let decoded = try JSONDecoder().decode([ScheduleRule].self, from: JSONEncoder().encode(rules))
        XCTAssertEqual(decoded, rules)
    }
}
