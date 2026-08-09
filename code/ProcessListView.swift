import SwiftUI
import Charts

enum ProcessViewMode: String, CaseIterable, Identifiable {
    case table = "Table"
    case bar = "Bar"
    case pie = "Pie"
    var id: String { rawValue }
}

struct ProcessListView: View {
    @EnvironmentObject var engine: MonitorEngine
    @ObservedObject var settings = SettingsStore.shared

    private let reorderInterval: TimeInterval = 10
    // topOffenders(window:) regroups the whole trailing window (up to an
    // hour of samples) from scratch on every call. That average barely moves
    // tick to tick, so recomputing it every refresh (as fast as once a
    // second) was pure waste — this caps it to a fixed cadence independent
    // of the refresh rate.
    private let historyRecomputeInterval: TimeInterval = 10

    @State private var liveOrder: [String] = []
    @State private var lastLiveReorder = Date.distantPast
    @State private var liveRows: [ProcessAggregate] = []

    @State private var historyOrder: [String] = []
    @State private var lastHistoryReorder = Date.distantPast
    @State private var lastHistoryRecompute = Date.distantPast
    @State private var historyRows: [ProcessAggregate] = []

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            liveSection
            offendersSection
        }
        .onAppear {
            updateLiveRows(engine.topProcesses)
            updateHistoryRows()
        }
        .onChange(of: engine.topProcesses) { _, newProcesses in
            updateLiveRows(newProcesses)
            updateHistoryRows()
        }
        .onChange(of: settings.historyTableWindow) { _, _ in
            historyOrder = []
            // The window itself just changed, so the old aggregate is now
            // for the wrong range — recompute immediately rather than
            // waiting out the throttle below.
            updateHistoryRows(force: true)
        }
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live: What's Using CPU Right Now")
                .font(.title3.bold())
            Text("A snapshot as of the last refresh. Row order re-ranks every \(Int(reorderInterval))s so it doesn't jump around constantly — or click any column header to sort manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
                // Reserves 2 lines of height regardless of actual wrap, so
                // this card's button row lines up with the History card's
                // even though the two captions are different lengths.
                .lineLimit(2, reservesSpace: true)
            HStack {
                Spacer()
                modePicker($settings.liveViewMode)
            }
            ProcessVisualization(rows: liveRows, mode: settings.liveViewMode, showMaxColumn: false)
            if liveRows.count > 15 {
                Text("Showing top 15 of \(liveRows.count) processes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var offendersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History: What Used the Most Over Time")
                .font(.title3.bold())
            Text("Averages each app's CPU usage across the selected range — finds what hammered your Mac even after it's no longer running.")
                .font(.caption)
                .foregroundStyle(.secondary)
                // Matches the reserved 2-line height on the Live card's
                // caption above, so both cards' button rows align.
                .lineLimit(2, reservesSpace: true)
            HStack {
                TimeWindowPicker(selection: $settings.historyTableWindow, label: "Last")
                Spacer()
                modePicker($settings.historyViewMode)
            }

            if historyRows.isEmpty {
                Text("Not enough history yet for this range — check back in a bit, or pick a shorter window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ProcessVisualization(rows: historyRows, mode: settings.historyViewMode, showMaxColumn: true)
                if historyRows.count > 15 {
                    Text("Showing top 15 of \(historyRows.count) processes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func modePicker(_ selection: Binding<ProcessViewMode>) -> some View {
        Picker("View as", selection: selection) {
            ForEach(ProcessViewMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
    }

    private func updateLiveRows(_ processes: [ProcessSnapshot]) {
        let now = Date()

        var merged: [String: (cpu: Double, mem: UInt64, uptime: TimeInterval?)] = [:]
        for p in processes {
            var entry = merged[p.name] ?? (0, 0, nil)
            entry.cpu += p.cpuPercent
            entry.mem += p.memBytes
            entry.uptime = max(entry.uptime ?? 0, p.uptimeSeconds ?? 0)
            merged[p.name] = entry
        }
        let current = merged.map { name, totals in
            ProcessAggregate(name: name, avgCPUPercent: totals.cpu, maxCPUPercent: totals.cpu,
                              avgMemBytes: totals.mem, maxMemBytes: totals.mem, sampleCount: 1,
                              uptimeSeconds: totals.uptime)
        }
        let dict = Dictionary(current.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        if liveOrder.isEmpty || now.timeIntervalSince(lastLiveReorder) > reorderInterval {
            liveOrder = current.sorted { $0.avgCPUPercent > $1.avgCPUPercent }.map { $0.name }
            lastLiveReorder = now
        } else {
            insertNewArrivals(into: &liveOrder, current: current, dict: dict)
        }
        liveRows = liveOrder.compactMap { dict[$0] }
    }

    private func updateHistoryRows(force: Bool = false) {
        let now = Date()
        guard force || historyRows.isEmpty || now.timeIntervalSince(lastHistoryRecompute) > historyRecomputeInterval else {
            return
        }
        lastHistoryRecompute = now

        let current = engine.history.topOffenders(window: settings.historyTableWindow.seconds)
        let dict = Dictionary(current.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        if historyOrder.isEmpty || now.timeIntervalSince(lastHistoryReorder) > reorderInterval {
            historyOrder = current.sorted { $0.avgCPUPercent > $1.avgCPUPercent }.map { $0.name }
            lastHistoryReorder = now
        } else {
            insertNewArrivals(into: &historyOrder, current: current, dict: dict)
        }
        historyRows = historyOrder.compactMap { dict[$0] }
    }

    /// Adds names from `current` that aren't already in `order` — inserting
    /// each at the rank position its CPU% would put it at among the
    /// existing (stable) order, rather than always appending to the end.
    /// Appending unconditionally is what let a brand-new process with real
    /// CPU usage (e.g. `screencapture` at 2.3%, 6s old) land visually below
    /// unrelated lower-usage rows (e.g. `Xcode` at 1.5%) until the next
    /// periodic reorder — the table looked unsorted even though nothing was
    /// actually wrong with the data. Existing rows' relative order is left
    /// untouched, so this doesn't reintroduce the jumping-around this
    /// stable-order scheme exists to avoid.
    private func insertNewArrivals(into order: inout [String], current: [ProcessAggregate], dict: [String: ProcessAggregate]) {
        for row in current where !order.contains(row.name) {
            let insertIndex = order.firstIndex { existingName in
                guard let existingCPU = dict[existingName]?.avgCPUPercent else { return false }
                return existingCPU < row.avgCPUPercent
            } ?? order.count
            order.insert(row.name, at: insertIndex)
        }
    }
}

private enum SortColumn {
    case name, avgCPU, maxCPU, avgMem, uptime
}

/// Single source of truth for the table's column widths, so the header row,
/// data rows, and the overall table-width calculation (used to center the
/// table in its card) can never drift out of sync with each other.
private enum Column {
    static let index: CGFloat = 20
    static let app: CGFloat = 160
    static let cpu: CGFloat = 64
    static let mem: CGFloat = 72
    static let uptime: CGFloat = 64
    static let spacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 12 // 6pt on each side
}

struct ProcessVisualization: View {
    let rows: [ProcessAggregate]
    let mode: ProcessViewMode
    var showMaxColumn: Bool = true

    @State private var hoveredSlice: (name: String, value: Double)?
    @State private var selectedRowName: String?

    @State private var sortColumn: SortColumn?
    @State private var sortAscending = false

    var body: some View {
        switch mode {
        case .table: tableView
        case .bar: barView
        case .pie: pieView
        }
    }

    private var sortedRows: [ProcessAggregate] {
        guard let sortColumn else { return rows }
        let sorted: [ProcessAggregate]
        switch sortColumn {
        case .name:
            sorted = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .avgCPU:
            sorted = rows.sorted { $0.avgCPUPercent < $1.avgCPUPercent }
        case .maxCPU:
            sorted = rows.sorted { $0.maxCPUPercent < $1.maxCPUPercent }
        case .avgMem:
            sorted = rows.sorted { $0.avgMemBytes < $1.avgMemBytes }
        case .uptime:
            sorted = rows.sorted { ($0.uptimeSeconds ?? -1) < ($1.uptimeSeconds ?? -1) }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private var columnCount: Int { showMaxColumn ? 6 : 5 }

    private var tableContentWidth: CGFloat {
        let columns = Column.index + Column.app + Column.cpu + (showMaxColumn ? Column.cpu : 0) + Column.mem + Column.uptime
        let spacing = Column.spacing * CGFloat(columnCount - 1)
        return columns + spacing + Column.horizontalPadding
    }

    private var tableView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Column.spacing) {
                sortHeader("#", column: .name, width: Column.index, alignment: .trailing)
                sortHeader("App", column: .name, width: Column.app, alignment: .leading)
                sortHeader("Avg CPU", column: .avgCPU, width: Column.cpu, alignment: .trailing)
                if showMaxColumn {
                    sortHeader("Max CPU", column: .maxCPU, width: Column.cpu, alignment: .trailing)
                }
                sortHeader("Avg Mem", column: .avgMem, width: Column.mem, alignment: .trailing)
                sortHeader("Uptime", column: .uptime, width: Column.uptime, alignment: .trailing)
            }
            .padding(.horizontal, Column.horizontalPadding / 2)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
            ForEach(Array(sortedRows.prefix(15).enumerated()), id: \.element.id) { index, row in
                let isSelected = selectedRowName == row.name
                HStack(spacing: Column.spacing) {
                    Text("\(index + 1)").foregroundStyle(.secondary).frame(width: Column.index, alignment: .trailing)
                    HStack(spacing: 6) {
                        Image(nsImage: AppIconProvider.shared.icon(for: row.name))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(row.name).lineLimit(1)
                    }
                    .frame(width: Column.app, alignment: .leading)
                    Text("\(row.avgCPUPercent, specifier: "%.1f")%")
                        .foregroundStyle(Severity.color(forPercent: row.avgCPUPercent))
                        .frame(width: Column.cpu, alignment: .trailing)
                    if showMaxColumn {
                        Text("\(row.maxCPUPercent, specifier: "%.1f")%")
                            .foregroundStyle(Severity.color(forPercent: row.maxCPUPercent))
                            .frame(width: Column.cpu, alignment: .trailing)
                    }
                    Text(formatBytes(row.avgMemBytes))
                        .foregroundStyle(Severity.color(forBytes: row.avgMemBytes))
                        .frame(width: Column.mem, alignment: .trailing)
                    Text(formatUptime(row.uptimeSeconds))
                        .foregroundStyle(.secondary)
                        .frame(width: Column.uptime, alignment: .trailing)
                }
                .font(.system(size: 13, design: .monospaced))
                .padding(.vertical, 5)
                .padding(.horizontal, Column.horizontalPadding / 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedRowName = isSelected ? nil : row.name
                }
            }
        }
        .frame(width: tableContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func sortHeader(_ title: String, column: SortColumn, width: CGFloat, alignment: Alignment) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = false
            }
        } label: {
            HStack(spacing: 2) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .font(.caption)
            .foregroundStyle(sortColumn == column ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
    }

    private var barView: some View {
        let top = Array(rows.sorted { $0.avgCPUPercent > $1.avgCPUPercent }.prefix(10))
        return Chart(top) { row in
            BarMark(
                x: .value("Avg CPU %", row.avgCPUPercent),
                y: .value("App", row.name)
            )
            .foregroundStyle(Severity.color(forPercent: row.avgCPUPercent))
            .annotation(position: .trailing) {
                Text("\(row.avgCPUPercent, specifier: "%.0f")%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))%")
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: CGFloat(top.count) * 28 + 20)
    }

    private var pieSlices: [(name: String, value: Double)] {
        let top = rows.sorted { $0.avgCPUPercent > $1.avgCPUPercent }.prefix(6)
        let topTotal = top.reduce(0.0) { $0 + $1.avgCPUPercent }
        let allTotal = rows.reduce(0.0) { $0 + $1.avgCPUPercent }
        var slices = top.map { (name: $0.name, value: $0.avgCPUPercent) }
        let remainder = allTotal - topTotal
        if remainder > 0.5 {
            slices.append((name: "Other", value: remainder))
        }
        return slices
    }

    private var pieView: some View {
        let slices = pieSlices
        let total = slices.reduce(0.0) { $0 + $1.value }
        return VStack(spacing: 6) {
            Chart(slices, id: \.name) { slice in
                SectorMark(angle: .value("CPU", slice.value), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(by: .value("App", slice.name))
                    .cornerRadius(3)
                    .opacity(hoveredSlice == nil || hoveredSlice?.name == slice.name ? 1 : 0.35)
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 4)
            .frame(height: 240)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame, total > 0 else {
                                    hoveredSlice = nil
                                    return
                                }
                                let rect = geo[plotFrame]
                                let center = CGPoint(x: rect.midX, y: rect.midY)
                                let outerRadius = min(rect.width, rect.height) / 2
                                let innerRadius = outerRadius * 0.55
                                let dx = location.x - center.x
                                let dy = location.y - center.y
                                let distance = (dx * dx + dy * dy).squareRoot()
                                guard distance <= outerRadius, distance >= innerRadius else {
                                    hoveredSlice = nil
                                    return
                                }
                                var angle = atan2(dy, dx) + .pi / 2
                                if angle < 0 { angle += 2 * .pi }
                                let value = (angle / (2 * .pi)) * total
                                var cumulative = 0.0
                                hoveredSlice = slices.first { slice in
                                    cumulative += slice.value
                                    return value <= cumulative
                                } ?? slices.last
                            case .ended:
                                hoveredSlice = nil
                            }
                        }
                }
            }

            Group {
                if let hoveredSlice {
                    Text("\(hoveredSlice.name): \(hoveredSlice.value, specifier: "%.1f")% CPU")
                        .font(.caption.bold())
                } else {
                    Text("Hover a slice to see details")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 16)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func formatUptime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(Int(seconds))s"
    }
}
