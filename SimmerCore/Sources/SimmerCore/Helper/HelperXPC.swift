import Foundation

public enum SimmerIdentifiers {
    public static let appBundleID = "com.simmer.app"
    /// Mach service name and launchd label of the privileged helper.
    public static let helperService = "com.simmer.helper"
    public static let helperPlistName = "com.simmer.helper.plist"
}

/// XPC interface of the privileged helper. Payloads are JSON-encoded Codable values
/// (`ChargeCommand`, `FailSafePolicy`, `HelperHandshake`); replies carry an error message
/// or `nil` on success. There is deliberately no way to write arbitrary SMC keys.
@objc public protocol SimmerHelperXPC {
    func handshake(reply: @escaping @Sendable (Data?) -> Void)
    func apply(_ command: Data, reply: @escaping @Sendable (String?) -> Void)
    func configure(_ policy: Data, reply: @escaping @Sendable (String?) -> Void)
    func resetToStock(reply: @escaping @Sendable (String?) -> Void)
}

/// The object the helper exports on each XPC connection. Decodes payloads and forwards
/// them to the shared ``HelperCore``.
public final class HelperXPCService: NSObject, SimmerHelperXPC, Sendable {
    private let core: HelperCore

    public init(core: HelperCore) {
        self.core = core
    }

    public func handshake(reply: @escaping @Sendable (Data?) -> Void) {
        reply(try? JSONEncoder().encode(core.handshake))
    }

    public func apply(_ command: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let command = try? JSONDecoder().decode(ChargeCommand.self, from: command) else {
            return reply(HelperError.invalidPayload.description)
        }
        do {
            try core.apply(command)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    public func configure(_ policy: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let policy = try? JSONDecoder().decode(FailSafePolicy.self, from: policy) else {
            return reply(HelperError.invalidPayload.description)
        }
        core.configure(policy)
        reply(nil)
    }

    public func resetToStock(reply: @escaping @Sendable (String?) -> Void) {
        do {
            try core.resetToStock()
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }
}
