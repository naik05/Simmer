import Foundation
import XCTest
@testable import SimmerCore

final class DryRunChargeControllerTests: XCTestCase {
    func testHandshakeReturnsDryRun() async throws {
        let controller = DryRunChargeController()
        let handshake = try await controller.handshake()
        XCTAssertTrue(handshake.isDryRun)
        XCTAssertEqual(handshake.version, HelperCore.version)
    }

    func testApplyCommandAndCaptureWrites() async throws {
        final class LogBox: @unchecked Sendable {
            private let lock = NSLock()
            private var writes: [DryRunSMC.Write] = []
            func add(_ write: DryRunSMC.Write) {
                lock.withLock { writes.append(write) }
            }
            var count: Int {
                lock.withLock { writes.count }
            }
        }

        let log = LogBox()
        let smc = DryRunSMC.hostDefault()
        let controller = DryRunChargeController(smc: smc) { write in
            log.add(write)
        }

        let cmd = ChargeCommand(
            chargingAllowed: false,
            adapterConnected: true,
            led: .green,
            hold: ChargeBand(upper: 80, lower: 75)
        )
        try await controller.apply(cmd)

        XCTAssertGreaterThan(log.count, 0)
    }

    func testConfigurePolicyAndResetToStock() async throws {
        let controller = DryRunChargeController()
        let policy = FailSafePolicy(resetOnDisconnect: true, persistentBand: ChargeBand(upper: 80, lower: 75))
        try await controller.configure(policy)
        try await controller.resetToStock()
        controller.disconnect()
    }
}
