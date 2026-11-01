import Charts
import NetQuotaCore
import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector

    enum Range: String, CaseIterable, Identifiable {
        case today = "今日", yesterday = "昨日", week = "7 天", month = "30 天", all = "全部"
        var id: String { rawValue }
    }

    @State private var range: Range = .today
    @State private var apps: [AppUsage] = []

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
                chart.frame(height: min(CGFloat(min(apps.count, 10)) * 26 + 20, 280))
                table
            }

            Text("各程式流量來自系統的 nettop，只在 NetQuota 執行期間記錄；輔助程序（例如 Chrome Helper、WebKit）會歸到所屬的 App。各程式加總可能與總用量略有差異（系統層級流量、VPN 封裝等），額度以總用量為準。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .task(id: "\(range.rawValue)-\(collector.dataVersion)") { reload() }
        .onChange(of: collector.apps) { _, live in
            if range == .today { apps = live }
        }
    }

    private var chart: some View {
        let top = Array(apps.prefix(10))
        return Chart {
            ForEach(top) { app in
                BarMark(xStart: .value("用量", 0), xEnd: .value("用量", Double(app.bytes.rx) / 1_000_000),
                        y: .value("程式", app.name))
                    .foregroundStyle(by: .value("方向", "下載"))
                BarMark(xStart: .value("用量", Double(app.bytes.rx) / 1_000_000),
                        xEnd: .value("用量", Double(app.bytes.total) / 1_000_000),
                        y: .value("程式", app.name))
                    .foregroundStyle(by: .value("方向", "上傳"))
            }
        }
        .chartForegroundStyleScale(["下載": UsageColor.download, "上傳": UsageColor.upload])
        .chartXAxisLabel("MB")
        .chartYScale(domain: top.map(\.name))
    }

    private var table: some View {
        let sum = max(1, apps.reduce(0) { $0 + Double($1.bytes.total) })
        return Table(apps) {
            TableColumn("程式") { app in
                HStack(spacing: 6) {
                    AppIconView(path: app.path, size: 16)
                    Text(app.name).lineLimit(1)
                }
            }
            .width(min: 180)
            TableColumn("下載") { Text(settings.format($0.bytes.rx)).monospacedDigit() }
            TableColumn("上傳") { Text(settings.format($0.bytes.tx)).monospacedDigit() }
            TableColumn("合計") { Text(settings.format($0.bytes.total)).monospacedDigit() }
            TableColumn("佔比") { app in
                Text(String(format: "%.1f%%", Double(app.bytes.total) / sum * 100)).monospacedDigit()
            }
        }
    }

    private func reload() {
        let policy = settings.policy
        let now = Date()
        let todayStart = collector.dayStart
        switch range {
        case .today:
            apps = collector.apps
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
