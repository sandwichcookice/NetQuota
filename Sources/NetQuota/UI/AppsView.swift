import NetQuotaCore
import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector
    @Environment(\.theme) private var theme

    enum Range: String, CaseIterable, Identifiable {
        case today = "今日", yesterday = "昨日", week = "7 天", month = "30 天", all = "全部"
        var id: String { rawValue }
    }

    @State private var range: Range = .today
    @State private var apps: [AppUsage] = []
    @State private var lastLiveUpdate = Date.distantPast

    /// 今日的即時排行最多每幾秒更新一次表格：每次取樣都重建整張表，捲動時會卡。
    private static let liveUpdateInterval: TimeInterval = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("範圍", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
                Spacer()
                ExportMenu()
            }

            if apps.isEmpty {
                ContentUnavailableView("尚無資料", systemImage: "square.grid.2x2",
                                       description: Text("程式流量會在 App 執行期間持續記錄。"))
            } else {
                // 比例條直接放在每一列，不再另外畫一張重複的圖表，表格可以顯示更多列。
                AppsTable(apps: apps).equatable().panel()
                HStack(spacing: 12) {
                    Label("下載", systemImage: "square.fill").foregroundStyle(theme.download)
                    Label("上傳", systemImage: "square.fill").foregroundStyle(theme.upload)
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
            }

            Text("各程式流量來自系統的 nettop，只在 NetQuota 執行期間記錄；輔助程序（例如 Chrome Helper、WebKit）會歸到所屬的 App。各程式加總可能與總用量略有差異（系統層級流量、VPN 封裝等），額度以總用量為準。")
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .task(id: "\(range.rawValue)-\(collector.dataVersion)") { reload() }
        .onChange(of: collector.apps) { _, live in
            let now = Date()
            guard range == .today, now.timeIntervalSince(lastLiveUpdate) >= Self.liveUpdateInterval else { return }
            lastLiveUpdate = now
            apps = live
        }
    }

    private func reload() {
        let policy = settings.policy
        let now = Date()
        let todayStart = collector.dayStart
        switch range {
        case .today:
            apps = collector.apps
            lastLiveUpdate = now
        case .yesterday:
            let start = policy.dayStart(containing: todayStart.addingTimeInterval(-3600))
            apps = collector.store.appTotals(from: start, to: todayStart)
        case .week:
            apps = collector.store.appTotals(from: todayStart.addingTimeInterval(-6 * 86_400), to: now.addingTimeInterval(3600))
        case .month:
            apps = collector.store.appTotals(from: todayStart.addingTimeInterval(-29 * 86_400), to: now.addingTimeInterval(3600))
        case .all:
            apps = collector.store.appTotals(from: .distantPast, to: now.addingTimeInterval(3600))
        }
    }
}

/// 程式排行表格。只依 `apps` 比較是否相同，collector 每次取樣讓上層重算時不會重建整張表。
private struct AppsTable: View, Equatable {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.theme) private var theme
    let apps: [AppUsage]
    /// 預設依合計由大到小；點表頭切換。
    @State private var sortOrder = [KeyPathComparator(\AppUsage.bytes.total, order: .reverse)]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.apps == rhs.apps }

    private var sortedApps: [AppUsage] { apps.sorted(using: sortOrder) }
    /// 排序可能不是依合計，比例條以最大的那個為基準。
    private var maxTotal: UInt64 { max(1, apps.map(\.bytes.total).max() ?? 1) }
    private var sum: Double { max(1, apps.reduce(0) { $0 + Double($1.bytes.total) }) }

    var body: some View {
        table
    }

    /// 程式名稱、圖示、比例條；命令列工具加上標籤，和同名的 App 區分。
    private func nameCell(_ app: AppUsage, maxTotal: UInt64) -> some View {
        let isCommandLine = !(app.path?.hasSuffix(".app") ?? false)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                AppIconView(path: app.path, size: 16)
                Text(app.name).lineLimit(1).truncationMode(.middle)
                if isCommandLine {
                    Text("命令列")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(theme.secondary)
                }
            }
            GeometryReader { proxy in
                let width = proxy.size.width * CGFloat(Double(app.bytes.total) / Double(maxTotal))
                let rxShare = app.bytes.total > 0 ? CGFloat(Double(app.bytes.rx) / Double(app.bytes.total)) : 0
                HStack(spacing: 0) {
                    Rectangle().fill(theme.download).frame(width: width * rxShare)
                    Rectangle().fill(theme.upload).frame(width: width * (1 - rxShare))
                }
            }
            .frame(height: 3)
            .padding(.leading, 22)
        }
        .help(app.path ?? app.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCommandLine ? "\(app.name)，命令列工具" : app.name)
    }

    /// 預設風格用原本的系統表格；Hack／Glass 用實心表頭的自訂表格，才能配合深色或透明背景。
    @ViewBuilder
    private var table: some View {
        if theme.kind == .standard { systemTable } else { plainTable }
    }

    private var systemTable: some View {
        Table(sortedApps, sortOrder: $sortOrder) {
            TableColumn("程式", value: \.name) { app in nameCell(app, maxTotal: maxTotal) }
            .width(min: 220)
            TableColumn("下載", value: \.bytes.rx) { Text(settings.format($0.bytes.rx)).monospacedDigit() }.alignment(.numeric)
            TableColumn("上傳", value: \.bytes.tx) { Text(settings.format($0.bytes.tx)).monospacedDigit() }.alignment(.numeric)
            TableColumn("合計", value: \.bytes.total) { Text(settings.format($0.bytes.total)).monospacedDigit() }
            .alignment(.numeric)
            // 佔比與合計同序。
            TableColumn("佔比", value: \.bytes.total) { app in
                Text(String(format: "%.1f%%", Double(app.bytes.total) / sum * 100)).monospacedDigit()
            }
            .alignment(.numeric)
        }
    }

    private var plainTable: some View {
        let byTotal = KeyPathComparator(\AppUsage.bytes.total, order: .reverse)
        return PlainTable(rows: sortedApps, columns: [
            PlainColumn("程式", sort: KeyPathComparator(\.name)) { app in nameCell(app, maxTotal: maxTotal) },
            PlainColumn("下載", width: 90, alignment: .trailing, sort: KeyPathComparator(\.bytes.rx, order: .reverse)) {
                Text(settings.format($0.bytes.rx))
            },
            PlainColumn("上傳", width: 90, alignment: .trailing, sort: KeyPathComparator(\.bytes.tx, order: .reverse)) {
                Text(settings.format($0.bytes.tx))
            },
            PlainColumn("合計", width: 90, alignment: .trailing, sort: byTotal) { Text(settings.format($0.bytes.total)) },
            PlainColumn("佔比", width: 60, alignment: .trailing, sort: byTotal) { app in
                Text(String(format: "%.1f%%", Double(app.bytes.total) / sum * 100))
            },
        ], sortOrder: $sortOrder)
    }
}
