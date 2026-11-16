import Foundation

public enum TemperatureUnit: String, Codable, Sendable, CaseIterable {
    case celsius, fahrenheit
}

public enum MenuBarStyle: String, Codable, Sendable, CaseIterable {
    /// Ring that fills with the state of charge.
    case ring
    /// Percentage as text.
    case percent
    /// Battery power in watts.
    case watts
    /// The minimal Simmer pot icon.
    case pot
}

/// Everything the user can configure. Unknown or missing fields decode to their defaults,
/// so settings survive app updates.
public struct SimmerSettings: Codable, Sendable, Equatable {
    public var engine = EngineConfig()
    /// Master switch. Off = macOS manages charging and Simmer only shows telemetry.
    public var isLimiterEnabled = true
    /// Hand the limit to the firmware / inhibit charging before the Mac sleeps.
    public var stopChargingBeforeSleep = true
    /// Keep a firmware-enforced limit when Simmer quits or the Mac is shut down.
    public var keepLimitWhenOff = false
    /// Restore stock charging behaviour when Simmer quits.
    public var resetOnQuit = true
    public var temperatureUnit = TemperatureUnit.celsius
    public var menuBarStyle = MenuBarStyle.ring
    public var notificationsEnabled = true
    /// Simulate SMC writes in-process instead of talking to the privileged helper.
    public var dryRun = false
    public var schedules: [ScheduleRule] = []
    /// Situation-dependent limits, in priority order.
    public var situationRules: [SituationRule] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SimmerSettings()
        engine = try values.decodeIfPresent(EngineConfig.self, forKey: .engine) ?? defaults.engine
        isLimiterEnabled = try values.decodeIfPresent(Bool.self, forKey: .isLimiterEnabled) ?? defaults.isLimiterEnabled
        stopChargingBeforeSleep = try values.decodeIfPresent(Bool.self, forKey: .stopChargingBeforeSleep)
            ?? defaults.stopChargingBeforeSleep
        keepLimitWhenOff = try values.decodeIfPresent(Bool.self, forKey: .keepLimitWhenOff) ?? defaults.keepLimitWhenOff
        resetOnQuit = try values.decodeIfPresent(Bool.self, forKey: .resetOnQuit) ?? defaults.resetOnQuit
        // Enums decode leniently: a value from a newer version must not wipe all settings.
        temperatureUnit = (try? values.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit))
            ?? defaults.temperatureUnit
        menuBarStyle = (try? values.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle)) ?? defaults.menuBarStyle
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)
            ?? defaults.notificationsEnabled
        dryRun = try values.decodeIfPresent(Bool.self, forKey: .dryRun) ?? defaults.dryRun
        schedules = try values.decodeIfPresent([ScheduleRule].self, forKey: .schedules) ?? defaults.schedules
        situationRules = (try? values.decodeIfPresent([SituationRule].self, forKey: .situationRules))
            ?? defaults.situationRules
    }

    /// What the helper should do when the app goes away.
    public var failSafePolicy: FailSafePolicy {
        FailSafePolicy(
            resetOnDisconnect: resetOnQuit,
            persistentBand: keepLimitWhenOff && isLimiterEnabled ? engine.holdBand : nil
        )
    }
}

/// Persists settings and engine state as JSON in `UserDefaults`.
public struct SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let settingsKey = "simmer.settings"
    private static let engineStateKey = "simmer.engineState"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadSettings() -> SimmerSettings {
        load(SimmerSettings.self, key: Self.settingsKey) ?? SimmerSettings()
    }

    public func save(_ settings: SimmerSettings) {
        store(settings, key: Self.settingsKey)
    }

    public func loadEngineState() -> EngineState {
        load(EngineState.self, key: Self.engineStateKey) ?? EngineState()
    }

    public func save(_ state: EngineState) {
        store(state, key: Self.engineStateKey)
    }

    private func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func store<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
