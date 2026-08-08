import Foundation

/// Keeps a rolling window of system + process snapshots in memory for charting,
/// and appends every snapshot to a JSON-lines file on disk so "last N hours"
/// queries survive an app relaunch.
@MainActor
final class HistoryStore {

    // Target coverage for the in-memory buffer: always keep at least this much
    // wall-clock history available, regardless of how fast/slow sampling runs.
    private let targetCoverageSeconds: TimeInterval = 3 * 3600
    private let minInMemorySamples = 1800

    // The on-disk logs are append-only, so without pruning they'd grow
    // forever — at a 2s refresh rate the process log alone adds up to
    // roughly 90MB/day. Retention here is generous relative to what the UI
    // actually shows (max 3-hour charts, 24h reload window) specifically to
    // leave room in case you want longer history later; trim further if
    // disk usage ever matters more than that.
    private let diskRetentionSeconds: TimeInterval = 48 * 3600
    private var recordsSinceLastPrune = 0
    private let pruneEveryNRecords = 300

    private(set) var systemHistory: [SystemSnapshot] = []
    private(set) var processHistory: [ProcessSnapshot] = []

    private let systemLogURL: URL
    private let processLogURL: URL
    private let fileQueue = DispatchQueue(label: "com.perfmonitor.historystore.io")

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerfMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        systemLogURL = dir.appendingPathComponent("system_history.jsonl")
        processLogURL = dir.appendingPathComponent("process_history.jsonl")

        // Loading can mean decoding tens of thousands of lines (up to 48h of
        // retention); do the file read + decode off the main actor so launch
        // doesn't stall, then hop back to assign the result.
        let url = systemLogURL
        Task { [weak self] in
            let loaded = await Self.loadRecentFromDisk(at: url)
            self?.systemHistory = loaded
        }
        pruneDiskLogs()
    }

    func record(system: SystemSnapshot, processes: [ProcessSnapshot], sampleIntervalSeconds: Double) {
        systemHistory.append(system)
        processHistory.append(contentsOf: processes)

        // e.g. at a 1s interval we need ~10800 samples for 3 hours; at 5min we
        // only need ~36. Recompute the cap each time since the user can change
        // the interval live in Settings.
        let maxInMemorySamples = max(minInMemorySamples, Int(targetCoverageSeconds / max(sampleIntervalSeconds, 1)) + 100)

        if systemHistory.count > maxInMemorySamples {
            systemHistory.removeFirst(systemHistory.count - maxInMemorySamples)
        }
        // Process history grows faster (N processes per tick); cap more aggressively.
        let maxProcessSamples = maxInMemorySamples * 12
        if processHistory.count > maxProcessSamples {
            processHistory.removeFirst(processHistory.count - maxProcessSamples)
        }

        appendToDisk(system: system, processes: processes)

        recordsSinceLastPrune += 1
        if recordsSinceLastPrune >= pruneEveryNRecords {
            recordsSinceLastPrune = 0
            pruneDiskLogs()
        }
    }

    /// Returns per-app aggregates over the trailing `window` seconds, sorted by avg CPU desc.
    /// This answers "which app was hammering my Mac over the last hour".
    func topOffenders(window: TimeInterval, limit: Int = 15) -> [ProcessAggregate] {
        let cutoff = Date().addingTimeInterval(-window)
        let recent = processHistory.filter { $0.timestamp >= cutoff }
        guard !recent.isEmpty else { return [] }

        var grouped: [String: [ProcessSnapshot]] = [:]
        for snap in recent {
            grouped[snap.name, default: []].append(snap)
        }

        let aggregates: [ProcessAggregate] = grouped.map { name, snaps in
            let avgCPU = snaps.reduce(0.0) { $0 + $1.cpuPercent } / Double(snaps.count)
            let maxCPU = snaps.map(\.cpuPercent).max() ?? 0
            let avgMem = UInt64(snaps.reduce(0.0) { $0 + Double($1.memBytes) } / Double(snaps.count))
            let maxMem = snaps.map(\.memBytes).max() ?? 0
            // Uptime should reflect "how long has it been running as of now",
            // so use the most recent snapshot's value, not an average or max
            // across the window (an average of uptimes is meaningless).
            let latestUptime = snaps.max(by: { $0.timestamp < $1.timestamp })?.uptimeSeconds
            return ProcessAggregate(name: name, avgCPUPercent: avgCPU, maxCPUPercent: maxCPU,
                                     avgMemBytes: avgMem, maxMemBytes: maxMem, sampleCount: snaps.count,
                                     uptimeSeconds: latestUptime)
        }

        return aggregates.sorted { $0.avgCPUPercent > $1.avgCPUPercent }.prefix(limit).map { $0 }
    }

    /// System-wide history over the trailing window, for the line charts.
    func systemHistory(window: TimeInterval) -> [SystemSnapshot] {
        let cutoff = Date().addingTimeInterval(-window)
        return systemHistory.filter { $0.timestamp >= cutoff }
    }

    /// Rewrites both log files keeping only entries within the retention
    /// window, so disk usage stays bounded no matter how long the app runs.
    /// Runs on the background file queue, roughly every ~300 samples rather
    /// than every tick, to keep the I/O cost low.
    private nonisolated func pruneDiskLogs() {
        let systemLogURL = self.systemLogURL
        let processLogURL = self.processLogURL
        let cutoff = Date().addingTimeInterval(-diskRetentionSeconds)
        fileQueue.async {
            Self.pruneFile(at: systemLogURL, cutoff: cutoff) { (snap: SystemSnapshot) in snap.timestamp }
            Self.pruneFile(at: processLogURL, cutoff: cutoff) { (snap: ProcessSnapshot) in snap.timestamp }
        }
    }

    private nonisolated static func pruneFile<T: Codable>(at url: URL, cutoff: Date, timestamp: (T) -> Date) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }

        let decoder = JSONDecoder()
        var kept: [Substring] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let value = try? decoder.decode(T.self, from: lineData) else { continue }
            if timestamp(value) >= cutoff {
                kept.append(line)
            }
        }

        let newContent = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? newContent.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Disk persistence

    private nonisolated func appendToDisk(system: SystemSnapshot, processes: [ProcessSnapshot]) {
        let systemLogURL = self.systemLogURL
        let processLogURL = self.processLogURL
        fileQueue.async {
            Self.appendLine(system, to: systemLogURL)
            for p in processes {
                Self.appendLine(p, to: processLogURL)
            }
        }
    }

    private nonisolated static func appendLine<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            try? Data("\n".utf8).append(to: url)
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    /// On launch, load the last 24 hours of system history from disk so charts
    /// aren't empty immediately after a relaunch. Process history is not
    /// preloaded (it's large); it repopulates live within a few minutes.
    ///
    /// `nonisolated` + `async` so this (potentially tens of thousands of lines
    /// of JSON decoding, up to 48h of retention) runs off the main actor
    /// instead of blocking app launch; the caller hops back to assign the
    /// result to the actor-isolated `systemHistory`.
    private nonisolated static func loadRecentFromDisk(at systemLogURL: URL) async -> [SystemSnapshot] {
        guard let data = try? Data(contentsOf: systemLogURL),
              let text = String(data: data, encoding: .utf8) else { return [] }

        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let decoder = JSONDecoder()
        var loaded: [SystemSnapshot] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let snap = try? decoder.decode(SystemSnapshot.self, from: lineData) else { continue }
            if snap.timestamp >= cutoff {
                loaded.append(snap)
            }
        }
        // Interval isn't known yet at load time (Settings may change it later),
        // so cap generously here; record() will re-trim to the right size once
        // sampling starts and the real interval is known.
        return Array(loaded.suffix(20000))
    }
}

private extension Data {
    // The project defaults every declaration to @MainActor isolation
    // (SWIFT_DEFAULT_ACTOR_ISOLATION); this is pure file I/O called from
    // HistoryStore's nonisolated appendLine(_:to:), off the main actor, so
    // it needs to opt back out explicitly.
    nonisolated func append(to url: URL) throws {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try self.write(to: url)
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(self)
    }
}
