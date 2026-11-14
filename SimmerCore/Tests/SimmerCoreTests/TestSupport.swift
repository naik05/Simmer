import Foundation
import XCTest
@testable import SimmerCore

// MARK: - Snapshots & configs

/// A plugged-in, 30 °C battery at `percent` unless stated otherwise.
func snapshot(
    _ percent: Int, plugged: Bool = true, temperature: Double? = 30, full: Bool = false
) -> BatterySnapshot {
    BatterySnapshot(percent: percent, isPluggedIn: plugged, isFullyCharged: full, temperatureC: temperature)
}

func engineConfig(
    limit: Int = 80, buffer: Int = 5, _ customize: (inout EngineConfig) -> Void = { _ in }
) -> EngineConfig {
    var config = EngineConfig()
    config.limit = limit
    config.sailingBuffer = buffer
    customize(&config)
    return config
}

let referenceDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

// MARK: - Engine simulation

/// Drives a ``ChargeEngine`` tick by tick with an injected clock.
struct EngineSimulation {
    var engine: ChargeEngine
    var config: EngineConfig
    var now = referenceDate
    var plugged = true
    var temperature: Double? = 30
    /// Every event emitted so far, in order.
    private(set) var events: [EngineEvent] = []
    private(set) var percent = 50

    init(config: EngineConfig = EngineConfig(), state: EngineState = EngineState()) {
        self.config = config
        engine = ChargeEngine(state: state)
    }

    /// Advances the clock by `after` seconds and feeds the engine a reading of `percent`.
    @discardableResult
    mutating func tick(_ percent: Int, full: Bool = false, after seconds: TimeInterval = 30) -> EngineOutput {
        now += seconds
        self.percent = percent
        let reading = snapshot(percent, plugged: plugged, temperature: temperature, full: full)
        let output = engine.tick(snapshot: reading, config: config, now: now)
        events += output.events
        return output
    }

    /// One tick per percent value.
    @discardableResult
    mutating func sweep(_ percents: some Sequence<Int>) -> [EngineOutput] {
        percents.map { tick($0) }
    }

    /// Calibration progress for the most recent reading.
    var progress: Double? {
        engine.calibrationProgress(
            snapshot: snapshot(percent, plugged: plugged, temperature: temperature), config: config, now: now
        )
    }
}

func assertOutput(
    _ output: EngineOutput, charging: Bool, adapter: Bool = true, activity: ChargeActivity,
    events: [EngineEvent]? = nil, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(output.command.chargingAllowed, charging, "chargingAllowed", file: file, line: line)
    XCTAssertEqual(output.command.adapterConnected, adapter, "adapterConnected", file: file, line: line)
    XCTAssertEqual(output.activity, activity, "activity", file: file, line: line)
    if let events {
        XCTAssertEqual(output.events, events, "events", file: file, line: line)
    }
}

// MARK: - SMC helpers

extension DryRunSMC {
    /// The write log as `KEY=hex` strings, e.g. `CHTE=01000000`.
    var writes: [String] { writeLog.map { "\($0.key)=\($0.hex)" } }

    func hex(_ key: FourCC) -> String? { (try? read(key))?.hex }
}

enum Preset: CaseIterable {
    case firmwareBand, tahoe, legacy, intel, intelBCLMOnly

    var architecture: HostArchitecture {
        switch self {
        case .firmwareBand, .tahoe, .legacy: .appleSilicon
        case .intel, .intelBCLMOnly: .intel
        }
    }

    func makeSMC() -> DryRunSMC {
        switch self {
        case .firmwareBand: .appleSiliconFirmwareBand()
        case .tahoe: .appleSiliconTahoe()
        case .legacy: .appleSiliconLegacy()
        case .intel: .intel()
        case .intelBCLMOnly: .intelBCLMOnly()
        }
    }

    func make() -> (hardware: ChargeHardware, smc: DryRunSMC) {
        let smc = makeSMC()
        return (ChargeHardware(smc: smc, architecture: architecture), smc)
    }
}

/// Wraps a ``DryRunSMC`` and injects failures. Still purely in-memory.
final class FaultySMC: SMCInterface, @unchecked Sendable {
    let base: DryRunSMC
    private let lock = NSLock()
    private var failingWrites: Set<FourCC>
    private let privilegedKeys: Set<FourCC>

    init(base: DryRunSMC, failingWrites: Set<FourCC> = [], privilegedKeys: Set<FourCC> = []) {
        self.base = base
        self.failingWrites = failingWrites
        self.privilegedKeys = privilegedKeys
    }

    func setFailingWrites(_ keys: Set<FourCC>) {
        lock.withLock { failingWrites = keys }
    }

    func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        if privilegedKeys.contains(key) { throw SMCError.notPrivileged(key) }
        return try base.keyInfo(key)
    }

    func read(_ key: FourCC) throws -> SMCValue { try base.read(key) }

    func write(_ key: FourCC, bytes: [UInt8]) throws {
        if lock.withLock({ failingWrites.contains(key) }) { throw SMCError.smc(0x86) }
        try base.write(key, bytes: bytes)
    }
}

// MARK: - Throwaway UserDefaults

extension XCTestCase {
    /// A private defaults suite that is removed again when the test ends.
    ///
    /// The suite name is an absolute path inside the temporary directory, so its backing
    /// plist never lands in `~/Library/Preferences` (cfprefsd would otherwise leave an
    /// empty file behind for every removed suite).
    func makeThrowawayDefaults() throws -> UserDefaults {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = directory.appendingPathComponent("defaults").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            CFPreferencesAppSynchronize(suite as CFString)
            try? FileManager.default.removeItem(at: directory)
        }
        return defaults
    }
}

// MARK: - Concurrency helpers

/// Manually advanced monotonic clock for ``HelperCore``.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ start: TimeInterval = 1_000) { value = start }

    var now: TimeInterval { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

/// Collects values delivered to `@Sendable` reply blocks.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] { lock.withLock { stored } }

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }
}
