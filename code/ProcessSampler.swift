import Foundation

/// Gets per-process CPU% and memory by shelling out to `top`. This avoids needing
/// sudo or private APIs, and top already aggregates threads per process for us.
nonisolated final class ProcessSampler {

    /// Runs `top -l 2` and returns up to `limit` processes sorted by CPU usage desc.
    /// Two samples are required: top's *first* sample in any run reports a
    /// since-launch average (often near-zero for background daemons), and only
    /// the *second* sample — a real ~1s delta — reflects actual current usage.
    /// Using -l 1 alone is why every row previously showed 0.0%.
    func sampleTopProcesses(limit: Int = 12) -> [ProcessSnapshot] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        task.arguments = ["-l", "2", "-s", "1", "-o", "cpu", "-n", "\(limit)", "-stats", "pid,command,cpu,mem"]
        // top isn't attached to a TTY here, so without a COLUMNS hint it falls
        // back to a narrow default width and truncates long command names
        // (e.g. "Vivaldi Helper (Renderer)" becomes "Vivaldi Helper ("). Two
        // different processes truncating to the same string would then get
        // merged together downstream, since rows are keyed by name.
        var environment = ProcessInfo.processInfo.environment
        environment["COLUMNS"] = "500"
        task.environment = environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // discard

        do {
            try task.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let snapshots = parseTopOutput(output)

        // Merge in per-process uptime from `ps`, a separate lightweight call
        // (one call covers every process, not one call per pid).
        let uptimes = fetchUptimes()
        return snapshots.map { snap in
            ProcessSnapshot(timestamp: snap.timestamp, pid: snap.pid, name: snap.name,
                             cpuPercent: snap.cpuPercent, memBytes: snap.memBytes,
                             uptimeSeconds: uptimes[snap.pid])
        }
    }

    private func parseTopOutput(_ output: String) -> [ProcessSnapshot] {
        let lines = output.split(separator: "\n").map(String.init)
        // With -l 2, "PID" headers appear twice (once per sample). Use the LAST
        // one so we read the real second sample, not the meaningless first.
        guard let headerIndex = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("PID") }) else {
            return []
        }

        let now = Date()
        var results: [ProcessSnapshot] = []

        for line in lines[(headerIndex + 1)...] {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 4 else { continue }

            guard let pid = Int32(cols[0]) else { continue }
            let memStr = cols[cols.count - 1]
            let cpuStr = cols[cols.count - 2]
            let name = cols[1..<(cols.count - 2)].joined(separator: " ")

            let cpu = Double(cpuStr.replacingOccurrences(of: "%", with: "")) ?? 0
            let mem = parseMemString(memStr)

            results.append(ProcessSnapshot(timestamp: now, pid: pid, name: name, cpuPercent: cpu, memBytes: mem, uptimeSeconds: nil))
        }

        return results
    }

    /// top's MEM column looks like "123M+" or "1.2G" or "512K"
    private func parseMemString(_ raw: String) -> UInt64 {
        var s = raw
        if s.hasSuffix("+") || s.hasSuffix("-") { s.removeLast() }
        guard let unit = s.last else { return 0 }
        let numPart = String(s.dropLast())
        guard let value = Double(numPart) else { return 0 }

        switch unit {
        case "K": return UInt64(value * 1024)
        case "M": return UInt64(value * 1024 * 1024)
        case "G": return UInt64(value * 1024 * 1024 * 1024)
        default: return UInt64(value)
        }
    }

    /// One `ps` call covering every process's elapsed (wall-clock) running
    /// time, keyed by pid, so we're not spawning a process per pid.
    private func fetchUptimes() -> [Int32: TimeInterval] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,etime"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [Int32: TimeInterval] = [:]
        let lines = output.split(separator: "\n").dropFirst() // skip header
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            if let seconds = parseEtime(String(parts[1])) {
                result[pid] = seconds
            }
        }
        return result
    }

    /// ps's ELAPSED column format varies by duration: "ss", "mm:ss",
    /// "hh:mm:ss", or "dd-hh:mm:ss".
    private func parseEtime(_ etime: String) -> TimeInterval? {
        var days: Double = 0
        var rest = etime
        if let dashRange = etime.range(of: "-") {
            days = Double(etime[etime.startIndex..<dashRange.lowerBound]) ?? 0
            rest = String(etime[dashRange.upperBound...])
        }
        let comps = rest.split(separator: ":").compactMap { Double($0) }
        guard !comps.isEmpty else { return nil }

        var seconds: Double = 0
        switch comps.count {
        case 1: seconds = comps[0]
        case 2: seconds = comps[0] * 60 + comps[1]
        case 3: seconds = comps[0] * 3600 + comps[1] * 60 + comps[2]
        default: return nil
        }
        return days * 86400 + seconds
    }
}
