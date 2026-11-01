import Foundation

/// 額度與「一天」的定義。
public struct QuotaPolicy: Equatable, Sendable {
    public var quotaBytes: Double
    /// 每天幾點歸零（0–23）。
    public var resetHour: Int
    public var calendar: Calendar

    public init(quotaBytes: Double, resetHour: Int, calendar: Calendar = .current) {
        self.quotaBytes = quotaBytes
        self.resetHour = min(max(resetHour, 0), 23)
        self.calendar = calendar
    }

    public static func quotaBytes(gb: Double, binary: Bool) -> Double {
        gb * (binary ? 1_073_741_824 : 1_000_000_000)
    }

    /// 包含 `date` 的那一天的起點。
    public func dayStart(containing date: Date) -> Date {
        let candidate = calendar.date(bySettingHour: resetHour, minute: 0, second: 0, of: date) ?? date
        if candidate <= date { return candidate }
        let previousDay = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        return calendar.date(bySettingHour: resetHour, minute: 0, second: 0, of: previousDay) ?? candidate
    }

    /// 下一天的起點（不含）。
    public func dayEnd(containing date: Date) -> Date {
        let start = dayStart(containing: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: resetHour, minute: 0, second: 0, of: next) ?? next
    }

    /// 例如 "2026-11-01"，以「這一天的起點」的日期命名。
    public func dayKey(for date: Date) -> String {
        let start = dayStart(containing: date)
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 把 [from, to) 依日界線切開。
    public func daySegments(from: Date, to: Date) -> [DateInterval] {
        guard to > from else { return [] }
        var segments: [DateInterval] = []
        var cursor = from
        while cursor < to {
            let end = min(dayEnd(containing: cursor), to)
            segments.append(DateInterval(start: cursor, end: end))
            cursor = end
        }
        return segments
    }

    /// 把一段時間內的流量依時間長度比例分配到各天（用於 App 關閉期間的補算）。
    public func split(_ bytes: ByteCounts, from: Date, to: Date) -> [(start: Date, bytes: ByteCounts)] {
        let segments = daySegments(from: from, to: to)
        guard segments.count > 1 else { return [(start: segments.first?.start ?? to, bytes: bytes)] }
        let total = to.timeIntervalSince(from)
        var remaining = bytes
        var result: [(start: Date, bytes: ByteCounts)] = []
        for (index, segment) in segments.enumerated() {
            if index == segments.count - 1 {
                result.append((segment.start, remaining))
            } else {
                let share = segment.duration / total
                let part = ByteCounts(rx: UInt64(Double(bytes.rx) * share), tx: UInt64(Double(bytes.tx) * share))
                remaining = ByteCounts(rx: remaining.rx - min(part.rx, remaining.rx), tx: remaining.tx - min(part.tx, remaining.tx))
                result.append((segment.start, part))
            }
        }
        return result
    }
}

/// 依目前速度推估今日用量。
public struct Forecast: Equatable, Sendable {
    /// 依近期速率推估到今天結束的總用量。
    public let projectedTotal: Double
    /// 近期平均速率（bytes/s，上傳＋下載）。
    public let rate: Double
    /// 預計超過額度的時間；今天內不會超過則為 nil。
    public let exceedAt: Date?

    public static func make(used: Double, quota: Double, recentBytes: Double, window: TimeInterval,
                            now: Date, dayEnd: Date) -> Forecast? {
        guard window >= 120 else { return nil }
        let rate = max(0, recentBytes / window)
        let remaining = max(0, dayEnd.timeIntervalSince(now))
        let projected = used + rate * remaining
        var exceedAt: Date?
        if used < quota, rate > 0 {
            let when = now.addingTimeInterval((quota - used) / rate)
            if when < dayEnd { exceedAt = when }
        }
        return Forecast(projectedTotal: projected, rate: rate, exceedAt: exceedAt)
    }
}
