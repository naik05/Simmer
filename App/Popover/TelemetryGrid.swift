import SimmerCore
import SwiftUI

/// Live readings in a two-column grid.
struct TelemetryGrid: View {
    @Environment(SimmerModel.self) private var model

    var body: some View {
        let snapshot = model.snapshot
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                TelemetryTile(
                    title: "Adapter", systemImage: "powerplug.fill",
                    value: adapterValue(snapshot), detail: adapterDetail(snapshot)
                )
                TelemetryTile(
                    title: "Battery", systemImage: "bolt.fill",
                    value: snapshot.map { Format.signedWatts($0.batteryWatts) },
                    detail: snapshot.map(batteryDetail)
                )
            }
            GridRow {
                TelemetryTile(
                    title: "Temperature", systemImage: "thermometer.medium",
                    value: snapshot?.temperatureC.map {
                        Format.temperature(celsius: $0, unit: model.settings.temperatureUnit)
                    }
                )
                TelemetryTile(
                    title: "Health", systemImage: "heart.fill",
                    value: snapshot?.healthPercent.map(Format.percent)
                )
            }
            GridRow {
                TelemetryTile(
                    title: "Cycles", systemImage: "arrow.triangle.2.circlepath",
                    value: snapshot.map { "\($0.cycleCount)" }
                )
                TelemetryTile(
                    title: "Voltage", systemImage: "waveform.path.ecg",
                    value: snapshot.map { Format.volts($0.voltage) }
                )
            }
        }
        .animation(.snappy(duration: 0.3), value: snapshot)
    }

    private func adapterValue(_ snapshot: BatterySnapshot?) -> String? {
        snapshot?.systemPowerIn.map { Format.watts($0) }
    }

    private func adapterDetail(_ snapshot: BatterySnapshot?) -> String? {
        guard let snapshot else { return nil }
        guard snapshot.isPluggedIn else { return "Not connected" }
        return snapshot.adapterWatts.map { "\(Format.watts($0, fractionDigits: 0)) rated" }
    }

    private func batteryDetail(_ snapshot: BatterySnapshot) -> String {
        let watts = snapshot.batteryWatts
        if watts >= 0.05 { return "Charging" }
        if watts <= -0.05 { return "Draining" }
        return "Idle"
    }
}

private struct TelemetryTile: View {
    var title: String
    var systemImage: String
    var value: String?
    var detail: String?

    var body: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 3) {
                CardTitle(title: title, systemImage: systemImage)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value ?? Format.placeholder)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText())
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value ?? "Not available", detail].compactMap(\.self).joined(separator: ", "))
    }
}
