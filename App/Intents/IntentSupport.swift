import AppIntents
import SimmerCore

enum SimmerIntentError: Error, CustomLocalizedStringResourceConvertible {
    case limitOutOfRange(Int)
    case noBattery
    case limiterDisabled
    case dischargeUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .limitOutOfRange(let value):
            "\(value) % is outside the supported range. Choose a limit between 20 % and 100 %."
        case .noBattery:
            "Simmer could not read the battery."
        case .limiterDisabled:
            "The charge limiter is turned off. Turn it on in Simmer first."
        case .dischargeUnavailable:
            "Discharging is not available. The helper is not connected or this Mac has no adapter control."
        }
    }
}

@MainActor
enum IntentSupport {
    /// Makes sure the model runs when an intent launched Simmer in the background, and gives
    /// it a moment to read the battery and reach the helper.
    static func readyModel() async -> SimmerModel {
        let model = SimmerModel.shared
        model.start()
        if model.snapshot == nil || model.connection == .connecting {
            model.refresh()
            for _ in 0..<30 where model.snapshot == nil || model.connection == .connecting {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return model
    }

    static func requireLimiter(_ model: SimmerModel) throws {
        guard model.snapshot != nil else { throw SimmerIntentError.noBattery }
        guard model.settings.isLimiterEnabled else { throw SimmerIntentError.limiterDisabled }
    }
}
