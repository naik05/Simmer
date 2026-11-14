import SimmerCore
import SwiftUI

struct HelperSettingsTab: View {
    @Environment(SimmerModel.self) private var model
    @State private var installer = HelperInstaller()
    @State private var installStatus = HelperInstaller.Status.notInstalled
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Status") {
                LabeledContent("Connection") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(connectionTitle)
                    }
                }
                if case .unavailable(let reason) = model.connection {
                    SettingsNote(reason)
                        .textSelection(.enabled)
                }
                LabeledContent("Helper daemon", value: installTitle)
                if installStatus == .requiresApproval {
                    SettingsNote("Allow Simmer under System Settings → General → Login Items & Extensions, then come back here.")
                }
            }

            Section("Installation") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("Install (Login Items)") {
                            run { try await installer.install(.serviceManagement) }
                        }
                        Button("Install with administrator password") {
                            run { try await installer.install(.script) }
                        }
                        if isWorking {
                            ProgressView().controlSize(.small)
                        }
                    }
                    HStack {
                        Button("Uninstall", role: .destructive) {
                            run { try await installer.uninstall() }
                        }
                        Button("Open Login Items Settings") {
                            installer.openLoginItemsSettings()
                        }
                    }
                }
                .disabled(isWorking)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                SettingsNote("Login Items needs a properly signed app. For a locally built copy, use the administrator password route.")
            }

            Section("Detected hardware") {
                LabeledContent("Mac", value: "\(HostInfo.modelIdentifier) · \(model.capabilities.architecture == .intel ? "Intel" : "Apple silicon")")
                LabeledContent("Charging control", value: chargingTitle)
                LabeledContent("Adapter control", value: adapterTitle)
                LabeledContent("Hardware limit", value: limitTitle)
                LabeledContent("MagSafe LED", value: model.capabilities.hasMagSafeLED ? "ACLC" : "Not available")
                if !model.connection.isUsable {
                    SettingsNote("Capabilities are detected by the helper once it is connected.")
                }
            }

            Section("Dry run") {
                Toggle(isOn: $model.settings.dryRun) {
                    Text("Simulate SMC writes")
                    SettingsNote("Simmer runs without the helper and only records what it would write. Nothing is changed on this Mac.")
                }
                if model.settings.dryRun || !model.dryRunLog.isEmpty {
                    DryRunLogView(lines: model.dryRunLog)
                    HStack {
                        Text("\(model.dryRunLog.count) writes")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { model.clearDryRunLog() }
                            .controlSize(.small)
                            .disabled(model.dryRunLog.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { installStatus = installer.status }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await operation()
            } catch let error as HelperInstaller.InstallError {
                errorMessage = error.description
            } catch {
                errorMessage = error.localizedDescription
            }
            installStatus = installer.status
            await model.reconnect()
            isWorking = false
        }
    }

    private var connectionTitle: String {
        switch model.connection {
        case .connecting: "Connecting…"
        case .connected(let version): "Connected · helper \(version)"
        case .dryRun: "Dry run – writes are simulated"
        case .unavailable: "Not connected"
        }
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connecting: .yellow
        case .connected: .green
        case .dryRun: .blue
        case .unavailable: .red
        }
    }

    private var installTitle: String {
        switch installStatus {
        case .notInstalled: "Not installed"
        case .requiresApproval: "Waiting for approval"
        case .installed: "Installed"
        }
    }

    private var chargingTitle: String {
        switch model.capabilities.charging {
        case .firmwareBand: "Firmware charge band (bfF0, bfD0, bfE0)"
        case .chte: "CHTE"
        case .ch0bCh0c: "CH0B and CH0C"
        case .bclm: "BCLM"
        case .adapterCycling: "Adapter cycling (holds the limit on battery power)"
        case .none: "Not available"
        }
    }

    private var adapterTitle: String {
        switch model.capabilities.adapter {
        case .chie: "CHIE"
        case .ch0j: "CH0J"
        case .ch0i: "CH0I"
        case .none: "Not available"
        }
    }

    private var limitTitle: String {
        switch model.capabilities.hardwareLimit {
        case .firmwareBand: "Firmware charge band (any limit)"
        case .bclm: "BCLM (any limit)"
        case .chwa: "CHWA (fixed 80 %)"
        case .none: "Not available"
        }
    }
}

/// Monospaced, auto-scrolling list of simulated SMC writes.
private struct DryRunLogView: View {
    var lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text("No writes recorded yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 130)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onChange(of: lines.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        .accessibilityLabel("Dry run log")
    }
}
