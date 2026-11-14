import Foundation
import Security
import SimmerCore

/// Builds the code-signing requirement every XPC client must satisfy.
///
/// The requirement is derived from the helper's own signature, so the same binary works
/// for distribution builds and for local ad-hoc builds:
///
/// - Helper signed with a Team ID: the client must be `com.simmer.app`, signed by a
///   certificate chaining to Apple and issued to the *same team*. Only the genuine app
///   can talk to the helper.
/// - Ad-hoc signed or unsigned helper (local builds): there is no team to pin, so the
///   requirement degrades to `identifier "com.simmer.app"`.
///
///   LIMITATION: an identifier-only requirement is spoofable – any local process can
///   ad-hoc sign itself with that identifier and connect. This is accepted for local
///   builds because the XPC interface only exposes semantic, range-clamped charge
///   commands (`ChargeCommand`, `FailSafePolicy`, reset): there is no raw SMC access, and
///   the worst a rogue client can do is what the Simmer UI itself can do (limit, pause or
///   discharge the battery), all of which the helper's fail-safe undoes once that client
///   disconnects or goes silent. Sign with a Developer ID to close the gap.
enum ClientValidation {
    struct Requirement: Sendable {
        let text: String
        /// `nil` for ad-hoc / unsigned builds.
        let teamID: String?
    }

    static func requirement() -> Requirement {
        let identifier = "identifier \"\(SimmerIdentifiers.appBundleID)\""
        guard let team = ownTeamIdentifier() else {
            return Requirement(text: identifier, teamID: nil)
        }
        return Requirement(
            text: "\(identifier) and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"",
            teamID: team
        )
    }

    /// The Team ID this process is signed with, or `nil` when ad-hoc signed / unsigned.
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        else { return nil }
        // The value is interpolated into a requirement string: accept only the plain
        // alphanumeric form real Team IDs have.
        let isPlain = !team.isEmpty && team.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        }
        return isPlain ? team : nil
    }
}
