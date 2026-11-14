import Foundation

/// The app's view of "something that can change the charging hardware state".
public protocol ChargeControlling: Sendable {
    func handshake() async throws -> HelperHandshake
    func apply(_ command: ChargeCommand) async throws
    func configure(_ policy: FailSafePolicy) async throws
    func resetToStock() async throws
    /// Drops the connection; the helper's fail-safe policy decides what happens next.
    func disconnect()
}

/// Talks to the privileged helper over XPC.
public final class XPCChargeController: ChargeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    public func handshake() async throws -> HelperHandshake {
        let data: Data? = try await call { helper, finish in
            helper.handshake { finish(.success($0)) }
        }
        guard let data, let handshake = try? JSONDecoder().decode(HelperHandshake.self, from: data) else {
            throw HelperError.invalidPayload
        }
        return handshake
    }

    public func apply(_ command: ChargeCommand) async throws {
        let payload = try JSONEncoder().encode(command)
        try await callReportingError { helper, reply in helper.apply(payload, reply: reply) }
    }

    public func configure(_ policy: FailSafePolicy) async throws {
        let payload = try JSONEncoder().encode(policy)
        try await callReportingError { helper, reply in helper.configure(payload, reply: reply) }
    }

    public func resetToStock() async throws {
        try await callReportingError { helper, reply in helper.resetToStock(reply: reply) }
    }

    public func disconnect() {
        let old = lock.withLock {
            let old = connection
            connection = nil
            return old
        }
        old?.invalidate()
    }

    // MARK: Plumbing

    private func activeConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let new = NSXPCConnection(machServiceName: SimmerIdentifiers.helperService, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: SimmerHelperXPC.self)
            new.invalidationHandler = { [weak self, weak new] in
                guard let self, let new else { return }
                self.lock.withLock { if self.connection === new { self.connection = nil } }
            }
            new.resume()
            connection = new
            return new
        }
    }

    private func call<Value: Sendable>(
        _ body: @escaping @Sendable (any SimmerHelperXPC, @escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        let connection = activeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            // XPC calls exactly one of the error handler and the reply block.
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: HelperError.connection(error.localizedDescription))
            }
            guard let helper = proxy as? any SimmerHelperXPC else {
                continuation.resume(throwing: HelperError.connection("unexpected proxy type"))
                return
            }
            body(helper) { continuation.resume(with: $0) }
        }
    }

    private func callReportingError(
        _ body: @escaping @Sendable (any SimmerHelperXPC, @escaping @Sendable (String?) -> Void) -> Void
    ) async throws {
        let message: String? = try await call { helper, finish in
            body(helper) { finish(.success($0)) }
        }
        if let message { throw HelperError.remote(message) }
    }
}

/// Runs the helper logic in-process against a ``DryRunSMC``. Used for dry-run mode: every
/// "write" is only logged, no privileges are needed and no hardware is touched.
public final class DryRunChargeController: ChargeControlling, Sendable {
    public let core: HelperCore
    public let smc: DryRunSMC

    public init(smc: DryRunSMC = .hostDefault(), onWrite: (@Sendable (DryRunSMC.Write) -> Void)? = nil) {
        let observed = DryRunSMC(keys: smc.snapshot(), onWrite: onWrite)
        self.smc = observed
        core = HelperCore(hardware: ChargeHardware(smc: observed), isDryRun: true)
    }

    public func handshake() async throws -> HelperHandshake { core.handshake }
    public func apply(_ command: ChargeCommand) async throws { try core.apply(command) }
    public func configure(_ policy: FailSafePolicy) async throws { core.configure(policy) }
    public func resetToStock() async throws { try core.resetToStock() }
    public func disconnect() { core.clientDisconnected() }
}
