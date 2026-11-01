import AppKit
import Combine
import NetQuotaCore
import SwiftUI

enum DashboardTab: Hashable {
    case today, history, apps, settings
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings()
    let store: TrafficStore
    let collector: TrafficCollector
    let databaseURL: URL?
    let backups: BackupManager?
    let updates = UpdateManager()
    @Published var storageError: String?
    @Published var dashboardTab: DashboardTab = .today
    /// 由 MenuBarLabel 接收並開啟儀表板視窗（openWindow 只能在 SwiftUI view 裡呼叫）。
    let dashboardRequests = PassthroughSubject<Void, Never>()

    func showDashboard(_ tab: DashboardTab = .today) {
        dashboardTab = tab
        dashboardRequests.send()
    }

    private init() {
        var url: URL?
        var opened: TrafficStore?
        var failure: String?
        do {
            url = try TrafficStore.defaultPath()
            opened = try TrafficStore(path: url!.path)
        } catch {
            failure = "無法開啟資料庫，本次資料不會被保存：\(error)"
            url = nil
        }
        store = opened ?? (try! TrafficStore(path: ":memory:"))
        databaseURL = url
        storageError = failure
        collector = TrafficCollector(store: store, settings: settings)
        let store = self.store
        backups = url.map { BackupManager(store: store, databaseURL: $0) }
        collector.start()
        backups?.start()
        updates.start()
        // 第一次啟動：選單列圖示可能被瀏海擋住，直接打開儀表板並說明。
        if !UserDefaults.standard.bool(forKey: "onboardingDismissed") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showDashboard(.today) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 用 `swift run` 執行時沒有 Info.plist 的 LSUIElement，這裡確保不出現在 Dock。
        NSApp.setActivationPolicy(.accessory)
        // 執行期間從選單列 App 切成一般 App 時，Dock 不會自己讀 Info.plist 的圖示。
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
    }

    /// 關掉儀表板視窗只是收回選單列，App 繼續在背景記錄。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 選單列太滿時圖示可能被瀏海擋住，再次打開 App 就直接顯示儀表板。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showDashboard() }
        return true
    }
}

@main
struct NetQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    /// 直接觀察設定，選單列開關才會即時生效。
    @StateObject private var settings = AppModel.shared.settings

    /// 系統放入或移除選單列圖示時會回寫這個值。即使值沒變，寫入也會觸發設定更新、
    /// 讓整個 App 重建畫面、再回寫一次，變成無窮循環（App 卡死、記憶體一直漲），
    /// 所以只有值真的不同時才寫入。
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarItem },
            set: { newValue in
                if settings.showMenuBarItem != newValue { settings.showMenuBarItem = newValue }
            })
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarInserted) {
            ThemedRoot(settings: model.settings) {
                PopoverView()
            }
            .environmentObject(model)
            .environmentObject(model.settings)
            .environmentObject(model.collector)
        } label: {
            MenuBarLabel(collector: model.collector, settings: model.settings, dashboardRequests: model.dashboardRequests)
        }
        .menuBarExtraStyle(.window)

        Window("NetQuota", id: "dashboard") {
            ThemedRoot(settings: model.settings) {
                DashboardView()
            }
            .environmentObject(model)
            .environmentObject(model.settings)
            .environmentObject(model.collector)
        }
        .defaultSize(width: 1000, height: 660)
        .defaultLaunchBehavior(.suppressed)
    }
}
