import SimmerCore
import SwiftUI

@main
struct SimmerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let model = SimmerModel.shared
    private let navigation = AppNavigation.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .environment(navigation)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(navigation)
        }
    }
}
