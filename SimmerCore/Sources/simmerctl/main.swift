import Foundation
import SimmerCore

// simmerctl – read-only diagnostics for Simmer's hardware layer.
//
//   simmerctl probe      list every SMC key Simmer knows about and whether this Mac has it
//   simmerctl caps       print the resolved key mapping (what the helper would write)
//   simmerctl battery    print one telemetry snapshot
//   simmerctl simulate   run the control commands against the dry-run SMC and show the writes
//   simmerctl keys CH    dump every SMC key (optionally filtered by prefix)
//   simmerctl debug KEY  show key info / read errors for individual keys

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? "probe"

func openSMC() -> AppleSMC {
    do {
        return try AppleSMC()
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

switch command {
case "probe":
    let smc = openSMC()
    print("Model: \(HostInfo.modelIdentifier)  arch: \(HostInfo.architecture.rawValue)  macOS \(HostInfo.osVersion)")
    for entry in SMCKeys.catalog {
        if let value = try? smc.read(entry.key) {
            let decoded = value.doubleValue.map { String(format: "  (%.2f)", $0) } ?? ""
            print("  ✓ \(entry.key)  [\(value.type)] \(value.bytes.count)B  = \(value.hex)\(decoded)  — \(entry.purpose)")
        } else if case .failure(SMCError.notPrivileged) = Result(catching: { try smc.keyInfo(entry.key) }) {
            print("  ⊘ \(entry.key)  gated (not accessible)  — \(entry.purpose)")
        } else {
            print("  ✗ \(entry.key)  missing  — \(entry.purpose)")
        }
    }
case "keys":
    // simmerctl keys [prefix…] – dump all SMC keys, optionally filtered by prefix.
    let smc = openSMC()
    let prefixes = Array(arguments.dropFirst())
    let keys = smc.allKeys()
    print("\(keys.count) keys")
    for key in keys where prefixes.isEmpty || prefixes.contains(where: { key.description.hasPrefix($0) }) {
        if let value = try? smc.read(key) {
            print("  \(key)  [\(value.type)] \(value.bytes.count)B  = \(value.hex)")
        } else {
            print("  \(key)  (unreadable)")
        }
    }
case "debug":
    debugKeyInfo(openSMC(), Array(arguments.dropFirst()))
case "caps":
    let hardware = ChargeHardware(smc: openSMC())
    print(hardware.capabilities.summary)
case "battery":
    let reader = BatteryReader(smc: try? AppleSMC())
    if let snapshot = reader.read() {
        print(snapshot.debugSummary)
    } else {
        print("No battery found.")
    }
case "simulate":
    let smc = DryRunSMC.hostDefault { print("  [dry-run] write \($0.key) = \($0.hex)") }
    let hardware = ChargeHardware(smc: smc)
    print(hardware.capabilities.summary)
    let steps: [(String, () throws -> Void)] = [
        ("inhibit charging", { try hardware.setCharging(enabled: false) }),
        ("force discharge", { try hardware.setAdapter(enabled: false) }),
        ("LED orange", { try hardware.setLED(.orange) }),
        ("reset to defaults", { try hardware.resetToDefaults() }),
    ]
    for (name, step) in steps {
        print("→ \(name)")
        do { try step() } catch { print("  failed: \(error)") }
    }
default:
    print("usage: simmerctl [probe|caps|battery|simulate|keys [prefix…]|debug KEY…]")
    exit(64)
}
