import Foundation
import NetQuotaCore

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case usedOfQuota
    case remaining
    case percent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usedOfQuota: "已用／上限（3.2/12G）"
        case .remaining: "剩餘（剩 8.8G）"
        case .percent: "百分比（27%）"
        }
    }
}

/// 使用者設定，存在 UserDefaults。
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// 舊版的單一上限，只用來在升級時套用到第一個偵測到的網路。上限現在依網路各自設定。
    let quotaGB: Double
    @Published var binaryUnits: Bool { didSet { defaults.set(binaryUnits, forKey: "binaryUnits") } }
    @Published var resetHour: Int { didSet { defaults.set(resetHour, forKey: "resetHour") } }
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    @Published var forecastAlertEnabled: Bool { didSet { defaults.set(forecastAlertEnabled, forKey: "forecastAlertEnabled") } }
    @Published var appSpikeEnabled: Bool { didSet { defaults.set(appSpikeEnabled, forKey: "appSpikeEnabled") } }
    @Published var appSpikeGB: Double { didSet { defaults.set(appSpikeGB, forKey: "appSpikeGB") } }
    @Published var appSpikeMinutes: Int { didSet { defaults.set(appSpikeMinutes, forKey: "appSpikeMinutes") } }
    @Published var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    @Published var showSpeedInMenuBar: Bool { didSet { defaults.set(showSpeedInMenuBar, forKey: "showSpeedInMenuBar") } }
    /// 關掉後 App 仍在背景記錄，從 Spotlight 或 Dock 打開會顯示儀表板。
    @Published var showMenuBarItem: Bool { didSet { defaults.set(showMenuBarItem, forKey: "showMenuBarItem") } }
    @Published var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "appTheme") } }
    /// 色盲友善配色：下載藍、上傳橘、警示琥珀。
    @Published var colorBlindFriendly: Bool { didSet { defaults.set(colorBlindFriendly, forKey: "colorBlindFriendly") } }

    /// macOS 依這個值（距離螢幕右緣的點數）決定選單列圖示的位置。
    static let statusItemPositionKey = "NSStatusItem Preferred Position Item-0"
    /// 選單列右側通常看得到的位置。圖示太靠左時會被瀏海和其他圖示擠到隱藏區。
    static let visibleStatusItemPosition = 260.0

    init() {
        defaults.register(defaults: [
            "quotaGB": 12.0,
            "binaryUnits": false,
            "resetHour": 0,
            "alertsEnabled": true,
            "forecastAlertEnabled": true,
            "appSpikeEnabled": true,
            "appSpikeGB": 1.0,
            "appSpikeMinutes": 10,
            // 選單列滿的時候，越短越不容易被瀏海擋住。
            "menuBarStyle": MenuBarStyle.percent.rawValue,
            "showSpeedInMenuBar": false,
            "showMenuBarItem": true,
        ])
        quotaGB = defaults.double(forKey: "quotaGB")
        binaryUnits = defaults.bool(forKey: "binaryUnits")
        resetHour = defaults.integer(forKey: "resetHour")
        alertsEnabled = defaults.bool(forKey: "alertsEnabled")
        forecastAlertEnabled = defaults.bool(forKey: "forecastAlertEnabled")
        appSpikeEnabled = defaults.bool(forKey: "appSpikeEnabled")
        appSpikeGB = defaults.double(forKey: "appSpikeGB")
        appSpikeMinutes = defaults.integer(forKey: "appSpikeMinutes")
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .percent
        showSpeedInMenuBar = defaults.bool(forKey: "showSpeedInMenuBar")
        showMenuBarItem = defaults.bool(forKey: "showMenuBarItem")
        theme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .standard
        colorBlindFriendly = defaults.bool(forKey: "colorBlindFriendly")
        // 新安裝時把選單列圖示放在右側；使用者自己拖過的位置不覆蓋。
        if defaults.object(forKey: Self.statusItemPositionKey) == nil {
            defaults.set(Self.visibleStatusItemPosition, forKey: Self.statusItemPositionKey)
        }
    }

    /// 「一天」的切法（上限依網路各自設定，這裡不使用 quotaBytes）。
    var policy: QuotaPolicy {
        QuotaPolicy(quotaBytes: 0, resetHour: resetHour)
    }

    func format(_ bytes: Double) -> String { ByteFormat.bytes(bytes, binary: binaryUnits) }
    func format(_ bytes: UInt64) -> String { ByteFormat.bytes(bytes, binary: binaryUnits) }
    func formatRate(_ bytesPerSecond: Double) -> String { ByteFormat.rate(bytesPerSecond, binary: binaryUnits) }

    var bytesPerGB: Double { binaryUnits ? 1_073_741_824 : 1_000_000_000 }
}
