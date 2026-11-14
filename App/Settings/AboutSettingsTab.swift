import SwiftUI

struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 14) {
            PotGlyph(size: CGSize(width: 72, height: 64))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text("Simmer")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Simmer keeps your MacBook's battery at a gentle charge level instead of holding it at 100 %. It stops charging at the limit you choose, lets the Mac run from the adapter, pauses charging when the battery gets warm, and can top up, discharge or calibrate the battery on demand or on a schedule.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text("Simmer changes charging behaviour through the System Management Controller using a privileged helper. It restores stock charging when it quits unless you choose otherwise. Use it at your own risk.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }
}
