import Foundation
import XCTest
@testable import SimmerCore

@MainActor
final class HelperInstallerTests: XCTestCase {
    func testShellQuoted() {
        XCTAssertEqual(HelperInstaller.shellQuoted(""), "''")
        XCTAssertEqual(HelperInstaller.shellQuoted("hello"), "'hello'")
        XCTAssertEqual(HelperInstaller.shellQuoted("hello world"), "'hello world'")
        XCTAssertEqual(HelperInstaller.shellQuoted("can't"), "'can'\\''t'")
        XCTAssertEqual(HelperInstaller.shellQuoted("/path/with space/'quotes'"), "'/path/with space/'\\''quotes'\\'''")
    }

    func testAppleScriptQuoted() {
        XCTAssertEqual(HelperInstaller.appleScriptQuoted(""), "\"\"")
        XCTAssertEqual(HelperInstaller.appleScriptQuoted("hello"), "\"hello\"")
        XCTAssertEqual(HelperInstaller.appleScriptQuoted("hello \"world\""), "\"hello \\\"world\\\"\"")
        XCTAssertEqual(HelperInstaller.appleScriptQuoted("path\\with\\backslashes"), "\"path\\\\with\\\\backslashes\"")
        XCTAssertEqual(HelperInstaller.appleScriptQuoted("quoted \\\"test\\\""), "\"quoted \\\\\\\"test\\\\\\\"\"")
    }

    func testInstallErrorDescriptions() {
        let missing = HelperInstaller.InstallError.missingResource("HelperTool")
        XCTAssertEqual(missing.description, "HelperTool is missing from the app bundle")

        let cancelled = HelperInstaller.InstallError.scriptFailed("")
        XCTAssertEqual(cancelled.description, "Installation was cancelled")

        let failed = HelperInstaller.InstallError.scriptFailed("Password was incorrect")
        XCTAssertEqual(failed.description, "Password was incorrect")
    }

    func testInstallerPaths() {
        XCTAssertEqual(
            HelperInstaller.scriptInstalledPlist,
            "/Library/LaunchDaemons/\(SimmerIdentifiers.helperPlistName)"
        )
        XCTAssertEqual(
            HelperInstaller.scriptInstalledBinary,
            "/Library/PrivilegedHelperTools/\(SimmerIdentifiers.helperService)"
        )
    }

    func testInstallerStatusEnum() {
        XCTAssertEqual(HelperInstaller.Status.installed, .installed)
        XCTAssertEqual(HelperInstaller.Status.notInstalled, .notInstalled)
        XCTAssertEqual(HelperInstaller.Status.requiresApproval, .requiresApproval)
        XCTAssertNotEqual(HelperInstaller.Status.installed, .notInstalled)
    }
}
