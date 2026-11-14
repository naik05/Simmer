import SimmerCore
import SwiftUI

/// Charge limit slider and sailing buffer.
struct LimitCard: View {
    @Environment(SimmerModel.self) private var model
    /// Value while the slider is being dragged; committed on release so the helper is not
    /// sent a new command for every intermediate step.
    @State private var draft: Int?
    @State private var isDragging = false

    var body: some View {
        @Bindable var model = model
        let engine = model.settings.engine

        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    CardTitle(title: "Charge limit", systemImage: "battery.75percent")
                    Spacer()
                    Text(Format.percent(draft ?? engine.effectiveLimit))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: draft ?? engine.effectiveLimit)
                }

                Slider(value: sliderValue, in: Self.range) {
                    Text("Charge limit")
                } minimumValueLabel: {
                    Text("\(EngineConfig.limitRange.lowerBound)").font(.caption2).foregroundStyle(.tertiary)
                } maximumValueLabel: {
                    Text("\(EngineConfig.limitRange.upperBound)").font(.caption2).foregroundStyle(.tertiary)
                } onEditingChanged: { editing in
                    isDragging = editing
                    if !editing, let draft {
                        model.setLimit(draft)
                        self.draft = nil
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityValue("\(draft ?? engine.effectiveLimit) percent")

                Divider()

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

    private static let range = Double(EngineConfig.limitRange.lowerBound)...Double(EngineConfig.limitRange.upperBound)

    private var sliderValue: Binding<Double> {
        Binding {
            Double(draft ?? model.settings.engine.effectiveLimit)
        } set: { newValue in
            let rounded = Int(newValue.rounded())
            if isDragging {
                draft = rounded
            } else {
                model.setLimit(rounded)
            }
        }
    }
}
