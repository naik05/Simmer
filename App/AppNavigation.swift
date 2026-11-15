import AppKit
import Observation
import SwiftUI

enum SettingsTab: String, Hashable, CaseIterable {
    case general, behavior, schedules, history, helper, about
}

/// UI-only navigation state shared between the popover and the Settings window.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    var settingsTab = SettingsTab.general

    /// Opens the Settings window, optionally on a specific tab, and brings it to the front.
    /// Simmer is an agent app (no Dock icon), so it has to activate itself explicitly.
    func showSettings(_ tab: SettingsTab? = nil, using openSettings: OpenSettingsAction) {
        if let tab { settingsTab = tab }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
