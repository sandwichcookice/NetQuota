import Foundation

/// 匯出給機器學習用的資料集（CSV，UTF-8，無 BOM，方便 pandas／PyTorch 直接讀取）。
///
/// - `minutes.csv`：從第一筆到最後一筆的**完整分鐘網格**，沒有紀錄的分鐘也會列出（observed_sec = 0），
///   模型才能分辨「沒用網路」和「沒在監測」。
/// - `app_minutes.csv`：各程式每分鐘用量（長格式，只列有流量的分鐘）。
/// - `network_minutes.csv`：各網路每分鐘用量（長格式）。
/// - `networks.csv`：網路清單（名稱、Wi-Fi、路由器、每日上限）。
/// - `samples.csv`、`app_samples.csv`：每次取樣的原始資料（schema v3 起，約每 2／3 秒一筆）。
/// - `days.csv`：每個網路每天的摘要（含是否超過該網路的上限，可當分類標籤）。
public enum DatasetExporter {
    public struct Result: Sendable {
        public let folder: URL
        public let minuteRows: Int
        public let appRows: Int
        public let networkRows: Int
        public let sampleRows: Int
        public let appSampleRows: Int
        public let dayRows: Int
    }

    public static func export(store: TrafficStore, policy: QuotaPolicy, to folder: URL, now: Date = Date()) throws -> Result {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = store.firstRecord() ?? now
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)

        let minuteRows = try writeMinutes(store: store, policy: policy, from: first, to: end,
                                          url: folder.appendingPathComponent("minutes.csv"))
        let appRows = try writeAppMinutes(store: store, from: first, to: end,
                                          url: folder.appendingPathComponent("app_minutes.csv"))
        let networkRows = try writeNetworkMinutes(store: store, from: first, to: end,
                                                  url: folder.appendingPathComponent("network_minutes.csv"))
        try writeNetworks(store: store, url: folder.appendingPathComponent("networks.csv"))
        let sampleStart = store.firstSample() ?? now
        let sampleRows = try writeSamples(store: store, from: sampleStart, to: now,
                                          url: folder.appendingPathComponent("samples.csv"))
        let appSampleRows = try writeAppSamples(store: store, from: sampleStart, to: now,
                                                url: folder.appendingPathComponent("app_samples.csv"))
        let dayRows = try writeDays(store: store, policy: policy, from: first, to: now,
                                    url: folder.appendingPathComponent("days.csv"))
        try schemaDescription(policy: policy).write(to: folder.appendingPathComponent("SCHEMA.md"), atomically: true, encoding: .utf8)
        return Result(folder: folder, minuteRows: minuteRows, appRows: appRows, networkRows: networkRows,
                      sampleRows: sampleRows, appSampleRows: appSampleRows, dayRows: dayRows)
    }

    static func writeMinutes(store: TrafficStore, policy: QuotaPolicy, from: Date, to: Date, url: URL) throws -> Int {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }
        writer.write("ts,local_time,quota_day,minute_of_day,weekday,rx_bytes,tx_bytes,peak_rx_Bps,peak_tx_Bps,observed_sec,recovered,iface,network")

        var records: [Int64: MinuteRecord] = [:]
        var count = 0
        let calendar = policy.calendar
        let iso = ISO8601DateFormatter()
        iso.timeZone = calendar.timeZone
        let start = Int64(from.timeIntervalSince1970) / 60 * 60
        let stop = Int64(to.timeIntervalSince1970) / 60 * 60

        // 一次讀一天，避免整年資料同時放進記憶體。
        var chunkStart = start
        while chunkStart <= stop {
            let chunkEnd = min(chunkStart + 86_400, stop + 60)
            records.removeAll(keepingCapacity: true)
            store.forEachMinute(from: Date(timeIntervalSince1970: TimeInterval(chunkStart)),
                                to: Date(timeIntervalSince1970: TimeInterval(chunkEnd))) { date, record in
                records[Int64(date.timeIntervalSince1970)] = record
            }
            var ts = chunkStart
            while ts < chunkEnd {
                let date = Date(timeIntervalSince1970: TimeInterval(ts))
                let record = records[ts] ?? MinuteRecord()
                let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
                let minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                // ISO 星期：1 = 週一 … 7 = 週日
                let weekday = ((parts.weekday ?? 1) + 5) % 7 + 1
                writer.write([
                    String(ts), iso.string(from: date), policy.dayKey(for: date), String(minuteOfDay), String(weekday),
                    String(record.bytes.rx), String(record.bytes.tx),
                    format(record.peakRx), format(record.peakTx), format(record.observedSeconds),
                    record.recovered ? "1" : "0", record.interface ?? "", record.network ?? "",
                ].joined(separator: ","))
                count += 1
                ts += 60
            }
            chunkStart = chunkEnd
        }
        return count
    }

    static func writeAppMinutes(store: TrafficStore, from: Date, to: Date, url: URL) throws -> Int {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }
        writer.write("ts,app,rx_bytes,tx_bytes")
        var count = 0
        store.forEachAppMinute(from: from, to: to.addingTimeInterval(60)) { date, app, bytes in
            writer.write("\(Int64(date.timeIntervalSince1970)),\(escape(app)),\(bytes.rx),\(bytes.tx)")
            count += 1
        }
        return count
    }

    /// 原始樣本量很大，逐日分塊讀出寫入。
    static func writeSamples(store: TrafficStore, from: Date, to: Date, url: URL) throws -> Int {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }
        writer.write("ts,dt,rx_bytes,tx_bytes,awake,network,ifaces")
        var count = 0
        forEachDay(from: from, to: to) { start, end in
            store.forEachSample(from: start, to: end) { sample in
                writer.write([
                    String(format: "%.3f", sample.time.timeIntervalSince1970), String(format: "%.3f", sample.dt),
                    String(sample.bytes.rx), String(sample.bytes.tx), sample.awake ? "1" : "0",
                    sample.network ?? "", sample.interfacesText,
                ].joined(separator: ","))
                count += 1
            }
        }
        return count
    }

    static func writeAppSamples(store: TrafficStore, from: Date, to: Date, url: URL) throws -> Int {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }
        writer.write("ts,app,pid,rx_bytes,tx_bytes,network")
        var count = 0
        forEachDay(from: from, to: to) { start, end in
            store.forEachAppSample(from: start, to: end) { sample in
                writer.write([
                    String(format: "%.3f", sample.time.timeIntervalSince1970), escape(sample.app), String(sample.pid),
                    String(sample.bytes.rx), String(sample.bytes.tx), sample.network ?? "",
                ].joined(separator: ","))
                count += 1
            }
        }
        return count
    }

    /// 把 [from, to] 切成每 24 小時一塊（最後一塊包含 `to`）。
    private static func forEachDay(from: Date, to: Date, _ body: (Date, Date) -> Void) {
        var start = from
        let end = to.addingTimeInterval(1)
        while start < end {
            let chunkEnd = min(start.addingTimeInterval(86_400), end)
            body(start, chunkEnd)
            start = chunkEnd
        }
    }

    static func writeNetworkMinutes(store: TrafficStore, from: Date, to: Date, url: URL) throws -> Int {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }
        writer.write("ts,network,rx_bytes,tx_bytes")
        var count = 0
        store.forEachNetworkMinute(from: from, to: to.addingTimeInterval(60)) { date, network, bytes in
            writer.write("\(Int64(date.timeIntervalSince1970)),\(network),\(bytes.rx),\(bytes.tx)")
            count += 1
        }
        return count
    }

    static func writeNetworks(store: TrafficStore, url: URL) throws {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }
        writer.write("network,name,ssid,router,quota_bytes,first_seen,last_seen")
        for network in store.networks() {
            writer.write([
                network.id, escape(network.displayName), escape(network.ssid ?? ""), network.router ?? "",
                network.quotaBytes.map { String(Int64($0)) } ?? "",
                String(Int64(network.firstSeen.timeIntervalSince1970)), String(Int64(network.lastSeen.timeIntervalSince1970)),
            ].joined(separator: ","))
        }
    }

    /// 每個網路每天一列，另加 network 為空的「全部網路」列。
    static func writeDays(store: TrafficStore, policy: QuotaPolicy, from: Date, to: Date, url: URL) throws -> Int {
        let writer = try CSVWriter(url: url)
        defer { writer.close() }
        writer.write("quota_day,network,rx_bytes,tx_bytes,calibration_bytes,total_bytes,quota_bytes,over_quota,peak_rx_Bps,peak_tx_Bps")
        var count = 0
        let scopes: [NetworkRecord?] = [nil] + store.networks()
        for scope in scopes {
            for day in store.dailySummaries(from: from, to: to, policy: policy, network: scope?.id) {
                if scope != nil, day.total == 0 { continue }
                let quota = scope?.quotaBytes
                writer.write([
                    day.day, scope?.id ?? "", String(day.bytes.rx), String(day.bytes.tx), String(Int64(day.calibration)),
                    String(Int64(day.total)), quota.map { String(Int64($0)) } ?? "",
                    quota.map { day.total > $0 ? "1" : "0" } ?? "",
                    scope == nil ? format(day.peak?.rxRate ?? 0) : "", scope == nil ? format(day.peak?.txRate ?? 0) : "",
                ].joined(separator: ","))
                count += 1
            }
        }
        return count
    }

    static func schemaDescription(policy: QuotaPolicy) -> String {
        """
        # NetQuota 資料集

        時間皆為 Unix 秒（`ts`，每分鐘的起點）。每天 \(policy.resetHour):00 歸零。每個網路有各自的每日上限（見 networks.csv）。

        ## minutes.csv（完整分鐘網格）
        | 欄位 | 說明 |
        |---|---|
        | ts | 該分鐘起點（Unix 秒） |
        | local_time | 當地時間（ISO 8601） |
        | quota_day | 所屬的額度日（依歸零時間切日） |
        | minute_of_day | 當地時間的第幾分鐘（0–1439） |
        | weekday | 1 = 週一 … 7 = 週日 |
        | rx_bytes / tx_bytes | 下載／上傳位元組（實體網路介面合計） |
        | peak_rx_Bps / peak_tx_Bps | 該分鐘內最高的 2 秒平均速率 |
        | observed_sec | 實際監測秒數。0 = 沒有監測（睡眠或 App 未執行），-1 = 舊版資料未記錄 |
        | recovered | 1 = App 關閉期間依時間比例補算的流量（時間分布不精確） |
        | iface | 該分鐘流量最多的介面（en0 通常是 Wi-Fi） |
        | network | 該分鐘流量最多的網路 id（對應 networks.csv；精確分配見 network_minutes.csv） |

        建議：訓練時以 `observed_sec > 0 or recovered == 1` 作為有效樣本的遮罩。

        ## app_minutes.csv（長格式）
        `ts, app, rx_bytes, tx_bytes`，只列有流量的分鐘。程式名稱以 .app 或執行檔名稱為準。
        用 pandas 轉寬格式：`df.pivot_table(index="ts", columns="app", values="rx_bytes", fill_value=0)`。

        ## samples.csv（原始樣本，約每 2 秒一筆，schema v3 起）
        | 欄位 | 說明 |
        |---|---|
        | ts | 取樣時間（Unix 秒，毫秒精度） |
        | dt | 與上一次取樣的實際間隔（秒），rx/tx 是這段間隔內的增量 |
        | rx_bytes / tx_bytes | 下載／上傳位元組（實體介面合計） |
        | awake | 0 = 這段間隔跨過睡眠，dt 很長、速率不可信 |
        | network | 當時所在的網路 id |
        | ifaces | 各介面增量，格式 `en0=下載/上傳;en7=…` |

        速率 = `rx_bytes / dt`。

        ## app_samples.csv（原始樣本，約每 3 秒一筆，schema v3 起）
        `ts, app, pid, rx_bytes, tx_bytes, network`：nettop 每個區塊裡有流量的程序各一列，增量對應前一個區塊到這個區塊之間。
        `pid` 可用來區分同一個 App 的不同程序（例如瀏覽器的分頁程序）。

        ## network_minutes.csv（長格式）
        `ts, network, rx_bytes, tx_bytes`：每分鐘在各網路的用量，同一分鐘換網路時會分成兩列。

        ## networks.csv
        `network`（以路由器硬體位址為主的 id）、`name`、`ssid`、`router`、`quota_bytes`（空白 = 不限制）。

        ## days.csv
        每個網路每天一列（`network` 空白為全部網路合計）。`over_quota` 依該網路自己的上限判斷，
        可當作「當天是否會超過上限」的標籤；沒有上限的網路為空白。

        ## 讀取範例
        ```python
        import pandas as pd
        m = pd.read_csv("minutes.csv", parse_dates=["local_time"])
        m["total"] = m.rx_bytes + m.tx_bytes
        valid = m[(m.observed_sec > 0) | (m.recovered == 1)]
        ```
        """
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int64(value)) : String(format: "%.1f", value)
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// 有緩衝的逐行寫檔。
final class CSVWriter {
    private let handle: FileHandle
    private var buffer = ""

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
    }

    func write(_ line: String) {
        buffer += line
        buffer += "\n"
        if buffer.utf8.count > 256 * 1024 { flush() }
    }

    func close() {
        flush()
        try? handle.close()
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(Data(buffer.utf8))
        buffer = ""
    }
}
