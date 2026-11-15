import XCTest
@testable import SimmerCore

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("simmer-history-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshot(_ percent: Int) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isPluggedIn: true, temperatureC: 30, voltage: 12, amperage: 1, systemPowerIn: 20)
    }

    func testRecordsAtMostOneSamplePerInterval() {
        let store = HistoryStore(directory: nil)
        XCTAssertTrue(store.record(snapshot(50), limit: 80, at: start))
        XCTAssertFalse(store.record(snapshot(51), limit: 80, at: start.addingTimeInterval(30)))
        XCTAssertTrue(store.record(snapshot(52), limit: nil, at: start.addingTimeInterval(60)))
        let samples = store.samples()
        XCTAssertEqual(samples.map(\.percent), [50, 52])
        XCTAssertEqual(samples.map(\.limit), [80, nil])
        XCTAssertEqual(samples[0].batteryWatts, 12)
        XCTAssertEqual(samples[0].adapterWatts, 20)
    }

    func testDropsSamplesOlderThanTheRetention() {
        let store = HistoryStore(directory: nil, retention: 3600)
        store.record(snapshot(40), limit: 80, at: start)
        store.record(snapshot(41), limit: 80, at: start.addingTimeInterval(1800))
        store.record(snapshot(42), limit: 80, at: start.addingTimeInterval(3700))
        XCTAssertEqual(store.samples().map(\.percent), [41, 42])
    }

    func testSamplesSinceFiltersByDate() {
        let store = HistoryStore(directory: nil)
        for minute in 0..<5 {
            store.record(snapshot(50 + minute), limit: 80, at: start.addingTimeInterval(Double(minute) * 60))
        }
        XCTAssertEqual(store.samples(since: start.addingTimeInterval(170)).map(\.percent), [53, 54])
    }

    func testPersistsAcrossInstances() {
        let first = HistoryStore(directory: directory, saveInterval: 0)
        first.record(snapshot(60), limit: 75, at: start)
        first.record(snapshot(61), limit: 75, at: start.addingTimeInterval(60))
        let second = HistoryStore(directory: directory)
        XCTAssertEqual(second.samples(), first.samples())
    }

    func testFlushWritesPendingSamples() {
        let store = HistoryStore(directory: directory, saveInterval: 3600)
        store.record(snapshot(60), limit: 75, at: start)
        store.record(snapshot(61), limit: 75, at: start.addingTimeInterval(60))
        store.flush()
        XCTAssertEqual(HistoryStore(directory: directory).samples().count, 2)
    }

    func testAClockJumpBackwardsDoesNotBlockRecording() {
        let store = HistoryStore(directory: nil)
        store.record(snapshot(50), limit: 80, at: start.addingTimeInterval(7200))
        XCTAssertTrue(store.record(snapshot(51), limit: 80, at: start))
        XCTAssertEqual(store.samples().map(\.percent), [51])
    }

    func testRemoveAllClearsMemoryAndDisk() {
        let store = HistoryStore(directory: directory, saveInterval: 0)
        store.record(snapshot(60), limit: 75, at: start)
        store.removeAll()
        XCTAssertTrue(store.samples().isEmpty)
        XCTAssertTrue(HistoryStore(directory: directory).samples().isEmpty)
    }

    func testDownsamplingAveragesBucketsAndKeepsOrder() {
        let samples = (0..<1000).map { index in
            HistorySample(date: start.addingTimeInterval(Double(index) * 60), percent: index / 10, temperatureC: 30, batteryWatts: 10)
        }
        let thinned = samples.downsampled(maxPoints: 100)
        XCTAssertLessThanOrEqual(thinned.count, 100)
        XCTAssertEqual(thinned.map(\.date), thinned.map(\.date).sorted())
        XCTAssertEqual(thinned.first?.percent, 0)
        XCTAssertEqual(thinned.last?.percent, 99)
        XCTAssertEqual(thinned.first?.batteryWatts, 10)
        XCTAssertEqual(Array(samples.prefix(50)).downsampled(maxPoints: 100).count, 50, "short series are untouched")
    }

    @MainActor
    func testModelRecordsHistoryOnTick() async {
        let suite = "simmer-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = HistoryStore(directory: nil)
        let model = SimmerModel(
            store: SettingsStore(defaults: defaults),
            readSnapshot: { BatterySnapshot(percent: 64, isPluggedIn: true) },
            makeController: { _, _ in DryRunChargeController() },
            history: history
        )
        await model.tick(now: start)
        await model.tick(now: start.addingTimeInterval(5))
        XCTAssertEqual(history.samples().map(\.percent), [64])
        XCTAssertEqual(history.samples().first?.limit, 80)
        XCTAssertEqual(model.historyRevision, 1)
    }
}
