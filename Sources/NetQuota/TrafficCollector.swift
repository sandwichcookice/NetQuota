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

/// 今天某個網路的用量摘要。
struct NetworkUsage: Identifiable {
    let network: NetworkRecord
    let bytes: ByteCounts
    let calibration: Double
    let isCurrent: Bool
    /// 有效的上限：流量監測模式或沒設定時為 nil。
    let quota: Double?

    var id: String { network.id }
    var used: Double { max(0, Double(bytes.total) + calibration) }
    var fraction: Double? { quota.map { $0 > 0 ? used / $0 : 0 } }
}

/// 每 2 秒讀一次介面計數器、接收 nettop 的各程式增量，依目前所在的網路分開累計，每分鐘寫入資料庫。
@MainActor
final class TrafficCollector: ObservableObject {
    /// 今天所有網路合計。
    @Published private(set) var today = ByteCounts.zero
    @Published private(set) var todayByNetwork: [String: ByteCounts] = [:]
    @Published private(set) var calibrations: [String: Double] = [:]
    @Published private(set) var networks: [NetworkRecord] = []
    @Published private(set) var currentNetwork: NetworkInfo?
    /// 選單列、圓環、預測所針對的網路：目前所在的網路；離線時沿用最後一個。
    @Published private(set) var focusNetworkID: String?
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
    let wifi = WiFiNameProvider()
    private let alerts: AlertManager
    private let monitor = ProcessMonitor(interval: 3)
    private let resolver = AppResolver()

    private var lastRaw: [String: ByteCounts] = [:]
    private var lastSample: Date?
    private var bootTime: Int64 = 0
    private var pendingMinute: (date: Date, record: MinuteRecord, interfaces: [String: UInt64],
                                networks: [String: ByteCounts])?
    /// 依分鐘分組的各程式增量；寫入時同時更新 minute_app 與 hour_app。
    private var pendingApps: [Date: [String: ByteCounts]] = [:]
    /// 尚未寫入的原始樣本，和每分鐘的彙總一起批次寫入。
    private var pendingSamples: [TotalSample] = []
    private var pendingAppSamples: [AppSample] = []
    private var appTotals: [String: ByteCounts] = [:]
    private var appPaths: [String: String] = [:]
    /// 最近 30 分鐘的取樣：增量、所在網路、實際監測秒數（跨睡眠的那筆只算一個取樣間隔）。
    private var forecastWindow: [(date: Date, bytes: UInt64, network: String?, observed: Double)] = []
    private var spikeWindow: [String: [(date: Date, bytes: UInt64)]] = [:]
    private var lastResolverPrune = Date()
    private var lastRoute: (interface: String, router: String)?
    private var timers: [Timer] = []
    private var cancellables: Set<AnyCancellable> = []

    private static let forecastSpan: TimeInterval = 30 * 60
    private var profile: UsageProfile?
    private var profileKey = ""

    // MARK: - 給介面用的數值（針對目前的網路）

    var focusNetwork: NetworkRecord? { networks.first { $0.id == focusNetworkID } }
    var focusName: String { focusNetwork?.displayName ?? "未連線" }
    var calibration: Double { focusNetworkID.flatMap { calibrations[$0] } ?? 0 }
    var focusBytes: ByteCounts { focusNetworkID.flatMap { todayByNetwork[$0] } ?? .zero }
    var used: Double { max(0, Double(focusBytes.total) + calibration) }
    var quota: Double? { effectiveQuota(focusNetwork) }
    var remaining: Double? { quota.map { max(0, $0 - used) } }
    var fraction: Double { quota.map { $0 > 0 ? used / $0 : 0 } ?? 0 }
    var totalUsed: Double { max(0, Double(today.total) + calibrations.values.reduce(0, +)) }

    /// 每日額度模式下這個網路的上限；流量監測模式一律沒有上限（設定值仍保留，切回來就恢復）。
    func effectiveQuota(_ network: NetworkRecord?) -> Double? {
        settings.isQuotaMode ? network?.quotaBytes : nil
    }

    /// 今天有用量、有設上限、或目前所在的網路。
    var networkUsages: [NetworkUsage] {
        networks.compactMap { network in
            let bytes = todayByNetwork[network.id] ?? .zero
            let isCurrent = network.id == focusNetworkID
            let quota = effectiveQuota(network)
            guard !bytes.isZero || quota != nil || isCurrent else { return nil }
            return NetworkUsage(network: network, bytes: bytes, calibration: calibrations[network.id] ?? 0,
                                isCurrent: isCurrent, quota: quota)
        }
        .sorted { ($0.isCurrent ? 1 : 0, $0.used) > ($1.isCurrent ? 1 : 0, $1.used) }
    }

    func usage(for id: String) -> Double {
        max(0, Double((todayByNetwork[id] ?? .zero).total) + (calibrations[id] ?? 0))
    }

    init(store: TrafficStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        alerts = AlertManager(settings: settings)
    }

    func start() {
        appPaths = store.appPaths()
        networks = store.networks()
        focusNetworkID = store.state("focusNetwork")
        bootTime = InterfaceCounter.bootTime()
        refreshNetwork()
        settings.migrateModeIfNeeded(hasQuota: networks.contains { $0.quotaBytes != nil })
        recoverGap()
        seedForecastWindow()
        reloadToday()

        schedule(every: 2) { $0.tick() }
        schedule(every: 10) { $0.refreshNetwork() }

        monitor.onSample = { [weak self] samples in
            Task { @MainActor in self?.ingest(samples) }
        }
        monitor.start()

        wifi.onAuthorizationChange = { [weak self] in self?.refreshNetwork(force: true) }
        wifi.requestIfNeeded()

        settings.$resetHour.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.flush()
                self?.reloadToday()
            }
        }.store(in: &cancellables)

        settings.$usageMode.dropFirst().sink { [weak self] _ in
            // @Published 在值改變前送出，等下一輪再用新的模式重算。
            Task { @MainActor in self?.updateForecast(now: Date()) }
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

    private func schedule(every interval: TimeInterval, _ action: @escaping (TrafficCollector) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        timer.tolerance = interval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    // MARK: - 網路設定

    /// 把某個網路今日已用量校正成 `gb`（例如對齊宿舍系統顯示的數字）。
    func calibrate(network id: String, toUsedGB gb: Double) {
        let value = gb * settings.bytesPerGB - Double((todayByNetwork[id] ?? .zero).total)
        calibrations[id] = value
        try? store.setCalibration(day: dayKey, network: id, bytes: value)
        dataVersion += 1
    }

    func clearCalibration(network id: String) {
        calibrations[id] = nil
        try? store.setCalibration(day: dayKey, network: id, bytes: 0)
        dataVersion += 1
    }

    /// 設定某個網路的每日上限；nil 代表不限制。
    func setQuota(network id: String, gb: Double?) {
        try? store.setNetworkQuota(id, bytes: gb.map { $0 * settings.bytesPerGB })
        networks = store.networks()
        updateForecast(now: Date())
        dataVersion += 1
    }

    func setLabel(network id: String, _ label: String) {
        try? store.setNetworkLabel(id, label)
        networks = store.networks()
    }

    // MARK: - 網路偵測

    /// 讀目前的預設路由；換了網路才查路由器位址（arp）與 Wi-Fi 名稱。
    func refreshNetwork(force: Bool = false) {
        guard let route = NetworkProbe.primaryRoute() else {
            if currentNetwork != nil { currentNetwork = nil }
            lastRoute = nil
            return
        }
        let changed = lastRoute.map { $0.interface != route.interface || $0.router != route.router } ?? true
        let missingName = currentNetwork != nil && currentNetwork?.ssid == nil && wifi.isAuthorized
        guard changed || force || missingName || currentNetwork == nil else { return }

        let mac = NetworkProbe.macAddress(of: route.router)
        var info = NetworkInfo(id: NetworkProbe.networkID(router: route.router, mac: mac, interface: route.interface),
                               interface: route.interface, router: route.router, routerMAC: mac)
        info.ssid = wifi.ssid(for: route.interface)
        lastRoute = route

        let isNew = currentNetwork?.id != info.id
        if isNew || currentNetwork?.ssid != info.ssid {
            try? store.upsertNetwork(info)
            // 升級前的舊資料（沒有網路資訊）歸到第一個偵測到的網路，並套用舊版的單一上限。
            if (try? store.backfillUnassigned(to: info.id,
                                               legacyQuotaBytes: settings.quotaGB * settings.bytesPerGB)) == true {
                reloadToday()
            }
            networks = store.networks()
        }
        if isNew {
            // 換網路前的那一段先寫進資料庫，歸給原本的網路。
            flush()
            currentNetwork = info
            focusNetworkID = info.id
            try? store.setState("focusNetwork", info.id)
            updateForecast(now: Date())
        } else {
            currentNetwork = info
        }
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
        let network = currentNetwork?.id
        pendingSamples.append(TotalSample(time: now, dt: dt, bytes: delta, awake: awake, network: network,
                                          interfaces: perInterface.filter { !$0.value.isZero }))
        add(MinuteRecord(bytes: delta, peakRx: awake ? rxRate : 0, peakTx: awake ? txRate : 0,
                         observedSeconds: awake ? dt : 2),
            interfaces: perInterface, network: network, at: now)
        lastRaw = raw
        lastSample = now

        forecastWindow.append((now, delta.total, network, awake ? dt : 2))
        let cutoff = now.addingTimeInterval(-Self.forecastSpan)
        if let index = forecastWindow.firstIndex(where: { $0.date > cutoff }), index > 0 {
            forecastWindow.removeFirst(index)
        }
        updateForecast(now: now)
        checkAlerts()
    }

    private func checkAlerts() {
        for network in networks {
            guard let quota = effectiveQuota(network) else { continue }
            let used = usage(for: network.id)
            guard used > 0 else { continue }
            alerts.checkQuota(day: dayKey, network: network.id, name: network.displayName, used: used, quota: quota,
                              forecast: network.id == focusNetworkID ? forecast : nil)
        }
    }

    private func add(_ sample: MinuteRecord, interfaces: [String: ByteCounts], network: String?, at now: Date) {
        let minute = Self.minuteStart(now)
        if let pending = pendingMinute, pending.date != minute {
            flush()
        }
        var entry = pendingMinute ?? (minute, MinuteRecord(), [:], [:])
        entry.record.bytes += sample.bytes
        entry.record.peakRx = max(entry.record.peakRx, sample.peakRx)
        entry.record.peakTx = max(entry.record.peakTx, sample.peakTx)
        entry.record.observedSeconds += sample.observedSeconds
        for (name, bytes) in interfaces where bytes.total > 0 {
            entry.interfaces[name, default: 0] += bytes.total
        }
        entry.record.interface = entry.interfaces.max { $0.value < $1.value }?.key
        if let network, !sample.bytes.isZero {
            entry.networks[network, default: .zero] += sample.bytes
            todayByNetwork[network, default: .zero] += sample.bytes
        }
        entry.record.network = entry.networks.max { $0.value.total < $1.value.total }?.key ?? network
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
            pendingAppSamples.append(AppSample(time: now, app: name, pid: sample.pid, bytes: sample.bytes,
                                               network: currentNetwork?.id))
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

    /// 只針對目前網路；額度模式下沒有上限的網路不預測，流量監測模式只推估今天的總用量。
    /// 有歷史資料時依過去同時段的用量推估，否則用最近 30 分鐘的速率。
    private func updateForecast(now: Date) {
        let target = settings.isQuotaMode ? quota : .infinity
        guard let quota = target, let focusNetworkID else {
            forecast = nil
            return
        }
        // 歷史同時段的平均用量：換網路或換日時重新計算。
        if profileKey != "\(focusNetworkID)|\(dayKey)" {
            profileKey = "\(focusNetworkID)|\(dayKey)"
            profile = store.usageProfile(network: focusNetworkID, before: dayStart, policy: settings.policy)
        }
        // 用實際監測的時間當分母：App 關閉或睡眠的空檔不算，重開後也能接續之前的資料。
        let span = min(Self.forecastSpan, forecastWindow.reduce(0.0) { $0 + $1.observed })
        let recent = forecastWindow.reduce(0.0) { $0 + ($1.network == focusNetworkID ? Double($1.bytes) : 0) }
        forecast = Forecast.make(used: used, quota: quota, recentBytes: recent, window: span, now: now, dayEnd: dayEnd,
                                 profile: profile)
    }

    /// 啟動時從資料庫讀回最近 30 分鐘的原始樣本，重開 App 後不必重新累積就有預測。
    /// App 關閉期間的補算流量只存在每分鐘彙總裡，不會被算進速率。
    private func seedForecastWindow(now: Date = Date()) {
        forecastWindow = []
        store.forEachSample(from: now.addingTimeInterval(-Self.forecastSpan), to: now) { sample in
            forecastWindow.append((sample.time, sample.bytes.total, sample.network, sample.awake ? sample.dt : 2))
        }
    }

    // MARK: - 資料庫

    /// 把尚未寫入的資料寫進資料庫，並記錄目前的計數器快照（下次啟動時用來補算關閉期間的流量）。
    func flush() {
        do {
            try store.transaction {
                if let pending = pendingMinute {
                    try store.addMinute(at: pending.date, pending.record)
                    for (network, bytes) in pending.networks {
                        try store.addNetworkMinute(at: pending.date, network: network, bytes)
                    }
                }
                for sample in pendingSamples {
                    try store.addSample(sample)
                }
                for sample in pendingAppSamples {
                    try store.addAppSample(sample)
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
            pendingSamples = []
            pendingAppSamples = []
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
        todayByNetwork = store.networkTotals(from: dayStart, to: dayEnd)
        calibrations = store.calibrations(day: dayKey)
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
        var network: String?
    }

    private func saveSnapshot(raw: [String: ByteCounts], at time: Date) throws {
        guard !raw.isEmpty else { return }
        let snapshot = Snapshot(boot: bootTime, time: time, raw: raw, network: currentNetwork?.id ?? focusNetworkID)
        try store.setState("snapshot", String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))
    }

    /// App 沒在執行的期間，介面計數器仍持續累加，用上次的快照把差額補回來，歸給當時所在的網路。
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
        // 關閉前在哪個網路就歸給哪個；舊版快照沒有記錄時，用目前的網路。
        let network = snapshot.network ?? currentNetwork?.id

        do {
            try store.transaction {
                for segment in settings.policy.split(bytes, from: from, to: now) {
                    try store.addMinute(at: segment.start, MinuteRecord(bytes: segment.bytes, recovered: true, network: network))
                    if let network {
                        try store.addNetworkMinute(at: segment.start, network: network, segment.bytes)
                    }
                }
                try saveSnapshot(raw: raw, at: now)
            }
        } catch {
            NSLog("NetQuota: 補算失敗：\(error)")
        }

        if bytes.total >= 1_000_000 {
            let span = "\(from.shortDateTime) – \(now.shortTime)"
            recoveredNote = "App 未執行期間（\(span)）補回 \(settings.format(bytes.total))，已依時間比例分配到各天；這段期間無法區分各程式。"
        }
    }
}
