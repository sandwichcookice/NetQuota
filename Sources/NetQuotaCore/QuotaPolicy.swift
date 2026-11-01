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

/// 某個網路過去每天各時段的平均用量（bytes／小時，索引為當地時間的 0–23 時）。
public struct UsageProfile: Equatable, Sendable {
    public let hourly: [Double]
    /// 有資料的天數。
    public let days: Int

    public init(hourly: [Double], days: Int) {
        precondition(hourly.count == 24)
        self.hourly = hourly
        self.days = days
    }

    /// 少於 3 天的資料不夠穩定，不拿來預測。
    public var isUsable: Bool { days >= 3 }
}

public struct ForecastPoint: Equatable, Sendable {
    public let date: Date
    public let total: Double
}

/// 推估今天結束時的用量。
///
/// - 有 3 天以上的歷史資料時：接下來 30 分鐘用最近的速度，之後每個小時用過去同一時段的平均用量。
///   這樣凌晨不會把短時間的速度放大成整天。
/// - 資料不足時：退回用最近 30 分鐘的速度直線延伸。
public struct Forecast: Equatable, Sendable {
    public enum Method: Equatable, Sendable {
        case recentRate
        case history(days: Int)
    }

    /// 推估今天結束時的總用量。
    public let projectedTotal: Double
    /// 近期平均速率（bytes/s，上傳＋下載）。
    public let rate: Double
    /// 預計超過上限的時間；今天內不會超過則為 nil。
    public let exceedAt: Date?
    public let method: Method
    /// 從現在到今天結束的預測曲線（給圖表畫虛線）。
    public let curve: [ForecastPoint]

    static let blendSpan: TimeInterval = 30 * 60

    public static func make(used: Double, quota: Double, recentBytes: Double, window: TimeInterval,
                            now: Date, dayEnd: Date, profile: UsageProfile? = nil,
                            calendar: Calendar = .current) -> Forecast? {
        let hasRate = window >= 120
        let rate = hasRate ? max(0, recentBytes / window) : 0
        let useProfile = profile?.isUsable == true
        guard hasRate || useProfile else { return nil }

        var curve = [ForecastPoint(date: now, total: used)]
        var total = used
        var exceedAt: Date?
        var cursor = now

        func advance(to next: Date, bytesPerSecond: Double) {
            let seconds = next.timeIntervalSince(cursor)
            guard seconds > 0 else { return }
            let added = bytesPerSecond * seconds
            if exceedAt == nil, total < quota, total + added >= quota, bytesPerSecond > 0 {
                exceedAt = cursor.addingTimeInterval((quota - total) / bytesPerSecond)
            }
            total += added
            cursor = next
            curve.append(ForecastPoint(date: next, total: total))
        }

        if let profile, useProfile {
            // 先用最近的速度接 30 分鐘（沒有近期速度時直接用歷史）。
            if hasRate {
                advance(to: min(now.addingTimeInterval(blendSpan), dayEnd), bytesPerSecond: rate)
            }
            while cursor < dayEnd {
                let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
                let next = min(hourStart.addingTimeInterval(3600), dayEnd)
                let hour = calendar.component(.hour, from: cursor)
                advance(to: next, bytesPerSecond: profile.hourly[hour] / 3600)
            }
            return Forecast(projectedTotal: total, rate: rate, exceedAt: exceedAt,
                            method: .history(days: profile.days), curve: curve)
        }

        advance(to: dayEnd, bytesPerSecond: rate)
        return Forecast(projectedTotal: total, rate: rate, exceedAt: exceedAt, method: .recentRate, curve: curve)
    }
}
