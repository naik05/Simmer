import SimmerCore
import SwiftUI

/// The status item content. Follows `settings.menuBarStyle`.
struct MenuBarLabel: View {
    let model: SimmerModel

    var body: some View {
        Group {
            switch model.settings.menuBarStyle {
            case .ring:
                Image(nsImage: GlyphRenderer.templateImage(
                    RingGlyph(fraction: fraction, mark: RingGlyph.Mark(activity: model.activity))
                ))
            case .percent:
                Text(model.snapshot.map { "\($0.percent)%" } ?? Format.placeholder)
                    .monospacedDigit()
            case .watts:
                Text(model.snapshot.map { Format.menuBarWatts($0.batteryWatts) } ?? Format.placeholder)
                    .monospacedDigit()
            case .pot:
                Image(nsImage: GlyphRenderer.templateImage(PotGlyph()))
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var fraction: Double {
        Double(model.snapshot?.percent ?? 0) / 100
    }

    private var accessibilityText: String {
        guard let snapshot = model.snapshot else { return "Simmer" }
        return "Simmer, battery \(snapshot.percent) percent, \(StatusDescription.text(for: model))"
    }
}
