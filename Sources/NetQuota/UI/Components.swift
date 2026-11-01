import AppKit
import NetQuotaCore
import SwiftUI

enum UsageColor {
    static func forFraction(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: .green
        case ..<0.9: .orange
        default: .red
        }
    }

    static let download = Color.blue
    static let upload = Color.purple
}

/// 今日用量的圓環。
struct UsageRing: View {
    let fraction: Double
    let usedText: String
    /// nil 代表沒有設定上限。
    let quotaText: String?
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(UsageColor.forFraction(fraction), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            VStack(spacing: 2) {
                Text(usedText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let quotaText {
                    Text("/ \(quotaText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(UsageColor.forFraction(fraction))
                } else {
                    Text("未設定上限")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 程式圖示：.app 用系統圖示，其他執行檔用終端機符號。
struct AppIconView: View {
    let path: String?
    var size: CGFloat = 18

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        if let path, path.hasSuffix(".app"), let image = Self.icon(for: path) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }

    private static func icon(for path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// 儀表板上方的數字卡片。
struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // 沒有附註時保留同樣高度，讓同一列的卡片對齊。
            Text(detail ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 一列程式用量（圖示、名稱、比例條、數字）。
struct AppUsageRow: View {
    let app: AppUsage
    let maxTotal: UInt64
    let format: (UInt64) -> String

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(path: app.path)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(app.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(format(app.bytes.total)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                GeometryReader { proxy in
                    let width = maxTotal > 0 ? proxy.size.width * CGFloat(Double(app.bytes.total) / Double(maxTotal)) : 0
                    let rxShare = app.bytes.total > 0 ? CGFloat(Double(app.bytes.rx) / Double(app.bytes.total)) : 0
                    HStack(spacing: 0) {
                        Rectangle().fill(UsageColor.download).frame(width: width * rxShare)
                        Rectangle().fill(UsageColor.upload).frame(width: width * (1 - rxShare))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 4)
            }
        }
    }
}

enum NetworkIcon {
    /// en0 在 MacBook 上是 Wi-Fi；其他 en* 多半是有線或 USB 網卡。
    static func symbol(for interface: String?) -> String {
        interface == "en0" ? "wifi" : "cable.connector"
    }
}

/// 一個網路今天的用量與上限。
struct NetworkUsageRow: View {
    let usage: NetworkUsage
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: NetworkIcon.symbol(for: usage.network.interface))
                    .foregroundStyle(.secondary).frame(width: 14)
                Text(usage.network.displayName).lineLimit(1)
                if usage.isCurrent {
                    Text("目前").font(.caption2).padding(.horizontal, 4)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text(usage.quota.map { "\(format(usage.used)) / \(format($0))" } ?? format(usage.used))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            if let fraction = usage.fraction {
                ProgressView(value: min(fraction, 1))
                    .tint(UsageColor.forFraction(fraction))
                    .controlSize(.mini)
            }
        }
    }
}

extension Date {
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
}
