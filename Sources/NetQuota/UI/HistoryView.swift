import Charts
import NetQuotaCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector

    enum Span: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90, year = 365
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .week: "7 天"
            case .month: "30 天"
            case .quarter: "90 天"
            case .year: "1 年"
            }
        }
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case day = "日", week = "週", month = "月"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        let id: String
        var label: String
        let start: Date
        var rx: Double
        var tx: Double
        var calibration: Double
        var peakRx: Double
        var peakTx: Double
        var days: Int
        var total: Double { max(0, rx + tx + calibration) }
    }

    private struct Segment: Identifiable {
        let row: Row
        let kind: String
        let low: Double
        let high: Double
        var id: String { "\(row.id)-\(kind)" }
    }

    /// 空字串 = 全部網路，其他為網路 id。
    @State private var network = ""
    @State private var span: Span = .month
    @State private var grouping: Grouping = .day
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("範圍", selection: $span) {
                    ForEach(Span.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Picker("單位", selection: $grouping) {
                    ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                Picker("網路", selection: $network) {
                    Text("全部網路").tag("")
                    ForEach(collector.networks) { Text($0.displayName).tag($0.id) }
                }
                .frame(maxWidth: 220)
                Spacer()
                ExportMenu()
            }
            summary
            chart.frame(height: 220)
            table
        }
        .padding(20)
        .task(id: "\(span.rawValue)-\(grouping.rawValue)-\(network)-\(collector.dataVersion)") { reload() }
    }

    /// 選定網路的每日上限；全部網路或沒設定時為 nil。
    private var quota: Double? {
        collector.networks.first { $0.id == network }?.quotaBytes
    }

    private func isOver(_ row: Row) -> Bool {
        grouping == .day && row.total > (quota ?? .infinity)
    }

    private var summary: some View {
        let days = dailyRowsForStats
        let active = days.filter { $0.total > 0 }
        let average = active.isEmpty ? 0 : active.reduce(0) { $0 + $1.total } / Double(active.count)
        let maxDay = days.max { $0.total < $1.total }
        let over = days.filter { $0.total > (quota ?? .infinity) }.count
        return HStack(spacing: 10) {
            StatTile(title: "區間合計", value: settings.format(days.reduce(0) { $0 + $1.total }))
            StatTile(title: "平均每日（有資料的日子）", value: settings.format(average))
            StatTile(title: "最高的一天", value: maxDay.map { settings.format($0.total) } ?? "—", detail: maxDay?.label)
            StatTile(title: "超過上限的天數", value: quota == nil ? "—" : "\(over) 天",
                     detail: quota == nil ? "選擇有設定上限的網路" : nil, tint: quota == nil ? .primary : (over > 0 ? .red : .green))
        }
    }

    private var chart: some View {
        let segments = rows.flatMap { row -> [Segment] in
            var result = [Segment(row: row, kind: "下載", low: 0, high: row.rx),
                          Segment(row: row, kind: "上傳", low: row.rx, high: row.rx + row.tx)]
            if row.calibration > 0 {
                result.append(Segment(row: row, kind: "校正", low: row.rx + row.tx, high: row.total))
            }
            return result
        }
        return Chart {
            ForEach(segments) { segment in
                BarMark(x: .value("日期", segment.row.label),
                        yStart: .value("用量", segment.low / settings.bytesPerGB),
                        yEnd: .value("用量", segment.high / settings.bytesPerGB))
                    .foregroundStyle(by: .value("類別", segment.kind))
            }
            if grouping == .day, let quota {
                RuleMark(y: .value("上限", quota / settings.bytesPerGB))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(["下載": UsageColor.download, "上傳": UsageColor.upload, "校正": Color.gray])
        .chartYAxisLabel(settings.binaryUnits ? "GiB" : "GB")
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(rows.count > 14 && grouping == .day ? String(label.suffix(2)) : label)
                    }
                }
            }
        }
    }

    private var table: some View {
        Table(rows.reversed()) {
            TableColumn(grouping == .day ? "日期" : "期間") { row in
                Text(row.label).foregroundStyle(isOver(row) ? .red : .primary)
            }
            TableColumn("下載") { Text(settings.format($0.rx)).monospacedDigit() }
            TableColumn("上傳") { Text(settings.format($0.tx)).monospacedDigit() }
            TableColumn("合計") { row in
                Text(settings.format(row.total)).monospacedDigit()
                    .foregroundStyle(isOver(row) ? .red : .primary)
            }
            TableColumn("下載峰值") { Text(settings.formatRate($0.peakRx)).monospacedDigit() }
            TableColumn("上傳峰值") { Text(settings.formatRate($0.peakTx)).monospacedDigit() }
        }
    }

    @State private var dailyRowsForStats: [Row] = []

    private func reload() {
        let policy = settings.policy
        let now = Date()
        // 從第一筆紀錄開始，不列出安裝前的空白日子。
        let earliest = policy.dayStart(containing: collector.store.firstRecord() ?? now)
        let from = max(earliest, policy.dayStart(containing: now.addingTimeInterval(-Double(span.rawValue - 1) * 86_400)))
        let filter = network.isEmpty ? nil : network
        var summaries = collector.store.dailySummaries(from: from, to: now, policy: policy, network: filter)
        // 今天用即時數字（包含還沒寫進資料庫的部分）。
        if let index = summaries.firstIndex(where: { $0.day == collector.dayKey }) {
            summaries[index].bytes = filter.map { collector.todayByNetwork[$0] ?? .zero } ?? collector.today
            summaries[index].calibration = filter.map { collector.calibrations[$0] ?? 0 }
                ?? collector.calibrations.values.reduce(0, +)
            summaries[index].peak = collector.peak
        }

        let daily = summaries.map { summary in
            Row(id: summary.day, label: summary.day, start: summary.start,
                rx: Double(summary.bytes.rx), tx: Double(summary.bytes.tx), calibration: summary.calibration,
                peakRx: summary.peak?.rxRate ?? 0, peakTx: summary.peak?.txRate ?? 0, days: 1)
        }
        dailyRowsForStats = daily

        switch grouping {
        case .day:
            // 圖表與表格只顯示 "11-01"。
            rows = daily.map { row in
                var copy = row
                copy.label = String(row.label.dropFirst(5))
                return copy
            }
        case .week, .month:
            let calendar = Calendar.current
            var grouped: [Row] = []
            for row in daily {
                let key: String
                let label: String
                if grouping == .week {
                    let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: row.start)
                    key = "\(parts.yearForWeekOfYear ?? 0)-W\(parts.weekOfYear ?? 0)"
                    let weekStart = calendar.dateInterval(of: .weekOfYear, for: row.start)?.start ?? row.start
                    label = weekStart.formatted(.dateTime.month(.defaultDigits).day()) + " 週"
                } else {
                    let parts = calendar.dateComponents([.year, .month], from: row.start)
                    key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
                    label = key
                }
                if let last = grouped.last, last.id == key {
                    grouped[grouped.count - 1].rx += row.rx
                    grouped[grouped.count - 1].tx += row.tx
                    grouped[grouped.count - 1].calibration += row.calibration
                    grouped[grouped.count - 1].peakRx = max(last.peakRx, row.peakRx)
                    grouped[grouped.count - 1].peakTx = max(last.peakTx, row.peakTx)
                    grouped[grouped.count - 1].days += 1
                } else {
                    grouped.append(Row(id: key, label: label, start: row.start, rx: row.rx, tx: row.tx,
                                       calibration: row.calibration, peakRx: row.peakRx, peakTx: row.peakTx, days: 1))
                }
            }
            rows = grouped
        }
    }
}
