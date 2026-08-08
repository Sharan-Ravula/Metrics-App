import Foundation

/// One point-in-time reading of overall system load, taken every sampling interval.
nonisolated struct SystemSnapshot: Identifiable, Codable {
    var id = UUID()
    let timestamp: Date
    let cpuUsagePercent: Double      // 0-100, all cores combined
    let memUsedPercent: Double       // 0-100
    let memUsedBytes: UInt64
    let memTotalBytes: UInt64
    let gpuActivePercent: Double?    // nil if powermetrics unavailable
    let thermalPressure: String?     // "Nominal" / "Moderate" / "Heavy" / "Trapping" / "Sleeping"
    let cpuTempC: Double?            // from user-selected SMC sensor, nil until configured
    let gpuTempC: Double?            // from user-selected SMC sensor, nil until configured
    let packagePowerWatts: Double?   // whole-SoC power draw, from SoCMetrics (Apple Silicon only)
}

/// Per-process reading, taken alongside each SystemSnapshot.
nonisolated struct ProcessSnapshot: Identifiable, Codable, Equatable {
    var id = UUID()
    let timestamp: Date
    let pid: Int32
    let name: String
    let cpuPercent: Double
    let memBytes: UInt64
    let uptimeSeconds: TimeInterval?
}

/// Aggregated view of a process's impact over a time window, used for the
/// "what was hammering your Mac in the last hour" view.
nonisolated struct ProcessAggregate: Identifiable {
    var id: String { name }
    let name: String
    let avgCPUPercent: Double
    let maxCPUPercent: Double
    let avgMemBytes: UInt64
    let maxMemBytes: UInt64
    let sampleCount: Int
    let uptimeSeconds: TimeInterval?
}
