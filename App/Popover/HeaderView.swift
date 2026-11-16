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
                limit: model.effectiveLimit,
                tint: gaugeTint,
                showsLimit: true,
                isLimiterEnabled: model.settings.isLimiterEnabled
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
        guard let snapshot = model.snapshot, model.connection.isUsable || model.activity == .onBattery else {
            return nil
        }
        let config = model.effectiveEngineConfig
        let system = snapshot.timeRemaining.flatMap { $0 > 0 ? $0 : nil }
        switch model.activity {
        case .charging:
            // macOS only estimates "until full"; while a limit applies, estimate to the limit.
            let target = chargeTarget(config)
            if target >= 100 { return system.map { "\(Format.duration(minutes: $0)) until full" } }
            return snapshot.minutes(toReach: target).map {
                "About \(Format.duration(minutes: $0)) until \(Format.percent(target))"
            }
        case .discharging:
            let target = dischargeTarget(config)
            return snapshot.minutes(toReach: target).map {
                "About \(Format.duration(minutes: $0)) until \(Format.percent(target))"
            }
        case .onBattery:
            return system.map { "\(Format.duration(minutes: $0)) remaining" }
        default:
            return nil
        }
    }

    private func chargeTarget(_ config: EngineConfig) -> Int {
        switch model.engineState.mode {
        case .topUp, .calibration(.chargeToFull): 100
        default: config.effectiveLimit
        }
    }

    private func dischargeTarget(_ config: EngineConfig) -> Int {
        if case .calibration = model.engineState.mode { return config.calibrationLowPercent }
        return config.effectiveLimit
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
