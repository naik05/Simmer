import XCTest
@testable import SimmerCore

/// A `ChargeControlling` fake that records every call. Its async methods are main-actor
/// isolated so a model tick never suspends, which keeps the tests deterministic.
final class RecordingController: ChargeControlling, @unchecked Sendable {
    struct Record: Sendable {
        var handshakes = 0
        var applied: [ChargeCommand] = []
        var policies: [FailSafePolicy] = []
        var resets = 0
        var disconnects = 0
        var handshakeError: (any Error)?
        var applyError: (any Error)?
    }

    static let capabilities = HardwareCapabilities(
        architecture: .appleSilicon, charging: .chte, adapter: .chie, hardwareLimit: .chwa, hasMagSafeLED: true
    )

    private let lock = NSLock()
    private var stored = Record()
    let handshakeValue: HelperHandshake

    init(capabilities: HardwareCapabilities = RecordingController.capabilities, isDryRun: Bool = false) {
        handshakeValue = HelperHandshake(version: "9.9.9", capabilities: capabilities, isDryRun: isDryRun)
    }

    var record: Record { lock.withLock { stored } }

    func update(_ body: (inout Record) -> Void) {
        lock.withLock { body(&stored) }
    }

    @MainActor func handshake() async throws -> HelperHandshake {
        let error = lock.withLock {
            stored.handshakes += 1
            return stored.handshakeError
        }
        if let error { throw error }
        return handshakeValue
    }

    @MainActor func apply(_ command: ChargeCommand) async throws {
        if let error = lock.withLock({ stored.applyError }) { throw error }
        lock.withLock { stored.applied.append(command) }
    }

    @MainActor func configure(_ policy: FailSafePolicy) async throws {
        lock.withLock { stored.policies.append(policy) }
    }

    @MainActor func resetToStock() async throws {
        lock.withLock { stored.resets += 1 }
    }

    func disconnect() {
        lock.withLock { stored.disconnects += 1 }
    }
}

@MainActor
final class BatteryStub {
    var snapshot: BatterySnapshot?
    init(_ snapshot: BatterySnapshot?) { self.snapshot = snapshot }
}

@MainActor
final class SimmerModelTests: XCTestCase {
    private struct Boom: Error {}

    private let t0 = referenceDate

    /// A settings store on a throwaway defaults suite, removed when the test ends.
    private func makeStore(_ customize: (inout SimmerSettings) -> Void = { _ in }) throws -> SettingsStore {
        let store = SettingsStore(defaults: try makeThrowawayDefaults())
        var settings = SimmerSettings()
        customize(&settings)
        if settings != SimmerSettings() { store.save(settings) }
        return store
    }

    private func makeModel(
        store: SettingsStore, battery: BatteryStub, controller: any ChargeControlling
    ) -> SimmerModel {
        SimmerModel(
            store: store, tickInterval: .seconds(3600),
            readSnapshot: { battery.snapshot },
            makeController: { _, _ in controller }
        )
    }

    /// Lets the `refresh()` tasks spawned by actions and settings changes run to completion.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func expectedCommand(
        for reading: BatterySnapshot, settings: SimmerSettings, state: EngineState = EngineState()
    ) -> ChargeCommand {
        var engine = ChargeEngine(state: state)
        return engine.tick(snapshot: reading, config: settings.engine, now: t0).command
    }

    // MARK: Tick

    func testInitialState() throws {
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(50)), controller: RecordingController())
        XCTAssertEqual(model.settings, SimmerSettings())
        XCTAssertEqual(model.connection, .connecting)
        XCTAssertEqual(model.activity, .unmanaged)
        XCTAssertEqual(model.capabilities, .unsupported)
        XCTAssertEqual(model.engineState, EngineState())
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.appliedCommand)
        XCTAssertNil(model.calibrationProgress)
        XCTAssertNil(model.lastError)
    }

    func testTickConnectsAndAppliesTheEngineCommandWhileCharging() async throws {
        let controller = RecordingController()
        let battery = BatteryStub(snapshot(50))
        let model = makeModel(store: try makeStore(), battery: battery, controller: controller)

        await model.tick(now: t0)

        let expected = expectedCommand(for: snapshot(50), settings: model.settings)
        XCTAssertTrue(expected.chargingAllowed)
        XCTAssertEqual(model.appliedCommand, expected)
        XCTAssertEqual(controller.record.applied, [expected])
        XCTAssertEqual(model.connection, .connected(version: "9.9.9"))
        XCTAssertEqual(model.capabilities, RecordingController.capabilities)
        XCTAssertEqual(controller.record.handshakes, 1)
        XCTAssertEqual(controller.record.policies, [model.settings.failSafePolicy])
        XCTAssertEqual(model.snapshot, snapshot(50))
        XCTAssertEqual(model.activity, .charging)
        XCTAssertNil(model.lastError)
        XCTAssertNil(model.calibrationProgress)
    }

    func testTickHoldsAtTheLimitAndReportsTheEvent() async throws {
        let controller = RecordingController()
        let battery = BatteryStub(snapshot(79))
        let model = makeModel(store: try makeStore(), battery: battery, controller: controller)
        var events: [EngineEvent] = []
        model.onEvent = { events.append($0) }

        await model.tick(now: t0)
        XCTAssertEqual(model.activity, .charging)
        XCTAssertEqual(events, [])

        battery.snapshot = snapshot(80)
        await model.tick(now: t0 + 5)

        let hold = ChargeCommand(chargingAllowed: false, adapterConnected: true, led: .system,
                                 hold: ChargeBand(upper: 80, lower: 75))
        XCTAssertEqual(model.appliedCommand, hold)
        XCTAssertEqual(controller.record.applied.last, hold)
        XCTAssertEqual(model.activity, .holding)
        XCTAssertTrue(model.engineState.isHolding)
        XCTAssertEqual(events, [.limitReached(80)])

        await model.tick(now: t0 + 10)
        XCTAssertEqual(events, [.limitReached(80)])
    }

    func testAppliedCommandFollowsTheEngineOverASimulatedCharge() async throws {
        let controller = RecordingController()
        let battery = BatteryStub(snapshot(70))
        let model = makeModel(store: try makeStore { $0.engine.ledMode = .status }, battery: battery, controller: controller)

        var reference = ChargeEngine()
        var now = t0
        for percent in Array(70...80) + [79, 77, 75, 76] {
            battery.snapshot = snapshot(percent)
            now += 5
            await model.tick(now: now)
            let expected = reference.tick(snapshot: snapshot(percent), config: model.settings.engine, now: now)
            XCTAssertEqual(model.appliedCommand, expected.command, "\(percent) %")
            XCTAssertEqual(model.activity, expected.activity, "\(percent) %")
            XCTAssertEqual(model.engineState, reference.state, "\(percent) %")
        }
        XCTAssertEqual(model.appliedCommand?.led, .orange)
    }

    func testLimiterDisabledAppliesStock() async throws {
        let controller = RecordingController()
        let store = try makeStore { $0.isLimiterEnabled = false }
        let model = makeModel(store: store, battery: BatteryStub(snapshot(95)), controller: controller)

        await model.tick(now: t0)

        XCTAssertEqual(model.appliedCommand, .stock)
        XCTAssertEqual(controller.record.applied, [.stock])
        XCTAssertEqual(model.activity, .unmanaged)
        XCTAssertEqual(model.snapshot?.percent, 95, "telemetry is still shown")
    }

    func testNoBatteryReadingAppliesNothing() async throws {
        let controller = RecordingController()
        let model = makeModel(store: try makeStore(), battery: BatteryStub(nil), controller: controller)

        await model.tick(now: t0)

        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.activity, .unmanaged)
        XCTAssertNil(model.appliedCommand)
        XCTAssertEqual(controller.record.applied, [])
    }

    func testUnchangedCommandIsResentAsHeartbeatEvery30Seconds() async throws {
        let controller = RecordingController()
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(50)), controller: controller)

        await model.tick(now: t0)
        await model.tick(now: t0 + 5)
        await model.tick(now: t0 + 29)
        XCTAssertEqual(controller.record.applied.count, 1)

        await model.tick(now: t0 + 30)
        XCTAssertEqual(controller.record.applied.count, 2)
        await model.tick(now: t0 + 35)
        XCTAssertEqual(controller.record.applied.count, 2)
        XCTAssertEqual(controller.record.handshakes, 1, "the connection is established once")
    }

    func testDryRunFlagIsPassedToTheControllerFactory() async throws {
        let store = try makeStore { $0.dryRun = true }
        let controller = RecordingController(isDryRun: true)
        var requested: [Bool] = []
        let model = SimmerModel(
            store: store, tickInterval: .seconds(3600),
            readSnapshot: { snapshot(50) },
            makeController: { dryRun, _ in
                requested.append(dryRun)
                return controller
            }
        )
        await model.tick(now: t0)
        XCTAssertEqual(requested, [true])
        XCTAssertEqual(model.connection, .dryRun)
        XCTAssertTrue(model.connection.isUsable)
    }

    // MARK: Connection failures

    func testThrowingHandshakeMakesTheConnectionUnavailable() async throws {
        let controller = RecordingController()
        controller.update { $0.handshakeError = HelperError.notInstalled }
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(50)), controller: controller)

        await model.tick(now: t0)

        XCTAssertEqual(model.connection, .unavailable("The Simmer helper is not installed"))
        XCTAssertFalse(model.connection.isUsable)
        XCTAssertNil(model.appliedCommand)
        XCTAssertEqual(controller.record.applied, [])
        XCTAssertEqual(controller.record.policies, [])
        XCTAssertEqual(model.capabilities, .unsupported)
        // The engine keeps running so the UI still shows what would happen.
        XCTAssertEqual(model.snapshot, snapshot(50))
        XCTAssertEqual(model.activity, .charging)
    }

    func testArbitraryHandshakeErrorDoesNotCrash() async throws {
        let controller = RecordingController()
        controller.update { $0.handshakeError = Boom() }
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(50)), controller: controller)
        await model.tick(now: t0)
        guard case .unavailable = model.connection else {
            return XCTFail("expected .unavailable, got \(model.connection)")
        }
        XCTAssertNil(model.appliedCommand)
    }

    func testConnectionIsRetriedEveryTenSeconds() async throws {
        let controller = RecordingController()
        controller.update { $0.handshakeError = HelperError.connection("no helper") }
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(50)), controller: controller)

        await model.tick(now: t0)
        await model.tick(now: t0 + 5)
        await model.tick(now: t0 + 9)
        XCTAssertEqual(controller.record.handshakes, 1)

        await model.tick(now: t0 + 10)
        XCTAssertEqual(controller.record.handshakes, 2)
        XCTAssertFalse(model.connection.isUsable)

        controller.update { $0.handshakeError = nil }
        await model.tick(now: t0 + 20)
        XCTAssertEqual(controller.record.handshakes, 3)
        XCTAssertEqual(model.connection, .connected(version: "9.9.9"))
        XCTAssertEqual(model.appliedCommand, expectedCommand(for: snapshot(50), settings: model.settings))
        XCTAssertEqual(controller.record.applied.count, 1)
    }

    func testConnectionErrorWhileApplyingDropsTheConnection() async throws {
        let controller = RecordingController()
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(50)), controller: controller)
        await model.tick(now: t0)
        XCTAssertNotNil(model.appliedCommand)

        controller.update { $0.applyError = HelperError.connection("interrupted") }
        await model.tick(now: t0 + 30)

        XCTAssertEqual(model.connection, .unavailable("Helper connection failed: interrupted"))
        XCTAssertEqual(model.lastError, "Helper connection failed: interrupted")
        XCTAssertNil(model.appliedCommand)

        // The helper comes back: the model reconnects and re-applies.
        controller.update { $0.applyError = nil }
        await model.tick(now: t0 + 40)
        XCTAssertEqual(model.connection, .connected(version: "9.9.9"))
        XCTAssertNotNil(model.appliedCommand)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(controller.record.applied.count, 2)
    }

    func testRemoteErrorWhileApplyingKeepsTheConnection() async throws {
        let controller = RecordingController()
        controller.update { $0.applyError = HelperError.remote("SMC result code 0x86") }
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(50)), controller: controller)

        await model.tick(now: t0)

        XCTAssertEqual(model.connection, .connected(version: "9.9.9"))
        XCTAssertEqual(model.lastError, "SMC result code 0x86")
        XCTAssertNil(model.appliedCommand, "a rejected command is not recorded as applied")

        // … so it is retried on the very next tick.
        controller.update { $0.applyError = nil }
        await model.tick(now: t0 + 5)
        XCTAssertNotNil(model.appliedCommand)
        XCTAssertNil(model.lastError)
    }

    // MARK: Settings

    func testSetLimitClampsAndPersists() async throws {
        let store = try makeStore()
        let model = makeModel(store: store, battery: BatteryStub(snapshot(50)), controller: RecordingController())

        model.setLimit(5)
        XCTAssertEqual(model.settings.engine.limit, 20)
        model.setLimit(150)
        XCTAssertEqual(model.settings.engine.limit, 100)
        model.setLimit(65)
        XCTAssertEqual(model.settings.engine.limit, 65)
        XCTAssertEqual(store.loadSettings().engine.limit, 65)
        await settle()
    }

    func testChangingTheLimitChangesTheAppliedCommand() async throws {
        let controller = RecordingController()
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(70)), controller: controller)
        await model.tick(now: t0)
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, true)

        model.setLimit(60)
        await model.tick(now: t0 + 5)
        await settle()

        XCTAssertEqual(model.appliedCommand?.chargingAllowed, false)
        XCTAssertEqual(model.appliedCommand?.hold, ChargeBand(upper: 60, lower: 55))
        XCTAssertEqual(model.activity, .holding)
    }

    func testChangingTheFailSafePolicyReconfiguresTheHelper() async throws {
        let controller = RecordingController()
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(50)), controller: controller)
        await model.tick(now: t0)

        model.settings.keepLimitWhenOff = true
        await settle()

        let expected = FailSafePolicy(resetOnDisconnect: true, persistentBand: ChargeBand(upper: 80, lower: 75))
        XCTAssertEqual(controller.record.policies.last, expected)
        XCTAssertEqual(controller.record.policies.count, 2)
    }

    func testSettingsAreLoadedFromTheStore() async throws {
        let store = try makeStore {
            $0.engine.limit = 60
            $0.engine.sailingBuffer = 0
            $0.resetOnQuit = false
        }
        let controller = RecordingController()
        let model = makeModel(store: store, battery: BatteryStub(snapshot(60)), controller: controller)
        XCTAssertEqual(model.settings.engine.limit, 60)

        await model.tick(now: t0)
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, false)
        XCTAssertEqual(model.appliedCommand?.hold, ChargeBand(upper: 60, lower: 60))
        XCTAssertEqual(controller.record.policies, [FailSafePolicy(resetOnDisconnect: false, persistentBand: nil)])
    }

    // MARK: Actions

    func testTopUpActionChangesModeAndCommand() async throws {
        let store = try makeStore()
        let controller = RecordingController()
        let model = makeModel(store: store, battery: BatteryStub(snapshot(80)), controller: controller)
        await model.tick(now: t0)
        XCTAssertEqual(model.activity, .holding)

        model.startTopUp()
        XCTAssertEqual(model.engineState.mode, .topUp)
        XCTAssertEqual(store.loadEngineState().mode, .topUp, "engine state is persisted")

        await model.tick(now: t0 + 5)
        await settle()
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, true)
        XCTAssertEqual(model.appliedCommand?.hold, ChargeBand(upper: 100, lower: 100))
        XCTAssertEqual(model.activity, .charging)

        model.returnToNormal()
        XCTAssertEqual(model.engineState.mode, .normal)
        await model.tick(now: t0 + 10)
        await settle()
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, false)
        XCTAssertEqual(model.activity, .holding)
    }

    func testDischargeActionDisconnectsTheAdapter() async throws {
        let controller = RecordingController()
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(95)), controller: controller)
        await model.tick(now: t0)

        model.startDischarge()
        XCTAssertEqual(model.engineState.mode, .discharge)
        await model.tick(now: t0 + 5)
        await settle()

        XCTAssertEqual(model.appliedCommand?.adapterConnected, false)
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, false)
        XCTAssertEqual(model.activity, .discharging)

        model.returnToNormal()
        await model.tick(now: t0 + 10)
        await settle()
        XCTAssertEqual(model.engineState.mode, .normal)
        XCTAssertEqual(model.appliedCommand?.adapterConnected, true)
    }

    func testDischargeAndCalibrationNeedAdapterControl() async throws {
        let caps = HardwareCapabilities(
            architecture: .intel, charging: .bclm, adapter: .none, hardwareLimit: .bclm, hasMagSafeLED: false
        )
        let controller = RecordingController(capabilities: caps)
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(95)), controller: controller)

        // Before the first handshake nothing is known about the hardware.
        model.startDischarge()
        XCTAssertEqual(model.engineState.mode, .normal)

        await model.tick(now: t0)
        XCTAssertFalse(model.capabilities.canDischarge)
        model.startDischarge()
        model.startCalibration()
        XCTAssertEqual(model.engineState.mode, .normal)
        await settle()
    }

    func testCalibrationActionReportsProgress() async throws {
        let controller = RecordingController()
        let battery = BatteryStub(snapshot(60))
        let model = makeModel(store: try makeStore(), battery: battery, controller: controller)

        model.startCalibration()
        XCTAssertEqual(model.engineState.mode, .normal, "needs a battery reading and adapter control first")

        await model.tick(now: t0)
        model.startCalibration()
        XCTAssertEqual(model.engineState.mode, .calibration(.chargeToFull))
        XCTAssertEqual(model.engineState.calibrationStartPercent, 60)

        await model.tick(now: t0 + 5)
        await settle()
        XCTAssertEqual(model.calibrationProgress, 0)
        XCTAssertEqual(model.appliedCommand?.hold, ChargeBand(upper: 100, lower: 100))

        battery.snapshot = snapshot(100)
        await model.tick(now: t0 + 10)
        XCTAssertEqual(model.engineState.mode, .calibration(.dischargeToLow))
        XCTAssertEqual(model.calibrationProgress, 0.25)
        XCTAssertEqual(model.appliedCommand?.adapterConnected, false)
        XCTAssertEqual(model.activity, .discharging)

        model.returnToNormal()
        await model.tick(now: t0 + 15)
        await settle()
        XCTAssertEqual(model.engineState.mode, .normal)
        XCTAssertNil(model.calibrationProgress)
        XCTAssertEqual(model.appliedCommand?.adapterConnected, true)
    }

    func testPerformScheduleActions() async throws {
        let controller = RecordingController()
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(90)), controller: controller)
        await model.tick(now: t0)

        model.perform(.setLimit(55))
        XCTAssertEqual(model.settings.engine.limit, 55)
        model.perform(.setLimit(500))
        XCTAssertEqual(model.settings.engine.limit, 100)

        model.perform(.topUp)
        XCTAssertEqual(model.engineState.mode, .topUp)
        model.perform(.startDischarge)
        XCTAssertEqual(model.engineState.mode, .discharge)
        model.perform(.startCalibration)
        XCTAssertEqual(model.engineState.mode, .calibration(.chargeToFull))
        model.perform(.returnToNormal)
        XCTAssertEqual(model.engineState.mode, .normal)
        await settle()
    }

    func testEngineStateIsRestoredFromTheStore() async throws {
        let store = try makeStore()
        var state = EngineState()
        state.mode = .topUp
        store.save(state)

        let model = makeModel(store: store, battery: BatteryStub(snapshot(85)), controller: RecordingController())
        XCTAssertEqual(model.engineState.mode, .topUp)

        await model.tick(now: t0)
        XCTAssertEqual(model.appliedCommand, expectedCommand(for: snapshot(85), settings: model.settings, state: state))
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, true)
    }

    func testDueScheduleRuleIsPerformedOnTick() async throws {
        // The schedule baseline is the real clock at init (not injectable), so the rule is
        // placed at a whole minute at least one minute in the future and `now` is injected.
        let calendar = Calendar.current
        let soon = Date().addingTimeInterval(120)
        let fire = try XCTUnwrap(calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: soon)
        ))
        let rule = ScheduleRule(
            weekdays: [calendar.component(.weekday, from: fire)],
            hour: calendar.component(.hour, from: fire), minute: calendar.component(.minute, from: fire),
            action: .topUp
        )
        let store = try makeStore { $0.schedules = [rule] }
        let model = makeModel(store: store, battery: BatteryStub(snapshot(80)), controller: RecordingController())

        await model.tick(now: fire.addingTimeInterval(-1))
        XCTAssertEqual(model.engineState.mode, .normal, "not due yet")

        await model.tick(now: fire.addingTimeInterval(1))
        XCTAssertEqual(model.engineState.mode, .topUp)
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, true)
        await settle()
    }

    // MARK: Lifecycle

    func testPrepareForTerminationDisconnectsTheController() async throws {
        let controller = RecordingController()
        let model = makeModel(store: try makeStore(), battery: BatteryStub(snapshot(50)), controller: controller)
        await model.tick(now: t0)
        model.prepareForTermination()
        XCTAssertEqual(controller.record.disconnects, 1)
        model.prepareForTermination()
        XCTAssertEqual(controller.record.disconnects, 1, "nothing left to disconnect")
    }

    // MARK: Dry-run integration

    func testDryRunControllerEndToEnd() async throws {
        let store = try makeStore {
            $0.dryRun = true
            $0.engine.ledMode = .status
        }
        let battery = BatteryStub(snapshot(80))
        var controllers: [DryRunChargeController] = []
        let model = SimmerModel(
            store: store, tickInterval: .seconds(3600),
            readSnapshot: { battery.snapshot },
            makeController: { _, onWrite in
                let controller = DryRunChargeController(smc: .appleSiliconTahoe(), onWrite: onWrite)
                controllers.append(controller)
                return controller
            }
        )

        await model.tick(now: t0)

        let controller = try XCTUnwrap(controllers.first)
        XCTAssertEqual(controllers.count, 1)
        XCTAssertEqual(model.connection, .dryRun)
        XCTAssertEqual(model.capabilities.charging, .chte)
        XCTAssertEqual(model.appliedCommand, ChargeCommand(
            chargingAllowed: false, adapterConnected: true, led: .green, hold: ChargeBand(upper: 80, lower: 75)
        ))
        XCTAssertEqual(controller.smc.writes, ["CHIE=00", "CHTE=01000000", "ACLC=03"])

        // The simulated writes are mirrored into the dry-run console.
        for _ in 0..<1_000 where model.dryRunLog.count < 3 { await Task.yield() }
        XCTAssertEqual(model.dryRunLog.count, 3)
        XCTAssertTrue(model.dryRunLog[1].hasSuffix("CHTE ← 01000000"), model.dryRunLog[1])
        model.clearDryRunLog()
        XCTAssertEqual(model.dryRunLog, [])

        // Battery sailed down to the resume level: charging is allowed again.
        battery.snapshot = snapshot(75)
        await model.tick(now: t0 + 5)
        XCTAssertEqual(controller.smc.hex("CHTE"), "00000000")
        XCTAssertEqual(controller.smc.hex("ACLC"), "04")

        // Quitting drops the connection; the in-process helper restores stock values.
        model.prepareForTermination()
        XCTAssertEqual(controller.smc.hex("ACLC"), "00")
        XCTAssertEqual(controller.smc.hex("CHTE"), "00000000")
    }
}
