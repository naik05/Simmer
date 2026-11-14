import XCTest
@testable import SimmerCore

final class SettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> SimmerSettings {
        try JSONDecoder().decode(SimmerSettings.self, from: Data(json.utf8))
    }

    private var customized: SimmerSettings {
        var settings = SimmerSettings()
        settings.engine.limit = 65
        settings.engine.sailingBuffer = 10
        settings.engine.heatProtectionEnabled = false
        settings.engine.heatThresholdC = 38.5
        settings.engine.heatHysteresisC = 3
        settings.engine.ledMode = .status
        settings.engine.calibrationLowPercent = 20
        settings.engine.calibrationRestDuration = 1800
        settings.isLimiterEnabled = false
        settings.stopChargingBeforeSleep = false
        settings.keepLimitWhenOff = true
        settings.resetOnQuit = false
        settings.temperatureUnit = .fahrenheit
        settings.menuBarStyle = .watts
        settings.notificationsEnabled = false
        settings.dryRun = true
        settings.schedules = [
            ScheduleRule(weekdays: [2, 4], hour: 6, minute: 5, action: .setLimit(90)),
            ScheduleRule(isEnabled: false, weekdays: [1], hour: 23, minute: 0, action: .startCalibration),
        ]
        return settings
    }

    // MARK: Codable

    func testDefaults() {
        let settings = SimmerSettings()
        XCTAssertEqual(settings.engine, EngineConfig())
        XCTAssertTrue(settings.isLimiterEnabled)
        XCTAssertTrue(settings.stopChargingBeforeSleep)
        XCTAssertFalse(settings.keepLimitWhenOff)
        XCTAssertTrue(settings.resetOnQuit)
        XCTAssertEqual(settings.temperatureUnit, .celsius)
        XCTAssertEqual(settings.menuBarStyle, .ring)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertFalse(settings.dryRun)
        XCTAssertEqual(settings.schedules, [])
    }

    func testCodableRoundTrip() throws {
        let settings = customized
        let decoded = try JSONDecoder().decode(SimmerSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertNotEqual(decoded, SimmerSettings())

        let defaults = try JSONDecoder().decode(SimmerSettings.self, from: JSONEncoder().encode(SimmerSettings()))
        XCTAssertEqual(defaults, SimmerSettings())
    }

    func testEmptyJSONYieldsDefaults() throws {
        XCTAssertEqual(try decode("{}"), SimmerSettings())
    }

    func testMissingKeysKeepTheirDefaults() throws {
        let settings = try decode(#"{"isLimiterEnabled": false, "menuBarStyle": "pot", "engine": {"limit": 70}}"#)
        XCTAssertFalse(settings.isLimiterEnabled)
        XCTAssertEqual(settings.menuBarStyle, .pot)
        XCTAssertEqual(settings.engine.limit, 70)

        var expected = SimmerSettings()
        expected.isLimiterEnabled = false
        expected.menuBarStyle = .pot
        expected.engine.limit = 70
        XCTAssertEqual(settings, expected, "everything else stays at its default")
    }

    func testUnknownKeysAreIgnored() throws {
        let settings = try decode("""
        {
          "resetOnQuit": false,
          "someFutureToggle": true,
          "futureObject": {"a": [1, 2, 3]},
          "engine": {"sailingBuffer": 8, "futureKnob": "x"}
        }
        """)
        var expected = SimmerSettings()
        expected.resetOnQuit = false
        expected.engine.sailingBuffer = 8
        XCTAssertEqual(settings, expected)
    }

    func testDecodedEngineConfigIsSanitized() throws {
        let settings = try decode(#"{"engine": {"limit": 250, "sailingBuffer": 99, "heatThresholdC": 5}}"#)
        XCTAssertEqual(settings.engine.limit, 100)
        XCTAssertEqual(settings.engine.sailingBuffer, 30)
        XCTAssertEqual(settings.engine.heatThresholdC, 25)
    }

    // MARK: Fail-safe policy

    func testDefaultFailSafePolicyResetsWithoutPersistentBand() {
        XCTAssertEqual(SimmerSettings().failSafePolicy, FailSafePolicy(resetOnDisconnect: true, persistentBand: nil))
    }

    func testFailSafePolicyFollowsResetOnQuit() {
        var settings = SimmerSettings()
        settings.resetOnQuit = false
        XCTAssertEqual(settings.failSafePolicy, FailSafePolicy(resetOnDisconnect: false, persistentBand: nil))
    }

    func testKeepLimitWhenOffPersistsTheHoldBand() {
        var settings = SimmerSettings()
        settings.keepLimitWhenOff = true
        settings.engine.limit = 70
        settings.engine.sailingBuffer = 10
        XCTAssertEqual(
            settings.failSafePolicy,
            FailSafePolicy(resetOnDisconnect: true, persistentBand: ChargeBand(upper: 70, lower: 60))
        )
    }

    func testNoPersistentBandWhileTheLimiterIsDisabled() {
        var settings = SimmerSettings()
        settings.keepLimitWhenOff = true
        settings.isLimiterEnabled = false
        XCTAssertNil(settings.failSafePolicy.persistentBand)
    }

    func testPersistentBandUsesTheClampedLimit() {
        var settings = SimmerSettings()
        settings.keepLimitWhenOff = true
        settings.engine.limit = 5
        settings.engine.sailingBuffer = 0
        XCTAssertEqual(settings.failSafePolicy.persistentBand, ChargeBand(upper: 20, lower: 20))
    }

    func testFailSafePolicyCodableRoundTrip() throws {
        for policy in [
            FailSafePolicy(),
            FailSafePolicy(resetOnDisconnect: false, persistentBand: ChargeBand(upper: 80, lower: 75)),
        ] {
            let decoded = try JSONDecoder().decode(FailSafePolicy.self, from: JSONEncoder().encode(policy))
            XCTAssertEqual(decoded, policy)
        }
        XCTAssertEqual(FailSafePolicy(), FailSafePolicy(resetOnDisconnect: true, persistentBand: nil))
    }

    // MARK: SettingsStore

    /// A throwaway defaults suite that is removed again when the test ends.
    private func makeStore() throws -> (store: SettingsStore, defaults: UserDefaults) {
        let defaults = try makeThrowawayDefaults()
        return (SettingsStore(defaults: defaults), defaults)
    }

    func testEmptyStoreLoadsDefaults() throws {
        let (store, _) = try makeStore()
        XCTAssertEqual(store.loadSettings(), SimmerSettings())
        XCTAssertEqual(store.loadEngineState(), EngineState())
    }

    func testStoreRoundTripsSettings() throws {
        let (store, defaults) = try makeStore()
        let settings = customized   // rule ids are random, so build it once
        store.save(settings)
        XCTAssertEqual(store.loadSettings(), settings)
        XCTAssertEqual(SettingsStore(defaults: defaults).loadSettings(), settings, "a second store sees the same data")
        XCTAssertEqual(store.loadEngineState(), EngineState(), "engine state is stored separately")
    }

    func testStoreRoundTripsEngineState() throws {
        let (store, _) = try makeStore()
        var state = EngineState()
        state.mode = .calibration(.rest)
        state.isHolding = true
        state.restStartedAt = referenceDate
        state.calibrationStartPercent = 55
        store.save(state)
        XCTAssertEqual(store.loadEngineState(), state)
        XCTAssertEqual(store.loadSettings(), SimmerSettings())
    }

    func testStoreOverwritesPreviousValues() throws {
        let (store, _) = try makeStore()
        store.save(customized)
        store.save(SimmerSettings())
        XCTAssertEqual(store.loadSettings(), SimmerSettings())
    }

    func testCorruptedDataFallsBackToDefaults() throws {
        let (store, defaults) = try makeStore()
        defaults.set(Data("not json".utf8), forKey: "simmer.settings")
        defaults.set(Data("[1, 2".utf8), forKey: "simmer.engineState")
        XCTAssertEqual(store.loadSettings(), SimmerSettings())
        XCTAssertEqual(store.loadEngineState(), EngineState())
    }

    func testStoreReadsSettingsWrittenByAnOlderVersion() throws {
        let (store, defaults) = try makeStore()
        defaults.set(Data(#"{"engine": {"limit": 60}, "dryRun": true}"#.utf8), forKey: "simmer.settings")
        let settings = store.loadSettings()
        XCTAssertEqual(settings.engine.limit, 60)
        XCTAssertTrue(settings.dryRun)
        XCTAssertTrue(settings.resetOnQuit)
    }
}
