import XCTest
@testable import SimmerCore

final class SMCValueTests: XCTestCase {
    private func value(_ type: String, _ bytes: [UInt8]) -> SMCValue {
        SMCValue(key: "TEST", type: FourCC(type), bytes: bytes)
    }

    // MARK: Decoding

    func testFloatIsLittleEndianIEEE754() {
        XCTAssertEqual(value("flt", [0x00, 0x00, 0xF0, 0x41]).doubleValue, 30.0)
        XCTAssertEqual(value("flt", [0x00, 0x00, 0x0E, 0x42]).doubleValue, 35.5)
        XCTAssertEqual(value("flt", [0x00, 0x00, 0x80, 0xBF]).doubleValue, -1.0)
        XCTAssertEqual(value("flt", [0, 0, 0, 0]).doubleValue, 0)
    }

    func testFloatWithWrongSizeIsNil() {
        XCTAssertNil(value("flt", [0x00, 0xF0, 0x41]).doubleValue)
        XCTAssertNil(value("flt", [0, 0, 0, 0, 0]).doubleValue)
        XCTAssertNil(value("flt", []).doubleValue)
    }

    func testSP78IsBigEndianSignedFixedPoint() {
        XCTAssertEqual(value("sp78", [0x1E, 0x00]).doubleValue, 30.0)
        XCTAssertEqual(value("sp78", [0x23, 0x80]).doubleValue, 35.5)
        XCTAssertEqual(value("sp78", [0x19, 0x40]).doubleValue, 25.25)
        XCTAssertEqual(value("sp78", [0xFF, 0x80]).doubleValue, -0.5)
        XCTAssertEqual(value("sp78", [0xF6, 0x00]).doubleValue, -10.0)
    }

    func testSP78WithWrongSizeIsNil() {
        XCTAssertNil(value("sp78", [0x1E]).doubleValue)
        XCTAssertNil(value("sp78", [0x1E, 0x00, 0x00]).doubleValue)
    }

    func testUnsignedIntegersAreLittleEndian() {
        XCTAssertEqual(value("ui8", [0x64]).doubleValue, 100)
        XCTAssertEqual(value("ui8", [0xFF]).doubleValue, 255)
        XCTAssertEqual(value("ui16", [0x34, 0x12]).doubleValue, 0x1234)
        XCTAssertEqual(value("ui32", [0x78, 0x56, 0x34, 0x12]).doubleValue, 0x1234_5678)
        XCTAssertEqual(value("ui32", [0xFF, 0xFF, 0xFF, 0xFF]).doubleValue, 4_294_967_295)
        XCTAssertEqual(value("ui32", [80, 0, 0, 0]).doubleValue, 80)
    }

    func testHexFlagAndSignedByte() {
        XCTAssertEqual(value("hex_", [0x02]).doubleValue, 2)
        XCTAssertEqual(value("flag", [0x01]).doubleValue, 1)
        XCTAssertEqual(value("si8", [0xFF]).doubleValue, -1)
        XCTAssertEqual(value("si8", [0x7F]).doubleValue, 127)
        XCTAssertNil(value("si8", [0x01, 0x02]).doubleValue)
    }

    func testIntegerWithEmptyOrOversizedPayloadIsNil() {
        XCTAssertNil(value("ui8", []).doubleValue)
        XCTAssertNil(value("ui32", [1, 2, 3, 4, 5]).doubleValue)
    }

    func testUnknownTypeIsNil() {
        XCTAssertNil(value("ch8*", [0x41, 0x42]).doubleValue)
        XCTAssertNil(value("{pwm", [0, 0]).doubleValue)
    }

    func testIsZeroAndHex() {
        XCTAssertTrue(value("ui32", [0, 0, 0, 0]).isZero)
        XCTAssertFalse(value("ui32", [0, 0, 0, 1]).isZero)
        XCTAssertTrue(value("ui8", []).isZero)
        XCTAssertEqual(value("ui32", [0x01, 0x00, 0xAB, 0xFF]).hex, "0100abff")
    }

    // MARK: FourCC

    func testFourCCPadsShortStringsWithSpaces() {
        XCTAssertEqual(FourCC("ui8"), FourCC("ui8 "))
        XCTAssertEqual(FourCC("ui8").rawValue, 0x7569_3820)
        XCTAssertEqual(FourCC("").description, "    ")
        XCTAssertEqual(FourCC("a").description, "a   ")
    }

    func testFourCCTruncatesLongStrings() {
        XCTAssertEqual(FourCC("CH0BXYZ"), FourCC("CH0B"))
    }

    func testFourCCLiteralRawValueAndCodable() throws {
        let literal: FourCC = "bfF0"
        XCTAssertEqual(literal, FourCC(rawValue: 0x6266_4630))
        XCTAssertEqual(literal.description, "bfF0")
        XCTAssertNotEqual(FourCC("bfF0"), FourCC("BFF0"), "keys are case-sensitive")

        let decoded = try JSONDecoder().decode([FourCC].self, from: JSONEncoder().encode([literal]))
        XCTAssertEqual(decoded, [literal])
    }

    // MARK: DryRunSMC

    func testDryRunReadAndKeyInfo() throws {
        let smc = DryRunSMC.appleSiliconTahoe()
        XCTAssertEqual(try smc.keyInfo("CHTE"), SMCKeyInfo(size: 4, type: "ui32"))
        XCTAssertEqual(try smc.keyInfo("CHIE"), SMCKeyInfo(size: 1, type: "hex_"))
        XCTAssertEqual(try smc.read("TB0T").doubleValue, 30.0)
        XCTAssertEqual(try DryRunSMC.intel().read("TB0T").doubleValue, 30.0)
        XCTAssertEqual(try DryRunSMC.intel().read("BCLM").doubleValue, 100)
    }

    func testDryRunUnknownKeyErrors() {
        let smc = DryRunSMC.appleSiliconTahoe()
        XCTAssertThrowsError(try smc.read("NOPE")) { XCTAssertEqual($0 as? SMCError, .keyNotFound("NOPE")) }
        XCTAssertThrowsError(try smc.keyInfo("NOPE")) { XCTAssertEqual($0 as? SMCError, .keyNotFound("NOPE")) }
        XCTAssertThrowsError(try smc.write("NOPE", bytes: [1])) { XCTAssertEqual($0 as? SMCError, .keyNotFound("NOPE")) }
        XCTAssertNil(smc.readIfPresent("NOPE"))
        XCTAssertTrue(smc.writeLog.isEmpty)
    }

    func testDryRunSizeMismatchIsRejectedAndNotLogged() {
        let smc = DryRunSMC.appleSiliconTahoe()
        XCTAssertThrowsError(try smc.write("CHTE", bytes: [1])) {
            XCTAssertEqual($0 as? SMCError, .sizeMismatch(key: "CHTE", expected: 4, got: 1))
        }
        XCTAssertThrowsError(try smc.write("CHIE", bytes: [8, 0])) {
            XCTAssertEqual($0 as? SMCError, .sizeMismatch(key: "CHIE", expected: 1, got: 2))
        }
        XCTAssertEqual(smc.hex("CHTE"), "00000000", "a rejected write must not change the value")
        XCTAssertTrue(smc.writeLog.isEmpty)
    }

    func testDryRunWriteUpdatesValueKeepsTypeAndLogs() throws {
        let observed = Box<DryRunSMC.Write>()
        let smc = DryRunSMC(
            keys: [SMCValue(key: "CHTE", type: "ui32", bytes: [0, 0, 0, 0])],
            onWrite: { observed.append($0) }
        )
        try smc.write("CHTE", bytes: [1, 0, 0, 0])
        try smc.write("CHTE", bytes: [0, 0, 0, 0])

        XCTAssertEqual(try smc.read("CHTE"), SMCValue(key: "CHTE", type: "ui32", bytes: [0, 0, 0, 0]))
        XCTAssertEqual(smc.writes, ["CHTE=01000000", "CHTE=00000000"])
        XCTAssertEqual(observed.values, smc.writeLog)

        smc.clearLog()
        XCTAssertTrue(smc.writeLog.isEmpty)
    }

    // MARK: hasKey

    func testHasKey() {
        let smc = DryRunSMC.appleSiliconTahoe()
        XCTAssertTrue(smc.hasKey("CHTE"))
        XCTAssertFalse(smc.hasKey("CH0B"))
        XCTAssertFalse(smc.hasKey("BCLM"))
    }

    func testHasKeyTreatsZeroSizedKeysAsMissing() {
        let smc = DryRunSMC(keys: [SMCValue(key: "VOID", type: "ui8", bytes: [])])
        XCTAssertFalse(smc.hasKey("VOID"))
    }

    func testHasKeyTreatsGatedKeysAsUnusable() {
        let smc = FaultySMC(base: .appleSiliconTahoe(), privilegedKeys: ["CHTE", "NOPE"])
        XCTAssertFalse(smc.hasKey("CHTE"), "a key that rejects even key-info lookups cannot be used")
        XCTAssertFalse(smc.hasKey("NOPE"))
        XCTAssertTrue(smc.hasKey("CHIE"))
        XCTAssertFalse(smc.hasKey("CH0B"))
    }

    // MARK: Errors & temperature

    func testErrorDescriptions() {
        XCTAssertEqual(SMCError.keyNotFound("CH0B").description, "SMC key CH0B does not exist on this machine")
        XCTAssertEqual(
            SMCError.sizeMismatch(key: "CHTE", expected: 4, got: 1).description,
            "SMC key CHTE expects 4 byte(s), got 1"
        )
        XCTAssertEqual(SMCError.smc(0x84).description, "SMC result code 0x84")
        XCTAssertEqual(SMCError.unsupported("adapter control").description, "Unsupported on this hardware: adapter control")
    }

    func testReaderPicksHottestPlausibleSMCSensor() {
        let smc = DryRunSMC(keys: [
            SMCValue(key: "TB0T", type: "flt", bytes: [0x00, 0x00, 0xF0, 0x41]),   // 30.0
            SMCValue(key: "TB1T", type: "flt", bytes: [0x00, 0x00, 0x0E, 0x42]),   // 35.5
            SMCValue(key: "TB2T", type: "flt", bytes: [0x00, 0x00, 0x7A, 0x43]),   // 250 – implausible
        ])
        XCTAssertEqual(BatteryReader(smc: smc).smcTemperature(), 35.5)
        XCTAssertEqual(BatteryReader(smc: DryRunSMC.intel()).smcTemperature(), 30.0)
        XCTAssertNil(BatteryReader(smc: DryRunSMC(keys: [])).smcTemperature())
        XCTAssertNil(BatteryReader(smc: nil).smcTemperature())
    }
}
