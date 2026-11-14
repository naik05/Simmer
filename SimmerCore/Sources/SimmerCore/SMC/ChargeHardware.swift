import Foundation

/// Which SMC keys this machine offers for each control function.
public struct HardwareCapabilities: Codable, Sendable, Equatable {
    public enum ChargingMethod: String, Codable, Sendable {
        /// `bfF0`/`bfD0`/`bfE0`: the firmware holds the battery inside a band (macOS 27 era).
        case firmwareBand
        case chte, ch0bCh0c, bclm
        /// No usable charging-inhibit key (newer firmware gates them even for root): the
        /// limit is held by electrically disconnecting the adapter, so the Mac runs from
        /// its battery between the limit and the resume level instead of bypassing it.
        case adapterCycling
        case none
    }

    public enum AdapterMethod: String, Codable, Sendable {
        case chie, ch0j, ch0i, none
    }

    public enum HardwareLimitMethod: String, Codable, Sendable {
        /// `bfF0`/`bfD0`/`bfE0`: arbitrary upper/lower bound enforced by firmware.
        case firmwareBand
        /// Intel `BCLM`: arbitrary limit in percent.
        case bclm
        /// Apple Silicon `CHWA`: fixed 80 % limit only.
        case chwa
        case none
    }

    public var architecture: HostArchitecture
    public var charging: ChargingMethod
    public var adapter: AdapterMethod
    public var hardwareLimit: HardwareLimitMethod
    public var hasMagSafeLED: Bool

    public init(
        architecture: HostArchitecture, charging: ChargingMethod, adapter: AdapterMethod,
        hardwareLimit: HardwareLimitMethod, hasMagSafeLED: Bool
    ) {
        self.architecture = architecture
        self.charging = charging
        self.adapter = adapter
        self.hardwareLimit = hardwareLimit
        self.hasMagSafeLED = hasMagSafeLED
    }

    public static let unsupported = HardwareCapabilities(
        architecture: HostInfo.architecture, charging: .none, adapter: .none,
        hardwareLimit: .none, hasMagSafeLED: false
    )

    public var canLimitCharging: Bool { charging != .none }
    public var canDischarge: Bool { adapter != .none }
    public var canPersistLimit: Bool { hardwareLimit != .none }
    /// `true` when "not charging" can only be achieved by running from the battery.
    public var holdsByDischarging: Bool { charging == .adapterCycling }

    public var summary: String {
        """
        architecture:    \(architecture.rawValue)
        charging:        \(charging.rawValue)
        adapter:         \(adapter.rawValue)
        hardware limit:  \(hardwareLimit.rawValue)
        MagSafe LED:     \(hasMagSafeLED ? "ACLC" : "none")
        """
    }
}

/// A charge band: stop charging at `upper`, resume once the battery fell below `lower`.
public struct ChargeBand: Codable, Sendable, Equatable {
    public var upper: Int
    public var lower: Int

    public init(upper: Int, lower: Int) {
        let upper = min(max(upper, 10), 100)
        self.upper = upper
        self.lower = min(max(lower, 10), upper)
    }

    /// Decoded bands go through the same clamping – they arrive over XPC in the root helper.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(upper: try values.decode(Int.self, forKey: .upper), lower: try values.decode(Int.self, forKey: .lower))
    }

    /// The band re-clamped, in case its mutable fields were set out of range.
    public var clamped: ChargeBand { ChargeBand(upper: upper, lower: lower) }
}

/// The complete desired hardware state. The engine produces one per tick; the helper
/// applies it idempotently.
public struct ChargeCommand: Codable, Sendable, Equatable {
    public var chargingAllowed: Bool
    /// `false` electrically disconnects the adapter so the Mac drains its battery.
    public var adapterConnected: Bool
    public var led: LEDState
    /// While charging is not allowed: the band the battery should be held in. Firmware-band
    /// machines enforce it natively (also during sleep); others simply inhibit charging.
    public var hold: ChargeBand

    public init(chargingAllowed: Bool, adapterConnected: Bool = true, led: LEDState = .system, hold: ChargeBand) {
        self.chargingAllowed = chargingAllowed
        self.adapterConnected = adapterConnected
        self.led = led
        self.hold = hold
    }

    /// Stock behaviour: charge freely.
    public static let stock = ChargeCommand(chargingAllowed: true, hold: ChargeBand(upper: 100, lower: 100))
}

/// Semantic charge-control operations on top of raw SMC keys.
///
/// This is the only place that knows which bytes go into which key. It is used by the
/// privileged helper with ``AppleSMC`` and by tests / dry-run mode with ``DryRunSMC``.
public final class ChargeHardware: Sendable {
    public let smc: any SMCInterface
    public let capabilities: HardwareCapabilities

    public init(smc: any SMCInterface, architecture: HostArchitecture = HostInfo.architecture) {
        self.smc = smc
        capabilities = Self.detect(smc: smc, architecture: architecture)
    }

    static func detect(smc: any SMCInterface, architecture: HostArchitecture) -> HardwareCapabilities {
        let hasBand = smc.hasKey(SMCKeys.bfF0) && smc.hasKey(SMCKeys.bfD0) && smc.hasKey(SMCKeys.bfE0)
        let hasBCLM = architecture == .intel && smc.hasKey(SMCKeys.bclm)

        let adapter: HardwareCapabilities.AdapterMethod =
            if smc.hasKey(SMCKeys.chie) { .chie }
            else if smc.hasKey(SMCKeys.ch0j) { .ch0j }
            else if smc.hasKey(SMCKeys.ch0i) { .ch0i }
            else { .none }

        // Usability decides, never the OS version. The firmware band wins when it exists;
        // adapter cycling is the last resort when no inhibit key is accessible.
        let charging: HardwareCapabilities.ChargingMethod =
            if hasBand { .firmwareBand }
            else if smc.hasKey(SMCKeys.chte) { .chte }
            else if smc.hasKey(SMCKeys.ch0b), smc.hasKey(SMCKeys.ch0c) { .ch0bCh0c }
            else if hasBCLM { .bclm }
            else if adapter != .none { .adapterCycling }
            else { .none }

        let limit: HardwareCapabilities.HardwareLimitMethod =
            if hasBand { .firmwareBand }
            else if hasBCLM { .bclm }
            else if smc.hasKey(SMCKeys.chwa) { .chwa }
            else { .none }

        return HardwareCapabilities(
            architecture: architecture, charging: charging, adapter: adapter,
            hardwareLimit: limit, hasMagSafeLED: smc.hasKey(SMCKeys.aclc)
        )
    }

    // MARK: Whole-state apply

    /// Brings the hardware into the state described by `command`.
    public func apply(_ command: ChargeCommand) throws {
        // Order matters: never leave the adapter disconnected while charging is being changed.
        if capabilities.charging == .adapterCycling {
            // "Not charging" and "adapter disconnected" are the same thing here.
            try setAdapter(enabled: command.adapterConnected && command.chargingAllowed)
            try setLED(command.led)
            return
        }
        if command.adapterConnected { try setAdapter(enabled: true) }
        try setCharging(enabled: command.chargingAllowed, hold: command.hold)
        if !command.adapterConnected { try setAdapter(enabled: false) }
        try setLED(command.led)
    }

    // MARK: Charging

    /// Allows (`true`) or inhibits (`false`) charging while the adapter stays connected.
    public func setCharging(enabled: Bool, hold: ChargeBand = ChargeBand(upper: 10, lower: 10)) throws {
        switch capabilities.charging {
        case .firmwareBand:
            if enabled {
                try smc.write(SMCKeys.bfF0, bytes: littleEndian(0x00, for: SMCKeys.bfF0))
            } else {
                try writeFirmwareBand(hold)
            }
        case .chte:
            try smc.write(SMCKeys.chte, bytes: enabled ? [0, 0, 0, 0] : [1, 0, 0, 0])
        case .ch0bCh0c:
            let byte: UInt8 = enabled ? 0x00 : 0x02
            try smc.write(SMCKeys.ch0b, bytes: [byte])
            try smc.write(SMCKeys.ch0c, bytes: [byte])
        case .bclm:
            // BCLM-only Intel Macs: the firmware enforces the limit itself.
            try smc.write(SMCKeys.bclm, bytes: [enabled ? 100 : UInt8(max(hold.clamped.upper, 20))])
        case .adapterCycling:
            try setAdapter(enabled: enabled)
        case .none:
            throw SMCError.unsupported("charging control")
        }
    }

    /// `true` when charging is currently restricted by one of Simmer's keys.
    public func isChargingInhibited() -> Bool {
        switch capabilities.charging {
        case .firmwareBand: !(smc.readIfPresent(SMCKeys.bfF0)?.isZero ?? true)
        case .chte: !(smc.readIfPresent(SMCKeys.chte)?.isZero ?? true)
        case .ch0bCh0c: !(smc.readIfPresent(SMCKeys.ch0b)?.isZero ?? true)
        case .bclm: (smc.readIfPresent(SMCKeys.bclm)?.bytes.first ?? 100) < 100
        case .adapterCycling: isAdapterDisabled()
        case .none: false
        }
    }

    // MARK: Adapter

    /// Connects (`true`) or electrically disconnects (`false`) the power adapter.
    /// With the adapter disconnected the Mac runs from its battery although it is plugged in.
    public func setAdapter(enabled: Bool) throws {
        switch capabilities.adapter {
        case .chie: try smc.write(SMCKeys.chie, bytes: [enabled ? 0x00 : 0x08])
        case .ch0j: try smc.write(SMCKeys.ch0j, bytes: [enabled ? 0x00 : 0x01])
        case .ch0i: try smc.write(SMCKeys.ch0i, bytes: [enabled ? 0x00 : 0x01])
        case .none:
            // Re-enabling an adapter we cannot disable is a no-op, not an error.
            if !enabled { throw SMCError.unsupported("adapter control") }
        }
    }

    public func isAdapterDisabled() -> Bool {
        let key: FourCC? = switch capabilities.adapter {
        case .chie: SMCKeys.chie
        case .ch0j: SMCKeys.ch0j
        case .ch0i: SMCKeys.ch0i
        case .none: nil
        }
        guard let key, let value = smc.readIfPresent(key) else { return false }
        return !value.isZero
    }

    // MARK: MagSafe LED

    public func setLED(_ state: LEDState) throws {
        guard capabilities.hasMagSafeLED else { return }
        try smc.write(SMCKeys.aclc, bytes: [state.rawValue])
    }

    // MARK: Hardware limit

    /// Writes a limit that the firmware itself enforces, so it also holds while the Mac
    /// sleeps or is shut down. Returns the upper limit actually in effect (`CHWA` can only
    /// do 80 %; `BCLM` ignores the lower bound).
    @discardableResult
    public func setHardwareLimit(_ band: ChargeBand) throws -> Int {
        let band = band.clamped
        switch capabilities.hardwareLimit {
        case .firmwareBand:
            try writeFirmwareBand(band)
            return band.upper
        case .bclm:
            let limit = max(band.upper, 20)
            try smc.write(SMCKeys.bclm, bytes: [UInt8(limit)])
            return limit
        case .chwa:
            try smc.write(SMCKeys.chwa, bytes: [band.upper < 100 ? 0x01 : 0x00])
            return band.upper < 100 ? 80 : 100
        case .none:
            throw SMCError.unsupported("hardware charge limit")
        }
    }

    public func clearHardwareLimit() throws {
        switch capabilities.hardwareLimit {
        case .firmwareBand: try smc.write(SMCKeys.bfF0, bytes: littleEndian(0x00, for: SMCKeys.bfF0))
        case .bclm: try smc.write(SMCKeys.bclm, bytes: [100])
        case .chwa: try smc.write(SMCKeys.chwa, bytes: [0x00])
        case .none: break
        }
    }

    // MARK: Fail-safe

    /// Restores stock behaviour: adapter connected, charging allowed, LED under system
    /// control. With `persisting` set, that band is left behind as a firmware-enforced
    /// limit instead of clearing it. Every step is attempted even if an earlier one fails;
    /// the first error is rethrown afterwards.
    public func resetToDefaults(persisting band: ChargeBand? = nil) throws {
        var firstError: (any Error)?
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch { if firstError == nil { firstError = error } }
        }
        if capabilities.adapter != .none { attempt { try setAdapter(enabled: true) } }
        if capabilities.charging != .none { attempt { try setCharging(enabled: true) } }
        if capabilities.hasMagSafeLED { attempt { try setLED(.system) } }
        if let band, capabilities.hardwareLimit != .none {
            attempt { try setHardwareLimit(band) }
        } else {
            attempt { try clearHardwareLimit() }
        }
        if let firstError { throw firstError }
    }

    // MARK: Helpers

    private func writeFirmwareBand(_ band: ChargeBand) throws {
        let band = band.clamped
        // Deactivate, set both bounds, then activate – the order the firmware expects.
        try smc.write(SMCKeys.bfF0, bytes: littleEndian(0x00, for: SMCKeys.bfF0))
        try smc.write(SMCKeys.bfD0, bytes: littleEndian(band.upper, for: SMCKeys.bfD0))
        try smc.write(SMCKeys.bfE0, bytes: littleEndian(band.lower, for: SMCKeys.bfE0))
        try smc.write(SMCKeys.bfF0, bytes: littleEndian(0x02, for: SMCKeys.bfF0))
    }

    private func littleEndian(_ value: Int, for key: FourCC) throws -> [UInt8] {
        let size = try smc.keyInfo(key).size
        return (0..<size).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
}
