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
    @Published var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "appTheme") } }

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
            "menuBarStyle": MenuBarStyle.usedOfQuota.rawValue,
            "showSpeedInMenuBar": false,
        ])
        quotaGB = defaults.double(forKey: "quotaGB")
        binaryUnits = defaults.bool(forKey: "binaryUnits")
        resetHour = defaults.integer(forKey: "resetHour")
        alertsEnabled = defaults.bool(forKey: "alertsEnabled")
        forecastAlertEnabled = defaults.bool(forKey: "forecastAlertEnabled")
        appSpikeEnabled = defaults.bool(forKey: "appSpikeEnabled")
        appSpikeGB = defaults.double(forKey: "appSpikeGB")
        appSpikeMinutes = defaults.integer(forKey: "appSpikeMinutes")
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .usedOfQuota
        showSpeedInMenuBar = defaults.bool(forKey: "showSpeedInMenuBar")
        theme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .standard
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
