import SimmerCore
import SwiftUI

/// Shown while a calibration runs: the four phases, overall progress and a way out.
struct CalibrationCard: View {
    @Environment(SimmerModel.self) private var model
    var phase: CalibrationPhase

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(title: "Calibration", systemImage: "gauge.with.needle")
                    Spacer()
                    Text((model.calibrationProgress ?? 0).formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(CalibrationPhase.allCases, id: \.self) { item in
                        PhaseRow(
                            number: item.index + 1,
                            title: item.title(config: model.settings.engine),
                            state: item.index < phase.index ? .done : (item == phase ? .current : .upcoming)
                        )
                    }
                }

                ProgressView(value: min(max(model.calibrationProgress ?? 0, 0), 1))
                    .progressViewStyle(.linear)
                    .animation(.smooth, value: model.calibrationProgress)
                    .accessibilityLabel("Calibration progress")

                Button("Cancel Calibration", role: .cancel) {
                    model.returnToNormal()
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct PhaseRow: View {
    enum State { case done, current, upcoming }

    var number: Int
    var title: String
    var state: State

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                case .current:
                    Image(systemName: "\(number).circle.fill").foregroundStyle(Color.accentColor)
                case .upcoming:
                    Image(systemName: "\(number).circle").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 14))
            .frame(width: 16)

            Text(title)
                .font(.callout.weight(state == .current ? .semibold : .regular))
                .foregroundStyle(state == .current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Phase \(number): \(title)")
        .accessibilityValue(state == .done ? "Done" : (state == .current ? "In progress" : "Upcoming"))
    }
}
