import Foundation

/// The battery's condition on one day.
public struct HealthRecord: Codable, Sendable, Equatable, Identifiable {
    /// Start of the day the record belongs to.
    public var day: Date
    /// Full-charge capacity in mAh.
    public var maxCapacity: Int
    public var designCapacity: Int
    public var cycleCount: Int

    public var id: Date { day }

    public init(day: Date, maxCapacity: Int, designCapacity: Int, cycleCount: Int) {
        self.day = day
        self.maxCapacity = maxCapacity
        self.designCapacity = designCapacity
        self.cycleCount = cycleCount
    }

    /// Capacity relative to design, not capped: a new battery can read slightly above 100.
    public var healthPercent: Double {
        designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0
    }
}

/// What changed between the first and the latest record.
public struct HealthTrend: Sendable, Equatable {
    public var days: Int
    /// Change in health, in percentage points (negative = wear).
    public var healthChange: Double
    public var cyclesAdded: Int

    /// Average full cycles per week, once there is at least a week of data.
    public var cyclesPerWeek: Double? {
        days >= 7 ? Double(cyclesAdded) / Double(days) * 7 : nil
    }

    /// Health lost per 100 cycles, once enough cycles were added to mean something.
    public var wearPer100Cycles: Double? {
        cyclesAdded >= 10 ? -healthChange / Double(cyclesAdded) * 100 : nil
    }
}

/// Keeps one health record per day, indefinitely (a few KB per year), persisted as JSON.
/// With no directory it works in memory only.
public final class HealthStore: @unchecked Sendable {
    private let fileURL: URL?
    private let calendar: Calendar
    private let lock = NSLock()
    private var records: [HealthRecord]

    public init(directory: URL?, calendar: Calendar = .current) {
        self.calendar = calendar
        fileURL = directory?.appendingPathComponent("health.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? Self.decoder.decode([HealthRecord].self, from: data) {
            records = stored.sorted { $0.day < $1.day }
        } else {
            records = []
        }
    }

    /// Stores today's values. The capacity estimate moves a little during a day; the
    /// latest reading wins. Returns `true` when something changed.
    @discardableResult
    public func record(_ snapshot: BatterySnapshot, at now: Date = Date()) -> Bool {
        guard snapshot.maxCapacity > 0, snapshot.designCapacity > 0 else { return false }
        let record = HealthRecord(
            day: calendar.startOfDay(for: now), maxCapacity: snapshot.maxCapacity,
            designCapacity: snapshot.designCapacity, cycleCount: snapshot.cycleCount
        )
        lock.lock()
        defer { lock.unlock() }
        if let index = records.firstIndex(where: { $0.day == record.day }) {
            guard records[index] != record else { return false }
            records[index] = record
        } else {
            records.append(record)
            records.sort { $0.day < $1.day }
        }
        lockedSave()
        return true
    }

    public func allRecords() -> [HealthRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public var trend: HealthTrend? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = records.first, let last = records.last, first.day != last.day else { return nil }
        let days = calendar.dateComponents([.day], from: first.day, to: last.day).day ?? 0
        return HealthTrend(
            days: days, healthChange: last.healthPercent - first.healthPercent,
            cyclesAdded: last.cycleCount - first.cycleCount
        )
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
        lockedSave()
    }

    private func lockedSave() {
        guard let fileURL, let data = try? Self.encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
