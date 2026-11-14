import Foundation

/// SMC keys Simmer reads or writes.
///
/// Mappings were cross-checked against the open-source tools `battery` (actuallymentor) and
/// `batt` (charlie0129) and are resolved at runtime by key presence, never by OS version.
///
/// | Purpose                    | Apple Silicon                         | Intel                |
/// |----------------------------|---------------------------------------|----------------------|
/// | Inhibit charging           | `bfF0`+`bfD0`+`bfE0` (macOS 27), `CHTE`, `CH0B`+`CH0C` | `CH0B`+`CH0C`, `BCLM`|
/// | Disconnect adapter         | `CHIE` (new), `CH0J`, `CH0I` (old)    | `CH0I`               |
/// | Limit while off / asleep   | `bfF0`/`bfD0`/`bfE0` (new), `CHWA`    | `BCLM`               |
/// | MagSafe LED                | `ACLC`                                | –                    |
/// | Battery temperature        | `TB0T`/`TB1T`/`TB2T` (`flt `)         | same keys (`sp78`)   |
public enum SMCKeys {
    // Charging inhibit
    public static let ch0b: FourCC = "CH0B"   // 0x00 charge, 0x02 inhibit
    public static let ch0c: FourCC = "CH0C"   // 0x00 charge, 0x02 inhibit
    public static let chte: FourCC = "CHTE"   // 00000000 charge, 01000000 inhibit

    // Adapter disconnect (force discharge)
    public static let ch0i: FourCC = "CH0I"   // 0x00 adapter on, 0x01 adapter off
    public static let ch0j: FourCC = "CH0J"   // 0x00 adapter on, 0x01 adapter off
    public static let chie: FourCC = "CHIE"   // 0x00 adapter on, 0x08 adapter off

    // Hardware-enforced limits (survive sleep/shutdown)
    public static let bclm: FourCC = "BCLM"   // Intel: charge limit in percent (20…100)
    public static let chwa: FourCC = "CHWA"   // Apple Silicon: 0x01 = fixed 80 % limit
    public static let bfF0: FourCC = "bfF0"   // firmware limit active (0x02) / inactive (0x00)
    public static let bfD0: FourCC = "bfD0"   // firmware limit upper bound, percent, little endian
    public static let bfE0: FourCC = "bfE0"   // firmware limit lower bound, percent, little endian

    // MagSafe LED
    public static let aclc: FourCC = "ACLC"

    // Telemetry
    public static let temperatureKeys: [FourCC] = ["TB0T", "TB1T", "TB2T"]
    public static let buic: FourCC = "BUIC"   // battery percent (Apple Silicon)

    public static let catalog: [(key: FourCC, purpose: String)] = [
        (chte, "charging inhibit (newer Apple Silicon firmware)"),
        (ch0b, "charging inhibit"),
        (ch0c, "charging inhibit"),
        (chie, "adapter disconnect (newer Apple Silicon firmware)"),
        (ch0j, "adapter disconnect"),
        (ch0i, "adapter disconnect"),
        (bfF0, "firmware charge limit: active flag"),
        (bfD0, "firmware charge limit: upper bound"),
        (bfE0, "firmware charge limit: lower bound"),
        (chwa, "fixed 80 % hardware limit (Apple Silicon)"),
        (bclm, "hardware charge limit (Intel)"),
        (aclc, "MagSafe LED"),
        ("TB0T", "battery temperature 1"),
        ("TB1T", "battery temperature 2"),
        ("TB2T", "battery temperature 3"),
        (buic, "battery percent"),
        ("B0AV", "battery voltage"),
        ("B0AC", "battery current"),
        ("B0CT", "cycle count"),
        ("PDTR", "power delivered by adapter"),
        ("PPBR", "battery power rate"),
        ("AC-W", "adapter present"),
    ]
}

/// MagSafe LED states accepted by `ACLC`.
public enum LEDState: UInt8, Codable, Sendable, CaseIterable {
    case system = 0x00
    case off = 0x01
    case green = 0x03
    case orange = 0x04
    case blinkOnce = 0x05
    case blinkSlow = 0x06
    case blinkFast = 0x07
}

public enum HostArchitecture: String, Codable, Sendable {
    case appleSilicon
    case intel
}

public enum HostInfo {
    public static var architecture: HostArchitecture {
        #if arch(arm64)
        .appleSilicon
        #else
        .intel
        #endif
    }

    public static var modelIdentifier: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    public static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
