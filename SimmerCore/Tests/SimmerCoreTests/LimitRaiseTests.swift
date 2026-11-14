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
