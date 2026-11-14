import XCTest
@testable import SimmerCore

/// Sailing Mode / plain limiter (`EngineMode.normal`).
final class ChargeEngineLimiterTests: XCTestCase {
    private let band = ChargeBand(upper: 80, lower: 75)

    func testChargesBelowTheLimit() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        for output in sim.sweep(50...79) {
            assertOutput(output, charging: true, activity: .charging, events: [])
            XCTAssertEqual(output.command.hold, band)
            XCTAssertEqual(output.command.led, .system)
        }
        XCTAssertFalse(sim.engine.state.isHolding)
        XCTAssertEqual(sim.engine.state.mode, .normal)
    }

    func testStopsExactlyAtTheLimitAndReportsItOnce() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        assertOutput(sim.tick(79), charging: true, activity: .charging, events: [])

        let reached = sim.tick(80)
        assertOutput(reached, charging: false, activity: .holding, events: [.limitReached(80)])
        XCTAssertEqual(reached.command.hold, band)
        XCTAssertTrue(sim.engine.state.isHolding)

        for _ in 0..<5 {
            assertOutput(sim.tick(80), charging: false, activity: .holding, events: [])
        }
        XCTAssertEqual(sim.events, [.limitReached(80)])
    }

    func testOvershootAboveTheLimitAlsoHolds() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        assertOutput(sim.tick(93), charging: false, activity: .holding, events: [.limitReached(80)])
        assertOutput(sim.tick(92), charging: false, activity: .holding, events: [])
    }

    func testKeepsHoldingBetweenResumeLevelAndLimit() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(80)
        for output in sim.sweep([79, 78, 77, 76]) {
            assertOutput(output, charging: false, activity: .holding, events: [])
            XCTAssertEqual(output.command.hold, band)
        }
    }

    func testResumesAtTheResumeLevelAndChargesBackToTheLimit() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.sweep([80, 79, 78, 77, 76])

        assertOutput(sim.tick(75), charging: true, activity: .charging, events: [])
        XCTAssertFalse(sim.engine.state.isHolding)

        // Once charging resumed it continues through the sailing band up to the limit.
        for output in sim.sweep(76...79) {
            assertOutput(output, charging: true, activity: .charging, events: [])
        }
        assertOutput(sim.tick(80), charging: false, activity: .holding, events: [.limitReached(80)])
        XCTAssertEqual(sim.events, [.limitReached(80), .limitReached(80)])
    }

    func testResumesWhenDroppingBelowTheResumeLevelInOneStep() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(80)
        assertOutput(sim.tick(60), charging: true, activity: .charging, events: [])
    }

    func testBufferZeroBehavesAsPlainLimit() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 0))
        let reached = sim.tick(80)
        assertOutput(reached, charging: false, activity: .holding, events: [.limitReached(80)])
        XCTAssertEqual(reached.command.hold, ChargeBand(upper: 80, lower: 80))

        assertOutput(sim.tick(79), charging: true, activity: .charging, events: [])
        assertOutput(sim.tick(80), charging: false, activity: .holding, events: [.limitReached(80)])
    }

    // MARK: Unplug / replug

    func testReplugBelowTheLimitRechargesToTheLimit() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(80)
        assertOutput(sim.tick(79), charging: false, activity: .holding)

        sim.plugged = false
        let unplugged = sim.tick(78)
        assertOutput(unplugged, charging: true, activity: .onBattery, events: [])
        XCTAssertFalse(sim.engine.state.isHolding)

        sim.plugged = true
        assertOutput(sim.tick(78), charging: true, activity: .charging, events: [])
        assertOutput(sim.tick(79), charging: true, activity: .charging, events: [])
        assertOutput(sim.tick(80), charging: false, activity: .holding, events: [.limitReached(80)])
    }

    func testUnplugAtOrAboveTheLimitKeepsHolding() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(81)

        sim.plugged = false
        assertOutput(sim.tick(81), charging: false, activity: .onBattery, events: [])
        assertOutput(sim.tick(80), charging: false, activity: .onBattery, events: [])

        sim.plugged = true
        assertOutput(sim.tick(80), charging: false, activity: .holding, events: [])
        XCTAssertEqual(sim.events, [.limitReached(80)])
    }

    func testOnBatteryNeverDisconnectsTheAdapter() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.plugged = false
        for output in sim.sweep([90, 80, 60, 30]) {
            XCTAssertTrue(output.command.adapterConnected)
            XCTAssertEqual(output.activity, .onBattery)
            XCTAssertEqual(output.events, [])
        }
    }

    // MARK: Changing the limit

    func testLoweringTheLimitMidHoldKeepsHoldingWithTheNewBand() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(80)

        sim.config.limit = 60
        let lowered = sim.tick(80)
        assertOutput(lowered, charging: false, activity: .holding, events: [])
        XCTAssertEqual(lowered.command.hold, ChargeBand(upper: 60, lower: 55))

        // Sails all the way down to the new resume level before charging again.
        for output in sim.sweep(stride(from: 79, through: 56, by: -1)) {
            assertOutput(output, charging: false, activity: .holding, events: [])
        }
        assertOutput(sim.tick(55), charging: true, activity: .charging, events: [])
        sim.sweep(56...59)
        assertOutput(sim.tick(60), charging: false, activity: .holding, events: [.limitReached(60)])
    }

    func testLoweringTheLimitWhileChargingStopsImmediately() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        assertOutput(sim.tick(70), charging: true, activity: .charging)
        sim.config.limit = 60
        assertOutput(sim.tick(70), charging: false, activity: .holding, events: [.limitReached(60)])
    }

    func testRaisingTheLimitMidHoldResumesCharging() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(80)

        sim.config.limit = 90
        let raised = sim.tick(80)
        assertOutput(raised, charging: true, activity: .charging, events: [])
        XCTAssertEqual(raised.command.hold, ChargeBand(upper: 90, lower: 85))

        for output in sim.sweep(81...89) {
            assertOutput(output, charging: true, activity: .charging, events: [])
        }
        assertOutput(sim.tick(90), charging: false, activity: .holding, events: [.limitReached(90)])
    }

    // MARK: Limit 100

    func testLimit100ChargesAllTheWay() {
        var sim = EngineSimulation(config: engineConfig(limit: 100, buffer: 5))
        for output in sim.sweep(90...99) {
            assertOutput(output, charging: true, activity: .charging, events: [])
            XCTAssertEqual(output.command.hold, ChargeBand(upper: 100, lower: 95))
        }
        let full = sim.tick(100)
        XCTAssertEqual(full.events, [.limitReached(100)])
        XCTAssertTrue(full.command.adapterConnected)
        XCTAssertEqual(sim.tick(100).events, [])
    }

    // MARK: Sanitizing

    func testSanitizedClampsEveryField() {
        var config = EngineConfig()
        config.limit = 5
        config.sailingBuffer = -3
        config.heatThresholdC = 10
        config.heatHysteresisC = 0
        config.calibrationLowPercent = 1
        config.calibrationRestDuration = -60
        var clean = config.sanitized()
        XCTAssertEqual(clean.limit, 20)
        XCTAssertEqual(clean.sailingBuffer, 0)
        XCTAssertEqual(clean.heatThresholdC, 25)
        XCTAssertEqual(clean.heatHysteresisC, 0.5)
        XCTAssertEqual(clean.calibrationLowPercent, 5)
        XCTAssertEqual(clean.calibrationRestDuration, 0)

        config.limit = 150
        config.sailingBuffer = 50
        config.heatThresholdC = 90
        config.heatHysteresisC = 40
        config.calibrationLowPercent = 80
        clean = config.sanitized()
        XCTAssertEqual(clean.limit, 100)
        XCTAssertEqual(clean.sailingBuffer, 30)
        XCTAssertEqual(clean.heatThresholdC, 50)
        XCTAssertEqual(clean.heatHysteresisC, 10)
        XCTAssertEqual(clean.calibrationLowPercent, 50)
    }

    func testDefaultsAreAlreadySane() {
        let defaults = EngineConfig()
        XCTAssertEqual(defaults.sanitized(), defaults)
        XCTAssertEqual(defaults.limit, 80)
        XCTAssertEqual(defaults.sailingBuffer, 5)
        XCTAssertEqual(defaults.heatThresholdC, 35)
        XCTAssertEqual(defaults.heatHysteresisC, 2)
        XCTAssertEqual(defaults.calibrationLowPercent, 15)
        XCTAssertEqual(defaults.calibrationRestDuration, 3600)
        XCTAssertEqual(EngineConfig.limitRange, 20...100)
        XCTAssertEqual(EngineConfig.bufferRange, 0...30)
    }

    func testEffectiveLimitResumeLevelAndHoldBand() {
        XCTAssertEqual(engineConfig(limit: 80, buffer: 5).holdBand, ChargeBand(upper: 80, lower: 75))
        XCTAssertEqual(engineConfig(limit: 19, buffer: 0).effectiveLimit, 20)
        XCTAssertEqual(engineConfig(limit: 101, buffer: 0).effectiveLimit, 100)
        XCTAssertEqual(engineConfig(limit: 80, buffer: 99).resumeLevel, 50, "buffer is clamped to 30")
        XCTAssertEqual(engineConfig(limit: 80, buffer: -5).resumeLevel, 80, "negative buffer counts as 0")
        XCTAssertEqual(engineConfig(limit: 20, buffer: 30).resumeLevel, 10, "resume level never drops below 10 %")
        XCTAssertEqual(engineConfig(limit: 20, buffer: 30).holdBand, ChargeBand(upper: 20, lower: 10))
    }

    func testEngineClampsAnOutOfRangeLimit() {
        var low = EngineSimulation(config: engineConfig(limit: 5, buffer: 0))
        assertOutput(low.tick(19), charging: true, activity: .charging, events: [])
        let held = low.tick(20)
        assertOutput(held, charging: false, activity: .holding, events: [.limitReached(20)])
        XCTAssertEqual(held.command.hold, ChargeBand(upper: 20, lower: 20))

        var high = EngineSimulation(config: engineConfig(limit: 150, buffer: 0))
        assertOutput(high.tick(99), charging: true, activity: .charging, events: [])
        XCTAssertEqual(high.tick(100).events, [.limitReached(100)])
    }

    func testEngineClampsAnOutOfRangeBuffer() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 60))
        let held = sim.tick(80)
        XCTAssertEqual(held.command.hold, ChargeBand(upper: 80, lower: 50))
        assertOutput(sim.tick(51), charging: false, activity: .holding)
        assertOutput(sim.tick(50), charging: true, activity: .charging)
    }

    func testConfigDecodingSanitizesAndFillsDefaults() throws {
        let json = Data(#"{"limit": 150, "sailingBuffer": -4, "ledMode": "status", "fromTheFuture": 1}"#.utf8)
        let config = try JSONDecoder().decode(EngineConfig.self, from: json)
        XCTAssertEqual(config.limit, 100)
        XCTAssertEqual(config.sailingBuffer, 0)
        XCTAssertEqual(config.ledMode, .status)
        XCTAssertEqual(config.heatThresholdC, 35)
        XCTAssertTrue(config.heatProtectionEnabled)

        XCTAssertEqual(try JSONDecoder().decode(EngineConfig.self, from: Data("{}".utf8)), EngineConfig())
    }

    func testEngineIsDeterministic() {
        var a = EngineSimulation(config: engineConfig(limit: 70, buffer: 10))
        var b = a
        let percents = [50, 69, 70, 71, 65, 61, 60, 64, 70, 70]
        XCTAssertEqual(a.sweep(percents), b.sweep(percents))
        XCTAssertEqual(a.engine, b.engine)
    }
}
