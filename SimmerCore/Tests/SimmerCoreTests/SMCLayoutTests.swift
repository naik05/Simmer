import XCTest
@testable import SimmerCore

final class SMCLayoutTests: XCTestCase {
    func testParamStructMatchesKernelLayout() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.bytes), 48)
    }

    func testFourCCRoundTrip() {
        XCTAssertEqual(FourCC("CH0B").description, "CH0B")
        XCTAssertEqual(FourCC("CH0B").rawValue, 0x4348_3042)
        XCTAssertEqual(FourCC("flt").description, "flt ")
    }
}
