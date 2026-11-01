import Foundation

/// 看過的網路與它的設定。
public struct NetworkRecord: Identifiable, Hashable, Sendable {
    public let id: String
    /// 使用者自訂名稱。
    public var label: String?
    public var ssid: String?
    public var interface: String?
    public var router: String?
    /// 每日上限（bytes）；nil 代表不限制。
    public var quotaBytes: Double?
    public var firstSeen: Date
    public var lastSeen: Date

    public var displayName: String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
        if let ssid, !ssid.isEmpty { return ssid }
        if let router { return "網路 \(router)" }
        return id
    }
}

extension TrafficStore {
    /// 記錄看到某個網路：新的就建立，舊的更新最後出現時間（以及有拿到的 Wi-Fi 名稱）。
    public func upsertNetwork(_ info: NetworkInfo, at date: Date = Date()) throws {
        try db.run("""
            INSERT INTO networks (id, ssid, iface, router, first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET ssid = COALESCE(excluded.ssid, ssid), iface = excluded.iface,
                router = excluded.router, last_seen = excluded.last_seen
            """, [.text(info.id), info.ssid.map(SQLValue.text) ?? .null, .text(info.interface), .text(info.router),
                  .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970)])
    }

    public func setNetworkLabel(_ id: String, _ label: String?) throws {
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        try db.run("UPDATE networks SET label = ? WHERE id = ?",
                   [trimmed.flatMap { $0.isEmpty ? nil : SQLValue.text($0) } ?? .null, .text(id)])
    }

    public func setNetworkQuota(_ id: String, bytes: Double?) throws {
        try db.run("UPDATE networks SET quota_bytes = ? WHERE id = ?", [bytes.map(SQLValue.double) ?? .null, .text(id)])
    }

    public func networks() -> [NetworkRecord] {
        var result: [NetworkRecord] = []
        try? db.query("""
            SELECT id, label, ssid, iface, router, quota_bytes, first_seen, last_seen FROM networks ORDER BY first_seen
            """) { row in
            guard let id = row.text(0) else { return }
            result.append(NetworkRecord(
                id: id, label: row.text(1), ssid: row.text(2), interface: row.text(3), router: row.text(4),
                quotaBytes: row.isNull(5) ? nil : row.double(5),
                firstSeen: Date(timeIntervalSince1970: row.double(6)), lastSeen: Date(timeIntervalSince1970: row.double(7))))
        }
        return result
    }

    public func addNetworkMinute(at date: Date, network: String, _ bytes: ByteCounts) throws {
        guard !bytes.isZero else { return }
        let ts = Int64(date.timeIntervalSince1970) / 60 * 60
        try db.run("""
            INSERT INTO minute_network (ts, network, rx, tx) VALUES (?, ?, ?, ?)
            ON CONFLICT(ts, network) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
            """, [.int(ts), .text(network), .int(Int64(bytes.rx)), .int(Int64(bytes.tx))])
    }

    /// 區間內各網路的用量。
    public func networkTotals(from: Date, to: Date) -> [String: ByteCounts] {
        var result: [String: ByteCounts] = [:]
        try? db.query("SELECT network, SUM(rx), SUM(tx) FROM minute_network WHERE ts >= ? AND ts < ? GROUP BY network",
                      range(from, to)) { row in
            if let network = row.text(0) {
                result[network] = ByteCounts(rx: UInt64(row.int(1)), tx: UInt64(row.int(2)))
            }
        }
        return result
    }

    /// 某個網路每分鐘的用量。
    public func minuteTotals(from: Date, to: Date, network: String) -> [(date: Date, bytes: ByteCounts)] {
        var rows: [(date: Date, bytes: ByteCounts)] = []
        try? db.query("SELECT ts, rx, tx FROM minute_network WHERE ts >= ? AND ts < ? AND network = ? ORDER BY ts",
                      range(from, to) + [.text(network)]) { row in
            rows.append((Date(timeIntervalSince1970: TimeInterval(row.int(0))),
                         ByteCounts(rx: UInt64(row.int(1)), tx: UInt64(row.int(2)))))
        }
        return rows
    }

    /// 某個網路在 `before` 之前 `days` 天裡，每天各時段的平均用量。只計算有用量的日子。
    public func usageProfile(network: String, before: Date, days: Int = 14, policy: QuotaPolicy) -> UsageProfile {
        var hourly = [Double](repeating: 0, count: 24)
        var activeDays = Set<String>()
        let from = before.addingTimeInterval(-Double(days) * 86_400)
        try? db.query("""
            SELECT ts / 3600 * 3600 AS h, SUM(rx + tx) FROM minute_network
            WHERE ts >= ? AND ts < ? AND network = ? GROUP BY h
            """, range(from, before) + [.text(network)]) { row in
            let date = Date(timeIntervalSince1970: TimeInterval(row.int(0)))
            let bytes = Double(row.int(1))
            guard bytes > 0 else { return }
            hourly[policy.calendar.component(.hour, from: date)] += bytes
            activeDays.insert(policy.dayKey(for: date))
        }
        let count = activeDays.count
        return UsageProfile(hourly: count > 0 ? hourly.map { $0 / Double(count) } : hourly, days: count)
    }

    public func forEachNetworkMinute(from: Date, to: Date, _ body: (Date, String, ByteCounts) -> Void) {
        try? db.query("SELECT ts, network, rx, tx FROM minute_network WHERE ts >= ? AND ts < ? ORDER BY ts, network",
                      range(from, to)) { row in
            body(Date(timeIntervalSince1970: TimeInterval(row.int(0))), row.text(1) ?? "?",
                 ByteCounts(rx: UInt64(row.int(2)), tx: UInt64(row.int(3))))
        }
    }

    /// 升級到 v2 之前的資料沒有網路資訊。第一次偵測到網路時，把它們歸到該網路，
    /// 並套用舊版的單一上限與校正量。只會執行一次；回傳是否有執行。
    @discardableResult
    public func backfillUnassigned(to network: String, legacyQuotaBytes: Double?) throws -> Bool {
        guard state("pendingNetworkBackfill") == "1" else { return false }
        try db.transaction {
            try db.run("""
                INSERT INTO minute_network (ts, network, rx, tx)
                SELECT ts, ?, rx, tx FROM minute_total WHERE network IS NULL AND (rx > 0 OR tx > 0)
                ON CONFLICT(ts, network) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
                """, [.text(network)])
            try db.run("UPDATE minute_total SET network = ? WHERE network IS NULL", [.text(network)])
            try db.run("""
                INSERT OR REPLACE INTO network_calibration (day, network, bytes) SELECT day, ?, bytes FROM calibration
                """, [.text(network)])
            try db.exec("DELETE FROM calibration")
            if let legacyQuotaBytes {
                try db.run("UPDATE networks SET quota_bytes = ? WHERE id = ? AND quota_bytes IS NULL",
                           [.double(legacyQuotaBytes), .text(network)])
            }
            try setState("pendingNetworkBackfill", nil)
        }
        return true
    }
}
