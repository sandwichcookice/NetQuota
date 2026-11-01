import Foundation

/// 下載（rx）與上傳（tx）的位元組數。
public struct ByteCounts: Equatable, Hashable, Codable, Sendable {
    public var rx: UInt64
    public var tx: UInt64

    public init(rx: UInt64 = 0, tx: UInt64 = 0) {
        self.rx = rx
        self.tx = tx
    }

    public static let zero = ByteCounts()

    public var total: UInt64 { rx &+ tx }
    public var isZero: Bool { rx == 0 && tx == 0 }

    public static func + (lhs: ByteCounts, rhs: ByteCounts) -> ByteCounts {
        ByteCounts(rx: lhs.rx &+ rhs.rx, tx: lhs.tx &+ rhs.tx)
    }

    public static func += (lhs: inout ByteCounts, rhs: ByteCounts) {
        lhs = lhs + rhs
    }
}

public enum ByteFormat {
    /// 例如 "3.21 GB"。`binary` 為 true 時使用 1024 進位（GiB）。
    public static func bytes(_ value: Double, binary: Bool = false) -> String {
        let base: Double = binary ? 1024 : 1000
        let units = binary ? ["B", "KiB", "MiB", "GiB", "TiB"] : ["B", "KB", "MB", "GB", "TB"]
        var v = max(0, value)
        var i = 0
        while v >= base && i < units.count - 1 {
            v /= base
            i += 1
        }
        if i == 0 { return "\(Int(v)) B" }
        return "\(number(v)) \(units[i])"
    }

    public static func bytes(_ value: UInt64, binary: Bool = false) -> String {
        bytes(Double(value), binary: binary)
    }

    /// 例如 "1.24 MB/s"。
    public static func rate(_ bytesPerSecond: Double, binary: Bool = false) -> String {
        bytes(bytesPerSecond, binary: binary) + "/s"
    }

    /// 選單列用的精簡 GB 數字，例如 "3.2"。
    public static func compactGB(_ value: Double, binary: Bool = false) -> String {
        let gb = value / (binary ? 1_073_741_824 : 1_000_000_000)
        return gb >= 100 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
    }

    /// 選單列用的精簡速率，例如 "1.2M"。
    public static func compactRate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        return String(format: "%.0fB", v)
    }

    private static func number(_ v: Double) -> String {
        if v < 10 { return String(format: "%.2f", v) }
        if v < 100 { return String(format: "%.1f", v) }
        return String(format: "%.0f", v)
    }
}
