import SimmerCore

/// The one-line summary shown in the popover header and returned by the status intent.
@MainActor
enum StatusDescription {
    static func text(for model: SimmerModel) -> String {
        guard let snapshot = model.snapshot else { return "No battery detected" }
        let settings = model.settings
        guard settings.isLimiterEnabled else { return "Limiter off · macOS manages charging" }

        switch model.connection {
        case .connecting: return "Connecting to helper…"
        case .unavailable: return "Helper unavailable · macOS manages charging"
        case .connected, .dryRun: break
        }

        let limit = Format.percent(settings.engine.effectiveLimit)
        if model.activity == .heatPaused {
            guard let celsius = snapshot.temperatureC else { return "Paused – battery too warm" }
            return "Paused – battery \(Format.temperature(celsius: celsius, unit: settings.temperatureUnit))"
        }

        switch model.engineState.mode {
        case .calibration(let phase):
            return "Calibrating – phase \(phase.index + 1) of \(CalibrationPhase.allCases.count)"
        case .topUp:
            return model.activity == .onBattery
                ? "Top Up · waiting for power adapter"
                : "Top Up to \(Format.percent(100))"
        case .discharge:
            return "Discharging to \(limit)"
        case .normal:
            switch model.activity {
            case .holding:
                return model.capabilities.holdsByDischarging
                    ? "Holding below \(limit) · running on battery"
                    : "Holding at \(limit) · running on adapter"
            case .charging: return "Charging to \(limit)"
            case .full: return "Fully charged"
            case .onBattery: return "On battery · limit \(limit)"
            case .discharging: return "Discharging to \(limit)"
            case .resting: return "Resting"
            case .heatPaused: return "Paused – battery too warm"
            case .unmanaged: return "macOS manages charging"
            }
        }
    }
}
