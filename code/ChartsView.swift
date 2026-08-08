import SwiftUI
import Charts

enum ChartStyle: String, CaseIterable, Identifiable {
    case line = "Line"
    case bar = "Bar"
    case area = "Area"
    var id: String { rawValue }
}

struct ChartsView: View {
    @EnvironmentObject var engine: MonitorEngine
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History Graphs")
                    .font(.title3.bold())
                Spacer()
                Picker("Chart type", selection: $settings.chartStyle) {
                    ForEach(ChartStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            TimeWindowPicker(selection: $settings.chartLookback)
            Text("Hover any chart to see the exact value and time at that point.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            let points = engine.history.systemHistory(window: settings.chartLookback.seconds)

            HStack(alignment: .top, spacing: 12) {
                HoverableMetricChart(title: "CPU %", points: points, color: .blue, style: settings.chartStyle) { $0.cpuUsagePercent }
                HoverableMetricChart(title: "Memory %", points: points, color: .green, style: settings.chartStyle) { $0.memUsedPercent }
                if engine.gpuAvailable {
                    HoverableMetricChart(title: "GPU %", points: points, color: .purple, style: settings.chartStyle) { $0.gpuActivePercent }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct HoverableMetricChart: View {
    let title: String
    let points: [SystemSnapshot]
    let color: Color
    let style: ChartStyle
    // Optional so a genuinely-missing reading (e.g. GPU % before powermetrics
    // has reported anything yet) can be told apart from an actual 0.
    let valueForPoint: (SystemSnapshot) -> Double?

    @State private var hoverPoint: SystemSnapshot?

    // The chart itself still needs a concrete number per point to plot;
    // missing values are drawn as 0 so the line/bar/area stays continuous.
    private func plotValue(_ point: SystemSnapshot) -> Double {
        valueForPoint(point) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let hoverPoint {
                    if let value = valueForPoint(hoverPoint) {
                        Text("\(Int(value))%  ·  \(hoverPoint.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(color)
                    } else {
                        Text("No data  ·  \(hoverPoint.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Chart {
                ForEach(points) { point in
                    switch style {
                    case .line:
                        LineMark(x: .value("Time", point.timestamp), y: .value(title, plotValue(point)))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                    case .bar:
                        BarMark(x: .value("Time", point.timestamp), y: .value(title, plotValue(point)))
                            .foregroundStyle(color)
                    case .area:
                        AreaMark(x: .value("Time", point.timestamp), y: .value(title, plotValue(point)))
                            .foregroundStyle(color.opacity(0.5))
                            .interpolationMethod(.monotone)
                    }
                }

                if let hoverPoint {
                    RuleMark(x: .value("Time", hoverPoint.timestamp))
                        .foregroundStyle(.secondary.opacity(0.4))
                    PointMark(x: .value("Time", hoverPoint.timestamp), y: .value(title, plotValue(hoverPoint)))
                        .foregroundStyle(color)
                        .symbolSize(70)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))%")
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(height: 80)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else { return }
                                let origin = geo[plotFrame].origin
                                let xPos = location.x - origin.x
                                guard let date: Date = proxy.value(atX: xPos) else { return }
                                hoverPoint = points.min(by: {
                                    abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
                                })
                            case .ended:
                                hoverPoint = nil
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

enum TimeWindow: String, CaseIterable, Equatable {
    case fiveMinutes = "5m", fifteenMinutes = "15m", oneHour = "1h", threeHours = "3h"

    var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 3600
        case .threeHours: return 3 * 3600
        }
    }

    var label: String {
        switch self {
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        case .oneHour: return "1 hour"
        case .threeHours: return "3 hours"
        }
    }
}

struct TimeWindowPicker: View {
    @Binding var selection: TimeWindow
    var label: String = "Show last"

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(TimeWindow.allCases, id: \.self) { window in
                Text(window.label).tag(window)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
    }
}
