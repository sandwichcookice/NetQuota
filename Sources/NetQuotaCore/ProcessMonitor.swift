import Foundation

/// 各程序流量的來源：優先用系統的 NetworkStatistics 框架（幾乎不耗 CPU、不漏短連線），
/// 載入失敗或一直收不到資料時退回定時跑 nettop 快照。
///
/// 核心只把使用者空間的連線（Network.framework 的 QUIC，例如 Safari、nsurlsessiond 的 HTTP/3）
/// 給有 `com.apple.private.network.statistics` entitlement 的程序，框架拿不到，
/// 所以另外每 10 秒跑一次 nettop 快照、只補 `quic` 連線；這類連線都很長壽，漏得很少。
///
/// 不用常駐的 nettop：它不論取樣間隔多長都會持續吃掉 1 個以上的 CPU 核心（大多是系統時間），
/// 造成耗電與畫面卡頓。只監測非 loopback 的介面。
public final class ProcessMonitor: @unchecked Sendable {
    public enum Backend: String, Sendable {
        case networkStatistics, nettop
    }

    /// 在背景佇列上呼叫。
    public var onSample: (([ProcessSample]) -> Void)?

    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "NetQuota.ProcessMonitor")
    private var statistics: NetworkStatisticsSampler?
    private var nettop: NettopSampler?
    private static let quicInterval: TimeInterval = 10
    private var stopped = true

    public init(interval: TimeInterval = 2) {
        self.interval = interval
    }

    /// 目前用哪個來源；還沒啟動時為 nil。
    public var backend: Backend? {
        queue.sync { statistics != nil ? .networkStatistics : nettop != nil ? .nettop : nil }
    }

    public func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            if let sampler = NetworkStatisticsSampler(interval: interval) {
                sampler.onSample = { [weak self] in self?.onSample?($0) }
                sampler.start()
                statistics = sampler
                startNettop(interval: Self.quicInterval, maxInterval: Self.quicInterval * 6, flowPrefix: "quic")
                // 框架正常時啟動後馬上就有連線；一分鐘內一條都沒有就改用 nettop。
                queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                    guard let self, !stopped, let sampler = statistics, !sampler.hasSources else { return }
                    NSLog("NetQuota: NetworkStatistics 沒有回報任何連線，改用 nettop")
                    sampler.stop()
                    statistics = nil
                    nettop?.stop()
                    startNettop(interval: interval, maxInterval: 10, flowPrefix: nil)
                }
            } else {
                NSLog("NetQuota: 無法載入 NetworkStatistics，改用 nettop")
                startNettop(interval: interval, maxInterval: 10, flowPrefix: nil)
            }
        }
    }

    private func startNettop(interval: TimeInterval, maxInterval: TimeInterval, flowPrefix: String?) {
        let sampler = NettopSampler(interval: interval, maxInterval: maxInterval, flowPrefix: flowPrefix)
        sampler.onSample = { [weak self] in self?.onSample?($0) }
        sampler.start()
        nettop = sampler
    }

    public func stop() {
        queue.sync { [self] in
            stopped = true
            statistics?.stop()
            statistics = nil
            nettop?.stop()
            nettop = nil
        }
    }
}

/// 定時跑一次 nettop 快照（`-L 1`），和上一次快照比較後回呼各程序的增量。單次快照只要幾十毫秒。
///
/// 高負載判斷：快照跑得太久（系統忙、連線數暴增）時拉長間隔，最長到 `maxInterval`；恢復後再逐步縮回。
final class NettopSampler: @unchecked Sendable {
    var onSample: (([ProcessSample]) -> Void)?

    private let baseInterval: TimeInterval
    private let maxInterval: TimeInterval
    /// 單次快照超過這個時間就視為高負載。
    private let slowSnapshot: TimeInterval = 0.5
    /// 快照卡住時強制結束。
    private let timeout: TimeInterval = 10
    private let queue = DispatchQueue(label: "NetQuota.NettopSampler")
    /// 只統計這種連線（例如 "quic"）；nil 為全部。
    private let flowPrefix: String?
    private var parser: NettopParser
    private var interval: TimeInterval
    private var stopped = true
    private var generation = 0

    init(interval: TimeInterval = 2, maxInterval: TimeInterval = 10, flowPrefix: String? = nil) {
        baseInterval = interval
        self.maxInterval = maxInterval
        self.interval = interval
        self.flowPrefix = flowPrefix
        parser = NettopParser(flowPrefix: flowPrefix)
    }

    /// 目前的取樣間隔（高負載時會比設定的長）。
    var currentInterval: TimeInterval { queue.sync { interval } }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            generation += 1
            parser = NettopParser(flowPrefix: flowPrefix)
            interval = baseInterval
            sample(generation)
        }
    }

    func stop() {
        // 快照在同一個佇列上執行，這裡會等目前這次跑完（通常幾十毫秒）。
        queue.sync { [self] in stopped = true }
    }

    /// 跑一次快照，結束後依耗時排定下一次。
    private func sample(_ generation: Int) {
        guard !stopped, generation == self.generation else { return }
        let started = Date()
        let output = runSnapshot()
        let elapsed = Date().timeIntervalSince(started)
        guard !stopped, generation == self.generation else { return }

        if let output, let samples = parser.snapshot(output) {
            onSample?(samples.filter { !$0.bytes.isZero })
        }
        adjustInterval(elapsed: elapsed, failed: output == nil)
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.sample(generation) }
    }

    private func adjustInterval(elapsed: TimeInterval, failed: Bool) {
        if failed {
            interval = maxInterval
        } else if elapsed > slowSnapshot {
            interval = min(maxInterval, interval * 2)
        } else if interval > baseInterval {
            interval = max(baseInterval, interval / 2)
        }
    }

    /// 在監測佇列上同步執行；失敗或逾時回傳 nil。
    private func runSnapshot() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-n", "-L", "1", "-t", "external", "-x", "-J", "bytes_in,bytes_out"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            NSLog("NetQuota: 無法執行 nettop：\(error)")
            return nil
        }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // 先讀完再等結束：輸出超過 pipe 緩衝區時，nettop 會卡在寫入。
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        guard task.terminationReason == .exit, task.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
