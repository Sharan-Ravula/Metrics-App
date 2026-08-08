import SwiftUI
import AppKit

struct DashboardView: View {
    @EnvironmentObject var engine: MonitorEngine
    @ObservedObject var settings = SettingsStore.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if let timestamp = engine.current?.timestamp {
                        Text("Updated \(timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                summaryTiles
                ChartsView()
                ProcessListView()
            }
            .padding(16)
        }
        .navigationTitle("Performance Monitor")
        .onAppear {
            DispatchQueue.main.async {
                // Match by title, not just visibility — the Settings window
                // is a separate Scene that can also be visible/enumerated
                // here, and only one window can hold a given autosave name.
                NSApp.windows.first(where: { $0.title == "Performance Monitor" })?
                    .setFrameAutosaveName("PerfMonitorMainWindow")
            }
        }
    }

    private var summaryTiles: some View {
        HStack(spacing: 0) {
            MetricItem(
                icon: "cpu",
                title: "CPU",
                valueText: engine.current.map { "\(Int($0.cpuUsagePercent))%" },
                color: engine.current.map { Severity.color(forPercent: $0.cpuUsagePercent) } ?? .secondary,
                fallbackText: nil
            )
            Spacer()
            MetricItem(
                icon: "memorychip",
                title: "Memory",
                valueText: engine.current.map { "\(Int($0.memUsedPercent))%" },
                color: engine.current.map { Severity.color(forPercent: $0.memUsedPercent) } ?? .secondary,
                fallbackText: nil
            )
            Spacer()
            MetricItem(
                icon: "display",
                title: "GPU",
                valueText: engine.gpuAvailable ? engine.current?.gpuActivePercent.map { "\(Int($0))%" } ?? nil : nil,
                color: engine.current?.gpuActivePercent.map { Severity.color(forPercent: $0) } ?? .secondary,
                fallbackText: engine.gpuAvailable ? nil : "not set up"
            )
            Spacer()
            MetricItem(
                icon: "cpu.fill",
                title: "CPU Temp",
                valueText: engine.current?.cpuTempC.map { "\(Int(settings.celsiusToDisplay($0)))\(settings.temperatureUnit.symbol)" },
                color: engine.current?.cpuTempC.map { Severity.color(forCelsius: $0) } ?? .secondary,
                fallbackText: engine.current?.cpuTempC == nil ? "N/A" : nil
            )
            Spacer()
            MetricItem(
                icon: "display",
                title: "GPU Temp",
                valueText: engine.current?.gpuTempC.map { "\(Int(settings.celsiusToDisplay($0)))\(settings.temperatureUnit.symbol)" },
                color: engine.current?.gpuTempC.map { Severity.color(forCelsius: $0) } ?? .secondary,
                fallbackText: engine.current?.gpuTempC == nil ? "N/A" : nil,
                badge: engine.current?.thermalPressure,
                badgeColor: Severity.color(forThermalPressure: engine.current?.thermalPressure)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct MetricItem: View {
    let icon: String
    let title: String
    let valueText: String?
    let color: Color
    let fallbackText: String?
    var badge: String? = nil
    var badgeColor: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let valueText {
                    Text(valueText)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(color)
                } else {
                    Text(fallbackText ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15), in: Capsule())
            }
        }
        .fixedSize()
    }
}
