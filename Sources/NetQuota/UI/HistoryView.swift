import Charts
import NetQuotaCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector
    @Environment(\.theme) private var theme

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

    struct Row: Identifiable, Equatable {
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

    /// 空字串 = 全部網路，其他為網路 id。
    @State private var network = ""
    @State private var didChooseDefaultNetwork = false
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
            // 圖表與表格只在重新查詢後才變；抽成 Equatable 的子畫面，每 2 秒的即時更新不必重畫。
            HistoryDetail(rows: rows, grouping: grouping, quota: quota).equatable()
        }
        .padding(20)
        .task(id: "\(span.rawValue)-\(grouping.rawValue)-\(network)-\(collector.dataVersion)") { reload() }
        // 預設看目前所在的網路，「超過上限的天數」才有意義。
        .onAppear {
            guard !didChooseDefaultNetwork else { return }
            didChooseDefaultNetwork = true
            network = collector.focusNetworkID ?? ""
        }
    }

    /// 選定網路的每日上限；全部網路或沒設定時為 nil。
    private var quota: Double? {
        collector.effectiveQuota(collector.networks.first { $0.id == network })
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
            if settings.isQuotaMode {
                StatTile(title: "超過上限的天數", value: quota == nil ? "—" : "\(over) 天",
                         detail: quota == nil ? "選擇有設定上限的網路" : nil, tint: quota == nil ? nil : (over > 0 ? theme.bad : theme.good))
            } else {
                StatTile(title: "有資料的天數", value: "\(active.count) 天", detail: "共 \(days.count) 天")
            }
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
            Row(id: summary.day, label: shortDayLabel(summary.day), start: summary.start,
                rx: Double(summary.bytes.rx), tx: Double(summary.bytes.tx), calibration: summary.calibration,
                peakRx: summary.peak?.rxRate ?? 0, peakTx: summary.peak?.txRate ?? 0, days: 1)
        }
        dailyRowsForStats = daily

        switch grouping {
        case .day:
            rows = daily
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
                    label = "\(weekStart.shortDate) 起"
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

/// 歷史頁的長條圖與表格。
private struct HistoryDetail: View, Equatable {
    typealias Row = HistoryView.Row
    typealias Grouping = HistoryView.Grouping

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.theme) private var theme
    let rows: [Row]
    let grouping: Grouping
    let quota: Double?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows && lhs.grouping == rhs.grouping && lhs.quota == rhs.quota
    }

    private struct Segment: Identifiable {
        let row: Row
        let kind: String
        let low: Double
        let high: Double
        var id: String { "\(row.id)-\(kind)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            chart.frame(height: 220).panel()
            table.panel()
        }
    }

    private func isOver(_ row: Row) -> Bool {
        grouping == .day && row.total > (quota ?? .infinity)
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
                    .foregroundStyle(theme.bad.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(["下載": theme.download, "上傳": theme.upload, "校正": Color.gray])
        .accessibilityLabel("每\(grouping.rawValue)用量")
        .accessibilityValue(rows.map { "\($0.label) \(settings.format($0.total))" }.joined(separator: "，"))
        .chartYAxisLabel(settings.binaryUnits ? "GiB" : "GB")
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        // 天數多時只顯示「日」，避免標籤擠在一起。
                        Text(rows.count > 14 && grouping == .day ? String(label.split(separator: "/").last ?? "") : label)
                    }
                }
            }
        }
    }

    /// 預設風格用原本的系統表格；Hack／Glass 用實心表頭的自訂表格。
    @ViewBuilder
    private var table: some View {
        if theme.kind == .standard { systemTable } else { plainTable }
    }

    private var systemTable: some View {
        Table(rows.reversed()) {
            TableColumn(grouping == .day ? "日期" : "期間") { row in
                Text(row.label).foregroundStyle(isOver(row) ? theme.bad : .primary)
            }
            TableColumn("下載") { Text(settings.format($0.rx)).monospacedDigit() }.alignment(.numeric)
            TableColumn("上傳") { Text(settings.format($0.tx)).monospacedDigit() }.alignment(.numeric)
            TableColumn("合計") { row in
                Text(settings.format(row.total)).monospacedDigit()
                    .foregroundStyle(isOver(row) ? theme.bad : .primary)
            }
            .alignment(.numeric)
            TableColumn("下載峰值") { Text(settings.formatRate($0.peakRx)).monospacedDigit() }.alignment(.numeric)
            TableColumn("上傳峰值") { Text(settings.formatRate($0.peakTx)).monospacedDigit() }.alignment(.numeric)
        }
    }

    private var plainTable: some View {
        PlainTable(rows: Array(rows.reversed()), columns: [
            PlainColumn(grouping == .day ? "日期" : "期間") { row in
                Text(row.label).foregroundStyle(isOver(row) ? theme.bad : .primary)
            },
            PlainColumn("下載", width: 90, alignment: .trailing) { Text(settings.format($0.rx)) },
            PlainColumn("上傳", width: 90, alignment: .trailing) { Text(settings.format($0.tx)) },
            PlainColumn("合計", width: 90, alignment: .trailing) { row in
                Text(settings.format(row.total)).foregroundStyle(isOver(row) ? theme.bad : .primary)
            },
            PlainColumn("下載峰值", width: 100, alignment: .trailing) { Text(settings.formatRate($0.peakRx)) },
            PlainColumn("上傳峰值", width: 100, alignment: .trailing) { Text(settings.formatRate($0.peakTx)) },
        ])
    }
}
