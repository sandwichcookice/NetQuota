import Foundation

/// nettop 一筆程序資料（delta 模式下為這段間隔內的增量）。
public struct ProcessSample: Equatable, Sendable {
    public let name: String
    public let pid: Int32
    public let bytes: ByteCounts

    public init(name: String, pid: Int32, bytes: ByteCounts) {
        self.name = name
        self.pid = pid
        self.bytes = bytes
    }
}

/// 解析 `nettop -n -L 1 -x -J bytes_in,bytes_out` 的單次快照，並和上一次快照逐條連線相減，算出各程序的增量。
///
/// 常駐的 nettop（`-L 0`）不論取樣間隔多長都會持續消耗 1 個以上的 CPU 核心，所以改成定時跑一次快照。
/// 快照只列出目前開啟的連線，程序的合計會在連線關閉時變小，因此不能直接拿程序列相減，
/// 要逐條連線比較：舊連線算差額、新連線算全部。代價是兩次快照之間開啟又關閉的連線、
/// 以及連線關閉前最後一段的流量會漏掉。
public struct NettopParser {
    /// 上一次快照：`pid|連線` → 累計值。nil 代表還沒有基準點。
    private var previous: [String: ByteCounts]?
    /// 只統計這種連線（例如 "quic"）；nil 為全部。
    private let flowPrefix: String?

    public init(flowPrefix: String? = nil) {
        self.flowPrefix = flowPrefix
    }

    /// 解析一次快照的完整輸出，回傳和上一次相比的各程序增量；第一次只建立基準點，回傳 nil。
    public mutating func snapshot(_ text: String) -> [ProcessSample]? {
        let flows = Self.parseFlows(text, flowPrefix: flowPrefix)
        defer { previous = flows.counters }
        guard let previous else { return nil }

        var deltas: [Int32: ByteCounts] = [:]
        for (key, current) in flows.counters {
            let old = previous[key] ?? .zero
            // 同一組位址被新的 socket 重用時，累計值會比上次小，整筆都是新的流量。
            let rx = current.rx >= old.rx ? current.rx - old.rx : current.rx
            let tx = current.tx >= old.tx ? current.tx - old.tx : current.tx
            guard rx > 0 || tx > 0, let pid = flows.owners[key] else { continue }
            deltas[pid, default: .zero] += ByteCounts(rx: rx, tx: tx)
        }
        return deltas
            .compactMap { pid, bytes in flows.names[pid].map { ProcessSample(name: $0, pid: pid, bytes: bytes) } }
            .sorted { $0.pid < $1.pid }
    }

    private struct Flows {
        var counters: [String: ByteCounts] = [:]
        var owners: [String: Int32] = [:]
        var names: [Int32: String] = [:]
    }

    /// 程序列（`apsd.370,284626,142376,`）後面跟著它的連線列（`tcp4 a:1<->b:2,284626,142376,`）。
    private static func parseFlows(_ text: String, flowPrefix: String?) -> Flows {
        var flows = Flows()
        var owner: Int32?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces.union(.controlCharacters))
            if line.isEmpty || line.hasPrefix(",") { continue }
            if line.contains("<->") {
                guard let owner, flowPrefix.map({ line.hasPrefix($0) }) ?? true,
                      let flow = parseFlowLine(line) else { continue }
                let key = "\(owner)|\(flow.label)"
                flows.counters[key, default: .zero] += flow.bytes
                flows.owners[key] = owner
            } else {
                // 程序列的數字可能是空的，只取名稱和 pid。
                let label = line.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
                owner = processLabel(label).map { process in
                    flows.names[process.pid] = process.name
                    return process.pid
                }
            }
        }
        return flows
    }

    /// 連線列的數字是空的（例如只在監聽的 socket）時回傳 nil。
    private static func parseFlowLine(_ line: String) -> (label: String, bytes: ByteCounts)? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false)
        if fields.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { fields.removeLast() }
        guard fields.count >= 3,
              let tx = UInt64(fields[fields.count - 1].trimmingCharacters(in: .whitespaces)),
              let rx = UInt64(fields[fields.count - 2].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (fields[0..<(fields.count - 2)].joined(separator: ","), ByteCounts(rx: rx, tx: tx))
    }

    /// 解析 `Google Chrome H.1234,5013505,447,` 這樣的一行。
    public static func parseLine(_ line: String) -> ProcessSample? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        while let last = fields.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            fields.removeLast()
        }
        guard fields.count >= 3,
              let tx = UInt64(fields[fields.count - 1].trimmingCharacters(in: .whitespaces)),
              let rx = UInt64(fields[fields.count - 2].trimmingCharacters(in: .whitespaces))
        else { return nil }
        guard let process = processLabel(fields[0..<(fields.count - 2)].joined(separator: ",")) else { return nil }
        return ProcessSample(name: process.name, pid: process.pid, bytes: ByteCounts(rx: rx, tx: tx))
    }

    /// `Google Chrome H.1234` → 名稱與 pid。
    private static func processLabel<S: StringProtocol>(_ label: S) -> (name: String, pid: Int32)? {
        guard let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]) else { return nil }
        return (String(label[..<dot]), pid)
    }
}
