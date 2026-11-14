import Foundation

/// Four-character SMC key or data-type code (e.g. `CH0B`, `flt `).
public struct FourCC: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Creates a code from a string. Strings shorter than four characters are padded with spaces.
    public init(_ string: String) {
        var bytes = Array(string.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((rawValue >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct SMCKeyInfo: Sendable, Equatable {
    public let size: Int
    public let type: FourCC

    public init(size: Int, type: FourCC) {
        self.size = size
        self.type = type
    }
}

public struct SMCValue: Sendable, Equatable {
    public let key: FourCC
    public let type: FourCC
    public let bytes: [UInt8]

    public init(key: FourCC, type: FourCC, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Best-effort numeric decoding for the data types Simmer reads.
    public var doubleValue: Double? {
        switch type.description {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            return Double(Float(bitPattern: littleEndianUInt(bytes)))
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "ui8 ", "ui16", "ui32", "hex_", "flag":
            guard !bytes.isEmpty, bytes.count <= 4 else { return nil }
            return Double(littleEndianUInt(bytes))
        case "si8 ":
            guard bytes.count == 1 else { return nil }
            return Double(Int8(bitPattern: bytes[0]))
        default:
            return nil
        }
    }

    /// `true` when every byte is zero.
    public var isZero: Bool { bytes.allSatisfy { $0 == 0 } }

    private func littleEndianUInt(_ bytes: [UInt8]) -> UInt32 {
        bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * UInt32($1.offset))) }
    }
}

public enum SMCError: Error, Equatable, CustomStringConvertible {
    case serviceNotFound
    case openFailed(Int32)
    case keyNotFound(FourCC)
    case notPrivileged(FourCC)
    case sizeMismatch(key: FourCC, expected: Int, got: Int)
    case ioKit(Int32)
    case smc(UInt8)
    case unsupported(String)

    public var description: String {
        switch self {
        case .serviceNotFound: "AppleSMC service not found"
        case .openFailed(let code): "Opening AppleSMC failed (0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case .keyNotFound(let key): "SMC key \(key) does not exist on this machine"
        case .notPrivileged(let key): "Accessing SMC key \(key) requires root"
        case .sizeMismatch(let key, let expected, let got): "SMC key \(key) expects \(expected) byte(s), got \(got)"
        case .ioKit(let code): "IOKit error 0x\(String(UInt32(bitPattern: code), radix: 16))"
        case .smc(let code): "SMC result code 0x\(String(code, radix: 16))"
        case .unsupported(let what): "Unsupported on this hardware: \(what)"
        }
    }
}

/// Minimal SMC access used by the hardware layer. Implemented by ``AppleSMC`` (real hardware)
/// and ``DryRunSMC`` (in-memory simulation).
public protocol SMCInterface: AnyObject, Sendable {
    func keyInfo(_ key: FourCC) throws -> SMCKeyInfo
    func read(_ key: FourCC) throws -> SMCValue
    func write(_ key: FourCC, bytes: [UInt8]) throws
}

extension SMCInterface {
    public func hasKey(_ key: FourCC) -> Bool {
        // A key that answers "not privileged" counts as absent: for the root helper that
        // means the firmware gates it (e.g. by entitlement) and it cannot be used.
        guard let info = try? keyInfo(key) else { return false }
        return info.size > 0
    }

    public func readIfPresent(_ key: FourCC) -> SMCValue? { try? read(key) }
}
