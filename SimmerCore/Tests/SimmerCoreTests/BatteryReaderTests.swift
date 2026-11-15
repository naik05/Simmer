import XCTest
@testable import SimmerCore

final class BatteryReaderTests: XCTestCase {
    /// Shaped like `ioreg -rn AppleSmartBattery` on an Apple Silicon MacBook.
    private var appleSilicon: [String: Any] {
        [
            "CurrentCapacity": 76,
            "MaxCapacity": 100,
            "AppleRawMaxCapacity": 4382,
            "AppleRawCurrentCapacity": 3330,
            "DesignCapacity": 4563,
            "CycleCount": 212,
            "Voltage": 12_345,
            "Amperage": NSNumber(value: Int64(-1234)),
            "Temperature": 3012,
            "ExternalConnected": true,
            "IsCharging": false,
            "FullyCharged": false,
            "TimeRemaining": 187,
            "BatteryData": ["DesignCapacity": 4563, "CycleCount": 212, "StateOfCharge": 76] as [String: Any],
            "AdapterDetails": ["Watts": 96, "Name": "96W USB-C Power Adapter"] as [String: Any],
            "PowerTelemetryData": ["SystemPowerIn": 23_456, "SystemLoad": 21_000] as [String: Any],
        ]
    }

    /// Shaped like an Intel MacBook: capacities in mAh.
    private var intel: [String: Any] {
        [
            "CurrentCapacity": 3000,
            "MaxCapacity": 6000,
            "DesignCapacity": 6500,
            "CycleCount": 480,
            "Voltage": 11_800,
            "Amperage": 2100,
            "Temperature": 3055,
            "ExternalConnected": true,
            "IsCharging": true,
            "FullyCharged": false,
            "TimeRemaining": 65_535,
        ]
    }

    private func read(_ properties: [String: Any], smcTemperature: Double? = nil) throws -> BatterySnapshot {
        try XCTUnwrap(BatteryReader.snapshot(from: properties, smcTemperature: smcTemperature))
    }

    // MARK: Apple Silicon

    func testAppleSiliconSnapshot() throws {
        let snapshot = try read(appleSilicon, smcTemperature: 31.5)
        XCTAssertEqual(snapshot.percent, 76, "CurrentCapacity is already a percentage")
        XCTAssertTrue(snapshot.isPluggedIn)
        XCTAssertFalse(snapshot.isCharging)
        XCTAssertFalse(snapshot.isFullyCharged)
        XCTAssertEqual(snapshot.temperatureC, 31.5, "the SMC sensor wins over the registry value")
        XCTAssertEqual(snapshot.voltage, 12.345, accuracy: 1e-9)
        XCTAssertEqual(snapshot.amperage, -1.234, accuracy: 1e-9)
        XCTAssertEqual(snapshot.batteryWatts, -15.23373, accuracy: 1e-6)
        XCTAssertEqual(snapshot.adapterWatts, 96)
        XCTAssertEqual(try XCTUnwrap(snapshot.systemPowerIn), 23.456, accuracy: 1e-9)
        XCTAssertEqual(snapshot.cycleCount, 212)
        XCTAssertEqual(snapshot.designCapacity, 4563)
        XCTAssertEqual(snapshot.maxCapacity, 4382)
        XCTAssertEqual(snapshot.healthPercent, 96)
        XCTAssertEqual(snapshot.timeRemaining, 187)
    }

    func testCapacitiesFallBackToNestedBatteryData() throws {
        var properties = appleSilicon
        properties["DesignCapacity"] = nil
        properties["AppleRawMaxCapacity"] = nil
        properties["BatteryData"] = ["DesignCapacity": 5000, "AppleRawMaxCapacity": 4500]
        let snapshot = try read(properties)
        XCTAssertEqual(snapshot.designCapacity, 5000)
        XCTAssertEqual(snapshot.maxCapacity, 4500)
        XCTAssertEqual(snapshot.healthPercent, 90)
    }

    func testAppleSiliconWithoutRawCapacityHasUnknownHealth() throws {
        var properties = appleSilicon
        properties["AppleRawMaxCapacity"] = nil
        let snapshot = try read(properties)
        XCTAssertEqual(snapshot.maxCapacity, 0, "MaxCapacity == 100 is a percentage, not mAh")
        XCTAssertNil(snapshot.healthPercent)
    }

    func testUnpluggedHidesAdapterTelemetry() throws {
        var properties = appleSilicon
        properties["ExternalConnected"] = false
        let snapshot = try read(properties)
        XCTAssertFalse(snapshot.isPluggedIn)
        XCTAssertNil(snapshot.adapterWatts)
        XCTAssertNil(snapshot.systemPowerIn)
    }

    func testPluggedWithoutAdapterDetails() throws {
        var properties = appleSilicon
        properties["AdapterDetails"] = nil
        properties["PowerTelemetryData"] = nil
        let snapshot = try read(properties)
        XCTAssertTrue(snapshot.isPluggedIn)
        XCTAssertNil(snapshot.adapterWatts)
        XCTAssertNil(snapshot.systemPowerIn)
    }

    func testChargingAndFullFlags() throws {
        var properties = appleSilicon
        properties["IsCharging"] = true
        properties["FullyCharged"] = true
        properties["CurrentCapacity"] = 100
        let snapshot = try read(properties)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertTrue(snapshot.isFullyCharged)
        XCTAssertEqual(snapshot.percent, 100)
    }

    // MARK: Intel

    func testIntelSnapshotConvertsMilliampHoursToPercent() throws {
        let snapshot = try read(intel, smcTemperature: 29.75)
        XCTAssertEqual(snapshot.percent, 50)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertEqual(snapshot.temperatureC, 29.75)
        XCTAssertEqual(snapshot.voltage, 11.8, accuracy: 1e-9)
        XCTAssertEqual(snapshot.amperage, 2.1, accuracy: 1e-9)
        XCTAssertGreaterThan(snapshot.batteryWatts, 0)
        XCTAssertEqual(snapshot.cycleCount, 480)
        XCTAssertEqual(snapshot.designCapacity, 6500)
        XCTAssertEqual(snapshot.maxCapacity, 6000, "MaxCapacity in mAh doubles as the raw capacity")
        XCTAssertEqual(snapshot.healthPercent, 92)
        XCTAssertNil(snapshot.timeRemaining, "65535 means 'still calculating'")
        XCTAssertNil(snapshot.adapterWatts)
    }

    func testIntelPercentIsRoundedAndClamped() throws {
        var properties = intel
        properties["CurrentCapacity"] = 4797
        XCTAssertEqual(try read(properties).percent, 80)   // 79.95 → 80
        properties["CurrentCapacity"] = 6100
        XCTAssertEqual(try read(properties).percent, 100)
        properties["CurrentCapacity"] = 0
        XCTAssertEqual(try read(properties).percent, 0)
    }

    // MARK: Health

    func testHealthIsCappedAt100() throws {
        var properties = intel
        properties["MaxCapacity"] = 6800   // a new battery often exceeds its design capacity
        properties["CurrentCapacity"] = 3400
        let snapshot = try read(properties)
        XCTAssertEqual(snapshot.maxCapacity, 6800)
        XCTAssertEqual(snapshot.healthPercent, 100)
        XCTAssertEqual(snapshot.percent, 50)
    }

    func testHealthRequiresBothCapacities() {
        XCTAssertNil(BatterySnapshot(percent: 50, isPluggedIn: true, designCapacity: 0, maxCapacity: 4000).healthPercent)
        XCTAssertNil(BatterySnapshot(percent: 50, isPluggedIn: true, designCapacity: 5000, maxCapacity: 0).healthPercent)
        XCTAssertEqual(
            BatterySnapshot(percent: 50, isPluggedIn: true, designCapacity: 5000, maxCapacity: 4444).healthPercent, 89
        )
    }

    // MARK: Temperature

    func testTemperatureFallsBackToRegistryCentiDegrees() throws {
        XCTAssertEqual(try read(appleSilicon).temperatureC, 30.12)
        XCTAssertEqual(try read(intel).temperatureC, 30.55)
    }

    func testTemperatureFallsBackToVirtualTemperature() throws {
        var properties = appleSilicon
        properties["Temperature"] = nil
        properties["VirtualTemperature"] = 2871
        XCTAssertEqual(try read(properties).temperatureC, 28.71)
    }

    func testTemperatureIsNilWithoutAnySource() throws {
        var properties = appleSilicon
        properties["Temperature"] = nil
        XCTAssertNil(try read(properties).temperatureC)
    }

    func testFahrenheitConversion() {
        XCTAssertEqual(BatterySnapshot(percent: 50, isPluggedIn: true, temperatureC: 35).temperatureF, 95)
        XCTAssertNil(BatterySnapshot(percent: 50, isPluggedIn: true, temperatureC: nil).temperatureF)
    }

    // MARK: Edge cases

    func testMissingCurrentCapacityYieldsNoSnapshot() {
        XCTAssertNil(BatteryReader.snapshot(from: [:], smcTemperature: 30))
        XCTAssertNil(BatteryReader.snapshot(from: ["MaxCapacity": 100], smcTemperature: nil))
    }

    func testMinimalDictionaryUsesNeutralDefaults() throws {
        let snapshot = try read(["CurrentCapacity": 42])
        XCTAssertEqual(snapshot.percent, 42)
        XCTAssertFalse(snapshot.isPluggedIn)
        XCTAssertFalse(snapshot.isCharging)
        XCTAssertNil(snapshot.temperatureC)
        XCTAssertEqual(snapshot.voltage, 0)
        XCTAssertEqual(snapshot.amperage, 0)
        XCTAssertEqual(snapshot.cycleCount, 0)
        XCTAssertNil(snapshot.healthPercent)
        XCTAssertNil(snapshot.timeRemaining)
    }

    func testTimeRemainingIgnoresPlaceholderValues() throws {
        var properties = appleSilicon
        for placeholder in [0, -1, 65_535] {
            properties["TimeRemaining"] = placeholder
            XCTAssertNil(try read(properties).timeRemaining, "\(placeholder)")
        }
        properties["TimeRemaining"] = 1
        XCTAssertEqual(try read(properties).timeRemaining, 1)
    }

    func testSnapshotCodableRoundTrip() throws {
        let snapshot = try read(appleSilicon, smcTemperature: 31.5)
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testReadFromHardwareDoesNotCrash() {
        let reader = BatteryReader(smc: nil)
        _ = reader.read()
    }
}
