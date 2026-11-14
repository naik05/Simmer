import SwiftUI

/// Circular gauge: the arc shows the charge level, the tick marks the charge limit.
struct ChargeGauge: View {
    var percent: Int?
    var limit: Int
    var tint: Color
    var showsLimit = true
    var diameter: CGFloat = 84
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsLimit {
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 3, height: lineWidth + 6)
                    .offset(y: -(diameter - lineWidth) / 2)
                    .rotationEffect(.degrees(Double(limit) * 3.6))
                    .transition(.opacity)
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(percent.map(String.init) ?? Format.placeholder)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if percent != nil {
                    Text("%")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.smooth(duration: 0.5), value: fraction)
        .animation(.smooth(duration: 0.35), value: limit)
        .animation(.smooth(duration: 0.35), value: showsLimit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery charge")
        .accessibilityValue(accessibilityValue)
    }

    private var fraction: Double {
        min(max(Double(percent ?? 0) / 100, 0), 1)
    }

    private var accessibilityValue: String {
        guard let percent else { return "Unknown" }
        return showsLimit ? "\(percent) percent, limit \(limit) percent" : "\(percent) percent"
    }
}
