import Foundation
import NetQuotaCore

/// 每天自動把資料庫完整備份一份到 backups/，保留最近 14 份。
@MainActor
final class BackupManager: ObservableObject {
    @Published private(set) var lastBackup: Date?
    @Published private(set) var lastError: String?

    let folder: URL
    private let store: TrafficStore
    private var timer: Timer?
    private static let keep = 14
    private static let interval: TimeInterval = 20 * 3600

    init(store: TrafficStore, databaseURL: URL) {
        self.store = store
        folder = databaseURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        if let raw = store.state("lastBackup"), let seconds = Double(raw) {
            lastBackup = Date(timeIntervalSince1970: seconds)
        }
    }

    func start() {
        runIfDue()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func runIfDue() {
        if let lastBackup, Date().timeIntervalSince(lastBackup) < Self.interval { return }
        backupNow()
    }

    func backupNow() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = folder.appendingPathComponent("netquota-\(formatter.string(from: Date())).sqlite")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try store.backup(to: url)
            let now = Date()
            try store.setState("lastBackup", String(now.timeIntervalSince1970))
            lastBackup = now
            lastError = nil
            prune()
        } catch {
            lastError = "備份失敗：\(error)"
            NSLog("NetQuota: \(lastError!)")
        }
    }

    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let backups = files.filter { $0.lastPathComponent.hasPrefix("netquota-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(Self.keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
