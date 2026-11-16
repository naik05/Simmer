import SimmerCore
import SwiftUI

struct SchedulesSettingsTab: View {
    @Environment(SimmerModel.self) private var model
    @State private var expanded: Set<UUID> = []

    var body: some View {
        @Bindable var model = model

        Form {
            if model.settings.schedules.isEmpty {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No schedules yet")
                            .font(.headline)
                        Text("Automate Simmer by weekday and time, for example a Top Up on weekday mornings before you leave.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }

            ForEach($model.settings.schedules) { $rule in
                Section {
                    ScheduleRuleHeader(
                        rule: $rule,
                        isExpanded: expanded.contains(rule.id),
                        toggleExpanded: { toggle(rule.id) },
                        delete: { delete(rule.id) }
                    )
                    if expanded.contains(rule.id) {
                        ScheduleRuleEditor(rule: $rule)
                    }
                }
            }

            Section {
                Button {
                    let rule = ScheduleRule()
                    model.settings.schedules.append(rule)
                    expanded.insert(rule.id)
                } label: {
                    Label("Add Schedule", systemImage: "plus")
                }
            } footer: {
                Text("Schedules run while Simmer is open. One that is missed by more than 15 minutes, for example because the Mac was asleep, is skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SituationRulesSection()
        }
        .formStyle(.grouped)
        .animation(.snappy(duration: 0.25), value: expanded)
        .animation(.snappy(duration: 0.25), value: model.settings.schedules.map(\.id))
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func delete(_ id: UUID) {
        expanded.remove(id)
        model.settings.schedules.removeAll { $0.id == id }
    }
}

private struct ScheduleRuleHeader: View {
    @Binding var rule: ScheduleRule
    var isExpanded: Bool
    var toggleExpanded: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Enabled", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Enable schedule \(rule.summary)")

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.summary)
                    .monospacedDigit()
                Text(nextFireText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .opacity(rule.isEnabled ? 1 : 0.55)

            Spacer()

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this schedule")
            .accessibilityLabel("Delete schedule")

            Button(action: toggleExpanded) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Hide details" : "Edit this schedule")
            .accessibilityLabel(isExpanded ? "Collapse schedule" : "Edit schedule")
        }
    }

    private var nextFireText: String {
        guard rule.isEnabled else { return "Disabled" }
        guard let date = Scheduler.nextFireDate(for: rule, after: Date()) else { return "No weekday selected" }
        return "Next: \(date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute()))"
    }
}

private struct ScheduleRuleEditor: View {
    @Binding var rule: ScheduleRule

    /// Monday first; values are `Calendar` weekday numbers (1 = Sunday).
    private static let weekdays: [(number: Int, short: String, name: String)] = [
        (2, "Mon", "Monday"), (3, "Tue", "Tuesday"), (4, "Wed", "Wednesday"), (5, "Thu", "Thursday"),
        (6, "Fri", "Friday"), (7, "Sat", "Saturday"), (1, "Sun", "Sunday"),
    ]

    var body: some View {
        LabeledContent("Days") {
            HStack(spacing: 4) {
                ForEach(Self.weekdays, id: \.number) { day in
                    Toggle(day.short, isOn: weekdayBinding(day.number))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .accessibilityLabel(day.name)
                }
            }
        }

        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)

        Picker("Action", selection: kindBinding) {
            ForEach(ActionKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }

        if case .setLimit(let percent) = rule.action {
            Stepper(value: limitBinding, in: EngineConfig.limitRange, step: 5) {
                LabeledContent("Limit") {
                    Text(Format.percent(percent)).monospacedDigit()
                }
            }
        }
    }

    private func weekdayBinding(_ number: Int) -> Binding<Bool> {
        Binding {
            rule.weekdays.contains(number)
        } set: { isOn in
            if isOn { rule.weekdays.insert(number) } else { rule.weekdays.remove(number) }
        }
    }

    private var timeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            rule.hour = components.hour ?? rule.hour
            rule.minute = components.minute ?? rule.minute
        }
    }

    private var kindBinding: Binding<ActionKind> {
        Binding {
            ActionKind(rule.action)
        } set: { kind in
            guard kind != ActionKind(rule.action) else { return }
            rule.action = kind.action
        }
    }

    private var limitBinding: Binding<Int> {
        Binding {
            if case .setLimit(let percent) = rule.action { percent } else { 80 }
        } set: { percent in
            rule.action = .setLimit(percent)
        }
    }
}

/// `ScheduleAction` without its payload, for the picker.
private enum ActionKind: CaseIterable, Hashable {
    case topUp, setLimit, startDischarge, returnToNormal, startCalibration

    init(_ action: ScheduleAction) {
        self = switch action {
        case .topUp: .topUp
        case .setLimit: .setLimit
        case .startDischarge: .startDischarge
        case .returnToNormal: .returnToNormal
        case .startCalibration: .startCalibration
        }
    }

    var action: ScheduleAction {
        switch self {
        case .topUp: .topUp
        case .setLimit: .setLimit(80)
        case .startDischarge: .startDischarge
        case .returnToNormal: .returnToNormal
        case .startCalibration: .startCalibration
        }
    }

    var title: String {
        switch self {
        case .topUp: "Top Up"
        case .setLimit: "Set limit to…"
        case .startDischarge: "Start discharge"
        case .returnToNormal: "Return to normal"
        case .startCalibration: "Start calibration"
        }
    }
}

extension ScheduleAction {
    var title: String {
        switch self {
        case .topUp: "Top Up"
        case .setLimit(let percent): "Set limit to \(Format.percent(percent))"
        case .startDischarge: "Start discharge"
        case .returnToNormal: "Return to normal"
        case .startCalibration: "Start calibration"
        }
    }
}

extension ScheduleRule {
    /// "Weekdays 07:30 · Top Up"
    var summary: String {
        "\(weekdaySummary) \(timeText) · \(action.title)"
    }

    var timeText: String {
        guard let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) else {
            return "\(hour):\(minute < 10 ? "0" : "")\(minute)"
        }
        return date.formatted(.dateTime.hour().minute())
    }

    var weekdaySummary: String {
        switch weekdays {
        case []: return "Never"
        case Set(1...7): return "Every day"
        case [2, 3, 4, 5, 6]: return "Weekdays"
        case [1, 7]: return "Weekends"
        default:
            let names = [2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat", 1: "Sun"]
            return [2, 3, 4, 5, 6, 7, 1].filter(weekdays.contains).compactMap { names[$0] }.joined(separator: ", ")
        }
    }
}
