import Foundation
import XCTest
@testable import SimmerCore

final class HostInfoAndKeysTests: XCTestCase {
    func testHostInfoArchitecture() {
        #if arch(arm64)
        XCTAssertEqual(HostInfo.architecture, .appleSilicon)
        #else
        XCTAssertEqual(HostInfo.architecture, .intel)
        #endif
    }

    func testHostInfoModelIdentifier() {
        let model = HostInfo.modelIdentifier
        XCTAssertFalse(model.isEmpty)
        XCTAssertNotEqual(model, "unknown")
    }

    func testHostInfoOSVersion() {
        let os = HostInfo.osVersion
        let parts = os.split(separator: ".")
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        for part in parts {
            XCTAssertNotNil(Int(part))
        }
    }

    func testSMCKeysCatalog() {
        let catalog = SMCKeys.catalog
        XCTAssertFalse(catalog.isEmpty)
        for item in catalog {
            XCTAssertEqual(item.key.description.count, 4)
            XCTAssertFalse(item.purpose.isEmpty)
        }
    }

    func testSMCKeysTemperatureKeys() {
        XCTAssertEqual(SMCKeys.temperatureKeys.count, 3)
        XCTAssertTrue(SMCKeys.temperatureKeys.contains("TB0T"))
        XCTAssertTrue(SMCKeys.temperatureKeys.contains("TB1T"))
        XCTAssertTrue(SMCKeys.temperatureKeys.contains("TB2T"))
    }

    func testLEDStateCasesAndCodable() throws {
        XCTAssertEqual(LEDState.allCases.count, 7)
        XCTAssertEqual(LEDState.system.rawValue, 0x00)
        XCTAssertEqual(LEDState.off.rawValue, 0x01)
        XCTAssertEqual(LEDState.green.rawValue, 0x03)
        XCTAssertEqual(LEDState.orange.rawValue, 0x04)
        XCTAssertEqual(LEDState.blinkOnce.rawValue, 0x05)
        XCTAssertEqual(LEDState.blinkSlow.rawValue, 0x06)
        XCTAssertEqual(LEDState.blinkFast.rawValue, 0x07)

        for state in LEDState.allCases {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(LEDState.self, from: data)
            XCTAssertEqual(state, decoded)
        }
    }

    func testHostArchitectureCodable() throws {
        let arm = HostArchitecture.appleSilicon
        let intel = HostArchitecture.intel

        let armData = try JSONEncoder().encode(arm)
        let armDecoded = try JSONDecoder().decode(HostArchitecture.self, from: armData)
        XCTAssertEqual(arm, armDecoded)

        let intelData = try JSONEncoder().encode(intel)
        let intelDecoded = try JSONDecoder().decode(HostArchitecture.self, from: intelData)
        XCTAssertEqual(intel, intelDecoded)
    }
}
