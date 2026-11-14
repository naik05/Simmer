import XCTest
@testable import SimmerCore

final class HelperCoreTests: XCTestCase {
    private let band = ChargeBand(upper: 80, lower: 75)

    private var hold: ChargeCommand {
        ChargeCommand(chargingAllowed: false, adapterConnected: true, led: .green, hold: band)
    }

    private var discharge: ChargeCommand {
        ChargeCommand(chargingAllowed: false, adapterConnected: false, led: .off, hold: band)
    }

    private func makeCore(_ preset: Preset = .tahoe) -> (core: HelperCore, smc: DryRunSMC, clock: FakeClock) {
        let (hardware, smc) = preset.make()
        let clock = FakeClock()
        let core = HelperCore(hardware: hardware, isDryRun: true, uptime: { clock.now })
        return (core, smc, clock)
    }

    // MARK: Handshake

    func testHandshakeReportsVersionCapabilitiesAndDryRun() {
        let (core, _, _) = makeCore(.firmwareBand)
        XCTAssertEqual(core.handshake, HelperHandshake(
            version: HelperCore.version, capabilities: core.hardware.capabilities, isDryRun: true
        ))
        XCTAssertEqual(core.handshake.capabilities.charging, .firmwareBand)
        XCTAssertEqual(core.currentPolicy, FailSafePolicy(resetOnDisconnect: true, persistentBand: nil))
    }

    // MARK: Start-up fail-safe

    func testStartUpFailSafeWritesStockValues() throws {
        let (core, smc, _) = makeCore(.tahoe)
        // State left behind by a crashed previous run.
        try smc.write("CHTE", bytes: [1, 0, 0, 0])
        try smc.write("CHIE", bytes: [0x08])
        try smc.write("ACLC", bytes: [0x04])
        try smc.write("CHWA", bytes: [0x01])
        smc.clearLog()

        core.failSafeReset()

        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=00000000", "ACLC=00", "CHWA=00"])
        XCTAssertFalse(core.hardware.isChargingInhibited())
        XCTAssertFalse(core.hardware.isAdapterDisabled())
    }

    func testStartUpFailSafeOnEveryPresetEndsInStockState() throws {
        for preset in Preset.allCases {
            let (core, smc, _) = makeCore(preset)
            try core.hardware.setCharging(enabled: false, hold: band)
            if core.hardware.capabilities.canDischarge { try core.hardware.setAdapter(enabled: false) }
            try core.hardware.setHardwareLimit(band)
            smc.clearLog()

            core.failSafeReset()

            XCTAssertFalse(smc.writeLog.isEmpty, "\(preset)")
            XCTAssertFalse(core.hardware.isChargingInhibited(), "\(preset)")
            XCTAssertFalse(core.hardware.isAdapterDisabled(), "\(preset)")
        }
    }

    func testFailSafeResetBeforeExitLeavesTheConfiguredBand() {
        let (core, smc, _) = makeCore(.firmwareBand)
        core.configure(FailSafePolicy(resetOnDisconnect: true, persistentBand: band))
        core.failSafeReset()
        XCTAssertEqual(smc.hex("bfF0"), "02")
        XCTAssertEqual(smc.hex("bfD0"), "50000000")
        XCTAssertEqual(smc.hex("bfE0"), "4b000000")
    }

    func testFailSafeResetIgnoresResetOnDisconnectFalse() throws {
        let (core, smc, _) = makeCore(.tahoe)
        core.configure(FailSafePolicy(resetOnDisconnect: false))
        try core.apply(discharge)
        core.failSafeReset()
        XCTAssertEqual(smc.hex("CHTE"), "00000000", "helper start/exit always resets fully")
        XCTAssertEqual(smc.hex("CHIE"), "00")
    }

    // MARK: apply

    func testApplyWritesTheCommand() throws {
        let (core, smc, _) = makeCore(.tahoe)
        try core.apply(hold)
        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=01000000", "ACLC=03"])
    }

    func testIdenticalCommandsAreDedupedWithinAMinute() throws {
        let (core, smc, clock) = makeCore(.tahoe)
        try core.apply(hold)
        let first = smc.writes

        for _ in 0..<5 {
            clock.advance(10)
            try core.apply(hold)
        }
        clock.advance(9.5)   // 59.5 s after the write
        try core.apply(hold)
        XCTAssertEqual(smc.writes, first, "no rewrite within 60 s")

        clock.advance(0.5)   // exactly 60 s
        try core.apply(hold)
        XCTAssertEqual(smc.writes, first + first, "rewritten after a minute")

        clock.advance(30)
        try core.apply(hold)
        XCTAssertEqual(smc.writes, first + first, "the window restarts at the rewrite")
    }

    func testChangedCommandIsWrittenImmediately() throws {
        let (core, smc, clock) = makeCore(.tahoe)
        try core.apply(hold)
        smc.clearLog()

        clock.advance(1)
        try core.apply(discharge)
        XCTAssertEqual(smc.writes, ["CHTE=01000000", "CHIE=08", "ACLC=01"])

        smc.clearLog()
        clock.advance(1)
        try core.apply(hold)
        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=01000000", "ACLC=03"])
    }

    func testFailedApplyIsRetriedInsteadOfDeduped() throws {
        let base = DryRunSMC.appleSiliconTahoe()
        let smc = FaultySMC(base: base, failingWrites: ["ACLC"])
        let clock = FakeClock()
        let core = HelperCore(
            hardware: ChargeHardware(smc: smc, architecture: .appleSilicon), isDryRun: true, uptime: { clock.now }
        )

        XCTAssertThrowsError(try core.apply(hold)) { XCTAssertEqual($0 as? SMCError, .smc(0x86)) }
        XCTAssertEqual(base.writes, ["CHIE=00", "CHTE=01000000"])

        smc.setFailingWrites([])
        clock.advance(1)
        try core.apply(hold)
        XCTAssertEqual(base.writes, ["CHIE=00", "CHTE=01000000", "CHIE=00", "CHTE=01000000", "ACLC=03"])
    }

    func testApplyThrowsForUnsupportedOperations() {
        let (core, _, _) = makeCore(.intelBCLMOnly)
        XCTAssertThrowsError(try core.apply(discharge)) {
            XCTAssertEqual($0 as? SMCError, .unsupported("adapter control"))
        }
    }

    // MARK: Client disconnect

    func testDisconnectWithResetRestoresStock() throws {
        let (core, smc, _) = makeCore(.tahoe)
        try core.apply(discharge)
        smc.clearLog()

        core.clientDisconnected()

        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=00000000", "ACLC=00", "CHWA=00"])
        XCTAssertFalse(core.hardware.isChargingInhibited())
        XCTAssertFalse(core.hardware.isAdapterDisabled())
    }

    func testDisconnectWithResetLeavesThePersistentBand() throws {
        let (core, smc, _) = makeCore(.firmwareBand)
        core.configure(FailSafePolicy(resetOnDisconnect: true, persistentBand: band))
        XCTAssertEqual(core.currentPolicy.persistentBand, band)
        try core.apply(ChargeCommand(chargingAllowed: false, adapterConnected: false, led: .off,
                                     hold: ChargeBand(upper: 60, lower: 50)))
        smc.clearLog()

        core.clientDisconnected()

        XCTAssertEqual(smc.writes, [
            "CHIE=00", "bfF0=00", "ACLC=00", "bfF0=00", "bfD0=50000000", "bfE0=4b000000", "bfF0=02",
        ])
        XCTAssertFalse(core.hardware.isAdapterDisabled())
        XCTAssertEqual(smc.hex("bfF0"), "02", "the firmware keeps enforcing the limit")
    }

    func testDisconnectWithPersistentBandOnOtherHardware() throws {
        let expected: [Preset: String] = [.tahoe: "CHWA=01", .legacy: "CHWA=01", .intel: "BCLM=50", .intelBCLMOnly: "BCLM=50"]
        for (preset, lastWrite) in expected {
            let (core, smc, _) = makeCore(preset)
            core.configure(FailSafePolicy(resetOnDisconnect: true, persistentBand: band))
            try core.apply(hold)
            core.clientDisconnected()
            XCTAssertEqual(smc.writes.last, lastWrite, "\(preset)")
        }
    }

    func testDisconnectWithoutResetOnlyReEnablesTheAdapter() throws {
        let (core, smc, _) = makeCore(.tahoe)
        core.configure(FailSafePolicy(resetOnDisconnect: false))
        try core.apply(discharge)
        smc.clearLog()

        core.clientDisconnected()

        XCTAssertEqual(smc.writes, ["CHIE=00"])
        XCTAssertFalse(core.hardware.isAdapterDisabled(), "a forced discharge is always ended")
        XCTAssertTrue(core.hardware.isChargingInhibited(), "the charging state is left in place")
        XCTAssertEqual(smc.hex("ACLC"), "01")
    }

    func testDisconnectWithoutResetOnHardwareWithoutAdapterControlIsHarmless() throws {
        let (core, smc, _) = makeCore(.intelBCLMOnly)
        core.configure(FailSafePolicy(resetOnDisconnect: false))
        try core.apply(hold)
        smc.clearLog()
        core.clientDisconnected()
        XCTAssertTrue(smc.writeLog.isEmpty)
        XCTAssertEqual(smc.hex("BCLM"), "50")
    }

    func testCommandIsRewrittenAfterAReconnect() throws {
        let (core, smc, clock) = makeCore(.tahoe)
        try core.apply(hold)
        core.clientDisconnected()
        smc.clearLog()

        clock.advance(1)
        try core.apply(hold)
        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=01000000", "ACLC=03"], "the dedupe cache is dropped by the fail-safe")
    }

    // MARK: Watchdog

    func testWatchdogIsIdleWithoutAClient() {
        let (core, smc, clock) = makeCore(.tahoe)
        clock.advance(10_000)
        XCTAssertFalse(core.checkWatchdog())
        XCTAssertTrue(smc.writeLog.isEmpty)
    }

    func testWatchdogTripsOnlyAfterTheTimeoutAndOnlyOnce() throws {
        XCTAssertEqual(HelperCore.watchdogTimeout, 120)
        let (core, smc, clock) = makeCore(.tahoe)
        try core.apply(discharge)
        smc.clearLog()

        clock.advance(60)
        XCTAssertFalse(core.checkWatchdog())
        clock.advance(60)   // exactly the timeout
        XCTAssertFalse(core.checkWatchdog())
        XCTAssertTrue(smc.writeLog.isEmpty)
        XCTAssertTrue(core.hardware.isAdapterDisabled())

        clock.advance(0.5)
        XCTAssertTrue(core.checkWatchdog())
        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=00000000", "ACLC=00", "CHWA=00"])
        XCTAssertFalse(core.hardware.isAdapterDisabled())
        XCTAssertFalse(core.hardware.isChargingInhibited())

        smc.clearLog()
        clock.advance(1_000)
        XCTAssertFalse(core.checkWatchdog(), "trips only once")
        XCTAssertTrue(smc.writeLog.isEmpty)
    }

    func testEveryApplyIsAHeartbeatEvenWhenDeduped() throws {
        let (core, smc, clock) = makeCore(.tahoe)
        try core.apply(hold)
        // Ten minutes of 30 s heartbeats – far beyond the timeout in total.
        for _ in 0..<20 {
            clock.advance(30)
            try core.apply(hold)
            XCTAssertFalse(core.checkWatchdog())
        }
        XCTAssertTrue(core.hardware.isChargingInhibited())

        smc.clearLog()
        clock.advance(121)
        XCTAssertTrue(core.checkWatchdog())
        XCTAssertFalse(core.hardware.isChargingInhibited())
    }

    func testConfigureCountsAsContact() {
        let (core, _, clock) = makeCore(.tahoe)
        core.configure(FailSafePolicy())
        clock.advance(100)
        core.configure(FailSafePolicy())
        clock.advance(100)
        XCTAssertFalse(core.checkWatchdog(), "only 100 s since the last contact")
        clock.advance(21)
        XCTAssertTrue(core.checkWatchdog())
    }

    func testWatchdogRearmsWhenTheClientReturns() throws {
        let (core, _, clock) = makeCore(.tahoe)
        try core.apply(hold)
        clock.advance(121)
        XCTAssertTrue(core.checkWatchdog())

        try core.apply(hold)
        XCTAssertTrue(core.hardware.isChargingInhibited(), "the command is written again after the fail-safe")
        clock.advance(121)
        XCTAssertTrue(core.checkWatchdog())
    }

    func testWatchdogHonoursResetOnDisconnectFalse() throws {
        let (core, smc, clock) = makeCore(.tahoe)
        core.configure(FailSafePolicy(resetOnDisconnect: false))
        try core.apply(discharge)
        smc.clearLog()
        clock.advance(121)
        XCTAssertTrue(core.checkWatchdog())
        XCTAssertEqual(smc.writes, ["CHIE=00"])
        XCTAssertTrue(core.hardware.isChargingInhibited())
    }

    func testWatchdogIsDisarmedByDisconnect() throws {
        let (core, smc, clock) = makeCore(.tahoe)
        try core.apply(hold)
        core.clientDisconnected()
        smc.clearLog()
        clock.advance(1_000)
        XCTAssertFalse(core.checkWatchdog())
        XCTAssertTrue(smc.writeLog.isEmpty)
    }

    // MARK: resetToStock

    func testResetToStockClearsAHardwareLimit() throws {
        let (core, smc, _) = makeCore(.intel)
        try core.hardware.setHardwareLimit(band)
        try core.apply(discharge)
        XCTAssertEqual(smc.hex("BCLM"), "50")
        smc.clearLog()

        try core.resetToStock()

        XCTAssertEqual(smc.writes, ["CH0I=00", "CH0B=00", "CH0C=00", "BCLM=64"])
    }

    func testResetToStockIgnoresThePersistentBand() throws {
        let (core, smc, _) = makeCore(.firmwareBand)
        core.configure(FailSafePolicy(resetOnDisconnect: true, persistentBand: band))
        try core.apply(hold)
        XCTAssertEqual(smc.hex("bfF0"), "02")

        try core.resetToStock()

        XCTAssertEqual(smc.hex("bfF0"), "00", "an explicit reset removes the firmware limit too")
        XCTAssertFalse(core.hardware.isChargingInhibited())
    }

    func testResetToStockDropsTheDedupeCache() throws {
        let (core, smc, clock) = makeCore(.tahoe)
        try core.apply(hold)
        try core.resetToStock()
        smc.clearLog()
        clock.advance(1)
        try core.apply(hold)
        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=01000000", "ACLC=03"])
    }

    // MARK: XPC service

    private func makeService(_ preset: Preset = .tahoe) -> (service: HelperXPCService, core: HelperCore, smc: DryRunSMC) {
        let (core, smc, _) = makeCore(preset)
        return (HelperXPCService(core: core), core, smc)
    }

    func testXPCHandshakeRoundTrip() throws {
        let (service, core, _) = makeService()
        let replies = Box<Data?>()
        service.handshake { replies.append($0) }
        let data = try XCTUnwrap(replies.values.first ?? nil)
        XCTAssertEqual(try JSONDecoder().decode(HelperHandshake.self, from: data), core.handshake)
    }

    func testXPCApplyRoundTripsAValidCommand() throws {
        let (service, _, smc) = makeService()
        let replies = Box<String?>()
        service.apply(try JSONEncoder().encode(hold)) { replies.append($0) }
        XCTAssertEqual(replies.values, [nil])
        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=01000000", "ACLC=03"])
    }

    func testXPCApplyRejectsMalformedPayloads() {
        let (service, core, smc) = makeService()
        let replies = Box<String?>()
        let payloads = [
            "",
            "not json",
            "{}",
            "[]",
            #"{"chargingAllowed": true}"#,
            #"{"chargingAllowed": "yes", "adapterConnected": true, "led": 0, "hold": {"upper": 80, "lower": 75}}"#,
            #"{"chargingAllowed": false, "adapterConnected": true, "led": 99, "hold": {"upper": 80, "lower": 75}}"#,
            #"{"chargingAllowed": false, "adapterConnected": true, "led": 0, "hold": {"upper": 80}}"#,
        ]
        for payload in payloads {
            service.apply(Data(payload.utf8)) { replies.append($0) }
        }
        XCTAssertEqual(replies.values, Array(repeating: "Invalid payload", count: payloads.count))
        XCTAssertTrue(smc.writeLog.isEmpty, "nothing reaches the SMC")
        XCTAssertFalse(core.checkWatchdog())
    }

    func testXPCApplyReportsHardwareErrors() throws {
        let (service, _, _) = makeService(.intelBCLMOnly)
        let replies = Box<String?>()
        service.apply(try JSONEncoder().encode(discharge)) { replies.append($0) }
        XCTAssertEqual(replies.values, ["Unsupported on this hardware: adapter control"])
    }

    func testXPCConfigure() throws {
        let (service, core, _) = makeService()
        let replies = Box<String?>()
        let policy = FailSafePolicy(resetOnDisconnect: false, persistentBand: band)

        service.configure(Data("garbage".utf8)) { replies.append($0) }
        XCTAssertEqual(core.currentPolicy, FailSafePolicy(), "a malformed policy changes nothing")

        service.configure(try JSONEncoder().encode(policy)) { replies.append($0) }
        XCTAssertEqual(core.currentPolicy, policy)
        XCTAssertEqual(replies.values, ["Invalid payload", nil])
    }

    func testXPCResetToStock() throws {
        let (service, core, smc) = makeService()
        try core.apply(discharge)
        smc.clearLog()
        let replies = Box<String?>()
        service.resetToStock { replies.append($0) }
        XCTAssertEqual(replies.values, [nil])
        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=00000000", "ACLC=00", "CHWA=00"])
    }

    /// EXPECTED TO FAIL until the source is fixed (see report). The helper promises that
    /// "only semantic, range-clamped commands reach the SMC", but a band decoded from an
    /// XPC payload skips `ChargeBand.init(upper:lower:)` and is written verbatim.
    func testXPCApplyNeverWritesAnOutOfRangeBand() throws {
        let (service, _, smc) = makeService(.firmwareBand)
        let payload = #"{"chargingAllowed": false, "adapterConnected": true, "led": 0, "hold": {"upper": 250, "lower": 0}}"#
        service.apply(Data(payload.utf8)) { _ in }

        // Either rejecting the payload or clamping it is fine; writing 250 % / 0 % is not.
        let upper = try XCTUnwrap(try smc.read("bfD0").doubleValue)
        let lower = try XCTUnwrap(try smc.read("bfE0").doubleValue)
        XCTAssertLessThanOrEqual(upper, 100)
        XCTAssertGreaterThanOrEqual(lower, 10)
    }

    // MARK: Dry-run controller

    func testDryRunControllerRunsTheHelperLogicInProcess() async throws {
        let observed = Box<DryRunSMC.Write>()
        let controller = DryRunChargeController(smc: .appleSiliconTahoe(), onWrite: { observed.append($0) })

        let handshake = try await controller.handshake()
        XCTAssertTrue(handshake.isDryRun)
        XCTAssertEqual(handshake.version, HelperCore.version)
        XCTAssertEqual(handshake.capabilities.charging, .chte)

        try await controller.configure(FailSafePolicy(resetOnDisconnect: true, persistentBand: band))
        XCTAssertEqual(controller.core.currentPolicy.persistentBand, band)

        try await controller.apply(discharge)
        XCTAssertEqual(controller.smc.writes, ["CHTE=01000000", "CHIE=08", "ACLC=01"])
        XCTAssertEqual(observed.values, controller.smc.writeLog)

        controller.disconnect()
        XCTAssertEqual(controller.smc.hex("CHIE"), "00")
        XCTAssertEqual(controller.smc.hex("CHTE"), "00000000")
        XCTAssertEqual(controller.smc.hex("CHWA"), "01", "the persistent limit is left behind")

        try await controller.resetToStock()
        XCTAssertEqual(controller.smc.hex("CHWA"), "00")
    }
}
