import AppIntents

struct SimmerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetBatteryStatusIntent(),
            phrases: [
                "Get battery status from \(.applicationName)",
                "What is \(.applicationName) doing",
            ],
            shortTitle: "Battery Status",
            systemImageName: "battery.75percent"
        )
        AppShortcut(
            intent: TopUpIntent(),
            phrases: [
                "Top up with \(.applicationName)",
                "Charge to full with \(.applicationName)",
            ],
            shortTitle: "Top Up",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: SetChargeLimitIntent(),
            phrases: [
                "Set the charge limit with \(.applicationName)",
                "Change the \(.applicationName) charge limit",
            ],
            shortTitle: "Set Charge Limit",
            systemImageName: "slider.horizontal.3"
        )
        AppShortcut(
            intent: StartDischargeIntent(),
            phrases: [
                "Start discharging with \(.applicationName)",
                "Discharge the battery with \(.applicationName)",
            ],
            shortTitle: "Start Discharge",
            systemImageName: "arrow.down.to.line"
        )
        AppShortcut(
            intent: StopDischargeIntent(),
            phrases: [
                "Stop discharging with \(.applicationName)",
                "Return \(.applicationName) to normal",
            ],
            shortTitle: "Stop Discharge",
            systemImageName: "stop.fill"
        )
    }
}
