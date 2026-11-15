import XCTest
@testable import SimmerCore

final class LimitRaiseTests: XCTestCase {
    func testRaisingTheLimitSlightlyWhileHoldingResumesCharging() {
        var engine = ChargeEngine()
        var config = EngineConfig()
        config.limit = 80
        config.sailingBuffer = 5
        let now = Date(timeIntervalSince1970: 0)
        let atLimit = BatterySnapshot(percent: 80, isPluggedIn: true)

        XCTAssertFalse(engine.tick(snapshot: atLimit, config: config, now: now).command.chargingAllowed)
        XCTAssertEqual(engine.state.holdLimit, 80)

        config.limit = 82
        XCTAssertTrue(engine.tick(snapshot: atLimit, config: config, now: now).command.chargingAllowed)

        // Lowering the limit must not start a charge.
        config.limit = 81
        let atNewLimit = BatterySnapshot(percent: 82, isPluggedIn: true)
        XCTAssertFalse(engine.tick(snapshot: atNewLimit, config: config, now: now).command.chargingAllowed)
    }

    func testUnknownEnumValueKeepsOtherSettings() throws {
        let json = Data(#"{"menuBarStyle":"sparkles","isLimiterEnabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(SimmerSettings.self, from: json)
        XCTAssertEqual(settings.menuBarStyle, .ring)
        XCTAssertFalse(settings.isLimiterEnabled)
    }
}

final class TimeToLimitTests: XCTestCase {
    private func snapshot(percent: Int, amperage: Double, current: Int = 0) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isPluggedIn: true, amperage: amperage, maxCapacity: 6000, currentCapacity: current)
    }

    func testChargingEstimateUsesTheLimitNotFull() {
        // 69 % → 70 % of 6000 mAh is 60 mAh; at 4 A that is under a minute.
        XCTAssertEqual(snapshot(percent: 69, amperage: 4).minutes(toReach: 70), 1)
        // 50 % → 80 % is 1800 mAh; at 3 A that is 36 minutes.
        XCTAssertEqual(snapshot(percent: 50, amperage: 3).minutes(toReach: 80), 36)
    }

    func testRawCapacityRefinesTheEstimate() {
        // 4170 mAh present, target 70 % = 4200 mAh, 30 mAh missing at 0.6 A → 3 minutes.
        XCTAssertEqual(snapshot(percent: 69, amperage: 0.6, current: 4170).minutes(toReach: 70), 3)
    }

    func testDischargingEstimateRunsDownToTheTarget() {
        XCTAssertEqual(snapshot(percent: 90, amperage: -2).minutes(toReach: 80), 18)
    }

    func testNoEstimateWhenNotMovingTowardsTheTarget() {
        XCTAssertNil(snapshot(percent: 80, amperage: 4).minutes(toReach: 70))
        XCTAssertNil(snapshot(percent: 60, amperage: -2).minutes(toReach: 70))
        XCTAssertNil(snapshot(percent: 60, amperage: 0).minutes(toReach: 70))
        XCTAssertNil(BatterySnapshot(percent: 60, isPluggedIn: true, amperage: 3).minutes(toReach: 70))
    }
}
