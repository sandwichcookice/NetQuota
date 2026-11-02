import AppKit
import NetQuotaCore
import SwiftUI

/// 今日用量的圓環。Hack 風格為虛線刻度環並發光。
struct UsageRing: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    let usedText: String
    /// nil 代表沒有設定上限。
    let quotaText: String?
    var lineWidth: CGFloat = 12

    var body: some View {
        let color = quotaText == nil ? theme.secondary : theme.forFraction(fraction)
        let spoken = quotaText.map { "已用 \(usedText)，上限 \($0)，\(Int((fraction * 100).rounded()))%" } ?? "已用 \(usedText)，沒有上限"
        let style = theme.isHack
            ? StrokeStyle(lineWidth: lineWidth, lineCap: .butt, dash: [3, 2])
            : StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            Circle().stroke(theme.isHack ? theme.accent.opacity(0.12) : Color.secondary.opacity(0.15), style: style)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(theme.isHack ? AnyShapeStyle(color) : AnyShapeStyle(AngularGradient(
                    colors: [color.opacity(0.65), color], center: .center,
                    startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.01)))), style: style)
                .rotationEffect(.degrees(-90))
                .glow(color)
                .animation(.easeOut(duration: 0.4), value: fraction)
            if theme.isHack {
                Circle().stroke(theme.accent.opacity(0.25), lineWidth: 0.5).padding(lineWidth + 4)
                RadarSweep(color: color).padding(lineWidth / 2)
            }
            VStack(spacing: 2) {
                Group {
                    if theme.isHack { ScrambleText(text: usedText) } else { Text(usedText) }
                }
                    .font(.system(size: theme.isHack ? 17 : 20, weight: theme.isHack ? .bold : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.isHack ? theme.accent : .primary)
                    .glow()
                if let quotaText {
                    Text("/ \(quotaText)")
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                    Text(theme.isHack ? "[\(Int((fraction * 100).rounded()))%]" : "\(Int((fraction * 100).rounded()))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .glow(color)
                } else {
                    Text(theme.isHack ? "NO_LIMIT" : "未設定上限")
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日用量")
        .accessibilityValue(spoken)
    }
}

/// 流量監測模式取代圓環：只顯示今日用量的大數字，大小與 UsageRing 相同。
struct UsageFigure: View {
    @Environment(\.theme) private var theme
    let usedText: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.title3)
                .foregroundStyle(theme.secondary)
                .glow()
            Group {
                if theme.isHack { ScrambleText(text: usedText) } else { Text(usedText) }
            }
            .font(.system(size: theme.isHack ? 22 : 26, weight: .bold))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(theme.isHack ? theme.accent : .primary)
            .glow()
            Text(theme.isHack ? "[TODAY]" : "今日用量")
                .font(.caption)
                .foregroundStyle(theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日用量")
        .accessibilityValue(usedText)
    }
}

/// 程式圖示：.app 用系統圖示，其他執行檔用終端機符號。
struct AppIconView: View {
    @Environment(\.theme) private var theme
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
                .foregroundStyle(theme.secondary)
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
    @Environment(\.theme) private var theme
    let title: String
    let value: String
    var detail: String?
    /// nil 用預設文字色（Hack 風格為霓虹綠）。
    var tint: Color?

    var body: some View {
        let color = tint ?? (theme.isHack ? theme.accent : .primary)
        VStack(alignment: .leading, spacing: 4) {
            Text(theme.label(title)).font(.caption).foregroundStyle(theme.secondary)
            Group {
                if theme.isHack { ScrambleText(text: value) } else { Text(value) }
            }
                .font(.system(size: 18, weight: theme.isHack ? .bold : .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .glow(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // 沒有附註時保留同樣高度，讓同一列的卡片對齊。
            Text(detail ?? " ").font(.caption).foregroundStyle(theme.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: "，"))
    }
}

/// 一列程式用量（圖示、名稱、比例條、數字）。
struct AppUsageRow: View {
    @Environment(\.theme) private var theme
    let app: AppUsage
    let maxTotal: UInt64
    let format: (UInt64) -> String

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(path: app.path)
                .saturation(theme.isHack ? 0 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(app.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(format(app.bytes.total)).monospacedDigit().foregroundStyle(theme.secondary)
                }
                .font(.callout)
                if theme.isHack {
                    BlockBar(fraction: maxTotal > 0 ? Double(app.bytes.total) / Double(maxTotal) : 0, cells: 32,
                             color: theme.download)
                } else {
                    GeometryReader { proxy in
                        let width = maxTotal > 0 ? proxy.size.width * CGFloat(Double(app.bytes.total) / Double(maxTotal)) : 0
                        let rxShare = app.bytes.total > 0 ? CGFloat(Double(app.bytes.rx) / Double(app.bytes.total)) : 0
                        HStack(spacing: 0) {
                            Rectangle().fill(theme.download).frame(width: width * rxShare)
                            Rectangle().fill(theme.upload).frame(width: width * (1 - rxShare))
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 4)
                }
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
    @Environment(\.theme) private var theme
    let usage: NetworkUsage
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: NetworkIcon.symbol(for: usage.network.interface))
                    .foregroundStyle(theme.secondary).frame(width: 14)
                Text(usage.network.displayName).lineLimit(1)
                if usage.isCurrent {
                    Text(theme.isHack ? "*" : "目前").font(.caption2).padding(.horizontal, 4)
                        .background(theme.accent.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text(usage.quota.map { "\(format(usage.used)) / \(format($0))" } ?? format(usage.used))
                    .monospacedDigit().foregroundStyle(theme.secondary)
            }
            .font(.callout)
            if let fraction = usage.fraction {
                if theme.isHack {
                    BlockBar(fraction: fraction, cells: 32)
                } else {
                    ProgressView(value: min(fraction, 1))
                        .tint(theme.forFraction(fraction))
                        .controlSize(.mini)
                }
            }
        }
    }
}

/// 區塊標題。
struct SectionTitle: View {
    @Environment(\.theme) private var theme
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Group {
            if theme.isHack {
                GlitchText(text: theme.heading(text), color: theme.accent)
            } else {
                Text(text)
            }
        }
        .font(.headline)
        .glow()
    }
}

extension Date {
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
    /// 全 App 統一的日期時間寫法，例如「11/2 01:48」。
    var shortDateTime: String { "\(shortDate) \(formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))" }
    /// 例如「11/2」。
    var shortDate: String {
        let parts = Calendar.current.dateComponents([.month, .day], from: self)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
}

/// "2026-11-02" → "11/2"
func shortDayLabel(_ key: String) -> String {
    let parts = key.split(separator: "-")
    guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return key }
    return "\(month)/\(day)"
}
