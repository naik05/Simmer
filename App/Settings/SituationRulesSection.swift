import SimmerCore
import SwiftUI

extension SituationCondition {
    /// Short phrase for "this is why the limit differs right now".
    var summary: String {
        switch self {
        case .adapter(let watts): "\(watts) W adapter"
        case .externalDisplay: "External display connected"
        case .pluggedInWithoutDisplay: "Plugged in away from the desk"
        }
    }

    var title: String {
        switch self {
        case .adapter(let watts): "When a \(watts) W adapter is connected"
        case .externalDisplay: "When an external display is connected"
        case .pluggedInWithoutDisplay: "When plugged in without an external display"
        }
    }

    var symbolName: String {
        switch self {
        case .adapter: "powerplug"
        case .externalDisplay: "display"
        case .pluggedInWithoutDisplay: "laptopcomputer"
        }
    }
}

/// Situation-dependent charge limits: "at the desk hold 60 %, on the small charger 100 %".
struct SituationRulesSection: View {
    @Environment(SimmerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let activeID = model.activeSituationRule?.id

        Section {
            if model.settings.situationRules.isEmpty {
                SettingsNote("Use a different charge limit depending on where the Mac is: a lower one at the desk, a higher one on a travel charger. The first rule that matches wins; with no match the normal limit applies.")
            }
            ForEach($model.settings.situationRules) { $rule in
                HStack(spacing: 10) {
                    Toggle(rule.condition.title, isOn: $rule.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Enable rule: \(rule.condition.title)")
                    Image(systemName: rule.condition.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.condition.title)
                        if rule.id == activeID {
                            Text("Active now").font(.caption).foregroundStyle(.green)
                        }
                    }
                    Spacer()
                    Stepper(value: $rule.limit, in: EngineConfig.limitRange, step: 5) {
                        Text(Format.percent(rule.effectiveLimit)).monospacedDigit()
                    }
                    .fixedSize()
                    .accessibilityLabel("Limit for this rule")
                    .accessibilityValue("\(rule.effectiveLimit) percent")
                    Button(role: .destructive) {
                        model.settings.situationRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete rule")
                }
            }

            Menu {
                if let watts = model.situation.adapterWatts {
                    Button("For the connected \(watts) W adapter") { add(.adapter(watts: watts)) }
                }
                Button("When an external display is connected") { add(.externalDisplay) }
                Button("When plugged in without an external display") { add(.pluggedInWithoutDisplay) }
            } label: {
                Label("Add Situation Rule", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } header: {
            Text("Situations")
        } footer: {
            Text("Now: \(currentSituation)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var currentSituation: String {
        let adapter = model.situation.adapterWatts.map { "\($0) W adapter" } ?? "on battery"
        let count = model.situation.externalDisplayCount
        let displays = count == 0 ? "no external display" : "\(count) external display\(count == 1 ? "" : "s")"
        return "\(adapter), \(displays)"
    }

    private func add(_ condition: SituationCondition) {
        // A new rule starts at the normal limit so adding one changes nothing by itself.
        model.settings.situationRules.append(
            SituationRule(condition: condition, limit: model.settings.engine.effectiveLimit)
        )
    }
}
