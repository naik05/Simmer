import XCTest
@testable import SimmerCore

final class ChargeEngineCalibrationTests: XCTestCase {
    private let config = engineConfig(limit: 80, buffer: 5)

    /// Starts a calibration at `percent` and returns the simulation before its first tick.
    private func started(at percent: Int = 60) -> EngineSimulation {
        var sim = EngineSimulation(config: config)
        sim.tick(percent)
        sim.engine.startCalibration(currentPercent: percent)
        return sim
    }

    /// Runs the simulation up to (and including) the first tick of `phase`.
    private func advanced(to phase: CalibrationPhase) -> EngineSimulation {
        var sim = started()
        if phase == .chargeToFull {
            sim.tick(61)
            return sim
        }
        sim.sweep(61...100)
        if phase == .dischargeToLow { return sim }
        sim.sweep(stride(from: 99, through: 15, by: -1))
        if phase == .rest { return sim }
        sim.tick(15, after: 3600)
        return sim
    }

    // MARK: Full run

    func testFullFourPhaseRun() {
        var sim = started(at: 60)
        XCTAssertEqual(sim.engine.state.mode, .calibration(.chargeToFull))
        XCTAssertEqual(sim.engine.state.calibrationStartPercent, 60)

        // Phase 1: charge to 100 %, ignoring the limit.
        for output in sim.sweep(60...99) {
            assertOutput(output, charging: true, adapter: true, activity: .charging, events: [])
            XCTAssertEqual(output.command.hold, ChargeBand(upper: 100, lower: 100))
        }

        // Phase 2: discharge to 15 % with the adapter disconnected.
        let full = sim.tick(100)
        assertOutput(full, charging: false, adapter: false, activity: .discharging,
                     events: [.calibrationPhaseChanged(.dischargeToLow)])
        XCTAssertEqual(full.command.hold, ChargeBand(upper: 15, lower: 10))
        for output in sim.sweep(stride(from: 99, through: 16, by: -1)) {
            assertOutput(output, charging: false, adapter: false, activity: .discharging, events: [])
        }

        // Phase 3: rest for one hour, adapter connected, not charging.
        let low = sim.tick(15)
        let restStart = sim.now
        assertOutput(low, charging: false, adapter: true, activity: .resting,
                     events: [.calibrationPhaseChanged(.rest)])
        XCTAssertEqual(low.command.hold, ChargeBand(upper: 15, lower: 10))
        XCTAssertEqual(sim.engine.state.restStartedAt, restStart)

        assertOutput(sim.tick(15, after: 1800), charging: false, adapter: true, activity: .resting, events: [])
        assertOutput(sim.tick(15, after: 1799), charging: false, adapter: true, activity: .resting, events: [])
        XCTAssertEqual(sim.engine.state.restStartedAt, restStart, "the rest timer is not restarted")

        // Phase 4: recharge to the limit.
        let rested = sim.tick(15, after: 1)
        XCTAssertEqual(sim.now.timeIntervalSince(restStart), 3600)
        assertOutput(rested, charging: true, adapter: true, activity: .charging,
                     events: [.calibrationPhaseChanged(.rechargeToLimit)])
        XCTAssertEqual(rested.command.hold, ChargeBand(upper: 80, lower: 75))
        for output in sim.sweep(16...79) {
            assertOutput(output, charging: true, adapter: true, activity: .charging, events: [])
        }

        // Finished: back in the limiter, holding.
        let done = sim.tick(80)
        assertOutput(done, charging: false, adapter: true, activity: .holding, events: [.calibrationFinished])
        XCTAssertEqual(sim.engine.state.mode, .normal)
        XCTAssertTrue(sim.engine.state.isHolding)
        XCTAssertNil(sim.engine.state.restStartedAt)
        XCTAssertNil(sim.engine.state.calibrationStartPercent)
        assertOutput(sim.tick(79), charging: false, adapter: true, activity: .holding, events: [])

        XCTAssertEqual(sim.events, [
            .calibrationPhaseChanged(.dischargeToLow),
            .calibrationPhaseChanged(.rest),
            .calibrationPhaseChanged(.rechargeToLimit),
            .calibrationFinished,
        ])
    }

    func testStartingAtFullSkipsStraightToDischarge() {
        var sim = started(at: 100)
        assertOutput(sim.tick(100), charging: false, adapter: false, activity: .discharging,
                     events: [.calibrationPhaseChanged(.dischargeToLow)])
    }

    func testFullyChargedFlagEndsTheChargePhase() {
        var sim = started(at: 90)
        assertOutput(sim.tick(99, full: true), charging: false, adapter: false, activity: .discharging,
                     events: [.calibrationPhaseChanged(.dischargeToLow)])
    }

    func testRestUsesTheInjectedClockOnly() {
        var sim = advanced(to: .rest)
        // Many ticks without the clock reaching one hour: still resting.
        for _ in 0..<100 {
            assertOutput(sim.tick(15, after: 30), charging: false, activity: .resting, events: [])
        }
        XCTAssertEqual(sim.engine.state.mode, .calibration(.rest))
        XCTAssertEqual(sim.tick(15, after: 600).events, [.calibrationPhaseChanged(.rechargeToLimit)])
    }

    func testCustomLowPercentAndRestDuration() {
        var sim = EngineSimulation(config: engineConfig(limit: 70, buffer: 5) {
            $0.calibrationLowPercent = 30
            $0.calibrationRestDuration = 120
        })
        sim.engine.startCalibration(currentPercent: 100)
        let discharging = sim.tick(100)
        XCTAssertEqual(discharging.command.hold, ChargeBand(upper: 30, lower: 10))
        assertOutput(sim.tick(31), charging: false, adapter: false, activity: .discharging)
        assertOutput(sim.tick(30), charging: false, adapter: true, activity: .resting)
        assertOutput(sim.tick(30, after: 119), charging: false, adapter: true, activity: .resting)
        assertOutput(sim.tick(30, after: 1), charging: true, adapter: true, activity: .charging)
        XCTAssertEqual(sim.tick(70).events, [.calibrationFinished])
    }

    func testZeroRestDurationSkipsTheRest() {
        var sim = EngineSimulation(config: engineConfig { $0.calibrationRestDuration = 0 })
        sim.engine.startCalibration(currentPercent: 100)
        sim.tick(100)
        let output = sim.tick(15)
        assertOutput(output, charging: true, adapter: true, activity: .charging, events: [
            .calibrationPhaseChanged(.rest), .calibrationPhaseChanged(.rechargeToLimit),
        ])
    }

    // MARK: Progress

    func testProgressIsNilOutsideCalibration() {
        var sim = EngineSimulation(config: config)
        XCTAssertNil(sim.progress)
        sim.tick(50)
        XCTAssertNil(sim.progress)
        sim.engine.startTopUp()
        sim.tick(60)
        XCTAssertNil(sim.progress)
        sim.engine.startDischarge()
        sim.tick(90)
        XCTAssertNil(sim.progress)
    }

    func testProgressRunsMonotonicallyFromZeroToOne() throws {
        var sim = started(at: 60)
        var samples: [Double] = [try XCTUnwrap(sim.progress)]
        XCTAssertEqual(samples[0], 0)

        func step(_ percent: Int, after seconds: TimeInterval = 30) throws {
            sim.tick(percent, after: seconds)
            if let progress = sim.progress { samples.append(progress) }
        }

        for percent in 61...100 { try step(percent) }
        XCTAssertEqual(try XCTUnwrap(sim.progress), 0.25, accuracy: 1e-9)
        for percent in stride(from: 99, through: 15, by: -1) { try step(percent) }
        XCTAssertEqual(try XCTUnwrap(sim.progress), 0.5, accuracy: 1e-9)
        try step(15, after: 1800)
        XCTAssertEqual(try XCTUnwrap(sim.progress), 0.625, accuracy: 1e-9)
        try step(15, after: 1800)
        XCTAssertEqual(try XCTUnwrap(sim.progress), 0.75, accuracy: 1e-9)
        for percent in 16...79 { try step(percent) }

        XCTAssertEqual(samples, samples.sorted(), "progress must never go backwards")
        XCTAssertTrue(samples.allSatisfy { (0...1).contains($0) })
        XCTAssertGreaterThan(try XCTUnwrap(samples.last), 0.99)

        // The moment the limit is reached progress is exactly 1 …
        let atLimit = sim.engine.calibrationProgress(snapshot: snapshot(80), config: config, now: sim.now)
        XCTAssertEqual(atLimit, 1)
        // … and once the engine processed that reading the calibration is over.
        sim.tick(80)
        XCTAssertNil(sim.progress)
    }

    func testProgressStaysInRangeForOddReadings() throws {
        var state = EngineState()
        state.mode = .calibration(.rechargeToLimit)
        let engine = ChargeEngine(state: state)
        // Battery sagged below the low mark during the rest.
        XCTAssertEqual(engine.calibrationProgress(snapshot: snapshot(12), config: config, now: referenceDate), 0.75)

        state.mode = .calibration(.chargeToFull)
        state.calibrationStartPercent = 100
        XCTAssertEqual(
            ChargeEngine(state: state).calibrationProgress(snapshot: snapshot(100), config: config, now: referenceDate),
            0.25
        )
    }

    // MARK: Cancel

    func testCancelInEveryPhaseReturnsToTheLimiter() {
        for phase in CalibrationPhase.allCases {
            var sim = advanced(to: phase)
            XCTAssertEqual(sim.engine.state.mode, .calibration(phase), "setup for \(phase)")
            XCTAssertNotNil(sim.progress)
            let percent = sim.percent

            sim.engine.returnToNormal()
            XCTAssertEqual(sim.engine.state.mode, .normal)
            XCTAssertNil(sim.engine.state.restStartedAt)
            XCTAssertNil(sim.engine.state.calibrationStartPercent)
            XCTAssertNil(sim.progress)

            let output = sim.tick(percent)
            XCTAssertTrue(output.command.adapterConnected, "\(phase)")
            XCTAssertEqual(output.command.hold, ChargeBand(upper: 80, lower: 75), "\(phase)")
            XCTAssertEqual(output.command.chargingAllowed, percent < 80, "\(phase)")
            XCTAssertEqual(output.activity, percent < 80 ? .charging : .holding, "\(phase)")
            XCTAssertFalse(sim.events.contains(.calibrationFinished), "\(phase)")
            XCTAssertEqual(sim.engine.state.mode, .normal)
        }
    }

    func testRestartingCalibrationResetsTheRestTimer() {
        var sim = advanced(to: .rest)
        XCTAssertNotNil(sim.engine.state.restStartedAt)
        sim.engine.startCalibration(currentPercent: 15)
        XCTAssertNil(sim.engine.state.restStartedAt)
        XCTAssertEqual(sim.engine.state.mode, .calibration(.chargeToFull))
        XCTAssertEqual(sim.progress, 0)
    }

    // MARK: Persistence

    func testStateSurvivesCodableRoundTripMidRest() throws {
        var sim = advanced(to: .rest)
        sim.tick(15, after: 1200)
        let restStart = try XCTUnwrap(sim.engine.state.restStartedAt)

        let data = try JSONEncoder().encode(sim.engine.state)
        let restored = try JSONDecoder().decode(EngineState.self, from: data)
        XCTAssertEqual(restored, sim.engine.state)
        XCTAssertEqual(restored.mode, .calibration(.rest))

        // "Relaunch": a fresh engine continues where the old one stopped.
        var relaunched = EngineSimulation(config: config, state: restored)
        relaunched.now = sim.now
        XCTAssertEqual(try XCTUnwrap(relaunched.progress), try XCTUnwrap(sim.progress), accuracy: 1e-9)

        let remaining = 3600 - relaunched.now.timeIntervalSince(restStart)
        assertOutput(relaunched.tick(15, after: remaining - 1), charging: false, activity: .resting, events: [])
        assertOutput(relaunched.tick(15, after: 1), charging: true, activity: .charging,
                     events: [.calibrationPhaseChanged(.rechargeToLimit)])
        relaunched.sweep(16...79)
        XCTAssertEqual(relaunched.tick(80).events, [.calibrationFinished])
        XCTAssertEqual(relaunched.engine.state.mode, .normal)
    }

    func testEveryModeRoundTripsThroughCodable() throws {
        let modes: [EngineMode] = [.normal, .discharge, .topUp] + CalibrationPhase.allCases.map(EngineMode.calibration)
        for mode in modes {
            var state = EngineState()
            state.mode = mode
            state.isHolding = true
            state.isHeatPaused = true
            state.calibrationStartPercent = 42
            let decoded = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(decoded, state)
        }
    }
}
