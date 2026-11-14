import XCTest
@testable import SimmerCore

final class ChargeHardwareTests: XCTestCase {
    private let band = ChargeBand(upper: 80, lower: 75)

    // MARK: Capability detection

    func testCapabilitiesOfFirmwareBandMac() {
        let caps = Preset.firmwareBand.make().hardware.capabilities
        XCTAssertEqual(caps, HardwareCapabilities(
            architecture: .appleSilicon, charging: .firmwareBand, adapter: .chie,
            hardwareLimit: .firmwareBand, hasMagSafeLED: true
        ))
        XCTAssertTrue(caps.canLimitCharging)
        XCTAssertTrue(caps.canDischarge)
        XCTAssertTrue(caps.canPersistLimit)
    }

    func testCapabilitiesOfTahoeMac() {
        XCTAssertEqual(Preset.tahoe.make().hardware.capabilities, HardwareCapabilities(
            architecture: .appleSilicon, charging: .chte, adapter: .chie, hardwareLimit: .chwa, hasMagSafeLED: true
        ))
    }

    func testCapabilitiesOfLegacyAppleSiliconMac() {
        XCTAssertEqual(Preset.legacy.make().hardware.capabilities, HardwareCapabilities(
            architecture: .appleSilicon, charging: .ch0bCh0c, adapter: .ch0i, hardwareLimit: .chwa, hasMagSafeLED: true
        ))
    }

    func testCapabilitiesOfIntelMac() {
        XCTAssertEqual(Preset.intel.make().hardware.capabilities, HardwareCapabilities(
            architecture: .intel, charging: .ch0bCh0c, adapter: .ch0i, hardwareLimit: .bclm, hasMagSafeLED: false
        ))
    }

    func testCapabilitiesOfBCLMOnlyIntelMac() {
        let caps = Preset.intelBCLMOnly.make().hardware.capabilities
        XCTAssertEqual(caps, HardwareCapabilities(
            architecture: .intel, charging: .bclm, adapter: .none, hardwareLimit: .bclm, hasMagSafeLED: false
        ))
        XCTAssertTrue(caps.canLimitCharging)
        XCTAssertFalse(caps.canDischarge)
        XCTAssertTrue(caps.canPersistLimit)
    }

    func testBCLMIsIgnoredOnAppleSilicon() {
        let hardware = ChargeHardware(smc: DryRunSMC.intelBCLMOnly(), architecture: .appleSilicon)
        XCTAssertEqual(hardware.capabilities.charging, .none)
        XCTAssertEqual(hardware.capabilities.hardwareLimit, .none)
        XCTAssertFalse(hardware.capabilities.canLimitCharging)
    }

    func testEmptySMCHasNoCapabilities() {
        let caps = ChargeHardware(smc: DryRunSMC(keys: []), architecture: .appleSilicon).capabilities
        XCTAssertEqual(caps, HardwareCapabilities(
            architecture: .appleSilicon, charging: .none, adapter: .none, hardwareLimit: .none, hasMagSafeLED: false
        ))
        XCTAssertFalse(caps.canLimitCharging)
        XCTAssertFalse(caps.canDischarge)
        XCTAssertFalse(caps.canPersistLimit)
    }

    func testAdapterKeyPrecedenceIsCHIEThenCH0JThenCH0I() {
        func adapter(_ keys: [String]) -> HardwareCapabilities.AdapterMethod {
            let smc = DryRunSMC(keys: keys.map { SMCValue(key: FourCC($0), type: "hex_", bytes: [0]) })
            return ChargeHardware(smc: smc, architecture: .appleSilicon).capabilities.adapter
        }
        XCTAssertEqual(adapter(["CH0I", "CH0J", "CHIE"]), .chie)
        XCTAssertEqual(adapter(["CH0I", "CH0J"]), .ch0j)
        XCTAssertEqual(adapter(["CH0I"]), .ch0i)
        XCTAssertEqual(adapter([]), .none)
    }

    func testIncompleteFirmwareBandFallsBackToNextMethod() {
        // bfE0 missing → no firmware band; CHTE takes over.
        let smc = DryRunSMC(keys: [
            SMCValue(key: "bfF0", type: "ui8", bytes: [0]), SMCValue(key: "bfD0", type: "ui32", bytes: [100, 0, 0, 0]),
            SMCValue(key: "CHTE", type: "ui32", bytes: [0, 0, 0, 0]),
        ])
        let caps = ChargeHardware(smc: smc, architecture: .appleSilicon).capabilities
        XCTAssertEqual(caps.charging, .chte)
        XCTAssertEqual(caps.hardwareLimit, .none)
    }

    func testCH0BWithoutCH0CIsNotEnough() {
        let smc = DryRunSMC(keys: [SMCValue(key: "CH0B", type: "hex_", bytes: [0])])
        XCTAssertEqual(ChargeHardware(smc: smc, architecture: .appleSilicon).capabilities.charging, .none)
    }

    func testCapabilitiesCodableRoundTrip() throws {
        for preset in Preset.allCases {
            let caps = preset.make().hardware.capabilities
            let decoded = try JSONDecoder().decode(HardwareCapabilities.self, from: JSONEncoder().encode(caps))
            XCTAssertEqual(decoded, caps)
        }
    }

    // MARK: setCharging

    func testSetChargingOnFirmwareBandMac() throws {
        let (hardware, smc) = Preset.firmwareBand.make()
        try hardware.setCharging(enabled: false, hold: band)
        XCTAssertEqual(smc.writes, ["bfF0=00", "bfD0=50000000", "bfE0=4b000000", "bfF0=02"])
        XCTAssertTrue(hardware.isChargingInhibited())

        smc.clearLog()
        try hardware.setCharging(enabled: true, hold: band)
        XCTAssertEqual(smc.writes, ["bfF0=00"])
        XCTAssertFalse(hardware.isChargingInhibited())
    }

    func testFirmwareBandValuesAreSizedToTheKey() throws {
        let smc = DryRunSMC(keys: [
            SMCValue(key: "bfF0", type: "ui16", bytes: [0, 0]),
            SMCValue(key: "bfD0", type: "ui16", bytes: [0, 0]),
            SMCValue(key: "bfE0", type: "ui8", bytes: [0]),
        ])
        let hardware = ChargeHardware(smc: smc, architecture: .appleSilicon)
        try hardware.setCharging(enabled: false, hold: ChargeBand(upper: 90, lower: 60))
        XCTAssertEqual(smc.writes, ["bfF0=0000", "bfD0=5a00", "bfE0=3c", "bfF0=0200"])
    }

    func testSetChargingOnTahoeMac() throws {
        let (hardware, smc) = Preset.tahoe.make()
        try hardware.setCharging(enabled: false, hold: band)
        XCTAssertEqual(smc.writes, ["CHTE=01000000"])
        XCTAssertTrue(hardware.isChargingInhibited())

        smc.clearLog()
        try hardware.setCharging(enabled: true)
        XCTAssertEqual(smc.writes, ["CHTE=00000000"])
        XCTAssertFalse(hardware.isChargingInhibited())
    }

    func testSetChargingOnLegacyAndIntelMacs() throws {
        for preset in [Preset.legacy, .intel] {
            let (hardware, smc) = preset.make()
            try hardware.setCharging(enabled: false, hold: band)
            XCTAssertEqual(smc.writes, ["CH0B=02", "CH0C=02"])
            XCTAssertTrue(hardware.isChargingInhibited())

            smc.clearLog()
            try hardware.setCharging(enabled: true)
            XCTAssertEqual(smc.writes, ["CH0B=00", "CH0C=00"])
            XCTAssertFalse(hardware.isChargingInhibited())
        }
    }

    func testSetChargingOnBCLMOnlyMacWritesTheLimit() throws {
        let (hardware, smc) = Preset.intelBCLMOnly.make()
        XCTAssertFalse(hardware.isChargingInhibited())

        try hardware.setCharging(enabled: false, hold: band)
        XCTAssertEqual(smc.writes, ["BCLM=50"])
        XCTAssertTrue(hardware.isChargingInhibited())

        try hardware.setCharging(enabled: false, hold: ChargeBand(upper: 10, lower: 10))
        XCTAssertEqual(smc.writes.last, "BCLM=14", "BCLM never goes below 20 %")

        try hardware.setCharging(enabled: true)
        XCTAssertEqual(smc.writes.last, "BCLM=64")
        XCTAssertFalse(hardware.isChargingInhibited())
    }

    func testIntelChargingInhibitDoesNotTouchBCLM() throws {
        let (hardware, smc) = Preset.intel.make()
        try hardware.setCharging(enabled: false, hold: band)
        XCTAssertEqual(smc.hex("BCLM"), "64")
    }

    // MARK: setAdapter

    func testSetAdapterViaCHIE() throws {
        for preset in [Preset.firmwareBand, .tahoe] {
            let (hardware, smc) = preset.make()
            XCTAssertFalse(hardware.isAdapterDisabled())
            try hardware.setAdapter(enabled: false)
            XCTAssertEqual(smc.writes, ["CHIE=08"])
            XCTAssertTrue(hardware.isAdapterDisabled())
            try hardware.setAdapter(enabled: true)
            XCTAssertEqual(smc.writes, ["CHIE=08", "CHIE=00"])
            XCTAssertFalse(hardware.isAdapterDisabled())
        }
    }

    func testSetAdapterViaCH0I() throws {
        for preset in [Preset.legacy, .intel] {
            let (hardware, smc) = preset.make()
            try hardware.setAdapter(enabled: false)
            XCTAssertEqual(smc.writes, ["CH0I=01"])
            XCTAssertTrue(hardware.isAdapterDisabled())
            try hardware.setAdapter(enabled: true)
            XCTAssertEqual(smc.writes, ["CH0I=01", "CH0I=00"])
            XCTAssertFalse(hardware.isAdapterDisabled())
        }
    }

    func testSetAdapterViaCH0J() throws {
        let smc = DryRunSMC(keys: [
            SMCValue(key: "CH0J", type: "hex_", bytes: [0]), SMCValue(key: "CH0I", type: "hex_", bytes: [0]),
        ])
        let hardware = ChargeHardware(smc: smc, architecture: .appleSilicon)
        try hardware.setAdapter(enabled: false)
        try hardware.setAdapter(enabled: true)
        XCTAssertEqual(smc.writes, ["CH0J=01", "CH0J=00"])
    }

    func testAdapterControlUnsupportedOnBCLMOnlyMac() throws {
        let (hardware, smc) = Preset.intelBCLMOnly.make()
        XCTAssertThrowsError(try hardware.setAdapter(enabled: false)) {
            XCTAssertEqual($0 as? SMCError, .unsupported("adapter control"))
        }
        XCTAssertNoThrow(try hardware.setAdapter(enabled: true), "re-enabling is a no-op, not an error")
        XCTAssertTrue(smc.writeLog.isEmpty)
        XCTAssertFalse(hardware.isAdapterDisabled())
    }

    // MARK: LED

    func testSetLEDWritesEveryStateToACLC() throws {
        let (hardware, smc) = Preset.tahoe.make()
        for state in [LEDState.system, .off, .green, .orange, .blinkOnce, .blinkSlow, .blinkFast] {
            try hardware.setLED(state)
        }
        XCTAssertEqual(smc.writes, ["ACLC=00", "ACLC=01", "ACLC=03", "ACLC=04", "ACLC=05", "ACLC=06", "ACLC=07"])
    }

    func testSetLEDIsNoOpWithoutMagSafe() throws {
        for preset in [Preset.intel, .intelBCLMOnly] {
            let (hardware, smc) = preset.make()
            XCTAssertNoThrow(try hardware.setLED(.green))
            XCTAssertTrue(smc.writeLog.isEmpty)
        }
    }

    // MARK: Hardware limit

    func testHardwareLimitOnFirmwareBandMac() throws {
        let (hardware, smc) = Preset.firmwareBand.make()
        XCTAssertEqual(try hardware.setHardwareLimit(band), 80)
        XCTAssertEqual(smc.writes, ["bfF0=00", "bfD0=50000000", "bfE0=4b000000", "bfF0=02"])

        smc.clearLog()
        try hardware.clearHardwareLimit()
        XCTAssertEqual(smc.writes, ["bfF0=00"])
    }

    func testHardwareLimitViaCHWAIsFixedAt80() throws {
        for preset in [Preset.tahoe, .legacy] {
            let (hardware, smc) = preset.make()
            XCTAssertEqual(try hardware.setHardwareLimit(ChargeBand(upper: 60, lower: 55)), 80)
            XCTAssertEqual(smc.writes, ["CHWA=01"])
            XCTAssertEqual(try hardware.setHardwareLimit(ChargeBand(upper: 100, lower: 95)), 100)
            XCTAssertEqual(smc.writes, ["CHWA=01", "CHWA=00"])
            XCTAssertEqual(try hardware.setHardwareLimit(band), 80)
            try hardware.clearHardwareLimit()
            XCTAssertEqual(smc.writes.suffix(2), ["CHWA=01", "CHWA=00"])
        }
    }

    func testHardwareLimitViaBCLM() throws {
        for preset in [Preset.intel, .intelBCLMOnly] {
            let (hardware, smc) = preset.make()
            XCTAssertEqual(try hardware.setHardwareLimit(band), 80)
            XCTAssertEqual(try hardware.setHardwareLimit(ChargeBand(upper: 10, lower: 10)), 20)
            XCTAssertEqual(smc.writes, ["BCLM=50", "BCLM=14"])
            try hardware.clearHardwareLimit()
            XCTAssertEqual(smc.writes.last, "BCLM=64")
        }
    }

    func testOperationsWithoutAnySupportedKey() throws {
        let smc = DryRunSMC(keys: [])
        let hardware = ChargeHardware(smc: smc, architecture: .appleSilicon)
        XCTAssertThrowsError(try hardware.setCharging(enabled: false)) {
            XCTAssertEqual($0 as? SMCError, .unsupported("charging control"))
        }
        XCTAssertThrowsError(try hardware.setCharging(enabled: true)) {
            XCTAssertEqual($0 as? SMCError, .unsupported("charging control"))
        }
        XCTAssertThrowsError(try hardware.setHardwareLimit(band)) {
            XCTAssertEqual($0 as? SMCError, .unsupported("hardware charge limit"))
        }
        XCTAssertThrowsError(try hardware.apply(.stock))
        XCTAssertNoThrow(try hardware.clearHardwareLimit())
        XCTAssertNoThrow(try hardware.setLED(.green))
        XCTAssertNoThrow(try hardware.resetToDefaults())
        XCTAssertFalse(hardware.isChargingInhibited())
        XCTAssertFalse(hardware.isAdapterDisabled())
        XCTAssertTrue(smc.writeLog.isEmpty)
    }

    // MARK: apply(command)

    private var holdCommand: ChargeCommand {
        ChargeCommand(chargingAllowed: false, adapterConnected: true, led: .green, hold: band)
    }

    private var dischargeCommand: ChargeCommand {
        ChargeCommand(chargingAllowed: false, adapterConnected: false, led: .off, hold: band)
    }

    func testApplyHoldCommandReEnablesAdapterFirst() throws {
        let expected: [Preset: [String]] = [
            .firmwareBand: ["CHIE=00", "bfF0=00", "bfD0=50000000", "bfE0=4b000000", "bfF0=02", "ACLC=03"],
            .tahoe: ["CHIE=00", "CHTE=01000000", "ACLC=03"],
            .legacy: ["CH0I=00", "CH0B=02", "CH0C=02", "ACLC=03"],
            .intel: ["CH0I=00", "CH0B=02", "CH0C=02"],
            .intelBCLMOnly: ["BCLM=50"],
        ]
        for preset in Preset.allCases {
            let (hardware, smc) = preset.make()
            try hardware.apply(holdCommand)
            XCTAssertEqual(smc.writes, expected[preset], "\(preset)")
        }
    }

    func testApplyDischargeCommandDisconnectsAdapterAfterChargingChange() throws {
        let expected: [Preset: [String]] = [
            .firmwareBand: ["bfF0=00", "bfD0=50000000", "bfE0=4b000000", "bfF0=02", "CHIE=08", "ACLC=01"],
            .tahoe: ["CHTE=01000000", "CHIE=08", "ACLC=01"],
            .legacy: ["CH0B=02", "CH0C=02", "CH0I=01", "ACLC=01"],
            .intel: ["CH0B=02", "CH0C=02", "CH0I=01"],
        ]
        for (preset, writes) in expected {
            let (hardware, smc) = preset.make()
            try hardware.apply(dischargeCommand)
            XCTAssertEqual(smc.writes, writes, "\(preset)")
            XCTAssertTrue(hardware.isAdapterDisabled())
            XCTAssertTrue(hardware.isChargingInhibited())
        }
    }

    func testApplyDischargeCommandThrowsWithoutAdapterControl() {
        let (hardware, _) = Preset.intelBCLMOnly.make()
        XCTAssertThrowsError(try hardware.apply(dischargeCommand)) {
            XCTAssertEqual($0 as? SMCError, .unsupported("adapter control"))
        }
    }

    func testApplyStockCommand() throws {
        let expected: [Preset: [String]] = [
            .firmwareBand: ["CHIE=00", "bfF0=00", "ACLC=00"],
            .tahoe: ["CHIE=00", "CHTE=00000000", "ACLC=00"],
            .legacy: ["CH0I=00", "CH0B=00", "CH0C=00", "ACLC=00"],
            .intel: ["CH0I=00", "CH0B=00", "CH0C=00"],
            .intelBCLMOnly: ["BCLM=64"],
        ]
        for preset in Preset.allCases {
            let (hardware, smc) = preset.make()
            try hardware.apply(.stock)
            XCTAssertEqual(smc.writes, expected[preset], "\(preset)")
        }
    }

    func testApplyFromDischargeBackToChargingReconnectsAdapterBeforeCharging() throws {
        let (hardware, smc) = Preset.tahoe.make()
        try hardware.apply(dischargeCommand)
        smc.clearLog()
        try hardware.apply(ChargeCommand(chargingAllowed: true, led: .orange, hold: band))
        XCTAssertEqual(smc.writes, ["CHIE=00", "CHTE=00000000", "ACLC=04"])
        XCTAssertFalse(hardware.isAdapterDisabled())
        XCTAssertFalse(hardware.isChargingInhibited())
    }

    // MARK: resetToDefaults

    /// Puts every control key into a non-stock state, then clears the log.
    private func dirty(_ preset: Preset) throws -> (ChargeHardware, DryRunSMC) {
        let (hardware, smc) = preset.make()
        try hardware.setCharging(enabled: false, hold: ChargeBand(upper: 60, lower: 50))
        if hardware.capabilities.canDischarge { try hardware.setAdapter(enabled: false) }
        try hardware.setLED(.orange)
        try hardware.setHardwareLimit(ChargeBand(upper: 60, lower: 50))
        smc.clearLog()
        return (hardware, smc)
    }

    func testResetToDefaultsWithoutPersistentBand() throws {
        let expected: [Preset: [String]] = [
            .firmwareBand: ["CHIE=00", "bfF0=00", "ACLC=00", "bfF0=00"],
            .tahoe: ["CHIE=00", "CHTE=00000000", "ACLC=00", "CHWA=00"],
            .legacy: ["CH0I=00", "CH0B=00", "CH0C=00", "ACLC=00", "CHWA=00"],
            .intel: ["CH0I=00", "CH0B=00", "CH0C=00", "BCLM=64"],
            .intelBCLMOnly: ["BCLM=64", "BCLM=64"],
        ]
        for preset in Preset.allCases {
            let (hardware, smc) = try dirty(preset)
            try hardware.resetToDefaults()
            XCTAssertEqual(smc.writes, expected[preset], "\(preset)")
            XCTAssertFalse(hardware.isChargingInhibited(), "\(preset)")
            XCTAssertFalse(hardware.isAdapterDisabled(), "\(preset)")
        }
    }

    func testResetToDefaultsLeavesPersistentBandBehind() throws {
        let expected: [Preset: [String]] = [
            .firmwareBand: ["CHIE=00", "bfF0=00", "ACLC=00", "bfF0=00", "bfD0=50000000", "bfE0=4b000000", "bfF0=02"],
            .tahoe: ["CHIE=00", "CHTE=00000000", "ACLC=00", "CHWA=01"],
            .legacy: ["CH0I=00", "CH0B=00", "CH0C=00", "ACLC=00", "CHWA=01"],
            .intel: ["CH0I=00", "CH0B=00", "CH0C=00", "BCLM=50"],
            .intelBCLMOnly: ["BCLM=64", "BCLM=50"],
        ]
        for preset in Preset.allCases {
            let (hardware, smc) = try dirty(preset)
            try hardware.resetToDefaults(persisting: band)
            XCTAssertEqual(smc.writes, expected[preset], "\(preset)")
            XCTAssertFalse(hardware.isAdapterDisabled(), "\(preset)")
        }
    }

    func testResetToDefaultsPersistingFirmwareBandEndsActive() throws {
        let (hardware, smc) = try dirty(.firmwareBand)
        try hardware.resetToDefaults(persisting: band)
        XCTAssertEqual(smc.hex("bfF0"), "02")
        XCTAssertEqual(smc.hex("bfD0"), "50000000")
        XCTAssertEqual(smc.hex("bfE0"), "4b000000")
        XCTAssertEqual(smc.hex("CHIE"), "00")
        XCTAssertEqual(smc.hex("ACLC"), "00")
    }

    func testResetToDefaultsAttemptsEveryStepAndRethrowsFirstError() {
        let base = DryRunSMC.appleSiliconLegacy()
        let smc = FaultySMC(base: base, failingWrites: ["CH0I", "ACLC"])
        let hardware = ChargeHardware(smc: smc, architecture: .appleSilicon)

        XCTAssertThrowsError(try hardware.resetToDefaults(persisting: band)) {
            XCTAssertEqual($0 as? SMCError, .smc(0x86))
        }
        XCTAssertEqual(base.writes, ["CH0B=00", "CH0C=00", "CHWA=01"])
    }

    // MARK: ChargeBand / ChargeCommand

    func testChargeBandClamping() {
        XCTAssertEqual(ChargeBand(upper: 80, lower: 75).upper, 80)
        XCTAssertEqual(ChargeBand(upper: 80, lower: 75).lower, 75)

        let tooWide = ChargeBand(upper: 150, lower: 5)
        XCTAssertEqual([tooWide.upper, tooWide.lower], [100, 10])

        let tooLow = ChargeBand(upper: 5, lower: -20)
        XCTAssertEqual([tooLow.upper, tooLow.lower], [10, 10])

        let inverted = ChargeBand(upper: 60, lower: 90)
        XCTAssertEqual([inverted.upper, inverted.lower], [60, 60], "lower never exceeds upper")
    }

    func testStockCommand() {
        let stock = ChargeCommand.stock
        XCTAssertTrue(stock.chargingAllowed)
        XCTAssertTrue(stock.adapterConnected)
        XCTAssertEqual(stock.led, .system)
        XCTAssertEqual(stock.hold, ChargeBand(upper: 100, lower: 100))
    }

    func testChargeCommandCodableRoundTrip() throws {
        let command = ChargeCommand(chargingAllowed: false, adapterConnected: false, led: .blinkSlow, hold: band)
        let decoded = try JSONDecoder().decode(ChargeCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded, command)
    }

    /// EXPECTED TO FAIL until the source is fixed (see report): `ChargeBand` uses the
    /// synthesized `init(from:)`, which bypasses the clamping done by `init(upper:lower:)`.
    /// Bands arrive at the root helper as JSON, so decoding must clamp too.
    func testChargeBandDecodingClampsOutOfRangeValues() throws {
        let decoded = try JSONDecoder().decode(ChargeBand.self, from: Data(#"{"upper":250,"lower":0}"#.utf8))
        XCTAssertEqual(decoded.upper, 100)
        XCTAssertEqual(decoded.lower, 10)

        let inverted = try JSONDecoder().decode(ChargeBand.self, from: Data(#"{"upper":50,"lower":90}"#.utf8))
        XCTAssertEqual(inverted.upper, 50)
        XCTAssertEqual(inverted.lower, 50)
    }
}
