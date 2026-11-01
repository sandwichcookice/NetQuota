import Charts
import NetQuotaCore
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector

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

    @State private var cumulative: [CumulativePoint] = []
    @State private var bars: [BarPoint] = []

    private static let barMinutes = 15

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                tiles
                if let note = collector.recoveredNote {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                section("累積用量（虛線為依目前速度的預測）") { cumulativeChart.frame(height: 220) }
                section("每 \(Self.barMinutes) 分鐘用量") { barChart.frame(height: 170) }
            }
            .padding(20)
        }
        .task(id: collector.dataVersion) { reload() }
    }

    private var tiles: some View {
        let peak = collector.peak
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatTile(title: "今日已用", value: settings.format(collector.used),
                         detail: "\(Int((collector.fraction * 100).rounded()))%（上限 \(settings.format(collector.quota))）",
                         tint: UsageColor.forFraction(collector.fraction))
                StatTile(title: "剩餘", value: settings.format(collector.remaining),
                         detail: "\(collector.dayEnd.shortTime) 歸零")
                StatTile(title: "下載", value: settings.format(collector.today.rx), tint: UsageColor.download)
                StatTile(title: "上傳", value: settings.format(collector.today.tx), tint: UsageColor.upload)
            }
            HStack(spacing: 10) {
                StatTile(title: "下載峰值", value: settings.formatRate(peak.rxRate), detail: peak.rxAt.map { "於 \($0.shortTime)" })
                StatTile(title: "上傳峰值", value: settings.formatRate(peak.txRate), detail: peak.txAt.map { "於 \($0.shortTime)" })
                StatTile(title: "預估今日總量", value: collector.forecast.map { settings.format($0.projectedTotal) } ?? "—",
                         detail: collector.forecast.map { "近期 \(settings.formatRate($0.rate))" },
                         tint: (collector.forecast?.projectedTotal ?? 0) > collector.quota ? .orange : .primary)
                exhaustTile
            }
        }
    }

    private var exhaustTile: StatTile {
        if collector.used >= collector.quota {
            return StatTile(title: "預計用完", value: "已超過", tint: .red)
        }
        guard let forecast = collector.forecast else {
            return StatTile(title: "預計用完", value: "—", detail: "收集約 2 分鐘資料後顯示")
        }
        if let exceedAt = forecast.exceedAt {
            return StatTile(title: "預計用完", value: exceedAt.shortTime, detail: "照目前速度", tint: .red)
        }
        return StatTile(title: "預計用完", value: "今天不會", detail: "照目前速度", tint: .green)
    }

    private var cumulativeChart: some View {
        Chart {
            ForEach(cumulative) { point in
                LineMark(x: .value("時間", point.date), y: .value("用量", point.value / settings.bytesPerGB),
                         series: .value("系列", point.series))
                    .foregroundStyle(point.series == "實際" ? Color.accentColor : Color.orange)
                    .lineStyle(point.series == "實際" ? StrokeStyle(lineWidth: 2) : StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            RuleMark(y: .value("上限", collector.quota / settings.bytesPerGB))
                .foregroundStyle(.red.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("上限 \(settings.format(collector.quota))").font(.caption2).foregroundStyle(.red)
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
        .chartForegroundStyleScale(["下載": UsageColor.download, "上傳": UsageColor.upload])
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
            Text(title).font(.headline)
            content()
        }
    }

    private func reload() {
        let now = Date()
        let minutes = collector.store.minuteTotals(from: collector.dayStart, to: collector.dayEnd)

        var running = collector.calibration
        var points = [CumulativePoint(date: collector.dayStart, value: max(0, running), series: "實際")]
        for row in minutes {
            running += Double(row.bytes.total)
            points.append(CumulativePoint(date: row.date.addingTimeInterval(60), value: max(0, running), series: "實際"))
        }
        // 最後一點用即時數字，包含尚未寫入資料庫的這一分鐘。
        points.append(CumulativePoint(date: now, value: collector.used, series: "實際"))
        if let forecast = collector.forecast {
            points.append(CumulativePoint(date: now, value: collector.used, series: "預測"))
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
