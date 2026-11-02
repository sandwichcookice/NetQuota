import Foundation

/// 直接訂閱系統的 NetworkStatistics 私有框架（nettop、活動監視器底層用的那個），
/// 由核心推送每條 TCP／UDP 連線的計數，定時彙總成各程序的增量。
///
/// 比起跑 nettop 幾乎不耗 CPU，連線關閉前核心會送最後一次計數，所以不會漏掉短連線。
/// 是私有 API：用 dlopen 載入，找不到符號時 `init` 回傳 nil，由呼叫端退回 nettop。
/// `net.statistics_privcheck` 預設為 0，不需要 entitlement。
final class NetworkStatisticsSampler: @unchecked Sendable {
    private typealias Ref = OpaquePointer
    private typealias SourceBlock = @convention(block) (Ref) -> Void
    private typealias DictBlock = @convention(block) (CFDictionary?) -> Void
    private typealias VoidBlock = @convention(block) () -> Void

    /// 框架的 C 函式。block 參數以 AnyObject 傳入（Swift 會把 closure 當成非逃逸的 block）。
    private struct API {
        let create: @convention(c) (CFAllocator?, DispatchQueue, AnyObject) -> Ref?
        let addAllTCP: @convention(c) (Ref) -> Int32
        let addAllUDP: @convention(c) (Ref) -> Int32
        let queryAll: @convention(c) (Ref, AnyObject) -> Int32
        let setDescription: @convention(c) (Ref, AnyObject) -> Void
        let queryDescription: @convention(c) (Ref) -> Void
        let setCounts: @convention(c) (Ref, AnyObject) -> Void
        let setRemoved: @convention(c) (Ref, AnyObject) -> Void
        let copyProperties: @convention(c) (Ref) -> Unmanaged<CFDictionary>?
        let destroy: @convention(c) (Ref) -> Void

        init?() {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics",
                                      RTLD_NOW) else { return nil }
            func load<T>(_ name: String) -> T? {
                dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let create: @convention(c) (CFAllocator?, DispatchQueue, AnyObject) -> Ref? = load("NStatManagerCreate"),
                  let addAllTCP: @convention(c) (Ref) -> Int32 = load("NStatManagerAddAllTCP"),
                  let addAllUDP: @convention(c) (Ref) -> Int32 = load("NStatManagerAddAllUDP"),
                  let queryAll: @convention(c) (Ref, AnyObject) -> Int32 = load("NStatManagerQueryAllSources"),
                  let setDescription: @convention(c) (Ref, AnyObject) -> Void = load("NStatSourceSetDescriptionBlock"),
                  let queryDescription: @convention(c) (Ref) -> Void = load("NStatSourceQueryDescription"),
                  let setCounts: @convention(c) (Ref, AnyObject) -> Void = load("NStatSourceSetCountsBlock"),
                  let setRemoved: @convention(c) (Ref, AnyObject) -> Void = load("NStatSourceSetRemovedBlock"),
                  let copyProperties: @convention(c) (Ref) -> Unmanaged<CFDictionary>? = load("NStatSourceCopyProperties"),
                  let destroy: @convention(c) (Ref) -> Void = load("NStatManagerDestroy")
            else { return nil }
            self.create = create
            self.addAllTCP = addAllTCP
            self.addAllUDP = addAllUDP
            self.queryAll = queryAll
            self.setDescription = setDescription
            self.queryDescription = queryDescription
            self.setCounts = setCounts
            self.setRemoved = setRemoved
            self.copyProperties = copyProperties
            self.destroy = destroy
        }
    }

    /// 一條連線的程序資訊與最近一次的計數。
    private struct Source {
        /// nil 代表還沒收到第一筆計數。
        var last: ByteCounts?
        /// 啟動時就存在的連線，第一筆計數是歷史累計值，只當基準點；之後新開的連線整筆都算。
        let existedAtStart: Bool
        /// 來自描述（計數訊息不一定帶）。
        var pid: Int32?
        var name = ""
        var interface: UInt32?

        mutating func update(from dict: [String: Any]) {
            if let pid = (dict["processID"] as? NSNumber)?.int32Value { self.pid = pid }
            if let name = dict["processName"] as? String, !name.isEmpty { self.name = name }
            if let interface = (dict["interface"] as? NSNumber)?.uint32Value { self.interface = interface }
        }
    }

    /// 在監測佇列上呼叫；pid 與名稱來自核心，名稱最長 15 字元。
    var onSample: (([ProcessSample]) -> Void)?

    private let api: API
    private let queue = DispatchQueue(label: "NetQuota.NetworkStatistics")
    private let interval: TimeInterval
    private let loopbackIndex = if_nametoindex("lo0")
    private var manager: Ref?
    private var sources: [Ref: Source] = [:]
    private var baselineDone = false
    private var pending: [Int32: (name: String, bytes: ByteCounts)] = [:]
    private var generation = 0

    static var isAvailable: Bool { API() != nil }

    init?(interval: TimeInterval) {
        guard let api = API() else { return nil }
        self.api = api
        self.interval = interval
    }

    /// 曾經收到任何連線（用來判斷框架是否真的在運作）。
    var hasSources: Bool { queue.sync { !sources.isEmpty } }

    func start() {
        queue.async { [self] in
            guard manager == nil else { return }
            generation += 1
            let generation = generation
            baselineDone = false
            let onAdded: SourceBlock = { [weak self] source in self?.add(source) }
            guard let manager = api.create(kCFAllocatorDefault, queue, onAdded as AnyObject) else { return }
            self.manager = manager
            _ = api.addAllTCP(manager)
            _ = api.addAllUDP(manager)
            // 先查一輪當基準點，之後每個間隔查一次並發布增量。
            let done: VoidBlock = { [weak self] in
                guard let self, self.generation == generation else { return }
                baselineDone = true
                pending = [:]
                scheduleQuery(generation)
            }
            _ = api.queryAll(manager, done as AnyObject)
        }
    }

    func stop() {
        queue.sync { [self] in
            generation += 1
            if let manager { api.destroy(manager) }
            manager = nil
            sources = [:]
            pending = [:]
        }
    }

    private func scheduleQuery(_ generation: Int) {
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, let manager, self.generation == generation else { return }
            let done: VoidBlock = { [weak self] in
                guard let self, self.generation == generation else { return }
                publish()
                scheduleQuery(generation)
            }
            _ = api.queryAll(manager, done as AnyObject)
        }
    }

    private func publish() {
        let samples = pending
            .map { ProcessSample(name: $0.value.name, pid: $0.key, bytes: $0.value.bytes) }
            .sorted { $0.pid < $1.pid }
        pending = [:]
        onSample?(samples)
    }

    private func add(_ source: Ref) {
        sources[source] = Source(existedAtStart: !baselineDone)
        // 計數訊息不一定帶程序資訊，要另外查描述。
        let description: DictBlock = { [weak self] dict in
            guard let self, let dict = dict as? [String: Any] else { return }
            sources[source]?.update(from: dict)
        }
        api.setDescription(source, description as AnyObject)
        let counts: DictBlock = { [weak self] dict in
            guard let self, let dict = dict as? [String: Any] else { return }
            record(dict, for: source)
        }
        api.setCounts(source, counts as AnyObject)
        let removed: VoidBlock = { [weak self] in
            guard let self else { return }
            // 核心在移除前會先送最後一次計數；再讀一次屬性以防萬一。
            if let dict = api.copyProperties(source)?.takeRetainedValue() as? [String: Any] {
                record(dict, for: source)
            }
            sources[source] = nil
        }
        api.setRemoved(source, removed as AnyObject)
        api.queryDescription(source)
    }

    private static func number(_ dict: [String: Any], _ key: String) -> UInt64 {
        (dict[key] as? NSNumber)?.uint64Value ?? 0
    }

    private func record(_ dict: [String: Any], for source: Ref) {
        guard var entry = sources[source] else { return }
        entry.update(from: dict)
        let counts = ByteCounts(rx: Self.number(dict, "rxBytes"), tx: Self.number(dict, "txBytes"))
        let last = entry.last ?? (entry.existedAtStart ? counts : .zero)
        entry.last = counts
        sources[source] = entry
        // 只算非 loopback 介面（和 nettop -t external 一樣）；還沒綁定介面的也算。
        guard baselineDone, counts.rx >= last.rx, counts.tx >= last.tx, entry.interface != loopbackIndex else { return }
        let delta = ByteCounts(rx: counts.rx - last.rx, tx: counts.tx - last.tx)
        guard !delta.isZero, let pid = entry.pid else { return }
        let name = !entry.name.isEmpty ? entry.name : pending[pid]?.name ?? "pid \(pid)"
        pending[pid] = (name, (pending[pid]?.bytes ?? .zero) + delta)
    }
}
