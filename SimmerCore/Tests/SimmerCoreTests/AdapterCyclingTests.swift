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
}
