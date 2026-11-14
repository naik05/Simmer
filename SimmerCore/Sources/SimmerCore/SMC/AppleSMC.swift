import Foundation
import IOKit

// Layout mirrors the kernel's SMCParamStruct (80 bytes). Field order and the explicit
// `padding` member matter: Swift packs nested structs by size, not stride.
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCParamStruct {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

/// Thin, thread-safe wrapper around the `AppleSMC` IOKit user client.
///
/// Reading works for any user; writing requires root (the privileged helper).
public final class AppleSMC: SMCInterface, @unchecked Sendable {
    private enum Selector {
        static let kernelIndex: UInt32 = 2
        static let readBytes: UInt8 = 5
        static let writeBytes: UInt8 = 6
        static let keyFromIndex: UInt8 = 8
        static let readKeyInfo: UInt8 = 9
    }

    private static let smcKeyNotFound: UInt8 = 0x84
    private static let ioReturnNotPrivileged = Int32(bitPattern: 0xE00002C1)

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private var infoCache: [FourCC: SMCKeyInfo] = [:]

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw SMCError.openFailed(result) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    public func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        lock.lock()
        defer { lock.unlock() }
        return try lockedKeyInfo(key)
    }

    public func read(_ key: FourCC) throws -> SMCValue {
        lock.lock()
        defer { lock.unlock() }
        let info = try lockedKeyInfo(key)
        var input = SMCParamStruct()
        input.key = key.rawValue
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = Selector.readBytes
        let output = try call(input, key: key)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.size)) }
        return SMCValue(key: key, type: info.type, bytes: bytes)
    }

    public func write(_ key: FourCC, bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        let info = try lockedKeyInfo(key)
        guard info.size == bytes.count else {
            throw SMCError.sizeMismatch(key: key, expected: info.size, got: bytes.count)
        }
        var input = SMCParamStruct()
        input.key = key.rawValue
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = Selector.writeBytes
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        _ = try call(input, key: key)
    }

    /// Enumerates every key the SMC exposes (diagnostics only).
    public func allKeys() -> [FourCC] {
        lock.lock()
        defer { lock.unlock() }
        var keys: [FourCC] = []
        var index: UInt32 = 0
        while index < 10_000 {
            var input = SMCParamStruct()
            input.data8 = Selector.keyFromIndex
            input.data32 = index
            guard let output = try? call(input, key: "#KEY"), output.key != 0 else { break }
            keys.append(FourCC(rawValue: output.key))
            index += 1
        }
        return keys
    }

    private func lockedKeyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        if let cached = infoCache[key] { return cached }
        var input = SMCParamStruct()
        input.key = key.rawValue
        input.data8 = Selector.readKeyInfo
        let output = try call(input, key: key)
        let size = Int(output.keyInfo.dataSize)
        guard size > 0, size <= 32 else { throw SMCError.keyNotFound(key) }
        let info = SMCKeyInfo(size: size, type: FourCC(rawValue: output.keyInfo.dataType))
        infoCache[key] = info
        return info
    }

    private func call(_ input: SMCParamStruct, key: FourCC) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection, Selector.kernelIndex,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
        )
        if result == Self.ioReturnNotPrivileged { throw SMCError.notPrivileged(key) }
        guard result == kIOReturnSuccess else { throw SMCError.ioKit(result) }
        if output.result == Self.smcKeyNotFound { throw SMCError.keyNotFound(key) }
        guard output.result == 0 else { throw SMCError.smc(output.result) }
        return output
    }
}
