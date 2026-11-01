import Foundation

/// 一次介面計數器取樣（約每 2 秒）。
public struct TotalSample: Equatable, Sendable {
    public var time: Date
    /// 與上一次取樣的實際間隔（秒）。
    public var dt: Double
    public var bytes: ByteCounts
    /// false 代表這段間隔跨過睡眠（dt 很長，速率不可信）。
    public var awake: Bool
    public var network: String?
    /// 各介面的增量，只含有流量的介面。
    public var interfaces: [String: ByteCounts]

    public init(time: Date, dt: Double, bytes: ByteCounts, awake: Bool, network: String?, interfaces: [String: ByteCounts]) {
        self.time = time
        self.dt = dt
        self.bytes = bytes
        self.awake = awake
        self.network = network
        self.interfaces = interfaces
    }

    /// 例如 "en0=1234/56;en7=0/12"，不含逗號，可直接放進 CSV。
    public var interfacesText: String {
        interfaces.keys.sorted().map { "\($0)=\(interfaces[$0]!.rx)/\(interfaces[$0]!.tx)" }.joined(separator: ";")
    }

    static func parseInterfaces(_ text: String?) -> [String: ByteCounts] {
        var result: [String: ByteCounts] = [:]
        for part in (text ?? "").split(separator: ";") {
            let pair = part.split(separator: "=")
            let values = pair.count == 2 ? pair[1].split(separator: "/") : []
            if values.count == 2, let rx = UInt64(values[0]), let tx = UInt64(values[1]) {
                result[String(pair[0])] = ByteCounts(rx: rx, tx: tx)
            }
        }
        return result
    }
}

/// nettop 一個區塊（約每 3 秒）裡一個程序的增量。
public struct AppSample: Equatable, Sendable {
    public var time: Date
    public var app: String
    public var pid: Int32
    public var bytes: ByteCounts
    public var network: String?

    public init(time: Date, app: String, pid: Int32, bytes: ByteCounts, network: String?) {
        self.time = time
        self.app = app
        self.pid = pid
        self.bytes = bytes
        self.network = network
    }
}

extension TrafficStore {
    public func addSample(_ sample: TotalSample) throws {
        try db.run("""
            INSERT OR REPLACE INTO sample_total (ts, dt, rx, tx, awake, network, ifaces) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.double(Self.roundedTime(sample.time)), .double(sample.dt), .int(Int64(sample.bytes.rx)),
                  .int(Int64(sample.bytes.tx)), .int(sample.awake ? 1 : 0), sample.network.map(SQLValue.text) ?? .null,
                  sample.interfaces.isEmpty ? .null : .text(sample.interfacesText)])
    }

    public func addAppSample(_ sample: AppSample) throws {
        try db.run("INSERT INTO sample_app (ts, app, pid, rx, tx, network) VALUES (?, ?, ?, ?, ?, ?)", [
            .double(Self.roundedTime(sample.time)), .text(sample.app), .int(Int64(sample.pid)),
            .int(Int64(sample.bytes.rx)), .int(Int64(sample.bytes.tx)), sample.network.map(SQLValue.text) ?? .null,
        ])
    }

    public func forEachSample(from: Date, to: Date, _ body: (TotalSample) -> Void) {
        try? db.query("""
            SELECT ts, dt, rx, tx, awake, network, ifaces FROM sample_total WHERE ts >= ? AND ts < ? ORDER BY ts
            """, [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]) { row in
            body(TotalSample(time: Date(timeIntervalSince1970: row.double(0)), dt: row.double(1),
                             bytes: ByteCounts(rx: UInt64(row.int(2)), tx: UInt64(row.int(3))), awake: row.int(4) != 0,
                             network: row.text(5), interfaces: TotalSample.parseInterfaces(row.text(6))))
        }
    }

    public func forEachAppSample(from: Date, to: Date, _ body: (AppSample) -> Void) {
        try? db.query("""
            SELECT ts, app, pid, rx, tx, network FROM sample_app WHERE ts >= ? AND ts < ? ORDER BY ts, app
            """, [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]) { row in
            body(AppSample(time: Date(timeIntervalSince1970: row.double(0)), app: row.text(1) ?? "?",
                           pid: Int32(truncatingIfNeeded: row.int(2)),
                           bytes: ByteCounts(rx: UInt64(row.int(3)), tx: UInt64(row.int(4))), network: row.text(5)))
        }
    }

    /// 最早一筆原始樣本的時間（v3 之前沒有）。
    public func firstSample() -> Date? {
        var ts: Double?
        try? db.query("SELECT MIN(ts) FROM sample_total") { row in
            if !row.isNull(0) { ts = row.double(0) }
        }
        return ts.map { Date(timeIntervalSince1970: $0) }
    }

    /// 毫秒精度。
    static func roundedTime(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded() / 1000
    }
}
