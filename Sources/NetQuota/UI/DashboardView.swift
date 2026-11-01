import AppKit
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.dashboardTab) {
            TodayView()
                .tabItem { Label("今日", systemImage: "sun.max") }
                .tag(DashboardTab.today)
            HistoryView()
                .tabItem { Label("歷史", systemImage: "calendar") }
                .tag(DashboardTab.history)
            AppsView()
                .tabItem { Label("程式", systemImage: "square.grid.2x2") }
                .tag(DashboardTab.apps)
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(DashboardTab.settings)
        }
        .frame(minWidth: 720, minHeight: 520)
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
}
