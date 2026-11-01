import Charts
import NetQuotaCore
import SwiftUI

/// 點選單列圖示後出現的面板。
struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .center, spacing: 16) {
                UsageRing(fraction: collector.fraction,
                          usedText: settings.format(collector.used),
                          quotaText: settings.format(collector.quota))
                    .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 6) {
                    labeled("arrow.down", UsageColor.download, "下載", settings.format(collector.today.rx))
                    labeled("arrow.up", UsageColor.upload, "上傳", settings.format(collector.today.tx))
                    labeled("gauge.with.needle", .secondary, "剩餘", settings.format(collector.remaining))
                    if collector.calibration != 0 {
                        Text("含手動校正 \(settings.format(collector.calibration))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            forecastBox
            speedSection
            Divider()
            topApps
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("今日用量").font(.headline)
            Spacer()
            Text("\(collector.dayStart.shortTime) 起算")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func labeled(_ symbol: String, _ tint: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    @ViewBuilder
    private var forecastBox: some View {
        let used = collector.used
        let quota = collector.quota
        Group {
            if used >= quota {
                Label("已超過今日額度 \(settings.format(used - quota))", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            } else if let forecast = collector.forecast {
                if let exceedAt = forecast.exceedAt {
                    Label("照目前速度，預計 \(exceedAt.shortTime) 用完額度", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("照目前速度，今天約用 \(settings.format(forecast.projectedTotal))", systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("收集資料中，約 2 分鐘後顯示預測", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("即時").font(.caption).foregroundStyle(.secondary)
                Text("↓ \(settings.formatRate(collector.rxRate))").foregroundStyle(UsageColor.download)
                Text("↑ \(settings.formatRate(collector.txRate))").foregroundStyle(UsageColor.upload)
                Spacer()
            }
            .font(.callout.monospacedDigit())

            Chart(collector.recentRates) { point in
                AreaMark(x: .value("時間", point.date), y: .value("速率", point.rx), series: .value("方向", "下載"))
                    .foregroundStyle(UsageColor.download.opacity(0.35))
                LineMark(x: .value("時間", point.date), y: .value("速率", point.tx), series: .value("方向", "上傳"))
                    .foregroundStyle(UsageColor.upload)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 40)

            HStack {
                Text("今日峰值").font(.caption).foregroundStyle(.secondary)
                Text("↓ \(settings.formatRate(collector.peak.rxRate))")
                Text(collector.peak.rxAt?.shortTime ?? "").foregroundStyle(.secondary)
                Text("↑ \(settings.formatRate(collector.peak.txRate))")
                Text(collector.peak.txAt?.shortTime ?? "").foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
        }
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日用量最多的程式").font(.caption).foregroundStyle(.secondary)
            let top = Array(collector.apps.prefix(5))
            if top.isEmpty {
                Text("尚無資料").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(top) { app in
                    AppUsageRow(app: app, maxTotal: top.first?.bytes.total ?? 1, format: { settings.format($0) })
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                open(.today)
            } label: {
                Label("儀表板", systemImage: "chart.bar.xaxis")
            }
            Button {
                open(.settings)
            } label: {
                Label("設定", systemImage: "gearshape")
            }
            Spacer()
            Button("結束") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
    }

    private func open(_ tab: DashboardTab) {
        model.showDashboard(tab)
    }
}
