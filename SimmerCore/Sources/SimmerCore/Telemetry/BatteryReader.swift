import Foundation
import IOKit

/// Reads battery telemetry from the `AppleSmartBattery` registry entry, with SMC sensors
/// as the preferred temperature source. Needs no privileges.
public final class BatteryReader: Sendable {
    private let smc: (any SMCInterface)?

    public init(smc: (any SMCInterface)?) {
        self.smc = smc
    }

    public func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return Self.snapshot(from: properties, smcTemperature: smcTemperature())
    }

    /// Hottest of the SMC battery sensors, ignoring implausible readings.
    func smcTemperature() -> Double? {
        guard let smc else { return nil }
        return SMCKeys.temperatureKeys
            .compactMap { smc.readIfPresent($0)?.doubleValue }
            .filter { $0 > -20 && $0 < 120 }
            .max()
    }

    /// Pure mapping from registry properties to a snapshot (unit-testable).
    static func snapshot(from properties: [String: Any], smcTemperature: Double?) -> BatterySnapshot? {
        func int(_ key: String, in dictionary: [String: Any] = properties) -> Int? {
            (dictionary[key] as? NSNumber)?.intValue
        }
        func bool(_ key: String) -> Bool { (properties[key] as? NSNumber)?.boolValue ?? false }

        guard let current = int("CurrentCapacity") else { return nil }
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        let reportedMax = int("MaxCapacity") ?? 100
        // Apple Silicon reports percent directly (MaxCapacity == 100); Intel reports mAh.
        let percent = reportedMax == 100 || reportedMax <= 0
            ? current
            : Int((Double(current) / Double(reportedMax) * 100).rounded())

        let design = int("DesignCapacity") ?? int("DesignCapacity", in: batteryData) ?? 0
        let rawMax = int("AppleRawMaxCapacity") ?? int("AppleRawMaxCapacity", in: batteryData)
            ?? (reportedMax > 100 ? reportedMax : 0)

        var temperature = smcTemperature
        if temperature == nil, let centi = int("Temperature") ?? int("VirtualTemperature") {
            temperature = Double(centi) / 100
        }

        let adapter = properties["AdapterDetails"] as? [String: Any] ?? [:]
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
        let plugged = bool("ExternalConnected")
        let remaining = int("TimeRemaining").flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }

        return BatterySnapshot(
            percent: min(max(percent, 0), 100),
            isPluggedIn: plugged,
            isCharging: bool("IsCharging"),
            isFullyCharged: bool("FullyCharged"),
            temperatureC: temperature,
            voltage: Double(int("Voltage") ?? 0) / 1000,
            amperage: Double(int("Amperage") ?? 0) / 1000,
            adapterWatts: plugged ? int("Watts", in: adapter).map(Double.init) : nil,
            systemPowerIn: plugged ? int("SystemPowerIn", in: telemetry).map { Double($0) / 1000 } : nil,
            cycleCount: int("CycleCount") ?? 0,
            designCapacity: design,
            maxCapacity: rawMax,
            timeRemaining: remaining
        )
    }
}
