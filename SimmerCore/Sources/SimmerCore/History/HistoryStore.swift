import Foundation

/// One point of the battery history.
public struct HistorySample: Codable, Sendable, Equatable, Identifiable {
    public var date: Date
    public var percent: Int
    public var temperatureC: Double?
    /// Battery power in watts; positive = charging.
    public var batteryWatts: Double
    /// Power drawn from the adapter in watts, when plugged in and reported.
    public var adapterWatts: Double?
    /// The charge limit in effect, `nil` while the limiter was off.
    public var limit: Int?
    public var isPluggedIn: Bool

    public var id: Date { date }

    public init(
        date: Date, percent: Int, temperatureC: Double? = nil, batteryWatts: Double = 0,
        adapterWatts: Double? = nil, limit: Int? = nil, isPluggedIn: Bool = false
    ) {
        self.date = date
        self.percent = percent
        self.temperatureC = temperatureC
        self.batteryWatts = batteryWatts
        self.adapterWatts = adapterWatts
        self.limit = limit
        self.isPluggedIn = isPluggedIn
    }

    // Short keys: a week of minute samples is about ten thousand entries.
    enum CodingKeys: String, CodingKey {
        case date = "t", percent = "p", temperatureC = "c", batteryWatts = "b"
        case adapterWatts = "a", limit = "l", isPluggedIn = "x"
    }
}

/// Keeps a rolling history of battery samples, one per minute for a week, and persists
/// it as JSON. With no directory it works in memory only (tests, previews).
public final class HistoryStore: @unchecked Sendable {
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Simmer", isDirectory: true)
    }

    public let sampleInterval: TimeInterval
    public let retention: TimeInterval

    private let fileURL: URL?
    private let saveInterval: TimeInterval
    private let lock = NSLock()
    private var samples: [HistorySample]
    private var lastSave = Date.distantPast
    private var isDirty = false

    public init(
        directory: URL?, sampleInterval: TimeInterval = 60, retention: TimeInterval = 7 * 24 * 3600,
        saveInterval: TimeInterval = 300
    ) {
        self.sampleInterval = sampleInterval
        self.retention = retention
        self.saveInterval = saveInterval
        fileURL = directory?.appendingPathComponent("history.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? Self.decoder.decode([HistorySample].self, from: data) {
            samples = stored.sorted { $0.date < $1.date }
        } else {
            samples = []
        }
    }

    /// Adds a sample if at least ``sampleInterval`` passed since the previous one.
    /// Returns `true` when a sample was added.
    @discardableResult
    public func record(_ snapshot: BatterySnapshot, limit: Int?, at now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = samples.last {
            // A clock that jumped backwards must not block recording forever.
            let elapsed = now.timeIntervalSince(last.date)
            guard elapsed >= sampleInterval || elapsed < 0 else { return false }
            if elapsed < 0 { samples.removeAll { $0.date > now } }
        }
        samples.append(HistorySample(
            date: now, percent: snapshot.percent, temperatureC: snapshot.temperatureC,
            batteryWatts: snapshot.batteryWatts, adapterWatts: snapshot.systemPowerIn,
            limit: limit, isPluggedIn: snapshot.isPluggedIn
        ))
        let cutoff = now.addingTimeInterval(-retention)
        if let first = samples.first, first.date < cutoff {
            samples.removeAll { $0.date < cutoff }
        }
        isDirty = true
        if now.timeIntervalSince(lastSave) >= saveInterval { lockedSave(now: now) }
        return true
    }

    /// Samples from `start` on, oldest first.
    public func samples(since start: Date = .distantPast) -> [HistorySample] {
        lock.lock()
        defer { lock.unlock() }
        guard start > .distantPast else { return samples }
        return Array(samples.drop { $0.date < start })
    }

    /// Writes pending samples to disk now (call before the app quits).
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        lockedSave(now: Date())
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        isDirty = true
        lockedSave(now: Date())
    }

    private func lockedSave(now: Date) {
        guard isDirty, let fileURL else { return }
        lastSave = now
        guard let data = try? Self.encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if (try? data.write(to: fileURL, options: .atomic)) != nil { isDirty = false }
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

extension Array where Element == HistorySample {
    /// Thins the series to at most `maxPoints` by averaging equal time buckets, so a week
    /// of data stays cheap to draw. Gaps (Mac asleep or off) stay gaps.
    public func downsampled(maxPoints: Int) -> [HistorySample] {
        guard maxPoints > 0, count > maxPoints, let first, let last else { return self }
        let span = last.date.timeIntervalSince(first.date)
        guard span > 0 else { return self }
        let bucketLength = span / Double(maxPoints)
        var buckets: [Int: [HistorySample]] = [:]
        for sample in self {
            let index = Swift.min(Int(sample.date.timeIntervalSince(first.date) / bucketLength), maxPoints - 1)
            buckets[index, default: []].append(sample)
        }
        return buckets.keys.sorted().compactMap { index in
            guard let group = buckets[index], let latest = group.last else { return nil }
            let temperatures = group.compactMap(\.temperatureC)
            let adapter = group.compactMap(\.adapterWatts)
            let count = Double(group.count)
            return HistorySample(
                date: first.date.addingTimeInterval((Double(index) + 0.5) * bucketLength),
                percent: Int((Double(group.reduce(0) { $0 + $1.percent }) / count).rounded()),
                temperatureC: temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count),
                batteryWatts: group.reduce(0) { $0 + $1.batteryWatts } / count,
                adapterWatts: adapter.isEmpty ? nil : adapter.reduce(0, +) / Double(adapter.count),
                limit: latest.limit,
                isPluggedIn: latest.isPluggedIn
            )
        }
    }
}
