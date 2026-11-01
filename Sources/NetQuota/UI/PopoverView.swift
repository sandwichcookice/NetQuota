import Charts
import NetQuotaCore
import SwiftUI

/// 點選單列圖示後出現的面板。
struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .center, spacing: 16) {
                UsageRing(fraction: collector.fraction,
                          usedText: settings.format(collector.used),
                          quotaText: collector.quota.map { settings.format($0) })
                    .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 6) {
                    labeled("arrow.down", theme.download, "下載", settings.format(collector.focusBytes.rx))
                    labeled("arrow.up", theme.upload, "上傳", settings.format(collector.focusBytes.tx))
                    labeled("gauge.with.needle", theme.secondary, "剩餘", collector.remaining.map { settings.format($0) } ?? "不限制")
                    if collector.calibration != 0 {
                        Text("含手動校正 \(settings.format(collector.calibration))")
                            .font(.caption2).foregroundStyle(theme.secondary)
                    }
                }
            }
            .themedCard()
            forecastBox
            networksSection
            speedSection
            divider
            topApps
            divider
            footer
        }
        .padding(16)
        .frame(width: 340)
        // 預設與 Glass 不加自訂背景：系統的彈出視窗本身就是 Liquid Glass（Apple 建議移除自訂背景）。
        .background {
            if theme.isHack { HackBackground(theme: theme) }
        }
    }

    @ViewBuilder
    private var divider: some View {
        if theme.isHack {
            Text(String(repeating: "─", count: 44)).font(.caption2).foregroundStyle(theme.secondary.opacity(0.6)).lineLimit(1)
        } else {
            Divider()
        }
    }

    @ViewBuilder
    private var header: some View {
        if theme.isHack {
            // 終端機提示字元風格
            HStack(spacing: 0) {
                Text("root@").foregroundStyle(theme.secondary)
                Text(collector.currentNetwork == nil ? "offline" : collector.focusName).foregroundStyle(theme.accent).glow()
                Text(":~$ netquota --today ").foregroundStyle(theme.secondary)
                BlinkingCursor()
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                Image(systemName: collector.currentNetwork == nil ? "wifi.slash" : NetworkIcon.symbol(for: collector.currentNetwork?.interface))
                    .foregroundStyle(.secondary)
                Text(collector.focusName).font(.headline).lineLimit(1)
                if collector.currentNetwork == nil {
                    Text("未連線").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("今日 · \(collector.dayStart.shortTime) 起算")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 今天用過的其他網路，以及全部合計。
    @ViewBuilder
    private var networksSection: some View {
        let others = collector.networkUsages.filter { !$0.isCurrent }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(others) { usage in
                    NetworkUsageRow(usage: usage, format: { settings.format($0) })
                }
                HStack {
                    Text(theme.label("全部網路合計")).foregroundStyle(theme.secondary)
                    Spacer()
                    Text(settings.format(collector.totalUsed)).monospacedDigit()
                }
                .font(.caption)
            }
        }
    }

    private func labeled(_ symbol: String, _ tint: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14).glow(tint)
            Text(title).foregroundStyle(theme.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    @ViewBuilder
    private var forecastBox: some View {
        let used = collector.used
        Group {
            if collector.quota == nil {
                Label("這個網路沒有設定上限，可在設定 → 網路裡設定", systemImage: "infinity")
                    .foregroundStyle(theme.secondary)
            } else if let quota = collector.quota, used >= quota {
                Label("已超過今日額度 \(settings.format(used - quota))", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(theme.bad).glow(theme.bad)
            } else if let forecast = collector.forecast {
                if let exceedAt = forecast.exceedAt {
                    Label("照目前速度，預計 \(exceedAt.shortTime) 用完額度", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warn).glow(theme.warn)
                } else {
                    Label("照目前速度，今天約用 \(settings.format(forecast.projectedTotal))", systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(theme.secondary)
                }
            } else {
                Label("收集資料中，約 2 分鐘後顯示預測", systemImage: "hourglass")
                    .foregroundStyle(theme.secondary)
            }
        }
        .font(.callout)
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(theme.isHack ? "RX/TX" : "即時").font(.caption).foregroundStyle(theme.secondary)
                Text("↓ \(settings.formatRate(collector.rxRate))").foregroundStyle(theme.download).glow(theme.download)
                Text("↑ \(settings.formatRate(collector.txRate))").foregroundStyle(theme.upload).glow(theme.upload)
                Spacer()
            }
            .font(.callout.monospacedDigit())

            Chart(collector.recentRates) { point in
                AreaMark(x: .value("時間", point.date), y: .value("速率", point.rx), series: .value("方向", "下載"))
                    .foregroundStyle(theme.download.opacity(theme.isHack ? 0.25 : 0.35))
                LineMark(x: .value("時間", point.date), y: .value("速率", point.rx), series: .value("方向", "下載線"))
                    .foregroundStyle(theme.download)
                    .interpolationMethod(theme.isHack ? .stepCenter : .catmullRom)
                LineMark(x: .value("時間", point.date), y: .value("速率", point.tx), series: .value("方向", "上傳"))
                    .foregroundStyle(theme.upload)
                    .interpolationMethod(theme.isHack ? .stepCenter : .catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 40)
            .glow(theme.download)

            HStack {
                Text(theme.label("今日峰值")).font(.caption).foregroundStyle(theme.secondary)
                Text("↓ \(settings.formatRate(collector.peak.rxRate))")
                Text(collector.peak.rxAt?.shortTime ?? "").foregroundStyle(theme.secondary)
                Text("↑ \(settings.formatRate(collector.peak.txRate))")
                Text(collector.peak.txAt?.shortTime ?? "").foregroundStyle(theme.secondary)
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
        }
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(theme.isHack ? "> top -n 5 --by-bytes" : "今日用量最多的程式").font(.caption).foregroundStyle(theme.secondary)
            let top = Array(collector.apps.prefix(5))
            if top.isEmpty {
                Text("尚無資料").font(.callout).foregroundStyle(theme.secondary)
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
                model.showDashboard(.today)
            } label: {
                Label("儀表板", systemImage: "chart.bar.xaxis")
            }
            Button {
                model.showDashboard(.settings)
            } label: {
                Label("設定", systemImage: "gearshape")
            }
            Menu {
                Picker("風格", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("風格", systemImage: "paintpalette")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            Button("結束") { NSApp.terminate(nil) }
        }
        .modifier(FooterButtonStyle())
    }
}

/// Glass 風格的面板按鈕用系統的玻璃按鈕；其他風格維持無邊框。
private struct FooterButtonStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), theme.isGlass || theme.liquidGlass {
            GlassEffectContainer { content.buttonStyle(.glass) }
        } else {
            content.buttonStyle(.borderless)
        }
    }
}
