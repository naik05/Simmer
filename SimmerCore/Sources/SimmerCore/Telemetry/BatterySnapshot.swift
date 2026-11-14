import Foundation

/// One reading of everything Simmer knows about the battery.
public struct BatterySnapshot: Sendable, Equatable, Codable {
    /// State of charge as macOS reports it (0…100).
    public var percent: Int
    /// A power adapter is physically attached (even if Simmer disconnected it electrically).
    public var isPluggedIn: Bool
    public var isCharging: Bool
    public var isFullyCharged: Bool
    /// Battery temperature in °C, `nil` when no sensor is readable.
    public var temperatureC: Double?
    public var voltage: Double
    /// Amps; positive while charging, negative while discharging.
    public var amperage: Double
    /// Rated adapter power in watts, `nil` when unknown or unplugged.
    public var adapterWatts: Double?
    /// Power currently drawn from the adapter in watts, when the system reports it.
    public var systemPowerIn: Double?
    public var cycleCount: Int
    public var designCapacity: Int
    public var maxCapacity: Int
    /// Minutes until full/empty as estimated by the system, when available.
    public var timeRemaining: Int?

    public init(
        percent: Int, isPluggedIn: Bool, isCharging: Bool = false, isFullyCharged: Bool = false,
        temperatureC: Double? = 30, voltage: Double = 12, amperage: Double = 0,
        adapterWatts: Double? = nil, systemPowerIn: Double? = nil, cycleCount: Int = 0,
        designCapacity: Int = 0, maxCapacity: Int = 0, timeRemaining: Int? = nil
    ) {
        self.percent = percent
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.temperatureC = temperatureC
        self.voltage = voltage
        self.amperage = amperage
        self.adapterWatts = adapterWatts
        self.systemPowerIn = systemPowerIn
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
        self.timeRemaining = timeRemaining
    }

    /// Battery power in watts; positive = flowing into the battery.
    public var batteryWatts: Double { voltage * amperage }

    /// Maximum capacity relative to design capacity, capped at 100 like System Settings.
    public var healthPercent: Int? {
        guard designCapacity > 0, maxCapacity > 0 else { return nil }
        return min(100, Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded()))
    }

    public var temperatureF: Double? { temperatureC.map { $0 * 9 / 5 + 32 } }

    public var debugSummary: String {
        func format(_ value: Double?, _ unit: String) -> String {
            value.map { String(format: "%.2f %@", $0, unit) } ?? "n/a"
        }
        return """
        charge:        \(percent) %  (plugged in: \(isPluggedIn), charging: \(isCharging), full: \(isFullyCharged))
        temperature:   \(format(temperatureC, "°C"))
        voltage:       \(format(voltage, "V"))
        amperage:      \(format(amperage, "A"))
        battery power: \(format(batteryWatts, "W"))
        adapter:       \(format(adapterWatts, "W rated")), \(format(systemPowerIn, "W in"))
        cycles:        \(cycleCount)
        capacity:      \(maxCapacity) / \(designCapacity) mAh  (health \(healthPercent.map { "\($0) %" } ?? "n/a"))
        """
    }
}
