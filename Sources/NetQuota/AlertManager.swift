import Foundation
import NetQuotaCore
import UserNotifications

/// 額度與單一程式爆量的 macOS 通知。
@MainActor
final class AlertManager: NSObject, UNUserNotificationCenterDelegate {
    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    /// 以 `swift run` 直接執行（沒有 .app 套件）時無法使用通知中心。
    private let available = Bundle.main.bundleIdentifier != nil
    private var spikeCooldown: [String: Date] = [:]

    private static let levels = [70, 90, 100]
    private static let forecastLevel = 1

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 每個有上限的網路各自通知；同一天同一個網路的同一門檻只通知一次。
    func checkQuota(day: String, network: String, name: String, used: Double, quota: Double, forecast: Forecast?) {
        guard settings.alertsEnabled, quota > 0 else { return }
        let key = "\(day)|\(network)"
        var fired = firedLevels(for: key, day: day)
        let percent = used / quota * 100
        let remaining = max(0, quota - used)

        // 一次跳過多個門檻時（例如剛開 App 就已經 95%），只通知最高的那個。
        if let level = Self.levels.filter({ percent >= Double($0) && !fired.contains($0) }).max() {
            Self.levels.filter { $0 <= level }.forEach { fired.insert($0) }
            if level >= 100 {
                post(id: "quota-\(key)-\(level)", title: "⛔️ \(name) 已達今日上限 \(settings.format(quota))",
                     body: "今日在 \(name) 已使用 \(settings.format(used))，可能會被鎖卡。")
            } else {
                post(id: "quota-\(key)-\(level)", title: "\(name) 今日流量已用 \(level)%",
                     body: "已使用 \(settings.format(used))，剩餘 \(settings.format(remaining))（上限 \(settings.format(quota))）。")
            }
        }

        if settings.forecastAlertEnabled, !fired.contains(Self.forecastLevel), percent >= 30, percent < 100,
           let exceedAt = forecast?.exceedAt {
            fired.insert(Self.forecastLevel)
            let time = exceedAt.formatted(date: .omitted, time: .shortened)
            post(id: "forecast-\(key)", title: "照目前速度，\(name) 預計 \(time) 用完額度",
                 body: "已使用 \(settings.format(used))（\(Int(percent))%），最近速率約 \(settings.formatRate(forecast?.rate ?? 0))。")
        }

        saveFiredLevels(fired, for: key, day: day)
    }

    func checkSpike(app: String, bytesInWindow: UInt64) {
        guard settings.appSpikeEnabled else { return }
        let threshold = settings.appSpikeGB * settings.bytesPerGB
        guard Double(bytesInWindow) >= threshold else { return }
        if let last = spikeCooldown[app], Date().timeIntervalSince(last) < 30 * 60 { return }
        spikeCooldown[app] = Date()
        post(id: "spike-\(app)-\(Date().timeIntervalSince1970)", title: "\(app) 正在大量使用網路",
             body: "最近 \(settings.appSpikeMinutes) 分鐘內用了 \(settings.format(bytesInWindow))。")
    }

    private func firedLevels(for key: String, day: String) -> Set<Int> {
        let all = defaults.dictionary(forKey: "alerts.fired") as? [String: [Int]] ?? [:]
        return Set(all[key] ?? [])
    }

    /// 只保留今天的紀錄。
    private func saveFiredLevels(_ levels: Set<Int>, for key: String, day: String) {
        var all = (defaults.dictionary(forKey: "alerts.fired") as? [String: [Int]] ?? [:])
            .filter { $0.key.hasPrefix(day + "|") }
        all[key] = Array(levels)
        defaults.set(all, forKey: "alerts.fired")
    }

    private func post(id: String, title: String, body: String) {
        guard available else {
            NSLog("NetQuota 通知：\(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
