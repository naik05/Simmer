import SimmerCore
import SwiftUI

/// Charge limit slider and sailing buffer.
struct LimitCard: View {
    @Environment(SimmerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let engine = model.settings.engine

        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    CardTitle(title: "Charge limit", systemImage: "battery.75percent")
                    Spacer()
                    Text(Format.percent(engine.effectiveLimit))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: engine.effectiveLimit)
                }

                Slider(value: sliderValue, in: Self.range) {
                    Text("Charge limit")
                } minimumValueLabel: {
                    Text("\(EngineConfig.limitRange.lowerBound)").font(.caption2).foregroundStyle(.tertiary)
                } maximumValueLabel: {
                    Text("\(EngineConfig.limitRange.upperBound)").font(.caption2).foregroundStyle(.tertiary)
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityValue("\(engine.effectiveLimit) percent")

                Divider()

                if model.capabilities.limitEnforcedBySystem {
                    Label {
                        Text("macOS holds the battery at the limit, also during sleep.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "moon.zzz")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sailing buffer")
                            .font(.callout)
                        Text(engine.sailingBuffer == 0
                            ? "Off – recharges right below the limit"
                            : "Resumes at \(Format.percent(engine.resumeLevel))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(Format.percent(engine.sailingBuffer))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: engine.sailingBuffer)
                    Stepper("Sailing buffer", value: $model.settings.engine.sailingBuffer, in: EngineConfig.bufferRange)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityValue("\(engine.sailingBuffer) percent")
                }
                }
            }
        }
    }

    private static let range = Double(EngineConfig.limitRange.lowerBound)...Double(EngineConfig.limitRange.upperBound)

    private var sliderValue: Binding<Double> {
        Binding {
            Double(model.settings.engine.effectiveLimit)
        } set: { newValue in
            model.setLimit(Int(newValue.rounded()))
        }
    }
}
