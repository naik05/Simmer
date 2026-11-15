import SwiftUI

/// Circular gauge: the arc shows the charge level, the tick marks the charge limit.
struct ChargeGauge: View {
    var percent: Int?
    var limit: Int
    var tint: Color
    var showsLimit = true
    var isLimiterEnabled = true
    var diameter: CGFloat = 84
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if showsLimit {
                    // Cut a gap into the ring so the limit tick reads clearly on top of
                    // the arc as well as on the empty track.
                    limitTick(width: 8, extraHeight: 4)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            if showsLimit {
                // Limiter off: the tick stays (and follows the slider) as a quieter
                // preview of the limit that would apply.
                limitTick(width: 3, extraHeight: 6)
                    .foregroundStyle(isLimiterEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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
        .animation(.smooth(duration: 0.2), value: limit)
        .animation(.smooth(duration: 0.25), value: isLimiterEnabled)
        .animation(.smooth(duration: 0.35), value: showsLimit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery charge")
        .accessibilityValue(accessibilityValue)
    }

    private func limitTick(width: CGFloat, extraHeight: CGFloat) -> some View {
        Capsule()
            .frame(width: width, height: lineWidth + extraHeight)
            .offset(y: -(diameter - lineWidth) / 2)
            .rotationEffect(.degrees(Double(limit) * 3.6))
    }

    private var fraction: Double {
        min(max(Double(percent ?? 0) / 100, 0), 1)
    }

    private var accessibilityValue: String {
        guard let percent else { return "Unknown" }
        guard showsLimit else { return "\(percent) percent" }
        return isLimiterEnabled
            ? "\(percent) percent, limit \(limit) percent"
            : "\(percent) percent, limit \(limit) percent (limiter off)"
    }
}
