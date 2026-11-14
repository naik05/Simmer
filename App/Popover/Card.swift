import SwiftUI

/// A grouped, softly filled container in the style of Control Center modules.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Small uppercase caption used above card content.
struct CardTitle: View {
    var title: String
    var systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}
