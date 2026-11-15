import Charts
import SimmerCore
import SwiftUI

/// Long-term battery condition: capacity and cycle count, one record per day.
struct HealthSettingsTab: View {
    @Environment(SimmerModel.self) private var model
    @State private var selection: Date?

    var body: some View {
        let _ = model.healthRevision
        let records = model.health.allRecords()
        let latest = records.last
        let selected = selection.flatMap { date in
            records.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
        }

        Form {
            Section("Now") {
                if let latest {
                    LabeledContent("Health", value: percent(latest.healthPercent))
                    LabeledContent("Full charge capacity") {
                        Text("\(latest.maxCapacity) mAh of \(latest.designCapacity) mAh design").monospacedDigit()
                    }
                    LabeledContent("Cycles") { Text("\(latest.cycleCount)").monospacedDigit() }
                } else {
                    SettingsNote("No battery data yet.")
                }
            }

            Section("Trend") {
                if records.count < 2 {
                    ContentUnavailableView(
                        "Tracking started",
                        systemImage: "heart.text.square",
                        description: Text("Simmer stores one record per day. The trend appears once there are a few days of data.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    if let shown = selected ?? latest {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(selected == nil ? "Latest" : shown.day.formatted(.dateTime.day().month().year()))
                                .foregroundStyle(.secondary)
                            Spacer()
                            readout(percent(shown.healthPercent), label: "Health")
                            readout("\(shown.cycleCount)", label: "Cycles")
                        }
                        .font(.callout)
                        .monospacedDigit()
                        .accessibilityElement(children: .combine)
                    }

                    Chart {
                        ForEach(records) { record in
                            LineMark(x: .value("Day", record.day), y: .value("Health", record.healthPercent))
                                .foregroundStyle(Color.green)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                        if let selected {
                            RuleMark(x: .value("Selected", selected.day))
                                .foregroundStyle(.secondary)
                                .lineStyle(StrokeStyle(lineWidth: 1))
                            PointMark(x: .value("Day", selected.day), y: .value("Health", selected.healthPercent))
                                .foregroundStyle(Color.green)
                                .symbolSize(50)
                        }
                    }
                    .chartYScale(domain: healthDomain(records))
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(.quaternary)
                            AxisValueLabel { if let health = value.as(Double.self) { Text("\(Int(health)) %") } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { _ in
                            AxisGridLine().foregroundStyle(.quaternary)
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        }
                    }
                    .chartXSelection(value: $selection)
                    .frame(height: 150)
                    .padding(.vertical, 4)
                    .accessibilityLabel("Battery health over time")

                    if let trend = model.health.trend {
                        LabeledContent("Since tracking began") {
                            Text("\(signed(trend.healthChange)) over \(trend.days) day\(trend.days == 1 ? "" : "s")")
                                .monospacedDigit()
                        }
                        LabeledContent("Cycles added") { Text("\(trend.cyclesAdded)").monospacedDigit() }
                        if let perWeek = trend.cyclesPerWeek {
                            LabeledContent("Cycles per week") {
                                Text(perWeek.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
                            }
                        }
                        if let wear = trend.wearPer100Cycles {
                            LabeledContent("Wear per 100 cycles") {
                                Text("\(wear.formatted(.number.precision(.fractionLength(1))))\u{00A0}points").monospacedDigit()
                            }
                        }
                    }
                }
            }

            Section {
                SettingsNote("Health is full charge capacity relative to design capacity, as the battery reports it. The estimate moves by a percent or so from day to day, so judge the trend over weeks, not days.")
            }
        }
        .formStyle(.grouped)
    }

    /// A readable window around the data: at least five points tall, never below zero.
    private func healthDomain(_ records: [HealthRecord]) -> ClosedRange<Double> {
        let values = records.map(\.healthPercent)
        let low = (values.min() ?? 95).rounded(.down)
        let high = (values.max() ?? 100).rounded(.up)
        return max(0, min(low - 1, high - 5))...max(high + 1, 100)
    }

    private func readout(_ text: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(text).fontWeight(.medium)
        }
    }

    private func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))\u{00A0}%"
    }

    private func signed(_ value: Double) -> String {
        let text = abs(value).formatted(.number.precision(.fractionLength(1)))
        let sign = value > 0.05 ? "+" : value < -0.05 ? "\u{2212}" : ""
        return "\(sign)\(text)\u{00A0}points"
    }
}
