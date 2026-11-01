import AppKit
import SwiftUI

/// 介面風格。
enum AppTheme: String, CaseIterable, Identifiable {
    case standard
    case glass
    case hack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "預設"
        case .glass: "Glass"
        case .hack: "Hack"
        }
    }

    var subtitle: String {
        switch self {
        case .standard: "原本的樣式。系統支援時（macOS 26 且沒開「減少透明度」）自動套用 Apple Liquid Glass 的控制元件"
        case .glass: "透明玻璃面板：視窗透出桌布，卡片與控制都是 Clear Liquid Glass（需要 macOS 26）"
        case .hack: "黑底霓虹、終端機風格"
        }
    }
}

/// 一種風格的配色、字體與外觀細節。
struct Theme {
    let kind: AppTheme
    let accent: Color
    let download: Color
    let upload: Color
    let good: Color
    let warn: Color
    let bad: Color
    let secondary: Color
    var cardRadius: CGFloat
    /// 「預設」風格在系統支援時採用 Apple Liquid Glass 的版面（由 ThemedRoot 依系統狀態設定）。
    var liquidGlass = false

    var isHack: Bool { kind == .hack }
    /// Glass 外觀風格；只有 macOS 26 才有 Liquid Glass，舊系統退回毛玻璃材質。
    var isGlass: Bool {
        if #available(macOS 26.0, *) { return kind == .glass }
        return false
    }

    /// 依系統狀態調整：macOS 26 且沒開「減少透明度」時，「預設」風格採用 Apple Liquid Glass。
    func adapted(reduceTransparency: Bool) -> Theme {
        var copy = self
        if #available(macOS 26.0, *), kind == .standard, !reduceTransparency {
            copy.liquidGlass = true
            copy.cardRadius = 12
        }
        return copy
    }

    func forFraction(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: good
        case ..<0.9: warn
        default: bad
        }
    }

    /// 區塊標題：Hack 風格加上提示字元。
    func heading(_ text: String) -> String {
        isHack ? "> \(text)" : text
    }

    /// 卡片上的小標：Hack 風格加上註解符號。
    func label(_ text: String) -> String {
        isHack ? "// \(text)" : text
    }

    static let standard = Theme(
        kind: .standard,
        accent: .accentColor,
        download: .blue,
        upload: .purple,
        good: .green,
        warn: .orange,
        bad: .red,
        secondary: .secondary,
        cardRadius: 8
    )

    /// 透明玻璃上用較亮的顏色，壓在桌布上也看得清楚。
    static let glass = Theme(
        kind: .glass,
        accent: .accentColor,
        download: Color(red: 0.45, green: 0.78, blue: 1.00),
        upload: Color(red: 0.88, green: 0.62, blue: 1.00),
        good: Color(red: 0.42, green: 0.92, blue: 0.58),
        warn: Color(red: 1.00, green: 0.72, blue: 0.30),
        bad: Color(red: 1.00, green: 0.45, blue: 0.45),
        secondary: .secondary,
        cardRadius: 14
    )

    static let hack = Theme(
        kind: .hack,
        accent: Color(red: 0.22, green: 1.00, blue: 0.53),
        download: Color(red: 0.00, green: 0.90, blue: 1.00),
        upload: Color(red: 1.00, green: 0.24, blue: 0.80),
        good: Color(red: 0.22, green: 1.00, blue: 0.53),
        warn: Color(red: 1.00, green: 0.77, blue: 0.00),
        bad: Color(red: 1.00, green: 0.23, blue: 0.36),
        secondary: Color(red: 0.22, green: 1.00, blue: 0.53).opacity(0.55),
        cardRadius: 4
    )

    static func of(_ kind: AppTheme) -> Theme {
        switch kind {
        case .standard: .standard
        case .glass: .glass
        case .hack: .hack
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.standard
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// 把目前的風格套到整個畫面：配色、字體、明暗、強調色。
struct ThemedRoot<Content: View>: View {
    @ObservedObject var settings: AppSettings
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let theme = Theme.of(settings.theme).adapted(reduceTransparency: reduceTransparency)
        content
            .environment(\.theme, theme)
            .fontDesign(theme.isHack ? .monospaced : .default)
            .tint(theme.accent)
            // 透明玻璃壓在桌布上，深色模式文字比較好讀。
            .preferredColorScheme(theme.isHack || theme.kind == .glass ? .dark : nil)
    }
}

// MARK: - 背景

/// Hack 風格的視窗與面板背景。
struct ThemeBackground: View {
    /// 視窗背景（containerBackground）收不到環境值的更新，所以由呼叫端直接傳入。
    let theme: Theme

    var body: some View {
        ZStack {
            Color(red: 0.01, green: 0.03, blue: 0.02)
            GridPattern(spacing: 24, color: theme.accent.opacity(0.06))
            RadialGradient(colors: [theme.accent.opacity(0.10), .clear], center: .top, startRadius: 0, endRadius: 520)
            Scanlines(color: .black.opacity(0.35))
        }
        .ignoresSafeArea()
    }
}

/// Glass 風格的視窗背景：視窗本身透明（見 WindowTransparency），後方畫面先模糊再稍微暗化，
/// 透明玻璃面板疊在上面才讀得清楚（Apple 對 Clear 玻璃的建議：底下內容雜時要加處理）。
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            BehindWindowBlur()
            Color.black.opacity(0.18)
        }
        .ignoresSafeArea()
    }
}

/// 系統的「視窗後方模糊」，和 Finder 側邊欄、選單同一種做法。
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 讓視窗透明，桌布才會透到玻璃後面。
struct WindowTransparency: NSViewRepresentable {
    var clear: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = !clear
            window.backgroundColor = clear ? .clear : .windowBackgroundColor
        }
    }
}

/// CRT 掃描線。
struct Scanlines: View {
    var color: Color
    var spacing: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(color))
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

struct GridPattern: View {
    var spacing: CGFloat
    var color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 卡片與發光

/// 內容卡片。
/// - 預設＋Apple Liquid Glass：依 Apple 的說明，玻璃只用在控制與導覽層，內容卡片用一般背景。
/// - Glass：刻意做成透明玻璃面板的外觀（Clear Liquid Glass）。
private struct ThemedCard: ViewModifier {
    @Environment(\.theme) private var theme
    var padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        switch theme.kind {
        case .hack:
            content
                .padding(padding)
                .background(Color.black.opacity(0.55), in: shape)
                .overlay(shape.strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                .shadow(color: theme.accent.opacity(0.25), radius: 6)
        case .glass:
            if #available(macOS 26.0, *) {
                content
                    .padding(padding + 4)
                    .glassEffect(.clear, in: shape)
            } else {
                content
                    .padding(padding + 4)
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            }
        case .standard where theme.liquidGlass:
            content
                .padding(padding + 2)
                .background(.background.secondary, in: shape)
        default:
            content
                .padding(padding)
                .background(.quaternary.opacity(0.5), in: shape)
        }
    }
}

private struct Panel: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if theme.isHack {
            content.themedCard(padding: 8)
        } else {
            content
        }
    }
}

private struct Glow: ViewModifier {
    @Environment(\.theme) private var theme
    var color: Color?

    func body(content: Content) -> some View {
        if theme.isHack {
            content.shadow(color: (color ?? theme.accent).opacity(0.8), radius: 4)
        } else {
            content
        }
    }
}

extension View {
    /// 圖表、表格等大區塊的外框：只有 Hack 風格加直角邊框，其他風格不加，避免一層層圓角框。
    func panel() -> some View {
        modifier(Panel())
    }

    func themedCard(padding: CGFloat = 12) -> some View {
        modifier(ThemedCard(padding: padding))
    }

    /// Hack 風格的霓虹發光；Glass 風格不做任何事。
    func glow(_ color: Color? = nil) -> some View {
        modifier(Glow(color: color))
    }
}

// MARK: - Hack 專用小元件

/// 方塊字進度條，例如 ▓▓▓▓▓▓░░░░。
struct BlockBar: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    var cells = 20
    var color: Color?

    var body: some View {
        let filled = Int((min(max(fraction, 0), 1) * Double(cells)).rounded())
        HStack(spacing: 0) {
            Text(String(repeating: "▓", count: filled)).foregroundStyle(color ?? theme.forFraction(fraction))
            Text(String(repeating: "░", count: cells - filled)).foregroundStyle(theme.secondary.opacity(0.5))
        }
        .font(.system(size: 10, design: .monospaced))
        .glow(color ?? theme.forFraction(fraction))
    }
}

/// 閃爍的游標。
struct BlinkingCursor: View {
    @Environment(\.theme) private var theme
    @State private var visible = true

    var body: some View {
        Text("█")
            .foregroundStyle(theme.accent)
            .opacity(visible ? 1 : 0)
            .glow()
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever()) { visible.toggle() }
            }
    }
}
