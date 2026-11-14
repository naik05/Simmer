import Foundation

public enum ScheduleAction: Codable, Sendable, Equatable, Hashable {
    case topUp
    case setLimit(Int)
    case startDischarge
    /// Ends top-up/discharge and returns to the normal limiter.
    case returnToNormal
    case startCalibration
}

/// A weekly, time-based automation, e.g. "Mon–Fri 07:30 → Top Up".
public struct ScheduleRule: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var isEnabled: Bool
    /// `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    public var hour: Int
    public var minute: Int
    public var action: ScheduleAction

    public init(
        id: UUID = UUID(), isEnabled: Bool = true, weekdays: Set<Int> = [2, 3, 4, 5, 6],
        hour: Int = 7, minute: Int = 30, action: ScheduleAction = .topUp
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.weekdays = weekdays
        self.hour = hour
        self.minute = minute
        self.action = action
    }
}

public enum Scheduler {
    /// Rules that became due in `(lastCheck, now]`.
    ///
    /// Occurrences older than `grace` are dropped, so waking the Mac at noon does not
    /// replay a 07:30 rule.
    public static func dueRules(
        _ rules: [ScheduleRule], after lastCheck: Date, upTo now: Date,
        calendar: Calendar = .current, grace: TimeInterval = 15 * 60
    ) -> [ScheduleRule] {
        guard now > lastCheck else { return [] }
        let windowStart = max(lastCheck, now.addingTimeInterval(-grace))
        return rules.filter { rule in
            guard rule.isEnabled, !rule.weekdays.isEmpty,
                  let next = nextFireDate(for: rule, after: windowStart, calendar: calendar)
            else { return false }
            return next <= now
        }
    }

    /// The first moment strictly after `date` at which `rule` fires.
    public static func nextFireDate(for rule: ScheduleRule, after date: Date, calendar: Calendar = .current) -> Date? {
        guard !rule.weekdays.isEmpty else { return nil }
        let components = DateComponents(hour: rule.hour, minute: rule.minute, second: 0)
        var cursor = date
        for _ in 0..<8 {
            guard let candidate = calendar.nextDate(after: cursor, matching: components, matchingPolicy: .nextTime)
            else { return nil }
            if rule.weekdays.contains(calendar.component(.weekday, from: candidate)) { return candidate }
            cursor = candidate
        }
        return nil
    }
}
