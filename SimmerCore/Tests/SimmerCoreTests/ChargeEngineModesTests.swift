import XCTest
@testable import SimmerCore

/// Discharge, Top Up, Heat Protection and the LED mapping.
final class ChargeEngineModesTests: XCTestCase {
    private let band = ChargeBand(upper: 80, lower: 75)

    // MARK: Discharge

    func testDischargeDrainsToTheLimitThenHolds() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(90)
        sim.engine.startDischarge()
        XCTAssertEqual(sim.engine.state.mode, .discharge)

        for output in sim.sweep(stride(from: 90, through: 81, by: -1)) {
            assertOutput(output, charging: false, adapter: false, activity: .discharging, events: [])
            XCTAssertEqual(output.command.hold, band)
            XCTAssertEqual(sim.engine.state.mode, .discharge)
        }

        let finished = sim.tick(80)
        assertOutput(finished, charging: false, adapter: true, activity: .holding, events: [.dischargeFinished])
        XCTAssertEqual(finished.command.hold, band)
        XCTAssertEqual(sim.engine.state.mode, .normal)
        XCTAssertTrue(sim.engine.state.isHolding)

        // Back in the limiter: sails down, then recharges.
        for output in sim.sweep([80, 79, 76]) {
            assertOutput(output, charging: false, adapter: true, activity: .holding, events: [])
        }
        assertOutput(sim.tick(75), charging: true, adapter: true, activity: .charging, events: [])
        XCTAssertEqual(sim.events, [.limitReached(80), .dischargeFinished])
    }

    func testDischargeFinishesWhenJumpingBelowTheLimit() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.engine.startDischarge()
        assertOutput(sim.tick(85), charging: false, adapter: false, activity: .discharging)
        assertOutput(sim.tick(78), charging: false, adapter: true, activity: .holding, events: [.dischargeFinished])
    }

    func testDischargeStartedBelowTheResumeLevelEndsAtOnceAndCharges() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.engine.startDischarge()
        assertOutput(sim.tick(60), charging: true, adapter: true, activity: .charging, events: [.dischargeFinished])
        XCTAssertEqual(sim.engine.state.mode, .normal)
    }

    func testReturnToNormalCancelsDischarge() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.engine.startDischarge()
        assertOutput(sim.tick(95), charging: false, adapter: false, activity: .discharging)

        sim.engine.returnToNormal()
        XCTAssertEqual(sim.engine.state.mode, .normal)
        let output = sim.tick(94)
        assertOutput(output, charging: false, adapter: true, activity: .holding, events: [.limitReached(80)])
        XCTAssertFalse(sim.events.contains(.dischargeFinished))
    }

    func testHeatDoesNotInterfereWithDischarge() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.engine.startDischarge()
        sim.temperature = 40
        let output = sim.tick(90)
        assertOutput(output, charging: false, adapter: false, activity: .discharging, events: [.heatPauseBegan(40)])
        XCTAssertEqual(output.command.hold, band)
    }

    // MARK: Top Up

    func testTopUpChargesTo100RegardlessOfLimitThenHolds() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(80)
        sim.engine.startTopUp()

        for output in sim.sweep(80...99) {
            assertOutput(output, charging: true, activity: .charging, events: [])
            XCTAssertEqual(output.command.hold, ChargeBand(upper: 100, lower: 100))
            XCTAssertEqual(sim.engine.state.mode, .topUp)
        }

        let finished = sim.tick(100)
        assertOutput(finished, charging: false, activity: .holding, events: [.topUpFinished])
        XCTAssertEqual(finished.command.hold, band, "back to the previous limit")
        XCTAssertEqual(sim.engine.state.mode, .normal)

        // Does not recharge until it sailed down to the resume level.
        for output in sim.sweep(stride(from: 100, through: 76, by: -1)) {
            assertOutput(output, charging: false, activity: .holding, events: [])
        }
        assertOutput(sim.tick(75), charging: true, activity: .charging, events: [])
        XCTAssertEqual(sim.events, [.limitReached(80), .topUpFinished])
    }

    func testTopUpFinishesOnFullyChargedFlag() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.engine.startTopUp()
        assertOutput(sim.tick(98), charging: true, activity: .charging, events: [])
        assertOutput(sim.tick(99, full: true), charging: false, activity: .holding, events: [.topUpFinished])
        XCTAssertEqual(sim.engine.state.mode, .normal)
    }

    func testTopUpFromBelowTheLimitPassesStraightThroughIt() {
        var sim = EngineSimulation(config: engineConfig(limit: 60, buffer: 5))
        sim.engine.startTopUp()
        for output in sim.sweep(40...99) {
            assertOutput(output, charging: true, activity: .charging, events: [])
        }
        XCTAssertEqual(sim.tick(100).events, [.topUpFinished])
    }

    func testTopUpWhileUnpluggedWaitsOnBattery() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.engine.startTopUp()
        sim.plugged = false
        assertOutput(sim.tick(70), charging: true, activity: .onBattery, events: [])
        XCTAssertEqual(sim.engine.state.mode, .topUp)
    }

    func testReturnToNormalCancelsTopUp() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.engine.startTopUp()
        assertOutput(sim.tick(90), charging: true, activity: .charging)

        sim.engine.returnToNormal()
        let output = sim.tick(90)
        assertOutput(output, charging: false, activity: .holding, events: [.limitReached(80)])
        XCTAssertEqual(output.command.hold, band)
        XCTAssertFalse(sim.events.contains(.topUpFinished))
    }

    // MARK: Heat Protection

    func testHeatPausesAtThresholdAndResumesBelowHysteresis() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.temperature = 34.9
        assertOutput(sim.tick(50), charging: true, activity: .charging, events: [])

        sim.temperature = 35.0
        let paused = sim.tick(50)
        assertOutput(paused, charging: false, adapter: true, activity: .heatPaused, events: [.heatPauseBegan(35.0)])
        XCTAssertEqual(paused.command.hold, ChargeBand(upper: 50, lower: 10))
        XCTAssertTrue(sim.engine.state.isHeatPaused)

        // Inside the hysteresis window nothing changes.
        for temperature in [36.5, 35.0, 34.0, 33.1] {
            sim.temperature = temperature
            assertOutput(sim.tick(50), charging: false, adapter: true, activity: .heatPaused, events: [])
        }

        sim.temperature = 33.0
        assertOutput(sim.tick(50), charging: true, activity: .charging, events: [.heatPauseEnded])
        XCTAssertFalse(sim.engine.state.isHeatPaused)

        // Warming up again inside the window does not re-trigger below the threshold.
        sim.temperature = 34.5
        assertOutput(sim.tick(51), charging: true, activity: .charging, events: [])
        XCTAssertEqual(sim.events, [.heatPauseBegan(35.0), .heatPauseEnded])
    }

    func testHeatEventCarriesTheMeasuredTemperature() {
        var sim = EngineSimulation(config: engineConfig())
        sim.temperature = 41.25
        XCTAssertEqual(sim.tick(50).events, [.heatPauseBegan(41.25)])
    }

    func testCustomThresholdAndHysteresis() {
        var sim = EngineSimulation(config: engineConfig { $0.heatThresholdC = 40; $0.heatHysteresisC = 5 })
        sim.temperature = 39.9
        assertOutput(sim.tick(50), charging: true, activity: .charging, events: [])
        sim.temperature = 40
        assertOutput(sim.tick(50), charging: false, activity: .heatPaused, events: [.heatPauseBegan(40)])
        sim.temperature = 35.1
        assertOutput(sim.tick(50), charging: false, activity: .heatPaused, events: [])
        sim.temperature = 35
        assertOutput(sim.tick(50), charging: true, activity: .charging, events: [.heatPauseEnded])
    }

    func testHeatDoesNotTurnAHoldIntoACharge() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(80)

        sim.temperature = 40
        let hot = sim.tick(79)
        assertOutput(hot, charging: false, adapter: true, activity: .holding, events: [.heatPauseBegan(40)])
        XCTAssertEqual(hot.command.hold, band)

        sim.temperature = 30
        let cooled = sim.tick(79)
        assertOutput(cooled, charging: false, adapter: true, activity: .holding, events: [.heatPauseEnded])
        XCTAssertEqual(cooled.command.hold, band)
        XCTAssertTrue(sim.engine.state.isHolding)
    }

    func testHeatPauseAtTheResumeLevelDelaysRecharging() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.tick(80)
        sim.temperature = 38
        assertOutput(sim.tick(75), charging: false, activity: .heatPaused)
        sim.temperature = 30
        assertOutput(sim.tick(75), charging: true, activity: .charging, events: [.heatPauseEnded])
    }

    func testHeatAppliesDuringTopUp() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.engine.startTopUp()
        assertOutput(sim.tick(90), charging: true, activity: .charging)

        sim.temperature = 36
        let paused = sim.tick(91)
        assertOutput(paused, charging: false, adapter: true, activity: .heatPaused, events: [.heatPauseBegan(36)])
        XCTAssertEqual(paused.command.hold, ChargeBand(upper: 91, lower: 10))
        XCTAssertEqual(sim.engine.state.mode, .topUp, "top-up is paused, not cancelled")

        sim.temperature = 32
        let resumed = sim.tick(91)
        assertOutput(resumed, charging: true, activity: .charging, events: [.heatPauseEnded])
        XCTAssertEqual(resumed.command.hold, ChargeBand(upper: 100, lower: 100))
    }

    func testHeatAppliesDuringCalibrationChargePhases() {
        for phase in [CalibrationPhase.chargeToFull, .rechargeToLimit] {
            var state = EngineState()
            state.mode = .calibration(phase)
            state.calibrationStartPercent = 40
            var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5), state: state)

            assertOutput(sim.tick(50), charging: true, activity: .charging, events: [])
            sim.temperature = 37
            assertOutput(sim.tick(50), charging: false, adapter: true, activity: .heatPaused, events: [.heatPauseBegan(37)])
            XCTAssertEqual(sim.engine.state.mode, .calibration(phase))
            sim.temperature = 30
            assertOutput(sim.tick(50), charging: true, activity: .charging, events: [.heatPauseEnded])
        }
    }

    func testHeatNeverDisconnectsTheAdapter() {
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.temperature = 45
        for percent in [30, 60, 79, 80, 95] {
            XCTAssertTrue(sim.tick(percent).command.adapterConnected)
        }
        sim.engine.startTopUp()
        XCTAssertTrue(sim.tick(90).command.adapterConnected)
        sim.engine.startCalibration(currentPercent: 90)
        XCTAssertTrue(sim.tick(90).command.adapterConnected)
    }

    func testHeatProtectionDisabled() {
        var sim = EngineSimulation(config: engineConfig { $0.heatProtectionEnabled = false })
        sim.temperature = 48
        assertOutput(sim.tick(50), charging: true, activity: .charging, events: [])
        XCTAssertFalse(sim.engine.state.isHeatPaused)
    }

    func testDisablingHeatProtectionWhilePausedResumesCharging() {
        var sim = EngineSimulation(config: engineConfig())
        sim.temperature = 40
        assertOutput(sim.tick(50), charging: false, activity: .heatPaused)
        sim.config.heatProtectionEnabled = false
        assertOutput(sim.tick(50), charging: true, activity: .charging, events: [.heatPauseEnded])
    }

    func testUnknownTemperatureNeverPauses() {
        var sim = EngineSimulation(config: engineConfig())
        sim.temperature = nil
        assertOutput(sim.tick(50), charging: true, activity: .charging, events: [])
    }

    func testLosingTheSensorWhilePausedResumesCharging() {
        var sim = EngineSimulation(config: engineConfig())
        sim.temperature = 40
        sim.tick(50)
        sim.temperature = nil
        assertOutput(sim.tick(50), charging: true, activity: .charging, events: [.heatPauseEnded])
    }

    func testHeatPauseWhileUnpluggedReportsOnBattery() {
        var sim = EngineSimulation(config: engineConfig())
        sim.plugged = false
        sim.temperature = 40
        assertOutput(sim.tick(50), charging: false, adapter: true, activity: .onBattery, events: [.heatPauseBegan(40)])
    }

    // MARK: LED mapping

    /// One engine output per reachable activity.
    private func outputsByActivity(ledMode: LEDMode) -> [ChargeActivity: EngineOutput] {
        let config = engineConfig(limit: 80, buffer: 5) { $0.ledMode = ledMode }
        var result: [ChargeActivity: EngineOutput] = [:]
        func record(_ output: EngineOutput) { result[output.activity] = output }

        var normal = EngineSimulation(config: config)
        record(normal.tick(50))                     // charging
        record(normal.tick(50, full: true))         // full
        record(normal.tick(80))                     // holding
        normal.plugged = false
        record(normal.tick(70))                     // onBattery

        var hot = EngineSimulation(config: config)
        hot.temperature = 40
        record(hot.tick(50))                        // heatPaused

        var discharge = EngineSimulation(config: config)
        discharge.engine.startDischarge()
        record(discharge.tick(95))                  // discharging

        var restState = EngineState()
        restState.mode = .calibration(.rest)
        var rest = EngineSimulation(config: config, state: restState)
        record(rest.tick(15))                       // resting
        return result
    }

    func testEveryActivityIsReachable() {
        let activities = Set(outputsByActivity(ledMode: .status).keys)
        XCTAssertEqual(activities, [.charging, .full, .holding, .onBattery, .heatPaused, .discharging, .resting])
    }

    func testStatusLEDMapping() {
        let leds = outputsByActivity(ledMode: .status).mapValues(\.command.led)
        XCTAssertEqual(leds, [
            .charging: .orange,
            .full: .green,
            .holding: .green,
            .resting: .green,
            .discharging: .off,
            .onBattery: .off,
            .heatPaused: .blinkSlow,
        ])
    }

    func testSystemLEDModeLeavesTheLEDToMacOS() {
        for (activity, output) in outputsByActivity(ledMode: .system) {
            XCTAssertEqual(output.command.led, .system, "\(activity)")
        }
    }

    func testOffLEDModeIsAlwaysOff() {
        for (activity, output) in outputsByActivity(ledMode: .off) {
            XCTAssertEqual(output.command.led, .off, "\(activity)")
        }
    }
}
