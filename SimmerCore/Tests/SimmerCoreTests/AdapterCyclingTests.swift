import XCTest
@testable import SimmerCore

/// Machines whose firmware gates every charging-inhibit key: the limit is held by
/// disconnecting the adapter (`CHIE`).
final class AdapterCyclingTests: XCTestCase {
    private func writes(_ smc: DryRunSMC) -> [String] {
        smc.writeLog.map { "\($0.key)=\($0.hex)" }
    }

    func testDetectsAdapterCyclingWhenOnlyTheAdapterKeyIsUsable() {
        let hardware = ChargeHardware(smc: DryRunSMC.appleSiliconAdapterOnly(), architecture: .appleSilicon)
        XCTAssertEqual(hardware.capabilities.charging, .adapterCycling)
        XCTAssertEqual(hardware.capabilities.adapter, .chie)
        XCTAssertEqual(hardware.capabilities.hardwareLimit, .none)
        XCTAssertTrue(hardware.capabilities.holdsByDischarging)
        XCTAssertFalse(hardware.capabilities.canPersistLimit)

        let summary = hardware.capabilities.summary
        XCTAssertTrue(summary.contains("architecture:    appleSilicon"))
        XCTAssertTrue(summary.contains("charging:        adapterCycling"))
        XCTAssertTrue(summary.contains("adapter:         chie"))
    }

    func testGatedFirmwareBandFallsBackToAdapterCycling() {
        let base = DryRunSMC.appleSiliconFirmwareBand()
        let smc = FaultySMC(base: base, privilegedKeys: ["bfF0", "bfD0", "bfE0"])
        let hardware = ChargeHardware(smc: smc, architecture: .appleSilicon)
        XCTAssertEqual(hardware.capabilities.charging, .adapterCycling)
        XCTAssertEqual(hardware.capabilities.hardwareLimit, .none)
    }

    func testHoldDisconnectsTheAdapterWithASingleWrite() throws {
        let smc = DryRunSMC.appleSiliconAdapterOnly()
        let hardware = ChargeHardware(smc: smc, architecture: .appleSilicon)
        let band = ChargeBand(upper: 80, lower: 75)

        try hardware.apply(ChargeCommand(chargingAllowed: false, hold: band))
        XCTAssertEqual(writes(smc), ["CHIE=08", "ACLC=00"])
        XCTAssertTrue(hardware.isChargingInhibited())

        smc.clearLog()
        try hardware.apply(ChargeCommand(chargingAllowed: true, hold: band))
        XCTAssertEqual(writes(smc), ["CHIE=00", "ACLC=00"])
        XCTAssertFalse(hardware.isChargingInhibited())
    }

    func testResetReconnectsTheAdapter() throws {
        let smc = DryRunSMC.appleSiliconAdapterOnly()
        let hardware = ChargeHardware(smc: smc, architecture: .appleSilicon)
        try hardware.apply(ChargeCommand(chargingAllowed: false, hold: ChargeBand(upper: 80, lower: 75)))
        try hardware.resetToDefaults()
        XCTAssertFalse(hardware.isAdapterDisabled())
    }

    func testOlderAdapterKeysAreDetected() {
        // Machine with ch0j
        let smc0j = DryRunSMC(keys: [
            SMCValue(key: SMCKeys.ch0j, type: "ui8 ", bytes: [0x00])
        ])
        let hw0j = ChargeHardware(smc: smc0j, architecture: .appleSilicon)
        XCTAssertEqual(hw0j.capabilities.adapter, .ch0j)
        XCTAssertEqual(hw0j.capabilities.charging, .adapterCycling)

        // Machine with ch0i
        let smc0i = DryRunSMC(keys: [
            SMCValue(key: SMCKeys.ch0i, type: "ui8 ", bytes: [0x00])
        ])
        let hw0i = ChargeHardware(smc: smc0i, architecture: .appleSilicon)
        XCTAssertEqual(hw0i.capabilities.adapter, .ch0i)
        XCTAssertEqual(hw0i.capabilities.charging, .adapterCycling)
    }

    func testAdapterCyclingHoldingScenarioTickByTick() {
        // Simulates the full adapter cycling lifecycle in ChargeEngine
        var sim = EngineSimulation(config: engineConfig(limit: 80, buffer: 5))
        sim.plugged = true

        // 1. Charges up to 80 %
        let chargingOutput = sim.tick(78)
        XCTAssertTrue(chargingOutput.command.chargingAllowed)
        XCTAssertEqual(chargingOutput.activity, .charging)

        // 2. Hits limit 80 % -> engine switches to holding
        let limitOutput = sim.tick(80)
        XCTAssertFalse(limitOutput.command.chargingAllowed)
        XCTAssertEqual(limitOutput.activity, .holding)
        XCTAssertTrue(sim.events.contains(.limitReached(80)))

        // 3. In Adapter Cycling mode, the adapter is disconnected and drains to resumeLevel (75 %)
        let sailingOutput = sim.tick(77)
        XCTAssertFalse(sailingOutput.command.chargingAllowed)
        XCTAssertEqual(sailingOutput.activity, .holding)

        // 4. Hits resumeLevel (75 %) -> charging turns back on
        let resumeOutput = sim.tick(75)
        XCTAssertTrue(resumeOutput.command.chargingAllowed)
        XCTAssertEqual(resumeOutput.activity, .charging)

        // 5. Charges back up to 80 %
        let topOutput = sim.tick(80)
        XCTAssertFalse(topOutput.command.chargingAllowed)
        XCTAssertEqual(topOutput.activity, .holding)
    }
}
