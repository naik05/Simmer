import XCTest
@testable import SimmerCore

final class HealthStoreTests: XCTestCase {
    private var directory: URL!
    private var calendar: Calendar!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("simmer-health-\(UUID().uuidString)")
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshot(max: Int, cycles: Int, design: Int = 6000) -> BatterySnapshot {
        BatterySnapshot(percent: 70, isPluggedIn: true, cycleCount: cycles, designCapacity: design, maxCapacity: max)
    }

    private func day(_ offset: Int) -> Date { start.addingTimeInterval(Double(offset) * 86400) }

    func testKeepsOneRecordPerDayAndTheLatestReadingWins() {
        let store = HealthStore(directory: nil, calendar: calendar)
        XCTAssertTrue(store.record(snapshot(max: 6000, cycles: 4), at: day(0)))
        XCTAssertFalse(store.record(snapshot(max: 6000, cycles: 4), at: day(0).addingTimeInterval(3600)))
        XCTAssertTrue(store.record(snapshot(max: 5990, cycles: 5), at: day(0).addingTimeInterval(7200)))
        XCTAssertTrue(store.record(snapshot(max: 5980, cycles: 5), at: day(1)))
        let records = store.allRecords()
        XCTAssertEqual(records.map(\.maxCapacity), [5990, 5980])
        XCTAssertEqual(records.map(\.cycleCount), [5, 5])
        XCTAssertEqual(records[0].day, calendar.startOfDay(for: day(0)))
    }

    func testIgnoresSnapshotsWithoutCapacityData() {
        let store = HealthStore(directory: nil, calendar: calendar)
        XCTAssertFalse(store.record(snapshot(max: 0, cycles: 4), at: day(0)))
        XCTAssertFalse(store.record(snapshot(max: 6000, cycles: 4, design: 0), at: day(0)))
        XCTAssertTrue(store.allRecords().isEmpty)
    }

    func testHealthIsNotCappedAtOneHundred() {
        XCTAssertEqual(
            HealthRecord(day: start, maxCapacity: 6090, designCapacity: 6000, cycleCount: 1).healthPercent, 101.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(HealthRecord(day: start, maxCapacity: 100, designCapacity: 0, cycleCount: 1).healthPercent, 0)
    }

    func testTrendNeedsTwoDaysAndDerivesRates() {
        let store = HealthStore(directory: nil, calendar: calendar)
        store.record(snapshot(max: 6000, cycles: 10), at: day(0))
        XCTAssertNil(store.trend)

        store.record(snapshot(max: 5940, cycles: 30), at: day(14))
        let trend = store.trend
        XCTAssertEqual(trend?.days, 14)
        XCTAssertEqual(trend?.cyclesAdded, 20)
        XCTAssertEqual(trend?.healthChange ?? 0, -1.0, accuracy: 0.0001)
        XCTAssertEqual(trend?.cyclesPerWeek ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(trend?.wearPer100Cycles ?? 0, 5, accuracy: 0.0001)
    }

    func testRatesAreWithheldUntilThereIsEnoughData() {
        let trend = HealthTrend(days: 3, healthChange: -0.2, cyclesAdded: 2)
        XCTAssertNil(trend.cyclesPerWeek)
        XCTAssertNil(trend.wearPer100Cycles)
    }

    func testPersistsAcrossInstances() {
        let first = HealthStore(directory: directory, calendar: calendar)
        first.record(snapshot(max: 6000, cycles: 4), at: day(0))
        first.record(snapshot(max: 5995, cycles: 6), at: day(3))
        XCTAssertEqual(HealthStore(directory: directory, calendar: calendar).allRecords(), first.allRecords())
        first.removeAll()
        XCTAssertTrue(HealthStore(directory: directory, calendar: calendar).allRecords().isEmpty)
    }

    @MainActor
    func testModelRecordsHealthOnTick() async {
        let suite = "simmer-health-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let health = HealthStore(directory: nil, calendar: calendar)
        let model = SimmerModel(
            store: SettingsStore(defaults: defaults),
            readSnapshot: { BatterySnapshot(percent: 64, isPluggedIn: true, cycleCount: 7, designCapacity: 6000, maxCapacity: 5900) },
            makeController: { _, _ in DryRunChargeController() },
            health: health
        )
        await model.tick(now: start)
        XCTAssertEqual(health.allRecords().map(\.cycleCount), [7])
        XCTAssertEqual(model.healthRevision, 1)
    }
}
