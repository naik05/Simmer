import Foundation

/// What the helper does when its client (the app) goes away or stops responding.
public struct FailSafePolicy: Codable, Sendable, Equatable {
    /// Restore stock charging behaviour when the app disconnects. When `false` the current
    /// charging state is left in place – but a forced discharge is always ended.
    public var resetOnDisconnect: Bool
    /// Firmware-enforced limit to leave behind after a reset ("keep limit when off").
    public var persistentBand: ChargeBand?

    public init(resetOnDisconnect: Bool = true, persistentBand: ChargeBand? = nil) {
        self.resetOnDisconnect = resetOnDisconnect
        self.persistentBand = persistentBand
    }
}

public struct HelperHandshake: Codable, Sendable, Equatable {
    public var version: String
    public var capabilities: HardwareCapabilities
    public var isDryRun: Bool

    public init(version: String, capabilities: HardwareCapabilities, isDryRun: Bool) {
        self.version = version
        self.capabilities = capabilities
        self.isDryRun = isDryRun
    }
}

public enum HelperError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case connection(String)
    case remote(String)
    case invalidPayload

    public var description: String {
        switch self {
        case .notInstalled: "The Simmer helper is not installed"
        case .connection(let message): "Helper connection failed: \(message)"
        case .remote(let message): message
        case .invalidPayload: "Invalid payload"
        }
    }
}

/// The helper's logic, independent of XPC and of real hardware.
///
/// Safety properties (all unit-tested):
/// - Only semantic, range-clamped commands reach the SMC – never raw key writes.
/// - If the client disconnects or stops sending commands for ``watchdogTimeout`` seconds,
///   the fail-safe runs: stock behaviour is restored (or, if the user opted out of
///   resetting, at least a forced discharge is ended).
/// - The same fail-safe runs when the helper starts and when it is asked to terminate.
public final class HelperCore: @unchecked Sendable {
    public static let version = "1.1.1"
    /// The app sends a command at least every 30 s; three misses trip the watchdog.
    public static let watchdogTimeout: TimeInterval = 120

    public let hardware: ChargeHardware
    public let isDryRun: Bool

    private let lock = NSLock()
    private let uptime: @Sendable () -> TimeInterval
    private var policy = FailSafePolicy()
    private var lastCommand: ChargeCommand?
    private var lastWrite: TimeInterval = 0
    private var lastContact: TimeInterval?

    public init(
        hardware: ChargeHardware, isDryRun: Bool,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.hardware = hardware
        self.isDryRun = isDryRun
        self.uptime = uptime
    }

    public var handshake: HelperHandshake {
        HelperHandshake(version: Self.version, capabilities: hardware.capabilities, isDryRun: isDryRun)
    }

    public var currentPolicy: FailSafePolicy {
        lock.withLock { policy }
    }

    /// Applies a command. Identical commands are not rewritten to the SMC more than once a
    /// minute, but every call counts as a heartbeat.
    public func apply(_ command: ChargeCommand) throws {
        try lock.withLock {
            let now = uptime()
            lastContact = now
            if command == lastCommand, now - lastWrite < 60 { return }
            do {
                try hardware.apply(command)
            } catch {
                lastCommand = nil
                throw error
            }
            lastCommand = command
            lastWrite = now
        }
    }

    public func configure(_ policy: FailSafePolicy) {
        lock.withLock {
            self.policy = policy
            lastContact = uptime()
        }
    }

    /// Explicit user request: back to stock, including any firmware limit.
    public func resetToStock() throws {
        try lock.withLock {
            lastCommand = nil
            try hardware.resetToDefaults(persisting: nil)
        }
    }

    /// Call when the XPC connection to the app is invalidated.
    public func clientDisconnected() {
        lock.withLock {
            lastContact = nil
            lockedFailSafe(full: policy.resetOnDisconnect)
        }
    }

    /// Call periodically. Trips the fail-safe when the client went silent.
    /// Returns `true` if the fail-safe ran.
    @discardableResult
    public func checkWatchdog() -> Bool {
        lock.withLock {
            guard let lastContact, uptime() - lastContact > Self.watchdogTimeout else { return false }
            self.lastContact = nil
            lockedFailSafe(full: policy.resetOnDisconnect)
            return true
        }
    }

    /// Call at helper start-up and before the helper exits (SIGTERM, shutdown).
    public func failSafeReset() {
        lock.withLock { lockedFailSafe(full: true) }
    }

    private func lockedFailSafe(full: Bool) {
        lastCommand = nil
        if full {
            try? hardware.resetToDefaults(persisting: policy.persistentBand)
        } else {
            // Never leave the Mac draining its battery unattended.
            try? hardware.setAdapter(enabled: true)
        }
    }
}
