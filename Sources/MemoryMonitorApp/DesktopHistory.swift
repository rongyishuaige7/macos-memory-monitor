import Charts
import MemoryMonitorCore
import SwiftUI

struct HistoryTrendData {
    let records: [MemoryHistoryRecord]
    let points: [MemoryHistoryRecord]
    let segments: [Date: Int]
    let isolatedPoints: Set<Date>
    let average: Double?
    let peak: MemoryHistoryRecord?

    init(records: [MemoryHistoryRecord], hours: Int, now: Date) {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        let valid = records.filter {
            $0.timestamp >= start && $0.timestamp <= now &&
            $0.availableFraction.isFinite && (0...1).contains($0.availableFraction)
        }
        self.records = Dictionary(valid.map { ($0.timestamp, $0) }, uniquingKeysWith: { _, new in new })
            .values.sorted { $0.timestamp < $1.timestamp }
        points = DesktopPresentation.chartRecords(self.records, hours: hours, now: now)
        let groups = DesktopPresentation.chartSegments(self.records, hours: hours, now: now)
        segments = groups
        let counts = Dictionary(grouping: points, by: { groups[$0.timestamp] ?? 0 }).mapValues(\.count)
        isolatedPoints = Set(points.filter { counts[groups[$0.timestamp] ?? 0] == 1 }.map(\.timestamp))
        average = self.records.isEmpty ? nil : self.records.reduce(0) { $0 + $1.usedFraction } / Double(self.records.count)
        peak = self.records.max { $0.usedFraction < $1.usedFraction }
    }

    // Inspect original samples, including extrema omitted from the drawing budget.
    func nearest(to date: Date) -> MemoryHistoryRecord? {
        var lower = 0
        var upper = records.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if records[middle].timestamp < date { lower = middle + 1 } else { upper = middle }
        }
        let candidates = [lower - 1, lower].filter { records.indices.contains($0) }.map { records[$0] }
        guard let closest = candidates.min(by: {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }), abs(closest.timestamp.timeIntervalSince(date)) <= 60 else { return nil }
        return closest
    }

    static func percentage(_ fraction: Double?) -> String {
        fraction.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) + "%" } ?? "--"
    }
}

struct MemoryTrend: View {
    let records: [MemoryHistoryRecord]
    let hours: Int
    let now: Date
    var compact = false
    var sparkline = false
    var detailed = false
    @Environment(\.colorScheme) private var scheme
    @State private var data = HistoryTrendData(records: [], hours: 1, now: .distantPast)
    private enum Selection: Equatable { case sample(Date), gap }
    @State private var selection: Selection?
    @State private var pinned: Date?
    @FocusState private var chartFocused: Bool

    private var accent: Color { scheme == .dark ? .cyan : Color(red: 0.0, green: 0.46, blue: 0.59) }
    private var peakColor: Color { scheme == .dark ? .orange : Color(red: 0.70, green: 0.36, blue: 0.02) }
    private var timeTicks: [Date] {
        let divisions = compact ? 2 : 4
        return (0...divisions).map { now.addingTimeInterval(-Double(hours) * 3600 * Double(divisions - $0) / Double(divisions)) }
    }
    private var hovered: MemoryHistoryRecord? {
        guard case .sample(let date) = selection else { return nil }
        return data.nearest(to: date)
    }

    private var inspected: MemoryHistoryRecord? {
        if let pinned {
            return data.exactRecord(at: pinned)
        }
        return hovered
    }

    private var pinnedExpired: Bool {
        pinned != nil && inspected == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: detailed ? 18 : 0) {
            if detailed { summary }
            plot.frame(maxWidth: .infinity, maxHeight: .infinity)
            if detailed { inspection }
            if detailed {
                Text(data.coverageText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("history-coverage")
            }
        }
        .onChange(of: records, initial: true) { rebuild() }
        .onChange(of: hours) { selection = nil; pinned = nil; rebuild() }
        .onChange(of: now) { rebuild() }
        .onExitCommand { pinned = nil; selection = nil }
        .focusable(detailed)
        .focused($chartFocused)
        .onKeyPress(.leftArrow) { movePinned(-1); return .handled }
        .onKeyPress(.rightArrow) { movePinned(1); return .handled }
    }

    private var summary: some View {
        HStack(spacing: 20) {
            reading("最近记录", value: data.records.last?.usedFraction, color: accent)
            Divider()
            reading("时段平均", value: data.average, color: .primary)
            Divider()
            reading("时段最高", value: data.peak?.usedFraction, color: peakColor)
            if data.peak != nil {
                Button("定位最高记录", systemImage: "scope") { pinPeak() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("history-locate-peak")
            }
        }.frame(height: 65)
    }

    private func reading(_ title: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(HistoryTrendData.percentage(value))
                .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private var plot: some View {
        Chart {
            if detailed, let average = data.average, data.records.count > 1 {
                RuleMark(y: .value("时段平均", average * 100))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            ForEach(data.points) { record in
                AreaMark(x: .value("时间", record.timestamp), yStart: .value("基线", 0),
                         yEnd: .value("使用率", record.usedFraction * 100),
                         series: .value("连续记录", data.segments[record.timestamp] ?? 0))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.23 : 0.16), accent.opacity(0.015)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)
                LineMark(x: .value("时间", record.timestamp), y: .value("使用率", record.usedFraction * 100),
                         series: .value("连续记录", data.segments[record.timestamp] ?? 0))
                    .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: compact ? 1.8 : 2.3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                if data.isolatedPoints.contains(record.timestamp) || record.timestamp == data.records.last?.timestamp {
                    PointMark(x: .value("时间", record.timestamp), y: .value("使用率", record.usedFraction * 100))
                        .foregroundStyle(accent)
                        .symbolSize(record.timestamp == data.records.last?.timestamp ? (compact ? 20 : 36) : (compact ? 4 : 6))
                }
            }
            if detailed, let peak = data.peak, data.records.count > 1 {
                PointMark(x: .value("最高时间", peak.timestamp), y: .value("最高使用率", peak.usedFraction * 100))
                    .foregroundStyle(peakColor).symbolSize(30)
            }
            if detailed, let inspected {
                RuleMark(x: .value("选中时间", inspected.timestamp))
                    .foregroundStyle(Color.primary.opacity(0.30)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("选中时间", inspected.timestamp), y: .value("选中使用率", inspected.usedFraction * 100))
                    .foregroundStyle(accent).symbolSize(85)
                PointMark(x: .value("选中时间", inspected.timestamp), y: .value("选中使用率", inspected.usedFraction * 100))
                    .foregroundStyle(scheme == .dark ? Color.black : .white).symbolSize(20)
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-Double(hours) * 3600)...now,
                     range: .plotDimension(startPadding: 5, endPadding: 7))
        .chartYScale(domain: 0...100, range: .plotDimension(startPadding: 3, endPadding: 6))
        .chartXAxis {
            if !sparkline {
                AxisMarks(values: timeTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 5])).foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel(anchor: value.index == 0 ? .topLeading : value.index == value.count - 1 ? .topTrailing : .top) {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(hours == 24 && (value.index == 0 || value.index == value.count - 1)
                                                ? .dateTime.month().day().hour().minute() : .dateTime.hour().minute()))
                                .font(.caption2).foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            if !sparkline {
                AxisMarks(position: .leading, values: compact ? [0, 50, 100] : [0, 25, 50, 75, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [3, 4])).foregroundStyle(Color.secondary.opacity(0.16))
                    AxisValueLabel {
                        if let number = value.as(Int.self) { Text("\(number)%").font(.caption2).monospacedDigit() }
                    }.foregroundStyle(Color.secondary)
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): select(at: location, proxy: proxy, geometry: geometry)
                        case .ended: selection = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { select(at: $0.location, proxy: proxy, geometry: geometry) }
                        .onEnded { _ in
                            if let hovered {
                                pinned = hovered.timestamp
                                chartFocused = true
                            } else {
                                pinned = nil
                            }
                        })
                    .allowsHitTesting(detailed && !data.records.isEmpty)
            }
        }
        .overlay {
            if data.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: compact ? 18 : 26)).foregroundStyle(accent.opacity(0.65))
                    if !sparkline { Text("此时段暂无记录").font(.caption).foregroundStyle(.secondary) }
                }.allowsHitTesting(false)
            }
        }
        .accessibilityLabel("内存使用率趋势")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier(detailed ? "history-trend-chart" : "memory-trend-compact")
    }

    private var accessibilitySummary: String {
        guard !data.records.isEmpty else { return "暂无记录" }
        let average = HistoryTrendData.percentage(data.average)
        let peak = HistoryTrendData.percentage(data.peak?.usedFraction)
        return "共 \(data.records.count) 个样本，平均 \(average)，最高 \(peak)"
    }

    private var inspection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pinnedExpired {
                Label("固定的样本已移出当前范围，请重新定位最高记录。", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let record = inspected {
                let sample = data.presentation(for: record)
                HStack(spacing: 8) {
                    if pinned != nil {
                        Image(systemName: "pin.fill").foregroundStyle(accent)
                    }
                    Text(record.timestamp.formatted(.dateTime.month().day().hour().minute()))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(HistoryTrendData.percentage(record.usedFraction))
                        .fontWeight(.semibold)
                        .foregroundStyle(accent)
                }
                if let source = record.sourceSampledAt {
                    Text("源采样 " + source.formatted(.dateTime.hour().minute().second()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Text("压缩 " + SimpleMonitorPresentation.memory(record.compressedBytes))
                    Text("交换 " + SimpleMonitorPresentation.memory(record.swapUsedBytes))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                if let interval = sample.comparisonInterval,
                   let compressed = sample.compressedDelta,
                   let swap = sample.swapDelta {
                    Text("较 \(Int(interval)) 秒前：压缩 \(signedBytes(compressed))，交换 \(signedBytes(swap))（仅相邻有效记录，不是流量）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("相邻有效记录超过 120 秒或不存在，未计算压缩/交换增量。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(sample.workloadQuality.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(sample.workloadQuality == .complete ? Color.secondary : Color.orange)
                ForEach(sample.topWorkloads) { workload in
                    HStack(spacing: 6) {
                        Text(workload.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(SimpleMonitorPresentation.memory(workload.attributedFootprintBytes))
                            .monospacedDigit()
                        if workload.containsEstimatedFootprint {
                            Text("估算").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                }
                if sample.additionalWorkloadCount > 0 {
                    Text("另有 \(sample.additionalWorkloadCount) 个已保存工作组，展开历史详情查看。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(selection == nil ? "悬停预览，点击固定样本" : "此处没有记录")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("--").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .frame(minHeight: 30, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-inspection")
    }

    private func pinPeak() {
        guard let peak = data.peak else { return }
        pinned = peak.timestamp
        selection = .sample(peak.timestamp)
        chartFocused = true
    }

    private func movePinned(_ direction: Int) {
        let current = inspected?.timestamp ?? data.records.last?.timestamp
        guard let current,
              let target = data.adjacentRecord(to: current, direction: direction) else { return }
        pinned = target.timestamp
        selection = .sample(target.timestamp)
    }

    private func signedBytes(_ value: Int64) -> String {
        if value == 0 { return "无变化" }
        let magnitude = SimpleMonitorPresentation.memory(UInt64(abs(value)))
        return (value > 0 ? "+" : "−") + magnitude
    }

    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let frame = geometry[anchor]
        guard frame.contains(location), let date = proxy.value(atX: location.x - frame.minX, as: Date.self) else {
            selection = nil
            return
        }
        // Publish only when the inspected sample changes, not on every mouse pixel.
        let target = data.nearest(to: date).map { Selection.sample($0.timestamp) } ?? .gap
        if selection != target { selection = target }
    }

    private func rebuild() { data = HistoryTrendData(records: records, hours: hours, now: now) }
}

struct DesktopHistory: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var navigation: DesktopNavigation

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label("内存使用率", systemImage: "waveform.path").font(.subheadline.weight(.medium))
                        Spacer(minLength: 16)
                        Picker("时间范围", selection: $navigation.historyHours) {
                            Text("1 小时").tag(1)
                            Text("6 小时").tag(6)
                            Text("24 小时").tag(24)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 222)
                            .accessibilityIdentifier("history-range")
                    }.frame(height: 28)
                    MemoryTrend(records: model.history, hours: navigation.historyHours, now: model.updatedAt ?? Date(), detailed: true)
                        .frame(height: max(300, min(420, geometry.size.height - 136)))
                    HStack(spacing: 18) {
                        HStack(spacing: 6) {
                            Rectangle().fill(.secondary.opacity(0.5)).frame(width: 14, height: 1)
                            Text("时段平均")
                        }
                        HStack(spacing: 6) {
                            Circle().fill(.orange).frame(width: 5, height: 5)
                            Text("最高记录")
                        }
                        Spacer(minLength: 0)
                        Text("每分钟记录").foregroundStyle(.tertiary)
                    }.font(.caption2).foregroundStyle(.secondary).frame(minHeight: 22)
                    if model.historyError != nil {
                        Label("当前历史仅在内存中保留，尚未保存到磁盘", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(.horizontal, 28).padding(.vertical, 20)
            }
        }
        .onChange(of: model.history, initial: true) {
            guard !navigation.historyRangeInitialized, !model.history.isEmpty else { return }
            navigation.historyHours = DesktopPresentation.initialHistoryHours(
                model.history, now: model.updatedAt ?? Date()
            )
            navigation.historyRangeInitialized = true
        }
    }
}
