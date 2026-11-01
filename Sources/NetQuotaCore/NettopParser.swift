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

/// 解析 `nettop -P -L 0 -d -x -J bytes_in,bytes_out` 的串流輸出。
///
/// 每個取樣區塊以 `,bytes_in,bytes_out,` 標題列開始。delta 模式的第一個區塊是
/// 「目前開啟連線的累計值」而非增量，所以會被丟棄。
public struct NettopParser {
    private var pending = ""
    private var block: [ProcessSample] = []
    private var headersSeen = 0

    public init() {}

    /// 餵入新的輸出文字，回傳已完成的區塊（每個區塊為一次取樣的增量）。
    public mutating func feed(_ text: String) -> [[ProcessSample]] {
        pending += text
        var completed: [[ProcessSample]] = []
        while let newline = pending.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let line = pending[..<newline]
            pending = String(pending[pending.index(after: newline)...])
            handle(line, into: &completed)
        }
        return completed
    }

    private mutating func handle(_ rawLine: Substring, into completed: inout [[ProcessSample]]) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if line.isEmpty { return }
        if line.contains("bytes_in") {
            // 新區塊開始：前一個區塊完成。第一個區塊（headersSeen == 1 時累積的）是累計值，不輸出。
            if headersSeen >= 2 {
                completed.append(block)
            }
            headersSeen += 1
            block = []
            return
        }
        guard headersSeen > 0, let sample = Self.parseLine(line) else { return }
        if !sample.bytes.isZero {
            block.append(sample)
        }
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
        let label = fields[0..<(fields.count - 2)].joined(separator: ",")
        guard let dot = label.lastIndex(of: "."),
              let pid = Int32(label[label.index(after: dot)...])
        else { return nil }
        let name = String(label[..<dot])
        return ProcessSample(name: name, pid: pid, bytes: ByteCounts(rx: rx, tx: tx))
    }
}
