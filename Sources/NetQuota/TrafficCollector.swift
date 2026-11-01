import AppKit
import Combine
import Foundation
import NetQuotaCore

struct RatePoint: Identifiable {
    let date: Date
    let rx: Double
    let tx: Double
    var id: Date { date }
}

/// 每 2 秒讀一次介面計數器、接收 nettop 的各程式增量，彙總後每分鐘寫入資料庫。
@MainActor
final class TrafficCollector: ObservableObject {
    @Published private(set) var today = ByteCounts.zero
    @Published private(set) var calibration: Double = 0
    @Published private(set) var rxRate: Double = 0
    @Published private(set) var txRate: Double = 0
    @Published private(set) var peak = DayPeak()
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var forecast: Forecast?
    @Published private(set) var recentRates: [RatePoint] = []
    @Published private(set) var dayStart = Date()
    @Published private(set) var dayEnd = Date()
    @Published private(set) var dayKey = ""
    /// 每次寫入資料庫後遞增，讓圖表知道要重新查詢。
    @Published private(set) var dataVersion = 0
    @Published private(set) var recoveredNote: String?

    let store: TrafficStore
    let settings: AppSettings
    private let alerts: AlertManager
    private let monitor = ProcessMonitor(interval: 3)
    private let resolver = AppResolver()

    private var lastRaw: [String: ByteCounts] = [:]
    private var lastSample: Date?
    private var startedAt = Date()
    private var bootTime: Int64 = 0
    private var pendingMinute: (date: Date, record: MinuteRecord, interfaces: [String: UInt64])?
    /// 依分鐘分組的各程式增量；寫入時同時更新 minute_app 與 hour_app。
    private var pendingApps: [Date: [String: ByteCounts]] = [:]
    private var appTotals: [String: ByteCounts] = [:]
    private var appPaths: [String: String] = [:]
    private var forecastWindow: [(date: Date, bytes: UInt64)] = []
    private var spikeWindow: [String: [(date: Date, bytes: UInt64)]] = [:]
    private var lastResolverPrune = Date()
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private static let forecastSpan: TimeInterval = 30 * 60

    var used: Double { Double(today.total) + calibration }
    var quota: Double { settings.policy.quotaBytes }
    var remaining: Double { max(0, quota - used) }
    var fraction: Double { quota > 0 ? used / quota : 0 }

    init(store: TrafficStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        alerts = AlertManager(settings: settings)
    }

    func start() {
        appPaths = store.appPaths()
        bootTime = InterfaceCounter.bootTime()
        startedAt = Date()
        recoverGap()
        reloadToday()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        monitor.onSample = { [weak self] samples in
            Task { @MainActor in self?.ingest(samples) }
        }
        monitor.start()

        settings.$resetHour.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.flush()
                self?.reloadToday()
            }
        }.store(in: &cancellables)

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
                self?.monitor.stop()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    // MARK: - 校正

    /// 把今日已用量校正成 `gb`（例如對齊宿舍系統顯示的數字）。
    func calibrate(toUsedGB gb: Double) {
        calibration = gb * settings.bytesPerGB - Double(today.total)
        try? store.setCalibration(day: dayKey, bytes: calibration)
        dataVersion += 1
    }

    func clearCalibration() {
        calibration = 0
        try? store.setCalibration(day: dayKey, bytes: 0)
        dataVersion += 1
    }

    // MARK: - 取樣

    private func tick() {
        let now = Date()
        let raw = InterfaceCounter.read()
        guard let last = lastSample else {
            lastRaw = raw
            lastSample = now
            return
        }

        if now >= dayEnd {
            flush()
            reloadToday(at: now)
        }

        let perInterface = CounterMath.deltas(previous: lastRaw, current: raw)
        let delta = CounterMath.sum(perInterface)
        let dt = now.timeIntervalSince(last)
        // 睡眠喚醒後的第一筆間隔很長：不拿來算峰值，也只算一個取樣間隔的監測時間。
        let awake = dt < 10
        if dt > 0.5 {
            rxRate = Double(delta.rx) / dt
            txRate = Double(delta.tx) / dt
            if awake {
                if rxRate > peak.rxRate { peak.rxRate = rxRate; peak.rxAt = now }
                if txRate > peak.txRate { peak.txRate = txRate; peak.txAt = now }
            }
            recentRates.append(RatePoint(date: now, rx: rxRate, tx: txRate))
            if recentRates.count > 90 { recentRates.removeFirst(recentRates.count - 90) }
        }
        add(MinuteRecord(bytes: delta, peakRx: awake ? rxRate : 0, peakTx: awake ? txRate : 0,
                         observedSeconds: awake ? dt : 2),
            interfaces: perInterface, at: now)
        lastRaw = raw
        lastSample = now

        forecastWindow.append((now, delta.total))
        let cutoff = now.addingTimeInterval(-Self.forecastSpan)
        if let index = forecastWindow.firstIndex(where: { $0.date > cutoff }), index > 0 {
            forecastWindow.removeFirst(index)
        }
        updateForecast(now: now)
        alerts.checkQuota(day: dayKey, used: used, quota: quota, forecast: forecast)
    }

    private func add(_ sample: MinuteRecord, interfaces: [String: ByteCounts], at now: Date) {
        let minute = Self.minuteStart(now)
        if let pending = pendingMinute, pending.date != minute {
            flush()
        }
        var entry = pendingMinute ?? (minute, MinuteRecord(), [:])
        entry.record.bytes += sample.bytes
        entry.record.peakRx = max(entry.record.peakRx, sample.peakRx)
        entry.record.peakTx = max(entry.record.peakTx, sample.peakTx)
        entry.record.observedSeconds += sample.observedSeconds
        for (name, bytes) in interfaces where bytes.total > 0 {
            entry.interfaces[name, default: 0] += bytes.total
        }
        entry.record.interface = entry.interfaces.max { $0.value < $1.value }?.key
        pendingMinute = entry
        today += sample.bytes
    }

    private static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func ingest(_ samples: [ProcessSample]) {
        let now = Date()
        let minute = Self.minuteStart(now)
        let spikeCutoff = now.addingTimeInterval(-Double(settings.appSpikeMinutes) * 60)
        var touched = Set<String>()

        for sample in samples {
            let identity = resolver.resolve(pid: sample.pid, fallbackName: sample.name)
            let name = identity.name
            appTotals[name, default: .zero] += sample.bytes
            pendingApps[minute, default: [:]][name, default: .zero] += sample.bytes
            spikeWindow[name, default: []].append((now, sample.bytes.total))
            touched.insert(name)
            if let path = identity.path, appPaths[name] != path {
                appPaths[name] = path
                try? store.setAppPath(name, path: path)
            }
        }

        for name in touched {
            let entries = spikeWindow[name, default: []].filter { $0.date > spikeCutoff }
            spikeWindow[name] = entries
            alerts.checkSpike(app: name, bytesInWindow: entries.reduce(0) { $0 + $1.bytes })
        }
        spikeWindow = spikeWindow.filter { $0.value.last.map { $0.date > spikeCutoff } ?? false }

        if now.timeIntervalSince(lastResolverPrune) > 300 {
            resolver.pruneExited()
            lastResolverPrune = now
        }
        publishApps()
    }

    private func publishApps() {
        apps = appTotals
            .map { AppUsage(name: $0.key, path: appPaths[$0.key], bytes: $0.value) }
            .sorted { $0.bytes.total > $1.bytes.total }
    }

    private func updateForecast(now: Date) {
        let span = min(Self.forecastSpan, now.timeIntervalSince(startedAt))
        let recent = forecastWindow.reduce(0.0) { $0 + Double($1.bytes) }
        forecast = Forecast.make(used: used, quota: quota, recentBytes: recent, window: span, now: now, dayEnd: dayEnd)
    }

    // MARK: - 資料庫

    /// 把尚未寫入的資料寫進資料庫，並記錄目前的計數器快照（下次啟動時用來補算關閉期間的流量）。
    func flush() {
        do {
            try store.transaction {
                if let pending = pendingMinute {
                    try store.addMinute(at: pending.date, pending.record)
                }
                for (minute, apps) in pendingApps {
                    for (app, bytes) in apps {
                        try store.addAppMinute(at: minute, app: app, bytes)
                        try store.addAppHour(at: minute, app: app, bytes)
                    }
                }
                if !dayKey.isEmpty {
                    try store.setPeak(day: dayKey, peak)
                }
                try saveSnapshot(raw: lastRaw, at: lastSample ?? Date())
            }
            pendingMinute = nil
            pendingApps = [:]
            dataVersion += 1
        } catch {
            NSLog("NetQuota: 寫入資料庫失敗：\(error)")
        }
    }

    private func reloadToday(at now: Date = Date()) {
        let policy = settings.policy
        dayStart = policy.dayStart(containing: now)
        dayEnd = policy.dayEnd(containing: now)
        dayKey = policy.dayKey(for: now)
        today = store.totals(from: dayStart, to: dayEnd)
        calibration = store.calibration(day: dayKey)
        peak = store.peak(day: dayKey) ?? DayPeak()
        appTotals = Dictionary(store.appTotals(from: dayStart, to: dayEnd).map { ($0.name, $0.bytes) },
                               uniquingKeysWith: +)
        publishApps()
        updateForecast(now: now)
        dataVersion += 1
    }

    private struct Snapshot: Codable {
        var boot: Int64
        var time: Date
        var raw: [String: ByteCounts]
    }

    private func saveSnapshot(raw: [String: ByteCounts], at time: Date) throws {
        guard !raw.isEmpty else { return }
        let data = try JSONEncoder().encode(Snapshot(boot: bootTime, time: time, raw: raw))
        try store.setState("snapshot", String(decoding: data, as: UTF8.self))
    }

    /// App 沒在執行的期間，介面計數器仍持續累加，用上次的快照把差額補回來。
    private func recoverGap() {
        let now = Date()
        let raw = InterfaceCounter.read()
        lastRaw = raw
        lastSample = now

        guard let json = store.state("snapshot"),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)) else {
            // 第一次啟動：只建立基準點。今天之前的用量可以在設定裡手動校正。
            try? saveSnapshot(raw: raw, at: now)
            return
        }

        let from: Date
        let bytes: ByteCounts
        // 開機時間可能因為校時而有幾秒誤差。
        if abs(snapshot.boot - bootTime) <= 120 {
            from = snapshot.time
            bytes = CounterMath.delta(previous: snapshot.raw, current: raw)
        } else {
            // 中間重開過機：計數器從開機時歸零，目前值就是開機以來的流量。
            from = max(snapshot.time, Date(timeIntervalSince1970: TimeInterval(bootTime)))
            bytes = CounterMath.sum(raw)
        }
        guard from < now else { return }

        do {
            try store.transaction {
                for segment in settings.policy.split(bytes, from: from, to: now) {
                    try store.addMinute(at: segment.start, segment.bytes, recovered: true)
                }
                try saveSnapshot(raw: raw, at: now)
            }
        } catch {
            NSLog("NetQuota: 補算失敗：\(error)")
        }

        if bytes.total >= 1_000_000 {
            let span = "\(from.formatted(date: .abbreviated, time: .shortened)) – \(now.formatted(date: .omitted, time: .shortened))"
            recoveredNote = "App 未執行期間（\(span)）補回 \(settings.format(bytes.total))，已依時間比例分配到各天；這段期間無法區分各程式。"
        }
    }
}
