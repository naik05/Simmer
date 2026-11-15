import Foundation

/// Reads the charge limit macOS currently has registered (`pmset -g battlimit`).
/// Needs no privileges, so the app can tell whether a new target has taken effect yet.
public enum SystemChargeLimit {
    /// The registered manual limit in percent, or `nil` when none is active.
    public static func registered() -> Int? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "battlimit"]
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Pure parser for the `pmset -g battlimit` output.
    static func parse(_ output: String) -> Int? {
        // Entries look like `{ …; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 70; }`.
        for entry in output.components(separatedBy: "}") {
            guard entry.contains("manualChargeLimit"), !entry.contains("Terminated = 1") else { continue }
            guard let range = entry.range(of: "chargeSocLimitSoc = ") else { continue }
            let digits = entry[range.upperBound...].prefix { $0.isNumber }
            if let value = Int(digits), (1...100).contains(value) { return value < 100 ? value : nil }
        }
        return nil
    }
}
