import Charts
import NetQuotaCore
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector
    @Environment(\.theme) private var theme

    private struct CumulativePoint: Identifiable {
        let date: Date
        let value: Double
        let series: String
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    private struct BarPoint: Identifiable {
        let date: Date
        let end: Date
        /// MB
        let low: Double
        let high: Double
        let direction: String
        var id: String { "\(direction)-\(date.timeIntervalSince1970)" }
    }

    /// 要看的網路：空字串 = 目前的網路，`allNetworks` = 全部合計，其他為網路 id。
    @State private var selection = ""
    @State private var cumulative: [CumulativePoint] = []
    @State private var bars: [BarPoint] = []

    private static let allNetworks = "*"
    private static let barMinutes = 15

    /// 目前選擇的範圍算出來的數字。
    private struct Scope {
        var name: String
        var bytes: ByteCounts
        var calibration: Double
        var quota: Double?
        var forecast: Forecast?
        var networkID: String?

        var used: Double { max(0, Double(bytes.total) + calibration) }
        var remaining: Double? { quota.map { max(0, $0 - used) } }
        var fraction: Double { quota.map { $0 > 0 ? used / $0 : 0 } ?? 0 }
    }

    private var scope: Scope {
        if selection == Self.allNetworks {
            return Scope(name: "全部網路", bytes: collector.today,
                         calibration: collector.calibrations.values.reduce(0, +), quota: nil, forecast: nil, networkID: nil)
        }
        let id = selection.isEmpty ? collector.focusNetworkID : selection
        let network = collector.networks.first { $0.id == id }
        return Scope(name: network?.displayName ?? "未連線",
                     bytes: id.flatMap { collector.todayByNetwork[$0] } ?? .zero,
                     calibration: id.flatMap { collector.calibrations[$0] } ?? 0,
                     quota: network?.quotaBytes,
                     forecast: id == collector.focusNetworkID ? collector.forecast : nil,
                     networkID: id)
    }

    var body: some View {
        let scope = scope
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                networkPicker
                tiles(scope)
                if collector.networkUsages.count > 1 {
                    section("今日各網路") {
                        VStack(spacing: 8) {
                            ForEach(collector.networkUsages) { usage in
                                NetworkUsageRow(usage: usage, format: { settings.format($0) })
                            }
                        }
                        .panel()
                    }
                }
                if let note = collector.recoveredNote {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(theme.secondary)
                }
                section("累積用量（虛線為依目前速度的預測）") { cumulativeChart(scope).frame(height: 220).glow().panel() }
                section("每 \(Self.barMinutes) 分鐘用量") { barChart.frame(height: 170).panel() }
            }
            .padding(20)
        }
        .task(id: "\(collector.dataVersion)-\(selection)-\(collector.focusNetworkID ?? "")") { reload() }
    }

    private var networkPicker: some View {
        HStack {
            Picker("網路", selection: $selection) {
                Text("目前網路（\(collector.focusName)）").tag("")
                Text("全部網路").tag(Self.allNetworks)
                Divider()
                ForEach(collector.networks.filter { $0.id != collector.focusNetworkID }) { network in
                    Text(network.displayName).tag(network.id)
                }
            }
            .fixedSize()
            Spacer()
        }
    }

    private func tiles(_ scope: Scope) -> some View {
        let peak = collector.peak
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatTile(title: "今日已用", value: settings.format(scope.used),
                         detail: scope.quota.map { "\(Int((scope.fraction * 100).rounded()))%（上限 \(settings.format($0))）" }
                             ?? "未設定上限",
                         tint: scope.quota == nil ? nil : theme.forFraction(scope.fraction))
                StatTile(title: "剩餘", value: scope.remaining.map { settings.format($0) } ?? "不限制",
                         detail: "\(collector.dayEnd.shortTime) 歸零")
                StatTile(title: "下載", value: settings.format(scope.bytes.rx), tint: theme.download)
                StatTile(title: "上傳", value: settings.format(scope.bytes.tx), tint: theme.upload)
            }
            HStack(spacing: 10) {
                // 峰值為所有網路合計的速率。
                StatTile(title: "下載峰值", value: settings.formatRate(peak.rxRate), detail: peak.rxAt.map { "於 \($0.shortTime)" })
                StatTile(title: "上傳峰值", value: settings.formatRate(peak.txRate), detail: peak.txAt.map { "於 \($0.shortTime)" })
                StatTile(title: "預估今日總量", value: scope.forecast.map { settings.format($0.projectedTotal) } ?? "—",
                         detail: scope.forecast.map { "近期 \(settings.formatRate($0.rate))" },
                         tint: (scope.forecast?.projectedTotal ?? 0) > (scope.quota ?? .infinity) ? theme.warn : nil)
                exhaustTile(scope)
            }
        }
    }

    private func exhaustTile(_ scope: Scope) -> StatTile {
        guard let quota = scope.quota else {
            return StatTile(title: "預計用完", value: "—", detail: "沒有設定上限")
        }
        if scope.used >= quota {
            return StatTile(title: "預計用完", value: "已超過", tint: theme.bad)
        }
        guard let forecast = scope.forecast else {
            return StatTile(title: "預計用完", value: "—",
                            detail: scope.networkID == collector.focusNetworkID ? "收集約 2 分鐘資料後顯示" : "只預測目前所在的網路")
        }
        if let exceedAt = forecast.exceedAt {
            return StatTile(title: "預計用完", value: exceedAt.shortTime, detail: "照目前速度", tint: theme.bad)
        }
        return StatTile(title: "預計用完", value: "今天不會", detail: "照目前速度", tint: theme.good)
    }

    private func cumulativeChart(_ scope: Scope) -> some View {
        Chart {
            ForEach(cumulative) { point in
                LineMark(x: .value("時間", point.date), y: .value("用量", point.value / settings.bytesPerGB),
                         series: .value("系列", point.series))
                    .foregroundStyle(point.series == "實際" ? theme.accent : theme.warn)
                    .lineStyle(point.series == "實際" ? StrokeStyle(lineWidth: 2) : StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            if let quota = scope.quota {
                RuleMark(y: .value("上限", quota / settings.bytesPerGB))
                    .foregroundStyle(theme.bad.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("上限 \(settings.format(quota))").font(.caption2).foregroundStyle(theme.bad)
                    }
            }
        }
        .chartXScale(domain: collector.dayStart...collector.dayEnd)
        .chartYAxisLabel(settings.binaryUnits ? "GiB" : "GB")
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
    }

    private var barChart: some View {
        Chart(bars) { bar in
            // 下載在下、上傳疊在上面。
            RectangleMark(xStart: .value("開始", bar.date), xEnd: .value("結束", bar.end),
                    yStart: .value("用量", bar.low), yEnd: .value("用量", bar.high))
                .foregroundStyle(by: .value("方向", bar.direction))
        }
        .chartForegroundStyleScale(["下載": theme.download, "上傳": theme.upload])
        .chartXScale(domain: collector.dayStart...collector.dayEnd)
        .chartYAxisLabel("MB")
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            content()
        }
    }

    private func reload() {
        let now = Date()
        let scope = scope
        let minutes = scope.networkID.map {
            collector.store.minuteTotals(from: collector.dayStart, to: collector.dayEnd, network: $0)
        } ?? collector.store.minuteTotals(from: collector.dayStart, to: collector.dayEnd)

        var running = scope.calibration
        var points = [CumulativePoint(date: collector.dayStart, value: max(0, running), series: "實際")]
        for row in minutes {
            running += Double(row.bytes.total)
            points.append(CumulativePoint(date: row.date.addingTimeInterval(60), value: max(0, running), series: "實際"))
        }
        // 最後一點用即時數字，包含尚未寫入資料庫的這一分鐘。
        points.append(CumulativePoint(date: now, value: scope.used, series: "實際"))
        if let forecast = scope.forecast {
            points.append(CumulativePoint(date: now, value: scope.used, series: "預測"))
            points.append(CumulativePoint(date: collector.dayEnd, value: forecast.projectedTotal, series: "預測"))
        }
        cumulative = points

        let bucketSeconds = Double(Self.barMinutes * 60)
        var buckets: [Date: ByteCounts] = [:]
        for row in minutes {
            let offset = (row.date.timeIntervalSince(collector.dayStart) / bucketSeconds).rounded(.down) * bucketSeconds
            buckets[collector.dayStart.addingTimeInterval(offset), default: .zero] += row.bytes
        }
        bars = buckets.keys.sorted().flatMap { date in
            let bytes = buckets[date]!
            let start = date.addingTimeInterval(30)
            let end = date.addingTimeInterval(bucketSeconds - 30)
            let rx = Double(bytes.rx) / 1_000_000
            let total = Double(bytes.total) / 1_000_000
            return [BarPoint(date: start, end: end, low: 0, high: rx, direction: "下載"),
                    BarPoint(date: start, end: end, low: rx, high: total, direction: "上傳")]
        }
    }
}
