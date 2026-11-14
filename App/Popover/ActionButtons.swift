import SimmerCore
import SwiftUI

/// Top Up / Discharge / Calibrate. Each button toggles: tapping the active one cancels it.
struct ActionButtons: View {
    @Environment(SimmerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ActionButton(
                    title: "Top Up", systemImage: "bolt.fill", isActive: mode == .topUp,
                    help: mode == .topUp ? "Cancel Top Up" : "Charge to 100 % once, then return to the limit"
                ) {
                    toggle(isActive: mode == .topUp) { model.startTopUp() }
                }
                .disabled(!isManaging)

                ActionButton(
                    title: "Discharge", systemImage: "arrow.down.to.line", isActive: mode == .discharge,
                    help: dischargeHelp(
                        active: mode == .discharge, cancel: "Cancel discharge",
                        start: "Drain the battery down to the limit while plugged in"
                    )
                ) {
                    toggle(isActive: mode == .discharge) { model.startDischarge() }
                }
                .disabled(!isManaging || !model.capabilities.canDischarge)

                ActionButton(
                    title: "Calibrate", systemImage: "gauge.with.needle", isActive: isCalibrating,
                    help: dischargeHelp(
                        active: isCalibrating, cancel: "Cancel calibration",
                        start: "Run a full charge, discharge, rest and recharge cycle"
                    )
                ) {
                    toggle(isActive: isCalibrating) { model.startCalibration() }
                }
                .disabled(!isManaging || !model.capabilities.canDischarge)
            }

            if model.connection.isUsable, !model.capabilities.canDischarge {
                Text(Self.unsupportedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private static let unsupportedText =
        "Discharge and Calibrate need adapter control, which this Mac does not offer."

    private var mode: EngineMode { model.engineState.mode }

    private var isCalibrating: Bool {
        if case .calibration = mode { true } else { false }
    }

    /// Actions only do something while the limiter runs and a battery is present.
    private var isManaging: Bool {
        model.settings.isLimiterEnabled && model.snapshot != nil
    }

    private func toggle(isActive: Bool, start: () -> Void) {
        if isActive { model.returnToNormal() } else { start() }
    }

    private func dischargeHelp(active: Bool, cancel: String, start: String) -> String {
        if active { return cancel }
        if !model.settings.isLimiterEnabled { return "Turn the charge limiter on first" }
        if !model.connection.isUsable { return "Install the helper to use this" }
        if !model.capabilities.canDischarge { return Self.unsupportedText }
        return start
    }
}

private struct ActionButton: View {
    var title: String
    var systemImage: String
    var isActive: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.caption.weight(.medium))
            }
        }
        .buttonStyle(ActionButtonStyle(isActive: isActive))
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Active" : "Inactive")
        .accessibilityHint(help)
    }
}

private struct ActionButtonStyle: ButtonStyle {
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, isActive: isActive)
    }

    private struct Chrome: View {
        let configuration: Configuration
        var isActive: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                .background(
                    isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.06)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .animation(.snappy(duration: 0.2), value: isActive)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
