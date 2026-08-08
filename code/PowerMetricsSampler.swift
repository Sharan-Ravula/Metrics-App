import Foundation
import Darwin

/// Runs Apple's `powermetrics` as a long-lived background process and parses its
/// plist output stream to extract GPU activity and thermal info.
///
/// powermetrics requires root, and so does actually terminating it again —
/// see Settings > GPU % Setup (SettingsView.swift) for the sudoers config
/// this class expects for both. If it's not configured, this sampler simply
/// reports nil values and the rest of the app keeps working with CPU/RAM/
/// process data only.
///
/// Mutable state (`process`, `powermetricsPID`, `buffer`) is touched both
/// from start()/stop() (always called on the main actor by MonitorEngine)
/// and from a background FileHandle readability callback, so this class is
/// @MainActor overall — the actually-blocking work (spawning `pgrep`/`sudo
/// kill`, polling for the real PID, sleeping between retries) lives in
/// `nonisolated static` helpers reached via `Task`, so it never blocks the
/// main actor, while every mutation of instance state happens on it.
@MainActor
final class PowerMetricsSampler {

    struct Reading {
        let gpuActivePercent: Double?
        let thermalPressure: String?
        let cpuDieTempC: Double?
    }

    private var process: Process?
    // The real, root-owned powermetrics PID — a child of `process` (the sudo
    // front-end), NOT process.processIdentifier itself. Signalling the sudo
    // front-end and hoping it relays the signal down to this child is what
    // the previous implementation did, and it's unreliable: verified via
    // `ps` that repeatedly restarting the sampler (e.g. changing the refresh
    // rate in Settings) leaked a new root powermetrics process every time,
    // because the relay silently didn't happen. We track this PID so stop()
    // can terminate the real process directly and deterministically instead.
    private var powermetricsPID: pid_t?
    private var buffer = Data()
    private let outputHandler: @MainActor (Reading) -> Void
    private let intervalMs: Int

    init(intervalMs: Int = 2000, onReading: @escaping @MainActor (Reading) -> Void) {
        self.intervalMs = intervalMs
        self.outputHandler = onReading
    }

    func start() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = [
            "-n", // non-interactive: fail instead of prompting, see Settings > GPU % Setup for sudoers config
            "/usr/bin/powermetrics",
            "-i", "\(intervalMs)",
            "--samplers", "gpu_power,thermal",
            "-f", "plist"
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            print("PowerMetricsSampler: received \(chunk.count) bytes")
            // This callback fires on a background queue (not the main
            // actor), so hop over explicitly to touch `buffer`.
            Task { @MainActor [weak self] in
                self?.handleIncoming(chunk)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            print("PowerMetricsSampler: STDERR: \(text)")
        }

        task.terminationHandler = { proc in
            print("PowerMetricsSampler: sudo front-end exited with status \(proc.terminationStatus), reason \(proc.terminationReason)")
        }

        do {
            try task.run()
            self.process = task
            let sudoPID = task.processIdentifier
            print("PowerMetricsSampler: launched powermetrics via sudo, front-end pid \(sudoPID)")

            // Resolving the real PID means polling (there's a short race
            // between sudo forking/exec'ing the root-owned process and it
            // showing up in the process table), which shouldn't block the
            // main actor — the polling itself runs off-actor in the
            // nonisolated static helper; only the final assignment below
            // needs to be on the main actor.
            Task { [weak self] in
                let pid = await Self.resolvePowermetricsPID(sudoPID: sudoPID)
                self?.powermetricsPID = pid
                if pid == nil {
                    print("PowerMetricsSampler: couldn't resolve the real powermetrics PID after launch — stop() won't be able to clean it up directly.")
                }
            }
        } catch {
            print("PowerMetricsSampler: failed to launch powermetrics: \(error)")
        }
    }

    private nonisolated static func resolvePowermetricsPID(sudoPID: pid_t) async -> pid_t? {
        for _ in 0..<20 { // up to ~2s
            if let pid = findPowermetricsChild(ofSudoPID: sudoPID) {
                return pid
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private nonisolated static func findPowermetricsChild(ofSudoPID sudoPID: pid_t) -> pid_t? {
        // Direct child of the sudo front-end, the common case.
        if let pid = pgrepFirst(["-P", "\(sudoPID)", "-x", "powermetrics"]) { return pid }
        // Fall back to a system-wide exact-name match in case sudo's fork
        // topology has an extra hop (e.g. a separate monitor process) that
        // puts powermetrics one level further down than expected.
        return pgrepFirst(["-x", "powermetrics"])
    }

    private nonisolated static func pgrepFirst(_ args: [String]) -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    func stop() {
        guard process != nil else { return }
        process = nil

        guard let pmPID = powermetricsPID else {
            print("PowerMetricsSampler: stop() called with no resolved powermetrics PID — nothing to clean up directly.")
            return
        }
        powermetricsPID = nil

        // Terminate the real process directly via a fresh, targeted sudo
        // invocation of `kill` — not by signalling the sudo front-end and
        // hoping it forwards. Requires the sudoers entry to also permit
        // `kill` on this Mac (see Settings > GPU % Setup); older setups that
        // only granted `powermetrics` itself will fail here (logged below)
        // until updated. Detached (not just off-actor) since this involves
        // up to ~2s of waiting and has no need to ever touch instance state.
        Task.detached(priority: .utility) {
            guard Self.sudoKill(pid: pmPID, signal: "-INT") else { return }

            // powermetrics can take a moment to exit gracefully after
            // SIGINT; verify shortly after and escalate to SIGKILL if it's
            // still around, then verify once more so a failure is at least
            // visible in the logs instead of silently leaking.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard Self.isRunning(pid: pmPID) else { return }
            _ = Self.sudoKill(pid: pmPID, signal: "-9")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Self.isRunning(pid: pmPID) {
                print("PowerMetricsSampler: powermetrics (pid \(pmPID)) is still running after SIGINT and SIGKILL.")
            }
        }
    }

    /// Runs `sudo -n kill <signal> <pid>` and returns whether it succeeded.
    /// Failure here (nonzero exit) almost always means the sudoers entry
    /// doesn't yet permit `kill`, not that the signal itself failed.
    @discardableResult
    private nonisolated static func sudoKill(pid: pid_t, signal: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "/bin/kill", signal, "\(pid)"]
        task.standardOutput = Pipe()
        let errorPipe = Pipe()
        task.standardError = errorPipe
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("PowerMetricsSampler: `sudo kill \(signal) \(pid)` failed (status \(task.terminationStatus)): \(errText.trimmingCharacters(in: .whitespacesAndNewlines)). The sudoers entry may need updating — see Settings > GPU % Setup.")
            return false
        }
        return true
    }

    /// Since we're not root, a still-running root process reports EPERM
    /// (permission denied) rather than 0 when signalled with 0 (no-op,
    /// existence check only); ESRCH specifically means it's gone.
    private nonisolated static func isRunning(pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func handleIncoming(_ chunk: Data) {
        buffer.append(chunk)
        while let nulRange = buffer.range(of: Data([0x00])) {
            let plistData = buffer.subdata(in: buffer.startIndex..<nulRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<nulRange.upperBound)
            parsePlist(plistData)
        }
    }

    private func parsePlist(_ data: Data) {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return }

        // GPU: the field names powermetrics actually emits vary by macOS
        // version/chip. Confirmed present on this Mac's real output: "idle_ratio"
        // (fraction of the sample the GPU was idle — active% = 1 - idle_ratio).
        // Older/other versions may instead expose "gpu_active_residency"
        // directly, so that's kept as a fallback.
        var gpuPercent: Double? = nil
        if let gpu = plist["gpu"] as? [String: Any] {
            if let idleRatio = gpu["idle_ratio"] as? Double {
                gpuPercent = (1 - idleRatio) * 100
            } else if let v = gpu["gpu_active_residency"] as? Double {
                gpuPercent = v
            } else if let s = gpu["gpu_active_residency"] as? String {
                gpuPercent = Double(s.replacingOccurrences(of: "%", with: ""))
            } else if let v = gpu["active_residency"] as? Double {
                gpuPercent = v
            }
        }

        var pressure: String? = nil
        if let thermal = plist["thermal_pressure"] as? String {
            pressure = thermal
        } else if let thermal = plist["thermal"] as? [String: Any],
                  let level = thermal["thermal_pressure"] as? String {
            pressure = level
        }

        var tempC: Double? = nil
        if let thermal = plist["thermal"] as? [String: Any],
           let temp = thermal["die_temperature"] as? Double {
            tempC = temp
        }

        let reading = Reading(gpuActivePercent: gpuPercent, thermalPressure: pressure, cpuDieTempC: tempC)
        let gpuText = gpuPercent.map { "\($0)" } ?? "nil"
        print("PowerMetricsSampler: parsed sample — gpu=\(gpuText), thermal=\(pressure ?? "nil")")
        outputHandler(reading)
    }
}
