import Foundation
import os
import SimmerCore

/// Accepts XPC connections from the Simmer app and tracks how many are alive, so the
/// fail-safe only runs once the *last* client is gone.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let core: HelperCore
    private let log: HelperLog
    private let requirement: String
    private let activeConnections = OSAllocatedUnfairLock(initialState: 0)

    init(core: HelperCore, log: HelperLog, requirement: String) {
        self.core = core
        self.log = log
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Enforced by XPC on every incoming message: a peer that does not satisfy the
        // requirement never reaches the exported object, its connection is invalidated.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: SimmerHelperXPC.self)
        connection.exportedObject = HelperXPCService(core: core)

        let pid = connection.processIdentifier
        // Interruption and invalidation can both be delivered for one connection; it must
        // be counted out exactly once.
        let closed = OSAllocatedUnfairLock(initialState: false)
        let close: @Sendable (String) -> Void = { [self] reason in
            let alreadyClosed = closed.withLock { state in
                defer { state = true }
                return state
            }
            guard !alreadyClosed else { return }
            connectionClosed(pid: pid, reason: reason)
        }
        connection.invalidationHandler = { close("invalidated") }
        connection.interruptionHandler = { close("interrupted") }

        let count = activeConnections.withLock { count in
            count += 1
            return count
        }
        log.info("client connected (pid \(pid), \(count) active)")
        connection.resume()
        return true
    }

    private func connectionClosed(pid: pid_t, reason: String) {
        // The fail-safe runs under the counter's lock so a client that reconnects at the
        // same moment is counted (and can send commands) only after the reset finished.
        let remaining = activeConnections.withLock { count in
            count = max(count - 1, 0)
            if count == 0 { core.clientDisconnected() }
            return count
        }
        if remaining == 0 {
            log.notice("client pid \(pid) \(reason); last client gone, fail-safe applied")
        } else {
            log.info("client pid \(pid) \(reason); \(remaining) still active")
        }
    }
}
