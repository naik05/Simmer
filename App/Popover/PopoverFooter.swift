import AppKit
import SwiftUI

struct PopoverFooter: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Button {
                navigation.showSettings(using: openSettings)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit Simmer")
        }
        .buttonStyle(FooterButtonStyle())
        .padding(.top, 2)
    }
}

private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
