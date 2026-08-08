import Foundation
import Combine
import ServiceManagement

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }
}

enum TemperatureSource: String, CaseIterable, Identifiable {
    case cpu, gpu, highest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .highest: return "Highest of Both"
        }
    }
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, temperature
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cpu: return "CPU %"
        case .gpu: return "GPU %"
        case .memory: return "Memory %"
        case .temperature: return "Temperature"
        }
    }
}

/// UserDefaults-backed settings, published so SwiftUI views update live.
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Keys.tempUnit) }
    }
    @Published var menuBarMetric: MenuBarMetric {
        didSet { defaults.set(menuBarMetric.rawValue, forKey: Keys.menuBarMetric) }
    }

    @Published var temperatureSource: TemperatureSource {
        didSet { defaults.set(temperatureSource.rawValue, forKey: Keys.temperatureSource) }
    }

    @Published var liveViewMode: ProcessViewMode {
        didSet { defaults.set(liveViewMode.rawValue, forKey: Keys.liveViewMode) }
    }
    @Published var historyViewMode: ProcessViewMode {
        didSet { defaults.set(historyViewMode.rawValue, forKey: Keys.historyViewMode) }
    }

    @Published var chartLookback: TimeWindow {
        didSet { defaults.set(chartLookback.rawValue, forKey: Keys.chartLookback) }
    }
    @Published var chartStyle: ChartStyle {
        didSet { defaults.set(chartStyle.rawValue, forKey: Keys.chartStyle) }
    }
    @Published var historyTableWindow: TimeWindow {
        didSet { defaults.set(historyTableWindow.rawValue, forKey: Keys.historyTableWindow) }
    }

    /// Seconds between samples. Anywhere from 1s (near-live) to 300s (5 min, light on
    /// battery/CPU for long unattended monitoring).
    @Published var refreshIntervalSeconds: Double {
        didSet { defaults.set(refreshIntervalSeconds, forKey: Keys.refreshInterval) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    // Thresholds stored in their "natural" unit: percent for cpu/gpu, Celsius for temp
    // (converted for display only).
    @Published var cpuThresholdPercent: Double {
        didSet { defaults.set(cpuThresholdPercent, forKey: Keys.cpuThreshold) }
    }
    @Published var gpuThresholdPercent: Double {
        didSet { defaults.set(gpuThresholdPercent, forKey: Keys.gpuThreshold) }
    }
    @Published var tempThresholdCelsius: Double {
        didSet { defaults.set(tempThresholdCelsius, forKey: Keys.tempThreshold) }
    }

    // Which discovered SMC sensor key(s) represent CPU / GPU on this specific Mac.
    // NOTE: removed — temperature is now read via the SoCMetrics package,
    // which identifies CPU/GPU sensors on its own. No manual picking needed.


    private enum Keys {
        static let tempUnit = "settings.tempUnit"
        static let menuBarMetric = "settings.menuBarMetric"
        static let temperatureSource = "settings.temperatureSource"
        static let liveViewMode = "settings.liveViewMode"
        static let historyViewMode = "settings.historyViewMode"
        static let chartLookback = "settings.chartLookback"
        static let chartStyle = "settings.chartStyle"
        static let historyTableWindow = "settings.historyTableWindow"
        static let refreshInterval = "settings.refreshInterval"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let cpuThreshold = "settings.cpuThreshold"
        static let gpuThreshold = "settings.gpuThreshold"
        static let tempThreshold = "settings.tempThreshold"
    }

    private init() {
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: Keys.tempUnit) ?? "") ?? .celsius
        menuBarMetric = MenuBarMetric(rawValue: defaults.string(forKey: Keys.menuBarMetric) ?? "") ?? .cpu
        temperatureSource = TemperatureSource(rawValue: defaults.string(forKey: Keys.temperatureSource) ?? "") ?? .highest
        liveViewMode = ProcessViewMode(rawValue: defaults.string(forKey: Keys.liveViewMode) ?? "") ?? .table
        historyViewMode = ProcessViewMode(rawValue: defaults.string(forKey: Keys.historyViewMode) ?? "") ?? .table
        chartLookback = TimeWindow(rawValue: defaults.string(forKey: Keys.chartLookback) ?? "") ?? .fifteenMinutes
        chartStyle = ChartStyle(rawValue: defaults.string(forKey: Keys.chartStyle) ?? "") ?? .line
        historyTableWindow = TimeWindow(rawValue: defaults.string(forKey: Keys.historyTableWindow) ?? "") ?? .oneHour
        let storedInterval = defaults.object(forKey: Keys.refreshInterval) as? Double ?? 2.0
        refreshIntervalSeconds = storedInterval.clamped(to: 1...300)
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        cpuThresholdPercent = defaults.object(forKey: Keys.cpuThreshold) as? Double ?? 90
        gpuThresholdPercent = defaults.object(forKey: Keys.gpuThreshold) as? Double ?? 90
        tempThresholdCelsius = defaults.object(forKey: Keys.tempThreshold) as? Double ?? 90
    }

    func celsiusToDisplay(_ celsius: Double) -> Double {
        temperatureUnit == .celsius ? celsius : (celsius * 9 / 5 + 32)
    }

    func displayToCelsius(_ display: Double) -> Double {
        temperatureUnit == .celsius ? display : (display - 32) * 5 / 9
    }

    /// Resolves which temperature to show, respecting the user's chosen source.
    func selectedTemperatureC(from snapshot: SystemSnapshot) -> Double? {
        switch temperatureSource {
        case .cpu: return snapshot.cpuTempC
        case .gpu: return snapshot.gpuTempC
        case .highest: return [snapshot.cpuTempC, snapshot.gpuTempC].compactMap { $0 }.max()
        }
    }

    /// Not @Published since the real source of truth is macOS itself — the
    /// person could also toggle this from System Settings → General → Login
    /// Items directly, so we ask SMAppService rather than trusting a locally
    /// cached bool that could drift out of sync.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("SettingsStore: failed to update launch-at-login: \(error)")
            }
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// (label, seconds) pairs for the refresh-rate picker in Settings.
let refreshIntervalPresets: [(label: String, seconds: Double)] = [
    ("1s", 1), ("2s", 2), ("5s", 5), ("10s", 10),
    ("30s", 30), ("1m", 60), ("5m", 300)
]
