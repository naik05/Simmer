import Foundation
import XCTest
@testable import SimmerCore

final class BatterySnapshotTests: XCTestCase {
    func testBatteryWattsCalculation() {
        // Charging: positive amperage -> positive watts
        let charging = BatterySnapshot(percent: 50, isPluggedIn: true, voltage: 12.5, amperage: 2.0)
        XCTAssertEqual(charging.batteryWatts, 25.0, accuracy: 0.001)

        // Discharging: negative amperage -> negative watts
        let discharging = BatterySnapshot(percent: 50, isPluggedIn: false, voltage: 12.0, amperage: -1.5)
        XCTAssertEqual(discharging.batteryWatts, -18.0, accuracy: 0.001)

        // Idle: 0 amperage -> 0 watts
        let idle = BatterySnapshot(percent: 80, isPluggedIn: true, voltage: 12.0, amperage: 0.0)
        XCTAssertEqual(idle.batteryWatts, 0.0, accuracy: 0.001)
    }

    func testHealthPercentCalculation() {
        // Normal health calculation
        let normal = BatterySnapshot(
            percent: 80, isPluggedIn: true,
            designCapacity: 5000, maxCapacity: 4800
        )
        XCTAssertEqual(normal.healthPercent, 96)

        // Capped at 100% when maxCapacity > designCapacity
        let overCapacity = BatterySnapshot(
            percent: 80, isPluggedIn: true,
            designCapacity: 5000, maxCapacity: 5200
        )
        XCTAssertEqual(overCapacity.healthPercent, 100)

        // Nil when designCapacity is 0
        let zeroDesign = BatterySnapshot(
            percent: 80, isPluggedIn: true,
            designCapacity: 0, maxCapacity: 4800
        )
        XCTAssertNil(zeroDesign.healthPercent)

        // Nil when maxCapacity is 0
        let zeroMax = BatterySnapshot(
            percent: 80, isPluggedIn: true,
            designCapacity: 5000, maxCapacity: 0
        )
        XCTAssertNil(zeroMax.healthPercent)

        // Nil when both are negative
        let negative = BatterySnapshot(
            percent: 80, isPluggedIn: true,
            designCapacity: -100, maxCapacity: -100
        )
        XCTAssertNil(negative.healthPercent)
    }

    func testTemperatureConversion() {
        let snapshot = BatterySnapshot(percent: 80, isPluggedIn: true, temperatureC: 30.0)
        XCTAssertEqual(snapshot.temperatureF!, 86.0, accuracy: 0.001)

        let noTemp = BatterySnapshot(percent: 80, isPluggedIn: true, temperatureC: nil)
        XCTAssertNil(noTemp.temperatureF)
    }

    func testDebugSummaryContainsKeyValues() {
        let full = BatterySnapshot(
            percent: 75,
            isPluggedIn: true,
            isCharging: true,
            isFullyCharged: false,
            temperatureC: 32.5,
            voltage: 12.2,
            amperage: 1.8,
            adapterWatts: 67.0,
            systemPowerIn: 45.2,
            cycleCount: 142,
            designCapacity: 6000,
            maxCapacity: 5700,
            timeRemaining: 45
        )
        let summary = full.debugSummary
        XCTAssertTrue(summary.contains("charge:        75 %"))
        XCTAssertTrue(summary.contains("plugged in: true"))
        XCTAssertTrue(summary.contains("charging: true"))
        XCTAssertTrue(summary.contains("32.50 °C"))
        XCTAssertTrue(summary.contains("12.20 V"))
        XCTAssertTrue(summary.contains("1.80 A"))
        XCTAssertTrue(summary.contains("67.00 W rated"))
        XCTAssertTrue(summary.contains("45.20 W in"))
        XCTAssertTrue(summary.contains("cycles:        142"))
        XCTAssertTrue(summary.contains("5700 / 6000 mAh"))
        XCTAssertTrue(summary.contains("95 %"))

        // With nil values, formatting uses "n/a"
        let minimal = BatterySnapshot(
            percent: 50,
            isPluggedIn: false,
            temperatureC: nil,
            voltage: 11.5,
            amperage: -1.0,
            adapterWatts: nil,
            systemPowerIn: nil,
            designCapacity: 0,
            maxCapacity: 0
        )
        let minSummary = minimal.debugSummary
        XCTAssertTrue(minSummary.contains("temperature:   n/a"))
        XCTAssertTrue(minSummary.contains("adapter:       n/a, n/a"))
        XCTAssertTrue(minSummary.contains("health n/a"))
    }

    func testCodableRoundTrip() throws {
        let original = BatterySnapshot(
            percent: 82,
            isPluggedIn: true,
            isCharging: false,
            isFullyCharged: false,
            temperatureC: 28.5,
            voltage: 12.4,
            amperage: 0.1,
            adapterWatts: 96.0,
            systemPowerIn: 15.0,
            cycleCount: 55,
            designCapacity: 6000,
            maxCapacity: 5800,
            timeRemaining: 120
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
