import ServiceManagement
import SimmerCore
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(SimmerModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var model = model
        let engine = model.settings.engine

        Form {
            Section("Charging") {
                LabeledContent("Charge limit") {
                    HStack {
                        Slider(value: limitBinding, in: 20...100) { Text("Charge limit") }
                            .labelsHidden()
                        Text(Format.percent(engine.effectiveLimit))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Stepper(value: $model.settings.engine.sailingBuffer, in: EngineConfig.bufferRange) {
                    LabeledContent("Sailing buffer") {
                        Text(Format.percent(engine.sailingBuffer)).monospacedDigit()
                    }
                    SettingsNote(sailingNote(engine))
                }
                .disabled(model.capabilities.limitEnforcedBySystem)
            }

            Section("Heat protection") {
                Toggle("Pause charging when the battery is warm", isOn: $model.settings.engine.heatProtectionEnabled)
                LabeledContent("Threshold") {
                    HStack {
                        Slider(value: thresholdBinding, in: 25...50) { Text("Heat threshold") }
                            .labelsHidden()
                        Text(Format.temperature(celsius: engine.heatThresholdC, unit: model.settings.temperatureUnit))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(!engine.heatProtectionEnabled)
                Picker("Temperature unit", selection: $model.settings.temperatureUnit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
            }

            Section("Menu bar") {
                MenuBarStylePicker(selection: $model.settings.menuBarStyle)
            }

            Section("MagSafe LED") {
                Picker("LED", selection: $model.settings.engine.ledMode) {
                    Text("Controlled by macOS").tag(LEDMode.system)
                    Text("Show Simmer status").tag(LEDMode.status)
                    Text("Always off").tag(LEDMode.off)
                }
                .disabled(!model.capabilities.hasMagSafeLED)
                SettingsNote(model.capabilities.hasMagSafeLED
                    ? "Status: green while holding, orange while charging, off while discharging, blinking during a heat pause."
                    : "No controllable MagSafe LED was detected on this Mac.")
            }

            Section {
                Toggle("Launch Simmer at login", isOn: launchBinding)
                if let launchError {
                    Label(launchError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private var limitBinding: Binding<Double> {
        Binding {
            Double(model.settings.engine.effectiveLimit)
        } set: { newValue in
            model.setLimit(Int(newValue.rounded()))
        }
    }

    /// Snaps to half degrees Celsius.
    private var thresholdBinding: Binding<Double> {
        Binding {
            model.settings.engine.heatThresholdC
        } set: { newValue in
            model.settings.engine.heatThresholdC = min(max((newValue * 2).rounded() / 2, 25), 50)
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding {
            launchAtLogin
        } set: { enable in
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchError = nil
            } catch {
                launchError = "Could not change the login item: \(error.localizedDescription)"
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func sailingNote(_ engine: EngineConfig) -> String {
        if model.capabilities.limitEnforcedBySystem {
            return "Not used on this Mac: macOS holds the battery right at the limit itself."
        }
        return engine.sailingBuffer == 0
            ? "Charging resumes as soon as the battery drops below the limit."
            : "After reaching the limit, charging resumes at \(Format.percent(engine.resumeLevel))."
    }
}

/// Four selectable tiles, each previewing one menu bar style.
private struct MenuBarStylePicker: View {
    @Binding var selection: MenuBarStyle

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MenuBarStyle.allCases, id: \.self) { style in
                let isSelected = style == selection
                Button {
                    selection = style
                } label: {
                    VStack(spacing: 6) {
                        preview(for: style)
                            .frame(height: 22)
                        Text(title(for: style))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        Color.primary.opacity(isSelected ? 0.08 : 0.03),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title(for: style)) menu bar style")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: selection)
    }

    @ViewBuilder
    private func preview(for style: MenuBarStyle) -> some View {
        switch style {
        case .ring: RingGlyph(fraction: 0.8, mark: .holding)
        case .percent: Text("80%").font(.system(size: 13)).monospacedDigit()
        case .watts: Text("+45W").font(.system(size: 13)).monospacedDigit()
        case .pot: PotGlyph()
        }
    }

    private func title(for style: MenuBarStyle) -> String {
        switch style {
        case .ring: "Ring"
        case .percent: "Percent"
        case .watts: "Watts"
        case .pot: "Pot"
        }
    }
}
