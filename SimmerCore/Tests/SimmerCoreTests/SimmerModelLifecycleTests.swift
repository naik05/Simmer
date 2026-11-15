import AppKit
import Foundation
import XCTest
@testable import SimmerCore

@MainActor
final class SimmerModelLifecycleTests: XCTestCase {
    private func makeStore(configure: (inout SimmerSettings) -> Void = { _ in }) throws -> SettingsStore {
        let suite = "simmer.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var settings = SimmerSettings()
        configure(&settings)
        let store = SettingsStore(defaults: defaults)
        store.save(settings)
        return store
    }

    func testWillSleepAndDidWakeNotifications() async throws {
        let store = try makeStore {
            $0.stopChargingBeforeSleep = true
            $0.engine.limit = 80
        }
        let currentSnapshot = BatterySnapshot(percent: 75, isPluggedIn: true)

        let smc = DryRunSMC.hostDefault()
        let controller = DryRunChargeController(smc: smc)
        let model = SimmerModel(
            store: store,
            tickInterval: .milliseconds(50),
            readSnapshot: { currentSnapshot },
            makeController: { _, _ in controller }
        )

        model.start()
        await model.tick()
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, true)

        // Post sleep notification
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        // Give main queue task time to run
        try await Task.sleep(for: .milliseconds(50))
        await model.tick()

        // With stopChargingBeforeSleep enabled in normal mode, charging is inhibited and hold band is set
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, false)
        XCTAssertEqual(model.appliedCommand?.adapterConnected, true)
        XCTAssertEqual(model.appliedCommand?.hold.upper, 80)

        // Post wake notification
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        await model.tick()

        // Awake again: charging allowed resumes according to engine
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, true)

        model.prepareForTermination()
    }

    func testSleepCommandWhenHoldingByDischargingRestoresCharging() async throws {
        // Machines that hold by discharging must allow charging during sleep as a fail-safe
        let store = try makeStore {
            $0.stopChargingBeforeSleep = true
            $0.engine.limit = 80
        }
        let smc = DryRunSMC(keys: [
            SMCValue(key: SMCKeys.chie, type: "ch8*", bytes: [0x00]) // adapter cycling machine
        ])
        let controller = DryRunChargeController(smc: smc)
        let model = SimmerModel(
            store: store,
            readSnapshot: { BatterySnapshot(percent: 80, isPluggedIn: true) },
            makeController: { _, _ in controller }
        )

        model.start()
        await model.tick()
        XCTAssertTrue(model.capabilities.holdsByDischarging)

        // Put to sleep
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        await model.tick()

        // When holdsByDischarging is true, sleep command must reconnect adapter and allow charging
        XCTAssertEqual(model.appliedCommand?.adapterConnected, true)
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, true)

        model.prepareForTermination()
    }

    func testAdapterDisconnectTreatsMacAsPluggedIn() async throws {
        final class StateBox: @unchecked Sendable {
            var isPluggedIn = false
        }
        let box = StateBox()

        let store = try makeStore()
        let model = SimmerModel(
            store: store,
            readSnapshot: { BatterySnapshot(percent: 85, isPluggedIn: box.isPluggedIn) },
            makeController: { _, _ in DryRunChargeController() }
        )

        await model.tick()
        model.startDischarge()
        await model.tick()

        // Simmer has disconnected the adapter
        XCTAssertEqual(model.appliedCommand?.adapterConnected, false)

        // Hardware reports unplugged because the adapter is disconnected electrically
        box.isPluggedIn = false
        await model.tick()

        // Model must override snapshot?.isPluggedIn to true to prevent engine flapping
        XCTAssertEqual(model.snapshot?.isPluggedIn, true)
        XCTAssertEqual(model.activity, .discharging)
    }

    func testReconnectAndDryRunSettings() async throws {
        let store = try makeStore()
        let model = SimmerModel(
            store: store,
            readSnapshot: { BatterySnapshot(percent: 80, isPluggedIn: true) },
            makeController: { _, _ in
                DryRunChargeController()
            }
        )

        await model.tick()
        XCTAssertTrue(model.connection.isUsable)

        // Manual reconnect
        await model.reconnect()
        XCTAssertTrue(model.connection.isUsable)

        // Toggling dryRun triggers reconnect
        model.settings.dryRun.toggle()
        try await Task.sleep(for: .milliseconds(50))
        await model.tick()
        XCTAssertTrue(model.connection.isUsable)
    }

    func testClearDryRunLogAndLogTruncation() async throws {
        let store = try makeStore { $0.dryRun = true }
        var writeCallback: ((DryRunSMC.Write) -> Void)?
        let model = SimmerModel(
            store: store,
            readSnapshot: { BatterySnapshot(percent: 80, isPluggedIn: true) },
            makeController: { _, onWrite in
                writeCallback = onWrite
                return DryRunChargeController(onWrite: onWrite)
            }
        )

        await model.tick()

        // Produce 250 log entries
        for i in 1...250 {
            writeCallback?(DryRunSMC.Write(key: "TEST", bytes: [UInt8(i % 256)]))
        }
        try await Task.sleep(for: .milliseconds(50))

        // Must be capped at 200 entries
        XCTAssertEqual(model.dryRunLog.count, 200)

        // Clear log
        model.clearDryRunLog()
        XCTAssertTrue(model.dryRunLog.isEmpty)
    }
}
