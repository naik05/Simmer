import SimmerCore
import SwiftUI

/// The menu bar popover.
struct PopoverView: View {
    @Environment(SimmerModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            HeaderView()
                .padding(.horizontal, 4)
                .padding(.top, 2)

            if model.connection.isMissing {
                HelperBanner()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.helperNeedsUpdate {
                HelperUpdateBanner()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let error = model.lastError {
                ErrorBanner(message: error)
                    .transition(.opacity)
            }

            LimitCard()
            ActionButtons()

            if case .calibration(let phase) = model.engineState.mode {
                CalibrationCard(phase: phase)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }

            TelemetryGrid()
            PopoverFooter()
        }
        .padding(12)
        .frame(width: 320)
        .animation(.snappy(duration: 0.3), value: model.engineState.mode)
        .animation(.snappy(duration: 0.3), value: model.connection)
        .animation(.snappy(duration: 0.3), value: model.lastError)
        .onAppear { model.refresh() }
    }
}
