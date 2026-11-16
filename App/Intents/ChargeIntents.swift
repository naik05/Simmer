import AppIntents
import SimmerCore

struct SetChargeLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Charge Limit"
    static let description = IntentDescription("Sets the maximum charge level Simmer holds the battery at.")
    static let openAppWhenRun = false

    @Parameter(
        title: "Limit", description: "Charge limit in percent, from 20 to 100.",
        default: 80, inclusiveRange: (20, 100)
    )
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set the charge limit to \(\.$limit) %")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard EngineConfig.limitRange.contains(limit) else {
            throw SimmerIntentError.limitOutOfRange(limit)
        }
        let model = await IntentSupport.readyModel()
        model.setLimit(limit)
        let applied = model.settings.engine.effectiveLimit
        return .result(value: applied, dialog: "The charge limit is now \(applied) %.")
    }
}

struct StartDischargeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Discharge"
    static let description = IntentDescription("Drains the battery down to the charge limit while the Mac stays plugged in.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await IntentSupport.readyModel()
        try IntentSupport.requireLimiter(model)
        guard model.capabilities.canDischarge else { throw SimmerIntentError.dischargeUnavailable }
        model.startDischarge()
        return .result(dialog: "Discharging to \(model.effectiveLimit) %.")
    }
}

struct StopDischargeIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Discharge"
    static let description = IntentDescription("Ends a discharge, Top Up or calibration and returns to the normal charge limiter.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await IntentSupport.readyModel()
        model.returnToNormal()
        return .result(dialog: "Back to holding at \(model.effectiveLimit) %.")
    }
}

struct TopUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Top Up"
    static let description = IntentDescription("Charges the battery to 100 % once, then returns to the charge limit.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await IntentSupport.readyModel()
        try IntentSupport.requireLimiter(model)
        model.startTopUp()
        return .result(dialog: "Topping up to 100 %.")
    }
}

struct GetBatteryStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Battery Status"
    static let description = IntentDescription("Returns the battery charge in percent and describes what Simmer is doing.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let model = await IntentSupport.readyModel()
        guard let snapshot = model.snapshot else { throw SimmerIntentError.noBattery }
        let status = StatusDescription.text(for: model)
        return .result(value: snapshot.percent, dialog: "The battery is at \(snapshot.percent) %. \(status).")
    }
}
