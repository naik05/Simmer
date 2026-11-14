import Foundation

/// In-memory SMC used for the dry-run mode and unit tests. Nothing touches real hardware.
///
/// Every write is recorded in ``writeLog`` so tests (and the UI's dry-run console) can
/// inspect exactly which keys would have been written.
public final class DryRunSMC: SMCInterface, @unchecked Sendable {
    public struct Write: Sendable, Equatable {
        public let key: FourCC
        public let bytes: [UInt8]
        public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    }

    private let lock = NSLock()
    private var store: [FourCC: SMCValue]
    private var log: [Write] = []
    private let onWrite: (@Sendable (Write) -> Void)?

    public init(keys: [SMCValue], onWrite: (@Sendable (Write) -> Void)? = nil) {
        store = Dictionary(uniqueKeysWithValues: keys.map { ($0.key, $0) })
        self.onWrite = onWrite
    }

    public var writeLog: [Write] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    public func clearLog() {
        lock.lock()
        defer { lock.unlock() }
        log.removeAll()
    }

    public func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        lock.lock()
        defer { lock.unlock() }
        guard let value = store[key] else { throw SMCError.keyNotFound(key) }
        return SMCKeyInfo(size: value.bytes.count, type: value.type)
    }

    public func read(_ key: FourCC) throws -> SMCValue {
        lock.lock()
        defer { lock.unlock() }
        guard let value = store[key] else { throw SMCError.keyNotFound(key) }
        return value
    }

    public func write(_ key: FourCC, bytes: [UInt8]) throws {
        lock.lock()
        guard let existing = store[key] else {
            lock.unlock()
            throw SMCError.keyNotFound(key)
        }
        guard existing.bytes.count == bytes.count else {
            lock.unlock()
            throw SMCError.sizeMismatch(key: key, expected: existing.bytes.count, got: bytes.count)
        }
        store[key] = SMCValue(key: key, type: existing.type, bytes: bytes)
        let entry = Write(key: key, bytes: bytes)
        log.append(entry)
        lock.unlock()
        onWrite?(entry)
    }
}

extension DryRunSMC {
    private static func key(_ name: String, _ type: String, _ bytes: [UInt8]) -> SMCValue {
        SMCValue(key: FourCC(name), type: FourCC(type), bytes: bytes)
    }

    /// Apple Silicon with the classic `CH0B`/`CH0C`/`CH0I` keys (macOS 14 – early 15).
    public static func appleSiliconLegacy() -> DryRunSMC {
        DryRunSMC(keys: [
            key("CH0B", "hex_", [0]), key("CH0C", "hex_", [0]), key("CH0I", "hex_", [0]),
            key("CHWA", "ui8 ", [0]), key("ACLC", "ui8 ", [0]),
            key("TB0T", "flt ", [0, 0, 0xF0, 0x41]),
        ])
    }

    /// Apple Silicon with the newer `CHTE`/`CHIE` keys (macOS 15.7+/26).
    public static func appleSiliconTahoe() -> DryRunSMC {
        DryRunSMC(keys: [
            key("CHTE", "ui32", [0, 0, 0, 0]), key("CHIE", "hex_", [0]),
            key("CHWA", "ui8 ", [0]), key("ACLC", "ui8 ", [0]),
            key("TB0T", "flt ", [0, 0, 0xF0, 0x41]),
        ])
    }

    /// Apple Silicon whose firmware enforces a charge band itself (`bfF0`/`bfD0`/`bfE0`, macOS 27).
    public static func appleSiliconFirmwareBand() -> DryRunSMC {
        DryRunSMC(keys: [
            key("bfF0", "ui8 ", [0]), key("bfD0", "ui32", [100, 0, 0, 0]), key("bfE0", "ui32", [95, 0, 0, 0]),
            key("CHIE", "hex_", [0]), key("ACLC", "ui8 ", [0]),
            key("TB0T", "flt ", [0, 0, 0xF0, 0x41]),
        ])
    }

    /// Apple Silicon whose firmware gates every charging-inhibit key; only `CHIE` is usable.
    public static func appleSiliconAdapterOnly() -> DryRunSMC {
        DryRunSMC(keys: [
            key("CHIE", "hex_", [0]), key("ACLC", "ui8 ", [0]),
            key("TB0T", "flt ", [0, 0, 0xF0, 0x41]),
        ])
    }

    /// Intel Mac with `BCLM` plus the charging-inhibit keys.
    public static func intel() -> DryRunSMC {
        DryRunSMC(keys: [
            key("BCLM", "ui8 ", [100]), key("CH0B", "hex_", [0]), key("CH0C", "hex_", [0]),
            key("CH0I", "hex_", [0]), key("TB0T", "sp78", [0x1E, 0x00]),
        ])
    }

    /// Older Intel Mac that only exposes `BCLM`.
    public static func intelBCLMOnly() -> DryRunSMC {
        DryRunSMC(keys: [key("BCLM", "ui8 ", [100]), key("TB0T", "sp78", [0x1E, 0x00])])
    }

    /// A simulated machine matching the host architecture.
    public static func hostDefault(onWrite: (@Sendable (Write) -> Void)? = nil) -> DryRunSMC {
        #if arch(arm64)
        let template = appleSiliconTahoe()
        #else
        let template = intel()
        #endif
        return DryRunSMC(keys: Array(template.snapshot()), onWrite: onWrite)
    }

    func snapshot() -> [SMCValue] {
        lock.lock()
        defer { lock.unlock() }
        return Array(store.values)
    }
}
