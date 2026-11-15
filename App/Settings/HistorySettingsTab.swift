import Charts
import SimmerCore
import SwiftUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case sixHours, day, week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sixHours: "6 hours"
        case .day: "24 hours"
        case .week: "7 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .sixHours: 6 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        }
    }
}

/// A sample plus the unbroken stretch it belongs to, so lines do not bridge the hours
/// the Mac was asleep or off.
struct HistoryPoint: Identifiable {
    var sample: HistorySample
    var segment: Int

    var id: Date { sample.date }
}

enum HistorySeries {
    /// Thins the samples for drawing and splits them at gaps.
    static func points(from samples: [HistorySample], sampleInterval: TimeInterval, maxPoints: Int = 360) -> [HistoryPoint] {
        let thinned = samples.downsampled(maxPoints: maxPoints)
        guard let first = thinned.first, let last = thinned.last else { return [] }
        let spacing = thinned.count > 1
            ? last.date.timeIntervalSince(first.date) / Double(thinned.count - 1)
            : sampleInterval
        let gap = max(sampleInterval, spacing) * 4
        var segment = 0
        var previous = first.date
        return thinned.map { sample in
            if sample.date.timeIntervalSince(previous) > gap { segment += 1 }
            previous = sample.date
            return HistoryPoint(sample: sample, segment: segment)
        }
    }
}

struct HistorySettingsTab: View {
    @Environment(SimmerModel.self) private var model
    @State private var range = HistoryRange.day
    @State private var selection: Date?
    @State private var isConfirmingClear = false

    var body: some View {
        // Reading the revision makes the charts reload when a sample is added.
        let _ = model.historyRevision
        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        let points = HistorySeries.points(
            from: model.history.samples(since: start), sampleInterval: model.history.sampleInterval
        )
        let selected = selection.flatMap { nearest(to: $0, in: points) }

        Form {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if points.count < 2 {
                    ContentUnavailableView(
                        "Collecting data",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Simmer records one sample per minute while it runs. The charts appear after a few minutes.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    Readout(point: selected ?? points.last, isLive: selected == nil, unit: model.settings.temperatureUnit)
                }
            }

            if points.count >= 2 {
                Section("Charge") {
                    ChargeChart(points: points, selected: selected, domain: start...end, selection: $selection)
                }
                Section("Battery power") {
                    PowerChart(points: points, selected: selected, domain: start...end, selection: $selection)
                }
                Section("Temperature") {
                    TemperatureChart(
                        points: points, selected: selected, domain: start...end, selection: $selection,
                        unit: model.settings.temperatureUnit,
                        threshold: model.settings.engine.heatProtectionEnabled ? model.settings.engine.heatThresholdC : nil
                    )
                }
            }

            Section {
                HStack {
                    SettingsNote("History is kept for 7 days and stays on this Mac.")
                    Spacer()
                    Button("Clear History…", role: .destructive) { isConfirmingClear = true }
                        .disabled(points.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear the battery history?", isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) {
                model.history.removeAll()
                selection = nil
            }
        } message: {
            Text("This removes all recorded samples. It cannot be undone.")
        }
    }

    private func nearest(to date: Date, in points: [HistoryPoint]) -> HistoryPoint? {
        points.min { abs($0.sample.date.timeIntervalSince(date)) < abs($1.sample.date.timeIntervalSince(date)) }
    }
}

// MARK: - Readout

/// The values under the pointer, or the latest sample when nothing is hovered.
private struct Readout: View {
    var point: HistoryPoint?
    var isLive: Bool
    var unit: TemperatureUnit

    var body: some View {
        if let sample = point?.sample {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(isLive ? "Latest" : sample.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .foregroundStyle(.secondary)
                Spacer()
                value(Format.percent(sample.percent), label: "Charge")
                value(Format.signedWatts(sample.batteryWatts), label: "Power")
                value(sample.temperatureC.map { Format.temperature(celsius: $0, unit: unit) } ?? Format.placeholder, label: "Temp.")
            }
            .font(.callout)
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        }
    }

    private func value(_ text: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(text).fontWeight(.medium)
        }
    }
}

// MARK: - Charts

private struct ChargeChart: View {
    var points: [HistoryPoint]
    var selected: HistoryPoint?
    var domain: ClosedRange<Date>
    @Binding var selection: Date?

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.sample.date),
                    y: .value("Charge", point.sample.percent),
                    series: .value("Stretch", "charge-\(point.segment)")
                )
                .foregroundStyle(by: .value("Series", "Charge"))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(points.filter { $0.sample.limit != nil }) { point in
                LineMark(
                    x: .value("Time", point.sample.date),
                    y: .value("Limit", point.sample.limit ?? 0),
                    series: .value("Stretch", "limit-\(point.segment)")
                )
                .foregroundStyle(by: .value("Series", "Limit"))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .interpolationMethod(.stepEnd)
            }
            if let selected {
                SelectionRule(date: selected.sample.date)
                PointMark(x: .value("Time", selected.sample.date), y: .value("Charge", selected.sample.percent))
                    .foregroundStyle(Color.green)
                    .symbolSize(50)
            }
        }
        .chartForegroundStyleScale(["Charge": Color.green, "Limit": Color.secondary])
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent) %") } }
            }
        }
        .historyChart(domain: domain, selection: $selection, height: 130)
        .accessibilityLabel("Charge level and charge limit over time")
    }
}

private struct PowerChart: View {
    var points: [HistoryPoint]
    var selected: HistoryPoint?
    var domain: ClosedRange<Date>
    @Binding var selection: Date?

    var body: some View {
        Chart {
            RuleMark(y: .value("Idle", 0))
                .foregroundStyle(.tertiary)
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.sample.date),
                    y: .value("Power", point.sample.batteryWatts),
                    series: .value("Stretch", point.segment)
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let selected {
                SelectionRule(date: selected.sample.date)
                PointMark(x: .value("Time", selected.sample.date), y: .value("Power", selected.sample.batteryWatts))
                    .foregroundStyle(Color.blue)
                    .symbolSize(50)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let watts = value.as(Double.self) { Text("\(Int(watts)) W") } }
            }
        }
        .historyChart(domain: domain, selection: $selection, height: 92)
        .accessibilityLabel("Battery power over time; above zero is charging, below zero is discharging")

        SettingsNote("Above zero the battery is charging, below zero it is supplying the Mac.")
    }
}

private struct TemperatureChart: View {
    var points: [HistoryPoint]
    var selected: HistoryPoint?
    var domain: ClosedRange<Date>
    @Binding var selection: Date?
    var unit: TemperatureUnit
    var threshold: Double?

    var body: some View {
        let measured = points.filter { $0.sample.temperatureC != nil }
        Chart {
            if let threshold {
                RuleMark(y: .value("Heat protection", display(threshold)))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Heat protection").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            ForEach(measured) { point in
                LineMark(
                    x: .value("Time", point.sample.date),
                    y: .value("Temperature", display(point.sample.temperatureC ?? 0)),
                    series: .value("Stretch", point.segment)
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let selected, let celsius = selected.sample.temperatureC {
                SelectionRule(date: selected.sample.date)
                PointMark(x: .value("Time", selected.sample.date), y: .value("Temperature", display(celsius)))
                    .foregroundStyle(Color.orange)
                    .symbolSize(50)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let degrees = value.as(Double.self) { Text("\(Int(degrees)) \(unit == .celsius ? "°C" : "°F")") }
                }
            }
        }
        .historyChart(domain: domain, selection: $selection, height: 92)
        .accessibilityLabel("Battery temperature over time")
    }

    private func display(_ celsius: Double) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5 + 32
    }
}

private struct SelectionRule: ChartContent {
    var date: Date

    var body: some ChartContent {
        RuleMark(x: .value("Selected", date))
            .foregroundStyle(.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }
}

private extension View {
    /// Shared time axis, hover selection and size for the three stacked charts.
    func historyChart(domain: ClosedRange<Date>, selection: Binding<Date?>, height: CGFloat) -> some View {
        self
            .chartXScale(domain: domain)
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: domain.upperBound.timeIntervalSince(domain.lowerBound) > 36 * 3600
                        ? .dateTime.weekday(.abbreviated)
                        : .dateTime.hour().minute())
                }
            }
            .chartXSelection(value: selection)
            .frame(height: height)
            .padding(.vertical, 4)
    }
}
