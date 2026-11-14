import AppKit
import ServiceManagement

/// Installs and removes the privileged helper daemon.
///
/// Two routes:
/// - ``Method/serviceManagement``: `SMAppService` registers the daemon embedded in the app
///   bundle. The user approves it once in System Settings → Login Items. Needs a properly
///   signed app; with ad-hoc signing macOS may refuse to launch the daemon.
/// - ``Method/script``: runs the bundled `install-helper.sh` with administrator privileges
///   (one password prompt). It copies the helper to `/Library/PrivilegedHelperTools` and
///   loads a LaunchDaemon. This is the reliable route for locally built, ad-hoc signed apps.
@MainActor
public final class HelperInstaller {
    public enum Method: Sendable {
        case serviceManagement
        case script
    }

    public enum Status: Sendable, Equatable {
        case notInstalled
        case requiresApproval
        case installed
    }

    public enum InstallError: Error, CustomStringConvertible {
        case missingResource(String)
        case scriptFailed(String)

        public var description: String {
            switch self {
            case .missingResource(let name): "\(name) is missing from the app bundle"
            case .scriptFailed(let output): output.isEmpty ? "Installation was cancelled" : output
            }
        }
    }

    public static let scriptInstalledPlist = "/Library/LaunchDaemons/\(SimmerIdentifiers.helperPlistName)"
    public static let scriptInstalledBinary = "/Library/PrivilegedHelperTools/\(SimmerIdentifiers.helperService)"

    public init() {}

    private var service: SMAppService { .daemon(plistName: SimmerIdentifiers.helperPlistName) }

    public var isScriptInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.scriptInstalledPlist)
    }

    public var status: Status {
        if isScriptInstalled { return .installed }
        return switch service.status {
        case .enabled: .installed
        case .requiresApproval: .requiresApproval
        default: .notInstalled
        }
    }

    @discardableResult
    public func install(_ method: Method) async throws -> Status {
        switch method {
        case .serviceManagement:
            try service.register()
        case .script:
            let helper = Bundle.main.bundleURL.appending(path: "Contents/MacOS/SimmerHelper").path
            guard FileManager.default.fileExists(atPath: helper) else {
                throw InstallError.missingResource("SimmerHelper")
            }
            try await runBundledScript("install-helper", arguments: [helper])
        }
        return status
    }

    public func uninstall() async throws {
        if isScriptInstalled {
            try await runBundledScript("uninstall-helper", arguments: [])
        }
        if service.status != .notRegistered, service.status != .notFound {
            try await service.unregister()
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func runBundledScript(_ name: String, arguments: [String]) async throws {
        guard let script = Bundle.main.path(forResource: name, ofType: "sh") else {
            throw InstallError.missingResource("\(name).sh")
        }
        let command = (["/bin/sh", script] + arguments).map(Self.shellQuoted).joined(separator: " ")
        let source = "do shell script \(Self.appleScriptQuoted(command)) with administrator privileges"
        try await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                // -128 is "user cancelled" – report it as a plain cancellation.
                throw InstallError.scriptFailed(text.contains("-128") ? "" : text)
            }
        }.value
    }

    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
