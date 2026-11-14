import SimmerCore
import SwiftUI

/// Gauge, status line and the master switch.
struct HeaderView: View {
    @Environment(SimmerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 14) {
            ChargeGauge(
                percent: model.snapshot?.percent,
                limit: model.settings.engine.effectiveLimit,
                tint: gaugeTint,
                showsLimit: model.settings.isLimiterEnabled
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Simmer")
                        .font(.headline)
                    if model.connection == .dryRun {
                        DryRunBadge()
                    }
                    Spacer(minLength: 0)
                    Toggle("Charge limiter", isOn: $model.settings.isLimiterEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(model.settings.isLimiterEnabled
                            ? "Turn the charge limiter off and let macOS manage charging"
                            : "Turn the charge limiter on")
                }

                Label {
                    Text(StatusDescription.text(for: model))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: model.connection.isUsable ? model.activity.symbolName : "powerplug")
                        .foregroundStyle(gaugeTint)
                        .frame(width: 14)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)

                if let remaining = remainingText {
                    Text(remaining)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .animation(.smooth(duration: 0.3), value: model.activity)
        }
    }

    private var gaugeTint: Color {
        model.connection.isUsable ? model.activity.tint : Color.secondary
    }

    private var remainingText: String? {
        guard let snapshot = model.snapshot, let minutes = snapshot.timeRemaining, minutes > 0 else { return nil }
        switch model.activity {
        case .charging: return "\(Format.duration(minutes: minutes)) until full"
        case .onBattery, .discharging: return "\(Format.duration(minutes: minutes)) remaining"
        default: return nil
        }
    }
}

struct DryRunBadge: View {
    var body: some View {
        Text("Dry run")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .help("SMC writes are simulated. Nothing is changed on this Mac.")
    }
}
