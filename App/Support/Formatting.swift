import Foundation
import SimmerCore
import SwiftUI

enum Format {
    static let placeholder = "—"

    /// "80 %" with a non-breaking space.
    static func percent(_ value: Int) -> String {
        "\(value)\u{00A0}%"
    }

    static func temperature(celsius: Double, unit: TemperatureUnit, fractionDigits: Int = 1) -> String {
        let value = unit == .celsius ? celsius : celsius * 9 / 5 + 32
        let symbol = unit == .celsius ? "°C" : "°F"
        return "\(value.formatted(.number.precision(.fractionLength(fractionDigits))))\u{00A0}\(symbol)"
    }

    static func watts(_ value: Double, fractionDigits: Int = 1) -> String {
        "\(value.formatted(.number.precision(.fractionLength(fractionDigits))))\u{00A0}W"
    }

    /// "+45.2 W" / "−12.0 W" with a real minus sign; values that round to zero carry no sign.
    static func signedWatts(_ value: Double, fractionDigits: Int = 1) -> String {
        "\(sign(of: value, fractionDigits: fractionDigits))\(watts(abs(value), fractionDigits: fractionDigits))"
    }

    /// Compact menu bar form: "+45W" / "−12W".
    static func menuBarWatts(_ value: Double) -> String {
        "\(sign(of: value, fractionDigits: 0))\(Int(abs(value).rounded()))W"
    }

    static func volts(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2))))\u{00A0}V"
    }

    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    private static func sign(of value: Double, fractionDigits: Int) -> String {
        let scale = pow(10, Double(fractionDigits))
        let rounded = (value * scale).rounded() / scale
        if rounded > 0 { return "+" }
        if rounded < 0 { return "\u{2212}" }
        return ""
    }
}

extension CalibrationPhase {
    func title(config: EngineConfig) -> String {
        let config = config.sanitized()
        switch self {
        case .chargeToFull:
            return "Charge to \(Format.percent(100))"
        case .dischargeToLow:
            return "Discharge to \(Format.percent(config.calibrationLowPercent))"
        case .rest:
            return "Rest for \(Format.duration(minutes: max(1, Int(config.calibrationRestDuration / 60))))"
        case .rechargeToLimit:
            return "Recharge to \(Format.percent(config.effectiveLimit))"
        }
    }
}

extension ChargeActivity {
    /// Restrained accent used for the gauge and status icon.
    var tint: Color {
        switch self {
        case .charging, .full: .green
        case .holding: .accentColor
        case .discharging: .orange
        case .heatPaused: .red
        case .resting: .indigo
        case .onBattery, .unmanaged: .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .charging: "bolt.fill"
        case .full: "battery.100percent"
        case .holding: "powerplug.fill"
        case .discharging: "arrow.down"
        case .heatPaused: "thermometer.high"
        case .resting: "moon.zzz.fill"
        case .onBattery: "battery.50percent"
        case .unmanaged: "powerplug"
        }
    }
}

extension HelperConnection {
    var isMissing: Bool {
        switch self {
        case .connecting, .unavailable: true
        case .connected, .dryRun: false
        }
    }
}
