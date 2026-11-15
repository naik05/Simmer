import SimmerCore
import SwiftUI

struct BehaviorSettingsTab: View {
    @Environment(SimmerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let capabilities = model.capabilities

        Form {
            Section("Sleep and shutdown") {
                Toggle(isOn: $model.settings.stopChargingBeforeSleep) {
                    Text("Stop charging before sleep")
                    SettingsNote("Nobody watches the battery while the Mac sleeps, so Simmer inhibits charging before it does.")
                }
                Toggle(isOn: $model.settings.keepLimitWhenOff) {
                    Text("Keep the limit when the Mac is off")
                    SettingsNote(persistNote(capabilities))
                }
                .disabled(!capabilities.canPersistLimit)
            }

            Section("Quitting") {
                Toggle(isOn: $model.settings.resetOnQuit) {
                    Text("Reset to stock charging when Simmer quits")
                    SettingsNote("Recommended. Without it, the last charging state stays in effect until Simmer runs again or the Mac restarts.")
                }
            }

            Section("Notifications") {
                Toggle(isOn: $model.settings.notificationsEnabled) {
                    Text("Notify about charging events")
                    SettingsNote("Limit reached, Top Up and discharge finished, heat pauses and calibration progress.")
                }
                .onChange(of: model.settings.notificationsEnabled) { _, enabled in
                    guard enabled else { return }
                    Task { await NotificationPoster.requestAuthorizationIfNeeded() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func persistNote(_ capabilities: HardwareCapabilities) -> String {
        switch capabilities.hardwareLimit {
        case .none:
            return model.connection.isUsable
                ? "This Mac's firmware cannot enforce a charge limit on its own, so a limit only holds while Simmer runs."
                : "Available once the helper is installed and the firmware supports its own charge limit."
        case .chwa:
            return "The firmware enforces the limit while Simmer is not running. This Mac only supports a fixed 80 % firmware limit (CHWA), whatever limit you chose."
        case .bclm, .firmwareBand, .nativeLimit:
            return "The firmware enforces your limit while Simmer is not running or the Mac is shut down."
        }
    }
}
