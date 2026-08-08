import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @EnvironmentObject var engine: MonitorEngine

    private let sudoersCommand = "sudo visudo -f /etc/sudoers.d/powermetrics"
    // Grants two things: running powermetrics itself, and killing it again
    // by PID with SIGINT or SIGKILL. Both are needed — the app can't
    // terminate a root-owned process it isn't root itself, and relying on
    // `sudo` to relay a signal to the child it launched turned out to be
    // unreliable (confirmed via `ps`: repeated restarts leaked a new
    // root-owned powermetrics process every time). The kill grants are
    // scoped to exactly `kill -INT <pid>` / `kill -9 <pid>` — not a general
    // "run anything as root" permission.
    private var sudoersLine: String {
        "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/powermetrics, /bin/kill -INT [0-9]*, /bin/kill -9 [0-9]*"
    }

    var body: some View {
        Form {
            Section("Refresh Rate") {
                Picker("Sample every", selection: $settings.refreshIntervalSeconds) {
                    ForEach(refreshIntervalPresets, id: \.seconds) { preset in
                        Text(preset.label).tag(preset.seconds)
                    }
                }
                .pickerStyle(.segmented)
                caption("How often the app takes a new reading. This is separate from the \"Show last\" controls elsewhere in the app, which just control how much of the already-collected history you're currently looking at. Note: at the fastest \"1s\" setting, the process list can lag a tick behind the CPU/Memory numbers — it needs a short window of its own to measure accurate per-process CPU%.")
            }

            Section("Units") {
                Picker("Temperature unit", selection: $settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.symbol).tag(unit)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Temperature source", selection: $settings.temperatureSource) {
                    ForEach(TemperatureSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                caption("Which sensor to show/alert on throughout the app. \"Highest of Both\" shows whichever of CPU/GPU is currently hotter.")
            }

            Section("Menu Bar") {
                Picker("Show in menu bar", selection: $settings.menuBarMetric) {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Enable threshold notifications", isOn: $settings.notificationsEnabled)

                VStack(alignment: .leading) {
                    HStack {
                        Text("CPU alert above")
                        Spacer()
                        Text("\(Int(settings.cpuThresholdPercent))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.cpuThresholdPercent, in: 10...100, step: 5)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("GPU alert above")
                        Spacer()
                        Text("\(Int(settings.gpuThresholdPercent))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.gpuThresholdPercent, in: 10...100, step: 5)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Temperature alert above")
                        Spacer()
                        let display = settings.celsiusToDisplay(settings.tempThresholdCelsius)
                        Text("\(Int(display))\(settings.temperatureUnit.symbol)")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { settings.celsiusToDisplay(settings.tempThresholdCelsius) },
                        set: { settings.tempThresholdCelsius = settings.displayToCelsius($0) }
                    ), in: (settings.temperatureUnit == .celsius ? 40...110 : 104...230), step: 1)
                }
            }
            .disabled(!settings.notificationsEnabled)

            Section("GPU % Setup") {
                HStack {
                    statusDot(engine.gpuAvailable)
                    Text(engine.gpuAvailable ? "GPU monitoring is active" : "GPU monitoring is not active yet")
                        .font(.callout)
                }
                caption("GPU % comes from Apple's powermetrics tool, which requires admin access to run — and, separately, to stop again. To avoid a password prompt every couple seconds (and to let the app clean up after itself instead of leaking background processes), allow both passwordlessly, just for your user:")

                HStack {
                    Text(sudoersCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    Button("Copy") { copyToPasteboard(sudoersCommand) }
                }
                caption("1. Copy that command and run it in Terminal — it opens an editor.")

                HStack {
                    Text(sudoersLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    Button("Copy") { copyToPasteboard(sudoersLine) }
                }
                caption("2. Copy that line into the editor — it already has your actual Mac username filled in.\n3. Save and quit (in the default nano editor, that's Control-X, then Y, then Return).\n4. Quit and reopen this app. The GPU card should now show real numbers.\n\nAlready set this up before this version? The old line only covered running powermetrics, not stopping it — re-run the steps above with the updated line to replace it, or background powermetrics processes will pile up over time.")
            }

            Section("Temperature") {
                HStack {
                    statusDot(engine.tempAvailable)
                    Text(engine.tempAvailable ? "Temperature monitoring is active" : "Not available on this Mac")
                        .font(.callout)
                }
                caption("Powered by the swift-soc-metrics library, which reads real CPU/GPU die temperature on Apple Silicon automatically — no setup or sensor picking needed. If it shows unavailable, this is either an Intel Mac (not supported) or a chip generation the library hasn't been validated against yet.")
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func statusDot(_ ok: Bool) -> some View {
        Circle()
            .fill(ok ? .green : .orange)
            .frame(width: 8, height: 8)
    }
}
