import Charts
import NetQuotaCore
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector
    @Environment(\.theme) private var theme

    fileprivate struct CumulativePoint: Identifiable, Equatable {
        let date: Date
        let value: Double
        let series: String
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    fileprivate struct BarPoint: Identifiable, Equatable {
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
    @AppStorage("onboardingDismissed") private var onboardingDismissed = false
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
                     quota: collector.effectiveQuota(network),
                     forecast: id == collector.focusNetworkID ? collector.forecast : nil,
                     networkID: id)
    }

    var body: some View {
        let scope = scope
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !onboardingDismissed { onboarding }
                networkPicker
                hero(scope)
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
                // 圖表只在重新查詢後才變，抽成 Equatable 的子畫面，每 2 秒的即時數字更新時不必重畫。
                section("累積用量（虛線為依目前速度的預測）") {
                    CumulativeChart(points: cumulative, quota: scope.quota, domain: collector.dayStart...collector.dayEnd)
                        .equatable()
                        .frame(height: 220).glow().panel()
                }
                section("每 \(Self.barMinutes) 分鐘用量") {
                    BarChart(bars: bars, minutes: Self.barMinutes, domain: collector.dayStart...collector.dayEnd)
                        .equatable()
                        .frame(height: 170).panel()
                }
            }
            .padding(20)
        }
        .task(id: "\(collector.dataVersion)-\(selection)-\(collector.focusNetworkID ?? "")") { reload() }
    }

    private var onboarding: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "menubar.rectangle").font(.title2).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("NetQuota 會常駐在選單列").font(.headline)
                Text("如果選單列太滿、圖示被瀏海擋住，可以用 Spotlight 搜尋「NetQuota」打開這個視窗；也可以在系統設定 → 選單列關掉用不到的項目。")
                    .font(.callout).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("知道了") { onboardingDismissed = true }
        }
        .themedCard()
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

    /// 主要指標：額度模式回答「還剩多少、今天會不會超過」；流量監測模式回答「今天用了多少」。
    private func hero(_ scope: Scope) -> some View {
        HStack(alignment: .center, spacing: 22) {
            if settings.isQuotaMode {
                UsageRing(fraction: scope.fraction, usedText: settings.format(scope.used),
                          quotaText: scope.quota.map { settings.format($0) }, lineWidth: 11)
                    .frame(width: 118, height: 118)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(scope.remaining.map { "剩 \(settings.format($0))" } ?? "今日 \(settings.format(scope.used))")
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.isHack ? theme.accent : .primary)
                    .glow()
                Text(scope.quota.map {
                    "已用 \(settings.format(scope.used)) / 上限 \(settings.format($0)) · \(Int((scope.fraction * 100).rounded()))%"
                } ?? (settings.isQuotaMode ? "\(scope.name) 沒有設定上限"
                                           : "\(scope.name) · 下載 \(settings.format(scope.bytes.rx)) · 上傳 \(settings.format(scope.bytes.tx))"))
                    .font(.callout).monospacedDigit().foregroundStyle(theme.secondary)
                status(scope)
                Text(methodText(scope) + " · \(collector.dayEnd.shortTime) 歸零")
                    .font(.caption).foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(padding: 16)
        .accessibilityElement(children: .combine)
    }

    /// 狀態句：除了顏色也用圖示表示，色盲也分得出來。
    @ViewBuilder
    private func status(_ scope: Scope) -> some View {
        Group {
            if let quota = scope.quota, scope.used >= quota {
                Label("已超過上限 \(settings.format(scope.used - quota))", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(theme.bad)
            } else if scope.quota == nil, settings.isQuotaMode {
                Label("只記錄、不提醒", systemImage: "infinity").foregroundStyle(theme.secondary)
            } else if let forecast = scope.forecast, scope.quota == nil {
                Label("照目前趨勢今天約用 \(settings.format(forecast.projectedTotal))", systemImage: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(theme.secondary)
            } else if let forecast = scope.forecast {
                if let exceedAt = forecast.exceedAt {
                    Label("照目前趨勢，預計 \(exceedAt.shortTime) 超過上限", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warn)
                } else {
                    Label("照目前趨勢今天約用 \(settings.format(forecast.projectedTotal))，不會超過",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(theme.good)
                }
            } else if scope.networkID != collector.focusNetworkID {
                Label("只預測目前所在的網路", systemImage: "info.circle").foregroundStyle(theme.secondary)
            } else {
                Label("收集資料中，約 2 分鐘後顯示預測", systemImage: "hourglass").foregroundStyle(theme.secondary)
            }
        }
        .font(.callout.weight(.medium))
        .glow()
    }

    private func methodText(_ scope: Scope) -> String {
        switch scope.forecast?.method {
        case .history(let days): "依過去 \(days) 天同時段推估"
        case .recentRate: "依最近 30 分鐘的速度推估（歷史不足 3 天）"
        case nil: "今日"
        }
    }

    /// 次要數字。
    private func tiles(_ scope: Scope) -> some View {
        let peak = collector.peak
        return HStack(spacing: 10) {
            StatTile(title: "下載", value: settings.format(scope.bytes.rx), tint: theme.download)
            StatTile(title: "上傳", value: settings.format(scope.bytes.tx), tint: theme.upload)
            // 峰值為所有網路合計的速率。
            StatTile(title: "下載峰值", value: settings.formatRate(peak.rxRate), detail: peak.rxAt.map { "於 \($0.shortTime)" })
            StatTile(title: "上傳峰值", value: settings.formatRate(peak.txRate), detail: peak.txAt.map { "於 \($0.shortTime)" })
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            content()
        }
    }

    /// 平滑累積曲線：以 1 分鐘取樣後做時間移動平均，再每 5 分鐘取一點交給圖表做單調插值。
    /// 視窗在頭尾對稱縮小，所以起點與最後的即時值完全不變，預測線能無縫接上；
    /// 視窗兩端只會往後移，遞增的累積量平均後仍然遞增。
    private static func smoothed(_ raw: [(date: Date, value: Double)],
                                 halfWindowMinutes: Int = 10, strideMinutes: Int = 5) -> [(date: Date, value: Double)] {
        guard let start = raw.first?.date, let last = raw.last, raw.count > 2 else { return raw }
        let count = Int(last.date.timeIntervalSince(start) / 60) + 1
        guard count > 2 else { return raw }

        // 線性內插到每分鐘一點。
        var samples = [Double](repeating: 0, count: count)
        var j = 0
        for i in 0..<count {
            let date = start.addingTimeInterval(Double(i) * 60)
            while j + 1 < raw.count - 1, raw[j + 1].date <= date { j += 1 }
            let a = raw[j], b = raw[j + 1]
            let span = b.date.timeIntervalSince(a.date)
            let t = span > 0 ? min(1, max(0, date.timeIntervalSince(a.date) / span)) : 1
            samples[i] = a.value + (b.value - a.value) * t
        }

        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + samples[i] }
        func average(_ i: Int) -> Double {
            let h = min(halfWindowMinutes, i, count - 1 - i)
            return (prefix[i + h + 1] - prefix[i - h]) / Double(2 * h + 1)
        }

        var result = stride(from: 0, to: count, by: strideMinutes).map {
            (date: start.addingTimeInterval(Double($0) * 60), value: average($0))
        }
        // 接近尾端時每分鐘一點，讓縮小中的視窗平順收斂到即時值。
        for i in max(count - halfWindowMinutes, 1)..<count where i % strideMinutes != 0 {
            result.append((start.addingTimeInterval(Double(i) * 60), average(i)))
        }
        result.sort { $0.date < $1.date }
        if last.date > result.last!.date { result.append(last) }
        return result
    }

    private func reload() {
        let now = Date()
        let scope = scope
        let minutes = scope.networkID.map {
            collector.store.minuteTotals(from: collector.dayStart, to: collector.dayEnd, network: $0)
        } ?? collector.store.minuteTotals(from: collector.dayStart, to: collector.dayEnd)

        var running = scope.calibration
        var raw = [(date: collector.dayStart, value: max(0, running))]
        for row in minutes {
            running += Double(row.bytes.total)
            raw.append((row.date.addingTimeInterval(60), max(0, running)))
        }
        // 最後一點用即時數字，包含尚未寫入資料庫的這一分鐘。
        raw.append((now, scope.used))
        var points = Self.smoothed(raw).map { CumulativePoint(date: $0.date, value: $0.value, series: "實際") }
        if let forecast = scope.forecast {
            // 預測曲線從目前的實際值接續（曲線第一點是預測當下的值，可能比畫面上的即時值早幾秒）。
            points.append(CumulativePoint(date: now, value: scope.used, series: "預測"))
            for point in forecast.curve.dropFirst() where point.date > now {
                points.append(CumulativePoint(date: point.date, value: point.total - forecast.curve[0].total + scope.used,
                                              series: "預測"))
            }
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

/// 今日累積用量曲線：實際值與預測虛線，加上上限線。
private struct CumulativeChart: View, Equatable {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.theme) private var theme
    let points: [TodayView.CumulativePoint]
    let quota: Double?
    let domain: ClosedRange<Date>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.quota == rhs.quota && lhs.domain == rhs.domain
    }

    var body: some View {
        let used = points.last { $0.series == "實際" }?.value ?? 0
        let projected = points.last { $0.series == "預測" }?.value
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("時間", point.date), y: .value("用量", point.value / settings.bytesPerGB),
                         series: .value("系列", point.series))
                    .foregroundStyle(point.series == "實際" ? theme.accent : theme.warn)
                    .lineStyle(point.series == "實際" ? StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        : StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    // 單調插值：曲線圓滑但不會往回彎（累積量不會減少）。
                    .interpolationMethod(.monotone)
            }
            if let quota {
                RuleMark(y: .value("上限", quota / settings.bytesPerGB))
                    .foregroundStyle(theme.bad.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("上限 \(settings.format(quota))").font(.caption2).foregroundStyle(theme.bad)
                    }
            }
        }
        .chartXScale(domain: domain)
        // 刻度上限取上限、預測與實際值中最大的，留一點空間，曲線不會擠在底部。
        .chartYScale(domain: 0...max(0.5, max(quota ?? 0, projected ?? 0, used) * 1.1 / settings.bytesPerGB))
        .chartYAxisLabel(settings.binaryUnits ? "GiB" : "GB")
        .accessibilityLabel("今日累積用量")
        .accessibilityValue(projected.map { "目前 \(settings.format(used))，預估今天 \(settings.format($0))" }
            ?? "目前 \(settings.format(used))")
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
    }
}

/// 每段時間的用量長條：下載在下、上傳疊在上面。
private struct BarChart: View, Equatable {
    @Environment(\.theme) private var theme
    let bars: [TodayView.BarPoint]
    let minutes: Int
    let domain: ClosedRange<Date>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bars == rhs.bars && lhs.minutes == rhs.minutes && lhs.domain == rhs.domain
    }

    var body: some View {
        Chart(bars) { bar in
            RectangleMark(xStart: .value("開始", bar.date), xEnd: .value("結束", bar.end),
                    yStart: .value("用量", bar.low), yEnd: .value("用量", bar.high))
                .foregroundStyle(by: .value("方向", bar.direction))
        }
        .chartForegroundStyleScale(["下載": theme.download, "上傳": theme.upload])
        .chartXScale(domain: domain)
        .chartYAxisLabel("MB")
        .accessibilityLabel("每 \(minutes) 分鐘用量")
        .accessibilityValue("今天共 \(bars.count / 2) 個時段有用量")
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
    }
}
