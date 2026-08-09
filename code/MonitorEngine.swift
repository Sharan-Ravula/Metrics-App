import Foundation
import Combine

@MainActor
final class MonitorEngine: ObservableObject {

    @Published var current: SystemSnapshot?
    @Published var topProcesses: [ProcessSnapshot] = []
    @Published var gpuAvailable = false
    @Published var tempAvailable = false

    let history = HistoryStore()
    let settings = SettingsStore.shared

    private let systemSampler = SystemMetricsSampler()
    private let processSampler = ProcessSampler()
    private var powerSampler: PowerMetricsSampler?
    private var socReader: SoCTemperatureReader?

    private var timer: Timer?
    private var latestGPUReading: PowerMetricsSampler.Reading?
    private var latestCPUTempC: Double?
    private var latestGPUTempC: Double?
    private var latestPowerWatts: Double?
    private var cancellables = Set<AnyCancellable>()

    private var started = false
    private var processSamplingInFlight = false

    func start() {
        guard !started else { return }
        started = true
        _ = systemSampler.sampleCPU()

        NotificationManager.shared.requestAuthorization()

        socReader = SoCTemperatureReader()
        socReader?.start()
        tempAvailable = socReader?.isAvailable ?? false

        settings.$refreshIntervalSeconds
            .dropFirst()
            .removeDuplicates()
            .sink { interval in
                Task { @MainActor [weak self] in
                    self?.restartSampling(intervalSeconds: interval)
                }
            }
            .store(in: &cancellables)

        restartSampling(intervalSeconds: settings.refreshIntervalSeconds)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        powerSampler?.stop()
        socReader?.stop()
    }

    private func restartSampling(intervalSeconds: Double) {
        timer?.invalidate()
        powerSampler?.stop()

        let powerIntervalMs = max(1000, Int(intervalSeconds * 1000))
        powerSampler = PowerMetricsSampler(intervalMs: powerIntervalMs) { [weak self] reading in
            self?.latestGPUReading = reading
            self?.gpuAvailable = reading.gpuActivePercent != nil
        }
        powerSampler?.start()

        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        tick()
    }

    private func tick() {
        let cpu = systemSampler.sampleCPU()
        let mem = systemSampler.sampleMemory()

        let snapshot = SystemSnapshot(
            timestamp: Date(),
            cpuUsagePercent: cpu,
            memUsedPercent: mem.percent,
            memUsedBytes: mem.used,
            memTotalBytes: mem.total,
            gpuActivePercent: latestGPUReading?.gpuActivePercent,
            thermalPressure: latestGPUReading?.thermalPressure,
            cpuTempC: latestCPUTempC,
            gpuTempC: latestGPUTempC,
            packagePowerWatts: latestPowerWatts
        )

        current = snapshot
        checkThresholds(snapshot)

        guard !processSamplingInFlight else { return }
        processSamplingInFlight = true

        let sampler = processSampler
        let soc = socReader
        // .utility, not .userInitiated: this is routine recurring background
        // polling (top/ps + sensor reads), not user-blocking work. The higher
        // priority was biasing the scheduler toward performance cores for no
        // benefit, since nothing is waiting on this synchronously.
        Task.detached(priority: .utility) {
            let processes = sampler.sampleTopProcesses(limit: 15)
            let tempReading = soc?.sampleOnce()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.processSamplingInFlight = false
                if let tempReading {
                    self.latestCPUTempC = tempReading.cpuTempC
                    self.latestGPUTempC = tempReading.gpuTempC
                    self.latestPowerWatts = tempReading.packagePowerWatts
                }
                self.topProcesses = processes
                self.history.record(system: snapshot, processes: processes,
                                     sampleIntervalSeconds: self.settings.refreshIntervalSeconds)
            }
        }
    }

    private func checkThresholds(_ snapshot: SystemSnapshot) {
        guard settings.notificationsEnabled else { return }
        let mgr = NotificationManager.shared

        let topOffender = topProcesses.max(by: { $0.cpuPercent < $1.cpuPercent })

        evaluateThreshold(value: snapshot.cpuUsagePercent, limit: settings.cpuThresholdPercent) {
            let suffix = topOffender.map { " Top consumer: \($0.name)." } ?? ""
            mgr.notifyIfNeeded(metricKey: "cpu", title: "High CPU usage",
                                body: "CPU is at \(Int(snapshot.cpuUsagePercent))%, above your \(Int(settings.cpuThresholdPercent))% threshold.\(suffix)",
                                offendingPID: topOffender?.pid)
        } onBelow: {
            mgr.resetCooldown(metricKey: "cpu")
        }

        if let gpu = snapshot.gpuActivePercent {
            evaluateThreshold(value: gpu, limit: settings.gpuThresholdPercent) {
                let suffix = topOffender.map { " Possible cause (top CPU consumer): \($0.name)." } ?? ""
                mgr.notifyIfNeeded(metricKey: "gpu", title: "High GPU usage",
                                    body: "GPU is at \(Int(gpu))%, above your \(Int(settings.gpuThresholdPercent))% threshold.\(suffix)",
                                    offendingPID: topOffender?.pid)
            } onBelow: {
                mgr.resetCooldown(metricKey: "gpu")
            }
        }

        let hottest = settings.selectedTemperatureC(from: snapshot)
        if let hottest {
            let settings = self.settings
            evaluateThreshold(value: hottest, limit: settings.tempThresholdCelsius) {
                let display = settings.celsiusToDisplay(hottest)
                let limitDisplay = settings.celsiusToDisplay(settings.tempThresholdCelsius)
                let suffix = topOffender.map { " Possible cause (top CPU consumer): \($0.name)." } ?? ""
                mgr.notifyIfNeeded(metricKey: "temp", title: "High temperature",
                                    body: "Temperature reached \(Int(display))\(settings.temperatureUnit.symbol), above your \(Int(limitDisplay))\(settings.temperatureUnit.symbol) threshold.\(suffix)",
                                    offendingPID: topOffender?.pid)
            } onBelow: {
                mgr.resetCooldown(metricKey: "temp")
            }
        }
    }

    private func evaluateThreshold(value: Double, limit: Double, onAbove: () -> Void, onBelow: () -> Void) {
        if value >= limit {
            onAbove()
        } else {
            onBelow()
        }
    }
}
