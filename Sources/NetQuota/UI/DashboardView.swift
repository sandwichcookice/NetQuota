import AppKit
import NetQuotaCore
import SwiftUI

extension DashboardTab: CaseIterable, Identifiable {
    static var allCases: [DashboardTab] { [.today, .history, .apps, .settings] }

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "今日"
        case .history: "歷史"
        case .apps: "程式"
        case .settings: "設定"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .history: "calendar"
        case .apps: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }
}

/// 儀表板。各風格用不同的版面：
/// - 預設：系統分頁；系統支援 Liquid Glass 時再加上上方玻璃狀態列與玻璃按鈕。
/// - Glass：透明視窗，工具列放玻璃分頁切換，內容全是透明玻璃面板。
/// - Hack：自訂終端機分頁列。
struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch theme.kind {
            case .hack: hackLayout
            case .glass where theme.isGlass: glassAppearanceLayout
            case .standard where theme.liquidGlass: liquidGlassLayout
            default: standardLayout
            }
        }
        // 分頁在正中央、狀態列在右邊，同一行要放得下。
        .frame(minWidth: 900, minHeight: 540)
        .background(WindowTransparency(clear: theme.isGlass))
        // 背景直接畫在內容後面（延伸到標題列下方）。用 containerBackground 時，
        // 切換風格後系統常沿用舊的背景，所以不用它。
        .background { WindowBackground(theme: theme).ignoresSafeArea() }
        .safeAreaInset(edge: .top) {
            if let error = model.storageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
        // 儀表板開著時出現在 Dock 與 ⌘Tab，關掉後回到只有選單列。
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            // Dock 圖示要在 App 出現在 Dock 之後設定才會生效。
            DispatchQueue.main.async {
                if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
            }
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    @ViewBuilder
    private func page(_ tab: DashboardTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .history: HistoryView()
        case .apps: AppsView()
        case .settings: SettingsView()
        }
    }

    /// 把頁面固定成實際可用的大小。有些容器不會限制內容高度，有表格的頁面（程式、歷史）
    /// 會把所有列攤開、撐得比視窗還高，導致上方內容和導覽被擠出畫面。
    private func pinned(_ tab: DashboardTab) -> some View {
        GeometryReader { proxy in
            page(tab).frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    // MARK: - 預設

    private var standardLayout: some View {
        TabView(selection: $model.dashboardTab) {
            ForEach(DashboardTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
    }

    // MARK: - 預設 + Apple Liquid Glass

    @ViewBuilder
    private var liquidGlassLayout: some View {
        if #available(macOS 26.0, *) {
            // 和原本一樣用上方分頁；系統分頁在 macOS 26 本身就是 Liquid Glass。
            TabView(selection: $model.dashboardTab) {
                ForEach(DashboardTab.allCases) { tab in
                    pinned(tab)
                        .tabItem { Label(tab.title, systemImage: tab.symbol) }
                        .tag(tab)
                }
            }
            // 狀態列和分頁放在同一行（標題列）。
            .toolbar {
                ToolbarItem(placement: .primaryAction) { GlassStatusBar() }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    // MARK: - Glass 外觀

    @ViewBuilder
    private var glassAppearanceLayout: some View {
        if #available(macOS 26.0, *) {
            pinned(model.dashboardTab)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { GlassStatusBar(clear: true) }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .principal) {
                        Picker("頁面", selection: $model.dashboardTab) {
                            ForEach(DashboardTab.allCases) { tab in
                                Label(tab.title, systemImage: tab.symbol).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.titleAndIcon)
                    }
                }
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }

    // MARK: - Hack

    @ViewBuilder
    private var hackLayout: some View {
        if #available(macOS 26.0, *) {
            // 分頁直接放進標題列那一行（和關閉按鈕同一行），不再多一條系統標題列。
            pinned(model.dashboardTab)
                .id(model.dashboardTab)
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.accent.opacity(0.5)).frame(height: 1).glow()
                }
                .overlay { GlitchFlash(trigger: model.dashboardTab) }
                .overlay { BootSequence() }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        HackTabs(selection: $model.dashboardTab)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) {
                        HackStatus()
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            VStack(spacing: 0) {
                HStack {
                    HackTabs(selection: $model.dashboardTab)
                    Spacer()
                    HackStatus()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.accent.opacity(0.5)).frame(height: 1).glow()
                }
                pinned(model.dashboardTab)
                    .id(model.dashboardTab)
            }
            .overlay { GlitchFlash(trigger: model.dashboardTab) }
            .overlay { BootSequence() }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }
}

/// 標題列右側的狀態：即時速度與目前網路今日用量。
/// 屬於控制層，所以用 Liquid Glass；多個玻璃元件放在同一個 GlassEffectContainer。
@available(macOS 26.0, *)
private struct GlassStatusBar: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector
    @Environment(\.theme) private var theme
    /// Glass 外觀風格用透明玻璃；預設風格用 Apple 的標準玻璃。
    var clear = false

    private var glass: Glass { clear ? .clear : .regular }

    var body: some View {
        let usageColor: Color = collector.quota == nil ? .primary : theme.forFraction(collector.fraction)
        let usage = collector.quota.map { "\(settings.format(collector.used)) / \(settings.format($0))" }
            ?? settings.format(collector.used)
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("↓ \(settings.formatRate(collector.rxRate))").foregroundStyle(theme.download)
                    Text("↑ \(settings.formatRate(collector.txRate))").foregroundStyle(theme.upload)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(glass)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("下載 \(settings.formatRate(collector.rxRate))，上傳 \(settings.formatRate(collector.txRate))")

                // 網路名稱在今日頁已經看得到，這裡只放圖示，名稱放在提示裡。
                HStack(spacing: 5) {
                    Image(systemName: NetworkIcon.symbol(for: collector.currentNetwork?.interface))
                    Text(usage).foregroundStyle(usageColor)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(glass.tint(collector.quota == nil ? nil : usageColor.opacity(0.18)))
                .help("\(collector.focusName)：今日 \(usage)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(collector.focusName) 今日用量 \(usage)")
            }
            .font(.callout.monospacedDigit())
        }
        // 和視窗右側圓角保持一點距離。
        .padding(.trailing, 10)
    }
}

/// 視窗背景：Hack 為黑底特效，Glass 為模糊透明，預設交給系統。
private struct WindowBackground: View {
    let theme: Theme

    var body: some View {
        switch theme.kind {
        case .hack: HackBackground(theme: theme)
        case .glass where theme.isGlass: GlassBackdrop()
        default: Color.clear
        }
    }
}

/// Hack 風格的分頁按鈕（⌘1–⌘4）。
private struct HackTabs: View {
    @Binding var selection: DashboardTab
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(DashboardTab.allCases.enumerated()), id: \.element) { index, tab in
                let selected = tab == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = tab }
                } label: {
                    Text(selected ? "[\(index + 1)] \(tab.title)" : " \(index + 1)  \(tab.title)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(selected ? Color.black : theme.accent)
                        .background(selected ? theme.accent : Color.clear)
                        .overlay(Rectangle().strokeBorder(theme.accent.opacity(selected ? 0 : 0.35), lineWidth: 1))
                        .modifier(Pulse(active: selected, color: theme.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}

/// Hack 風格右上角的 LIVE、網路名稱與時鐘。
private struct HackStatus: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var collector: TrafficCollector

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(theme.bad).frame(width: 7, height: 7).modifier(Pulse(active: true, color: theme.bad))
            Text("LIVE").foregroundStyle(theme.bad)
            Text("·").foregroundStyle(theme.secondary)
            Text(collector.focusName).foregroundStyle(theme.accent)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()))
                    .foregroundStyle(theme.secondary)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 6)
    }
}
