import SimmerCore
import SwiftUI

/// Shown while the privileged helper cannot be reached.
struct HelperBanner: View {
    @Environment(SimmerModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isConnecting ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isConnecting ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(isConnecting ? "Connecting to the helper…" : "Helper not available")
                        .font(.callout.weight(.semibold))
                    Text("Simmer needs its privileged helper to control charging. Until it runs, macOS charges as usual.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Install Helper…") {
                        navigation.showSettings(.helper, using: openSettings)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
    }

    private var isConnecting: Bool {
        model.connection == .connecting
    }
}

/// Shown when the installed helper is older or newer than this app.
struct HelperUpdateBanner: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Helper needs an update")
                        .font(.callout.weight(.semibold))
                    Text("The installed helper is from a different version of Simmer. Reinstall it so charging control works as expected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Update Helper…") {
                        navigation.showSettings(.helper, using: openSettings)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
    }
}

/// The most recent helper error.
struct ErrorBanner: View {
    var message: String

    var body: some View {
        Card(padding: 10) {
            Label {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}
