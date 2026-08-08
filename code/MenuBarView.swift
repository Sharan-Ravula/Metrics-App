import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @EnvironmentObject var engine: MonitorEngine
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Text(labelText)
            .onAppear { engine.start() }
    }

    private var labelText: String {
        guard let snap = engine.current else { return "…" }
        switch settings.menuBarMetric {
        case .cpu:
            return "CPU \(Int(snap.cpuUsagePercent))%"
        case .gpu:
            guard let gpu = snap.gpuActivePercent else { return "GPU —" }
            return "GPU \(Int(gpu))%"
        case .memory:
            return "MEM \(Int(snap.memUsedPercent))%"
        case .temperature:
            let hottest = settings.selectedTemperatureC(from: snap)
            guard let hottest else { return "TEMP —" }
            let display = settings.celsiusToDisplay(hottest)
            return "\(Int(display))\(settings.temperatureUnit.symbol)"
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject var engine: MonitorEngine
    @ObservedObject var settings = SettingsStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snap = engine.current {
                metricRow("CPU", "\(Int(snap.cpuUsagePercent))%", color: Severity.color(forPercent: snap.cpuUsagePercent))
                metricRow("Memory", "\(Int(snap.memUsedPercent))%", color: Severity.color(forPercent: snap.memUsedPercent))
                if let gpu = snap.gpuActivePercent {
                    metricRow("GPU", "\(Int(gpu))%", color: Severity.color(forPercent: gpu))
                }
                if let temp = settings.selectedTemperatureC(from: snap) {
                    metricRow("Temp", "\(Int(settings.celsiusToDisplay(temp)))\(settings.temperatureUnit.symbol)",
                               color: Severity.color(forCelsius: temp))
                }
                if let pressure = snap.thermalPressure {
                    metricRow("Thermal", pressure, color: Severity.color(forThermalPressure: pressure))
                }
            } else {
                Text("Loading…")
            }

            Divider()

            if let top = engine.topProcesses.first {
                Text("Top: \(top.name) (\(String(format: "%.0f", top.cpuPercent))% CPU)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Open Dashboard") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            SettingsLink()
            Button("Quit PerfMonitor") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private func metricRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(color)
        }
        .font(.system(size: 13))
    }
}
