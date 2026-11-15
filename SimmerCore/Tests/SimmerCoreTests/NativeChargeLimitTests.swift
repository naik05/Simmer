import XCTest
@testable import SimmerCore

private final class FakeStore: NativeLimitStore, @unchecked Sendable {
    var values: [String: Int] = [:]
    var commits = 0
    var commitError: NativeLimitError?

    func value(for key: String) -> Int? { values[key] }
    func set(_ value: Int?, for key: String) { values[key] = value }
    func commit() throws {
        if let commitError { throw commitError }
        commits += 1
    }
}

private final class RecordingNativeLimit: NativeLimitControlling, @unchecked Sendable {
    var calls: [String] = []
    func setLimit(_ percent: Int) throws { calls.append("set \(percent)") }
    func disable() throws { calls.append("disable") }
    func restoreOriginal() throws { calls.append("restore") }
}

private final class Percent: @unchecked Sendable {
    var value: Int?
    init(_ value: Int?) { self.value = value }
}

final class NativeChargeLimitTests: XCTestCase {
    private var backupURL: URL!

    override func setUp() {
        backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-native-\(UUID().uuidString)/original.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: backupURL.deletingLastPathComponent())
    }

    // MARK: Preference handling

    func testSetLimitWritesFeatureAndTargetAndCommitsOnce() throws {
        let store = FakeStore()
        let limit = NativeChargeLimit(store: store, backupURL: backupURL)
        try limit.setLimit(70)
        XCTAssertEqual(store.values, ["MCLFeatureState": 1, "mclLimitValue": 70])
        try limit.setLimit(70)
        XCTAssertEqual(store.commits, 1, "an unchanged target is not rewritten")
        try limit.setLimit(71)
        XCTAssertEqual(store.commits, 2)
    }

    func testRejectsOutOfRangeTargets() {
        let limit = NativeChargeLimit(store: FakeStore(), backupURL: backupURL)
        XCTAssertThrowsError(try limit.setLimit(0))
        XCTAssertThrowsError(try limit.setLimit(100))
    }

    func testRestorePutsBackTheUsersOwnSetting() throws {
        let store = FakeStore()
        store.values = ["MCLFeatureState": 1, "mclLimitValue": 80]
        let limit = NativeChargeLimit(store: store, backupURL: backupURL)
        try limit.setLimit(55)
        try limit.disable()
        XCTAssertEqual(store.values["MCLFeatureState"], 0)
        try limit.restoreOriginal()
        XCTAssertEqual(store.values, ["MCLFeatureState": 1, "mclLimitValue": 80])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testRestoreRemovesKeysThatDidNotExistBefore() throws {
        let store = FakeStore()
        let limit = NativeChargeLimit(store: store, backupURL: backupURL)
        try limit.setLimit(60)
        try limit.restoreOriginal()
        XCTAssertTrue(store.values.isEmpty)
    }

    func testRestoreIsANoOpWhenSimmerNeverChangedTheSetting() throws {
        let store = FakeStore()
        store.values = ["MCLFeatureState": 1, "mclLimitValue": 80]
        try NativeChargeLimit(store: store, backupURL: backupURL).restoreOriginal()
        XCTAssertEqual(store.commits, 0)
    }

    func testBackupSurvivesAHelperRestart() throws {
        let store = FakeStore()
        store.values = ["MCLFeatureState": 1, "mclLimitValue": 80]
        try NativeChargeLimit(store: store, backupURL: backupURL).setLimit(50)
        // A new instance (helper restarted) must still know the original and not overwrite it.
        let restarted = NativeChargeLimit(store: store, backupURL: backupURL)
        try restarted.setLimit(40)
        try restarted.restoreOriginal()
        XCTAssertEqual(store.values["mclLimitValue"], 80)
    }

    func testCommitFailureIsReported() {
        let store = FakeStore()
        store.commitError = .notRoot
        let limit = NativeChargeLimit(store: store, backupURL: backupURL)
        XCTAssertThrowsError(try limit.setLimit(70)) { XCTAssertEqual($0 as? NativeLimitError, .notRoot) }
    }

    // MARK: Hardware layer

    private func hardware(_ native: RecordingNativeLimit, percent: Percent) -> ChargeHardware {
        ChargeHardware(smc: DryRunSMC.appleSiliconAdapterOnly(), architecture: .appleSilicon, nativeLimit: native) {
            percent.value
        }
    }

    func testNativeLimitIsPreferredOverAdapterCycling() {
        let hardware = hardware(RecordingNativeLimit(), percent: Percent(70))
        XCTAssertEqual(hardware.capabilities.charging, .nativeLimit)
        XCTAssertEqual(hardware.capabilities.hardwareLimit, .nativeLimit)
        XCTAssertEqual(hardware.capabilities.adapter, .chie)
        XCTAssertFalse(hardware.capabilities.holdsByDischarging)
        XCTAssertTrue(hardware.capabilities.limitEnforcedBySystem)
        XCTAssertTrue(hardware.capabilities.canPersistLimit)
    }

    func testUsableSMCKeysStillWinOverTheNativeLimit() {
        let hardware = ChargeHardware(
            smc: DryRunSMC.appleSiliconTahoe(), architecture: .appleSilicon, nativeLimit: RecordingNativeLimit()
        )
        XCTAssertEqual(hardware.capabilities.charging, .chte)
    }

    func testChargingTowardsTheLimitSetsTheSystemLimitToIt() throws {
        let native = RecordingNativeLimit()
        try hardware(native, percent: Percent(60))
            .apply(ChargeCommand(chargingAllowed: true, hold: ChargeBand(upper: 80, lower: 75)))
        XCTAssertEqual(native.calls, ["set 80"])
    }

    func testHoldingPinsTheLimitToTheCurrentLevelWithoutDraining() throws {
        let native = RecordingNativeLimit()
        let percent = Percent(100)
        let hardware = hardware(native, percent: percent)
        let hold = ChargeCommand(chargingAllowed: false, hold: ChargeBand(upper: 80, lower: 75))

        try hardware.apply(hold)
        percent.value = 78
        try hardware.apply(hold)
        percent.value = 4
        try hardware.apply(hold)
        XCTAssertEqual(native.calls, ["set 99", "set 78", "set 10"])
    }

    func testTopUpTurnsTheSystemLimitOff() throws {
        let native = RecordingNativeLimit()
        try hardware(native, percent: Percent(80))
            .apply(ChargeCommand(chargingAllowed: true, hold: ChargeBand(upper: 100, lower: 100)))
        XCTAssertEqual(native.calls, ["disable"])
    }

    func testDischargeCutsTheAdapterAfterPinningTheLimit() throws {
        let native = RecordingNativeLimit()
        let smc = DryRunSMC.appleSiliconAdapterOnly()
        let hardware = ChargeHardware(smc: smc, architecture: .appleSilicon, nativeLimit: native) { 90 }
        try hardware.apply(ChargeCommand(
            chargingAllowed: false, adapterConnected: false, hold: ChargeBand(upper: 80, lower: 75)
        ))
        XCTAssertEqual(native.calls, ["set 90"])
        XCTAssertTrue(hardware.isAdapterDisabled())
    }

    func testResetRestoresTheOriginalSettingOrLeavesAPersistentLimit() throws {
        let native = RecordingNativeLimit()
        let hardware = hardware(native, percent: Percent(80))
        try hardware.resetToDefaults()
        XCTAssertEqual(native.calls, ["restore"])

        native.calls.removeAll()
        try hardware.resetToDefaults(persisting: ChargeBand(upper: 80, lower: 75))
        XCTAssertEqual(native.calls, ["set 80"])
    }
}
