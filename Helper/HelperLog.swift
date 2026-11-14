import Foundation
import os

/// Unified logging (subsystem `com.simmer.helper`), optionally mirrored to stderr.
///
/// The mirror is on when stderr is a terminal or the helper runs with `--dry-run`, so the
/// helper is observable when started by hand. Under launchd only the unified log is used:
/// `log stream --predicate 'subsystem == "com.simmer.helper"'`.
struct HelperLog: Sendable {
    private let logger: Logger
    private let mirrorToStderr: Bool

    init(category: String = "daemon", mirrorToStderr: Bool) {
        logger = Logger(subsystem: "com.simmer.helper", category: category)
        self.mirrorToStderr = mirrorToStderr
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        mirror(message)
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        mirror(message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        mirror("error: " + message)
    }

    private func mirror(_ message: String) {
        guard mirrorToStderr else { return }
        FileHandle.standardError.write(Data("SimmerHelper: \(message)\n".utf8))
    }
}
