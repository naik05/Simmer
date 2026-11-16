import SimmerCore
import SwiftUI

/// The Settings window.
struct SettingsView: View {
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.settingsTab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            BehaviorSettingsTab()
                .tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.behavior)
            SchedulesSettingsTab()
                .tabItem { Label("Automation", systemImage: "calendar.badge.clock") }
                .tag(SettingsTab.schedules)
            HistorySettingsTab()
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
                .tag(SettingsTab.history)
            HealthSettingsTab()
                .tabItem { Label("Health", systemImage: "heart") }
                .tag(SettingsTab.health)
            HelperSettingsTab()
                .tabItem { Label("Helper", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.helper)
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 540, height: height)
    }

    private var height: CGFloat {
        switch navigation.settingsTab {
        case .general: 640
        case .behavior: 430
        case .schedules: 600
        case .history: 720
        case .health: 620
        case .helper: 640
        case .about: 400
        }
    }
}

/// Secondary explanatory text under a settings row.
struct SettingsNote: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
