import Foundation

public struct AppUsage: Identifiable, Hashable, Sendable {
    public let name: String
    public var path: String?
    public var bytes: ByteCounts

    public var id: String { name }

    public init(name: String, path: String?, bytes: ByteCounts) {
        self.name = name
        self.path = path
        self.bytes = bytes
    }
}

/// 一天的峰值速率（bytes/s）與發生時間。
public struct DayPeak: Equatable, Codable, Sendable {
    public var rxRate: Double = 0
    public var rxAt: Date?
    public var txRate: Double = 0
    public var txAt: Date?

    public init(rxRate: Double = 0, rxAt: Date? = nil, txRate: Double = 0, txAt: Date? = nil) {
        self.rxRate = rxRate
        self.rxAt = rxAt
        self.txRate = txRate
        self.txAt = txAt
    }
}

/// 一分鐘的總量紀錄（機器學習用的主要時間序列）。
public struct MinuteRecord: Equatable, Sendable {
    public var bytes: ByteCounts
    /// 這一分鐘內最高的 2 秒平均速率（bytes/s）。
    public var peakRx: Double
    public var peakTx: Double
    /// 這一分鐘實際有在監測的秒數（0–60）。0 代表沒有監測（睡眠、App 沒開），不是「沒用網路」；
    /// -1 代表 schema v1 之前的舊資料（未知）。
    public var observedSeconds: Double
    /// 是否為 App 關閉期間依時間比例補算的資料。
    public var recovered: Bool
    /// 這一分鐘流量最多的介面（例如 en0）。
    public var interface: String?
    /// 這一分鐘流量最多的網路（networks.id）。各網路的精確分配在 minute_network。
    public var network: String?

    public init(bytes: ByteCounts = .zero, peakRx: Double = 0, peakTx: Double = 0, observedSeconds: Double = 0,
                recovered: Bool = false, interface: String? = nil, network: String? = nil) {
        self.bytes = bytes
        self.peakRx = peakRx
        self.peakTx = peakTx
        self.observedSeconds = observedSeconds
        self.recovered = recovered
        self.interface = interface
        self.network = network
    }
}

public struct DaySummary: Identifiable, Equatable, Sendable {
    public let day: String
    public let start: Date
    public var bytes: ByteCounts
    /// 手動校正量（可為負）。
    public var calibration: Double
    public var peak: DayPeak?

    public var id: String { day }
    public var total: Double { max(0, Double(bytes.total) + calibration) }
}

/// 流量資料庫。
///
/// 所有資料永久保留，不會自動刪除。
/// - `minute_total`：每分鐘的總量（介面計數器）與特徵（峰值、監測秒數、補算旗標、介面）。每日總量由此依目前的重置時間彙總。
/// - `minute_app`：每分鐘、每個程式的用量（schema v1 起）。
/// - `hour_app`：每小時、每個程式的用量（給介面快速查詢）。
/// - `minute_network`：每分鐘、每個網路的用量（schema v2 起），各網路的額度由此計算。
/// - `networks`：看過的網路（路由器位址、Wi-Fi 名稱、自訂名稱、每日上限）。
/// - `sample_total`、`sample_app`：每次取樣的原始資料（schema v3 起）。
/// - `peak`：每天的峰值速率。
/// - `network_calibration`：每天、每個網路的手動校正量（`calibration` 為 v2 之前的舊表）。
/// - `state`：鍵值設定（例如上次的計數器快照）。
public final class TrafficStore {
    let db: SQLiteDB

    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS minute_total (ts INTEGER PRIMARY KEY, rx INTEGER NOT NULL, tx INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS hour_app (ts INTEGER NOT NULL, app TEXT NOT NULL, rx INTEGER NOT NULL, tx INTEGER NOT NULL,
                PRIMARY KEY (ts, app));
            CREATE TABLE IF NOT EXISTS app_path (app TEXT PRIMARY KEY, path TEXT);
            CREATE TABLE IF NOT EXISTS peak (day TEXT PRIMARY KEY, rx_rate REAL, rx_at REAL, tx_rate REAL, tx_at REAL);
            CREATE TABLE IF NOT EXISTS calibration (day TEXT PRIMARY KEY, bytes REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT);
            """)
        try migrate()
    }

    public static let schemaVersion: Int64 = 3

    private func migrate() throws {
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        if version < 1 {
            try db.transaction {
                // v1：每分鐘特徵欄位與各程式每分鐘明細。舊資料的 observed_sec 設為 -1（未知）。
                var columns = Set<String>()
                try db.query("PRAGMA table_info(minute_total)") { row in
                    if let name = row.text(1) { columns.insert(name) }
                }
                for (name, definition) in [("peak_rx", "REAL NOT NULL DEFAULT 0"), ("peak_tx", "REAL NOT NULL DEFAULT 0"),
                                           ("observed_sec", "REAL NOT NULL DEFAULT 0"),
                                           ("recovered", "INTEGER NOT NULL DEFAULT 0"), ("iface", "TEXT")]
                    where !columns.contains(name) {
                    try db.exec("ALTER TABLE minute_total ADD COLUMN \(name) \(definition)")
                }
                if !columns.contains("observed_sec") {
                    try db.exec("UPDATE minute_total SET observed_sec = -1")
                }
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS minute_app (ts INTEGER NOT NULL, app TEXT NOT NULL,
                        rx INTEGER NOT NULL, tx INTEGER NOT NULL, PRIMARY KEY (ts, app)) WITHOUT ROWID;
                    PRAGMA user_version = 1;
                    """)
            }
        }
        if version < 2 {
            try db.transaction {
                // v2：依網路分開記錄。舊資料在第一次偵測到網路時歸到那個網路（見 backfillUnassigned）。
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS networks (id TEXT PRIMARY KEY, label TEXT, ssid TEXT, iface TEXT, router TEXT,
                        quota_bytes REAL, first_seen REAL NOT NULL, last_seen REAL NOT NULL);
                    CREATE TABLE IF NOT EXISTS minute_network (ts INTEGER NOT NULL, network TEXT NOT NULL,
                        rx INTEGER NOT NULL, tx INTEGER NOT NULL, PRIMARY KEY (ts, network)) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS network_calibration (day TEXT NOT NULL, network TEXT NOT NULL,
                        bytes REAL NOT NULL, PRIMARY KEY (day, network));
                    ALTER TABLE minute_total ADD COLUMN network TEXT;
                    INSERT OR REPLACE INTO state (key, value) VALUES ('pendingNetworkBackfill', '1');
                    PRAGMA user_version = 2;
                    """)
            }
        }
        if version < 3 {
            try db.transaction {
                // v3：每次取樣的原始資料（總量約每 2 秒、各程式約每 3 秒一筆），從這個版本開始記錄。
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS sample_total (ts REAL PRIMARY KEY, dt REAL NOT NULL,
                        rx INTEGER NOT NULL, tx INTEGER NOT NULL, awake INTEGER NOT NULL, network TEXT, ifaces TEXT);
                    CREATE TABLE IF NOT EXISTS sample_app (ts REAL NOT NULL, app TEXT NOT NULL, pid INTEGER NOT NULL,
                        rx INTEGER NOT NULL, tx INTEGER NOT NULL, network TEXT);
                    CREATE INDEX IF NOT EXISTS sample_app_ts ON sample_app (ts);
                    PRAGMA user_version = 3;
                    """)
            }
        }
    }

    public static func defaultPath() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("NetQuota", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("netquota.sqlite")
    }

    public func transaction(_ body: () throws -> Void) throws {
        try db.transaction(body)
    }

    // MARK: - 寫入

    /// 補算或測試用：只有位元組數。
    public func addMinute(at date: Date, _ bytes: ByteCounts, recovered: Bool = false) throws {
        guard !bytes.isZero else { return }
        try addMinute(at: date, MinuteRecord(bytes: bytes, recovered: recovered))
    }

    /// 累加到同一分鐘：位元組與監測秒數相加，峰值取最大。
    public func addMinute(at date: Date, _ record: MinuteRecord) throws {
        guard !record.bytes.isZero || record.observedSeconds > 0 else { return }
        let ts = Int64(date.timeIntervalSince1970) / 60 * 60
        try db.run("""
            INSERT INTO minute_total (ts, rx, tx, peak_rx, peak_tx, observed_sec, recovered, iface, network)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(ts) DO UPDATE SET
                rx = rx + excluded.rx, tx = tx + excluded.tx,
                peak_rx = MAX(peak_rx, excluded.peak_rx), peak_tx = MAX(peak_tx, excluded.peak_tx),
                observed_sec = MIN(60, MAX(observed_sec, 0) + excluded.observed_sec),
                recovered = MAX(recovered, excluded.recovered),
                iface = COALESCE(excluded.iface, iface),
                network = COALESCE(excluded.network, network)
            """, [.int(ts), .int(Int64(record.bytes.rx)), .int(Int64(record.bytes.tx)),
                  .double(record.peakRx), .double(record.peakTx), .double(min(60, record.observedSeconds)),
                  .int(record.recovered ? 1 : 0), record.interface.map(SQLValue.text) ?? .null,
                  record.network.map(SQLValue.text) ?? .null])
    }

    public func addAppMinute(at date: Date, app: String, _ bytes: ByteCounts) throws {
        guard !bytes.isZero else { return }
        let ts = Int64(date.timeIntervalSince1970) / 60 * 60
        try db.run("""
            INSERT INTO minute_app (ts, app, rx, tx) VALUES (?, ?, ?, ?)
            ON CONFLICT(ts, app) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
            """, [.int(ts), .text(app), .int(Int64(bytes.rx)), .int(Int64(bytes.tx))])
    }

    public func addAppHour(at date: Date, app: String, _ bytes: ByteCounts) throws {
        guard !bytes.isZero else { return }
        let ts = Int64(date.timeIntervalSince1970) / 3600 * 3600
        try db.run("""
            INSERT INTO hour_app (ts, app, rx, tx) VALUES (?, ?, ?, ?)
            ON CONFLICT(ts, app) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
            """, [.int(ts), .text(app), .int(Int64(bytes.rx)), .int(Int64(bytes.tx))])
    }

    public func setAppPath(_ app: String, path: String?) throws {
        try db.run("INSERT OR REPLACE INTO app_path (app, path) VALUES (?, ?)",
                   [.text(app), path.map(SQLValue.text) ?? .null])
    }

    public func setPeak(day: String, _ peak: DayPeak) throws {
        try db.run("INSERT OR REPLACE INTO peak (day, rx_rate, rx_at, tx_rate, tx_at) VALUES (?, ?, ?, ?, ?)", [
            .text(day), .double(peak.rxRate), peak.rxAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .double(peak.txRate), peak.txAt.map { .double($0.timeIntervalSince1970) } ?? .null,
        ])
    }

    public func setCalibration(day: String, network: String, bytes: Double) throws {
        if bytes == 0 {
            try db.run("DELETE FROM network_calibration WHERE day = ? AND network = ?", [.text(day), .text(network)])
        } else {
            try db.run("INSERT OR REPLACE INTO network_calibration (day, network, bytes) VALUES (?, ?, ?)",
                       [.text(day), .text(network), .double(bytes)])
        }
    }

    public func setState(_ key: String, _ value: String?) throws {
        try db.run("INSERT OR REPLACE INTO state (key, value) VALUES (?, ?)", [.text(key), value.map(SQLValue.text) ?? .null])
    }

    // MARK: - 讀取

    public func state(_ key: String) -> String? {
        var value: String?
        try? db.query("SELECT value FROM state WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    public func totals(from: Date, to: Date) -> ByteCounts {
        var result = ByteCounts.zero
        try? db.query("SELECT COALESCE(SUM(rx), 0), COALESCE(SUM(tx), 0) FROM minute_total WHERE ts >= ? AND ts < ?",
                      range(from, to)) { row in
            result = ByteCounts(rx: UInt64(max(0, row.int(0))), tx: UInt64(max(0, row.int(1))))
        }
        return result
    }

    public func minuteTotals(from: Date, to: Date) -> [(date: Date, bytes: ByteCounts)] {
        var rows: [(date: Date, bytes: ByteCounts)] = []
        try? db.query("SELECT ts, rx, tx FROM minute_total WHERE ts >= ? AND ts < ? ORDER BY ts", range(from, to)) { row in
            rows.append((Date(timeIntervalSince1970: TimeInterval(row.int(0))),
                         ByteCounts(rx: UInt64(row.int(1)), tx: UInt64(row.int(2)))))
        }
        return rows
    }

    /// 某天各網路的校正量。
    public func calibrations(day: String) -> [String: Double] {
        var result: [String: Double] = [:]
        try? db.query("SELECT network, bytes FROM network_calibration WHERE day = ?", [.text(day)]) { row in
            if let network = row.text(0) { result[network] = row.double(1) }
        }
        return result
    }

    public func peak(day: String) -> DayPeak? {
        peaks(days: [day])[day]
    }

    public func appPaths() -> [String: String] {
        var paths: [String: String] = [:]
        try? db.query("SELECT app, path FROM app_path WHERE path IS NOT NULL") { row in
            if let app = row.text(0), let path = row.text(1) { paths[app] = path }
        }
        return paths
    }

    /// 區間內各程式的總用量，由大到小排序。
    public func appTotals(from: Date, to: Date) -> [AppUsage] {
        let paths = appPaths()
        var result: [AppUsage] = []
        try? db.query("""
            SELECT app, SUM(rx), SUM(tx) FROM hour_app WHERE ts >= ? AND ts < ?
            GROUP BY app ORDER BY SUM(rx) + SUM(tx) DESC
            """, range(from, to)) { row in
            let name = row.text(0) ?? "?"
            result.append(AppUsage(name: name, path: paths[name],
                                   bytes: ByteCounts(rx: UInt64(row.int(1)), tx: UInt64(row.int(2)))))
        }
        return result
    }

    /// 區間內每天的摘要（依 `policy` 的重置時間切日），由舊到新，沒有資料的日子也會列出。
    /// `network` 為 nil 時是所有網路合計。
    public func dailySummaries(from: Date, to: Date, policy: QuotaPolicy, network: String? = nil) -> [DaySummary] {
        var buckets: [String: (start: Date, bytes: ByteCounts)] = [:]
        var order: [String] = []
        var cursor = policy.dayStart(containing: from)
        while cursor < to {
            let key = policy.dayKey(for: cursor)
            buckets[key] = (cursor, .zero)
            order.append(key)
            cursor = policy.dayEnd(containing: cursor)
        }
        guard let first = order.first, let firstStart = buckets[first]?.start else { return [] }

        let hourly = network == nil
            ? "SELECT ts / 3600 * 3600 AS h, SUM(rx), SUM(tx) FROM minute_total WHERE ts >= ? AND ts < ? GROUP BY h"
            : "SELECT ts / 3600 * 3600 AS h, SUM(rx), SUM(tx) FROM minute_network WHERE ts >= ? AND ts < ? AND network = ? GROUP BY h"
        try? db.query(hourly, range(firstStart, to) + (network.map { [.text($0)] } ?? [])) { row in
            let key = policy.dayKey(for: Date(timeIntervalSince1970: TimeInterval(row.int(0))))
            buckets[key]?.bytes += ByteCounts(rx: UInt64(row.int(1)), tx: UInt64(row.int(2)))
        }

        let peaks = peaks(days: order)
        var calibrations: [String: Double] = [:]
        let calibrationSQL = network == nil
            ? "SELECT day, SUM(bytes) FROM network_calibration WHERE day >= ? AND day <= ? GROUP BY day"
            : "SELECT day, SUM(bytes) FROM network_calibration WHERE day >= ? AND day <= ? AND network = ? GROUP BY day"
        try? db.query(calibrationSQL, [.text(first), .text(order.last ?? first)] + (network.map { [.text($0)] } ?? [])) { row in
            if let day = row.text(0) { calibrations[day] = row.double(1) }
        }

        return order.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            return DaySummary(day: key, start: bucket.start, bytes: bucket.bytes,
                              calibration: calibrations[key] ?? 0, peak: peaks[key])
        }
    }

    /// 每天、每個程式的用量（給 CSV 匯出用）。
    public func appDaily(from: Date, to: Date, policy: QuotaPolicy) -> [(day: String, app: String, bytes: ByteCounts)] {
        var buckets: [String: [String: ByteCounts]] = [:]
        try? db.query("SELECT ts, app, rx, tx FROM hour_app WHERE ts >= ? AND ts < ?", range(from, to)) { row in
            let day = policy.dayKey(for: Date(timeIntervalSince1970: TimeInterval(row.int(0))))
            let app = row.text(1) ?? "?"
            buckets[day, default: [:]][app, default: .zero] += ByteCounts(rx: UInt64(row.int(2)), tx: UInt64(row.int(3)))
        }
        return buckets.keys.sorted().flatMap { day in
            buckets[day]!.sorted { $0.value.total > $1.value.total }.map { (day, $0.key, $0.value) }
        }
    }

    /// 依時間順序逐筆讀出每分鐘紀錄（匯出用，不會一次載入記憶體）。
    public func forEachMinute(from: Date, to: Date, _ body: (Date, MinuteRecord) -> Void) {
        try? db.query("""
            SELECT ts, rx, tx, peak_rx, peak_tx, observed_sec, recovered, iface, network FROM minute_total
            WHERE ts >= ? AND ts < ? ORDER BY ts
            """, range(from, to)) { row in
            body(Date(timeIntervalSince1970: TimeInterval(row.int(0))),
                 MinuteRecord(bytes: ByteCounts(rx: UInt64(row.int(1)), tx: UInt64(row.int(2))),
                              peakRx: row.double(3), peakTx: row.double(4), observedSeconds: row.double(5),
                              recovered: row.int(6) != 0, interface: row.text(7), network: row.text(8)))
        }
    }

    public func forEachAppMinute(from: Date, to: Date, _ body: (Date, String, ByteCounts) -> Void) {
        try? db.query("SELECT ts, app, rx, tx FROM minute_app WHERE ts >= ? AND ts < ? ORDER BY ts, app",
                      range(from, to)) { row in
            body(Date(timeIntervalSince1970: TimeInterval(row.int(0))), row.text(1) ?? "?",
                 ByteCounts(rx: UInt64(row.int(2)), tx: UInt64(row.int(3))))
        }
    }

    /// 用 `VACUUM INTO` 產生一致的完整副本（執行中也安全）。
    public func backup(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try db.run("VACUUM INTO ?", [.text(url.path)])
    }

    /// 最早的一筆資料時間。
    public func firstRecord() -> Date? {
        var ts: Int64?
        try? db.query("SELECT MIN(ts) FROM minute_total") { row in
            if !row.isNull(0) { ts = row.int(0) }
        }
        return ts.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private func peaks(days: [String]) -> [String: DayPeak] {
        guard let first = days.first, let last = days.last else { return [:] }
        var result: [String: DayPeak] = [:]
        try? db.query("SELECT day, rx_rate, rx_at, tx_rate, tx_at FROM peak WHERE day >= ? AND day <= ?",
                      [.text(first), .text(last)]) { row in
            guard let day = row.text(0) else { return }
            result[day] = DayPeak(
                rxRate: row.double(1), rxAt: row.isNull(2) ? nil : Date(timeIntervalSince1970: row.double(2)),
                txRate: row.double(3), txAt: row.isNull(4) ? nil : Date(timeIntervalSince1970: row.double(4)))
        }
        return result
    }

    func range(_ from: Date, _ to: Date) -> [SQLValue] {
        [.int(Int64(from.timeIntervalSince1970.rounded(.down))), .int(Int64(to.timeIntervalSince1970.rounded(.up)))]
    }
}
