import SwiftUI

// Hack 風格的動畫特效。系統開啟「減少動態效果」時全部改為靜態。

/// 確定性的偽亂數，讓每一格的字元與速度固定、可重現。
private func noise(_ a: Int, _ b: Int = 0) -> Double {
    var x = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663))
    x ^= x >> 33
    x = x &* 0xff51afd7ed558ccd
    x ^= x >> 33
    return Double(x % 10_000) / 10_000
}

/// Hack 背景：黑底、網格、數位雨、掃描光帶、掃描線。
struct HackBackground: View {
    let theme: Theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ThemeBackground(theme: theme)
            if !reduceMotion {
                MatrixRain(color: theme.accent).opacity(0.22)
                SweepLine(color: theme.accent)
            }
            // 四周暗角
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 250, endRadius: 700)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// 數位雨。
struct MatrixRain: View {
    var color: Color
    var columnWidth: CGFloat = 16
    var trail = 12

    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄ0123456789ABCDEF01")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            Canvas { canvas, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let rowHeight: CGFloat = 16
                let resolved = Self.glyphs.map {
                    canvas.resolve(Text(String($0)).font(.system(size: 13, design: .monospaced)).foregroundColor(color))
                }
                let head = canvas.resolve(Text("0").font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white))
                let columns = Int(size.width / columnWidth) + 1
                let rows = Int(size.height / rowHeight) + trail
                for column in 0..<columns {
                    let speed = 6 + noise(column) * 12               // 每秒幾列
                    let offset = noise(column, 7) * Double(rows)
                    let headRow = Int((t * speed + offset).truncatingRemainder(dividingBy: Double(rows + trail)))
                    let x = CGFloat(column) * columnWidth + columnWidth / 2
                    for i in 0..<trail {
                        let row = headRow - i
                        guard row >= 0 else { continue }
                        let y = CGFloat(row) * rowHeight
                        guard y < size.height + rowHeight else { continue }
                        // 字元每隔一段時間隨機換一次
                        let flip = Int(t * (2 + noise(column, row) * 6))
                        let glyph = resolved[Int(noise(column &* 31 &+ row, flip) * Double(resolved.count)) % resolved.count]
                        canvas.opacity = i == 0 ? 1 : max(0, 1 - Double(i) / Double(trail))
                        canvas.draw(i == 0 ? head : glyph, at: CGPoint(x: x, y: y))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 由上往下掃過的光帶。
struct SweepLine: View {
    var color: Color
    var period: Double = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            GeometryReader { proxy in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                LinearGradient(colors: [.clear, color.opacity(0.10), color.opacity(0.22), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .offset(y: proxy.size.height * phase * 1.3 - 90)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 霓虹呼吸光。
struct Pulse: ViewModifier {
    var active: Bool
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .shadow(color: active ? color.opacity(on ? 0.9 : 0.25) : .clear, radius: on ? 8 : 3)
            .onAppear {
                guard active, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// 偶發的紅青色偏移故障字。
struct GlitchText: View {
    let text: String
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(text).foregroundStyle(color)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let seed = abs(text.hashValue % 997)
                let cycle = 3.3 + Double(seed % 5) * 0.4
                let local = (t + Double(seed)).truncatingRemainder(dividingBy: cycle)
                let glitching = local < 0.18
                let jitter: CGFloat = glitching ? CGFloat(noise(Int(t * 40), seed) * 6 - 3) : 0
                ZStack {
                    if glitching {
                        Text(text).foregroundStyle(Color.cyan.opacity(0.8)).offset(x: jitter - 2)
                        Text(text).foregroundStyle(Color.pink.opacity(0.8)).offset(x: -jitter + 2)
                    }
                    Text(text).foregroundStyle(color).offset(x: glitching ? jitter / 2 : 0)
                }
                .compositingGroup()
            }
        }
    }
}

/// 數字改變時先亂碼、再由左到右逐字定格的「解碼」效果。
struct ScrambleText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date.distantPast
    @State private var previous = ""

    private static let duration = 0.45
    private static let pool = Array("0123456789ABCDEF#%&$@!?")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isScrambling)) { context in
            Text(rendered(at: context.date))
        }
        .onChange(of: text) { old, new in
            guard !reduceMotion, old != new else { return }
            startedAt = Date()
        }
        .onAppear {
            if !reduceMotion { startedAt = Date() }
        }
    }

    private var isScrambling: Bool { Date().timeIntervalSince(startedAt) < Self.duration }

    private func rendered(at date: Date) -> String {
        let progress = date.timeIntervalSince(startedAt) / Self.duration
        guard progress < 1 else { return text }
        let chars = Array(text)
        let locked = Int(Double(chars.count) * max(0, progress))
        let tick = Int(date.timeIntervalSinceReferenceDate * 30)
        return String(chars.enumerated().map { index, char in
            if index < locked || char == " " || char == "." || char == "/" { return char }
            return Self.pool[Int(noise(index, tick) * Double(Self.pool.count)) % Self.pool.count]
        })
    }
}

/// 雷達掃描：旋轉的扇形與外圈刻度，疊在用量環上。
struct RadarSweep: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle()
                        .fill(AngularGradient(colors: [color.opacity(0.0), color.opacity(0.0), color.opacity(0.35)],
                                              center: .center))
                        .rotationEffect(.degrees(t * 90))
                        .mask(Circle().padding(14))
                    Circle()
                        .stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [1, 6]))
                        .padding(-6)
                        .rotationEffect(.degrees(-t * 20))
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// 切換分頁時閃一下的雜訊條。
struct GlitchFlash<Trigger: Equatable>: View {
    let trigger: Trigger
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var firedAt = Date.distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: Date().timeIntervalSince(firedAt) > 0.3)) { context in
            let age = context.date.timeIntervalSince(firedAt)
            if age < 0.25 {
                Canvas { canvas, size in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate * 60)
                    for i in 0..<14 {
                        let y = noise(i, tick) * size.height
                        let h = 2 + noise(i &+ 99, tick) * 14
                        let x = noise(i &+ 7, tick) * size.width * 0.3
                        let color = i % 3 == 0 ? Color.pink : (i % 3 == 1 ? Color.cyan : theme.accent)
                        canvas.fill(Path(CGRect(x: x, y: y, width: size.width * (0.4 + noise(i, 3) * 0.6), height: h)),
                                    with: .color(color.opacity(0.35 * (1 - age / 0.25))))
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            if !reduceMotion { firedAt = Date() }
        }
    }
}

/// 開機畫面：逐行印出啟動訊息後淡出。
struct BootSequence: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var collector: TrafficCollector
    @State private var startedAt = Date()
    @State private var finished = false

    private var lines: [String] {
        let quota = collector.quota.map { String(format: "%.1fGB", $0 / 1_000_000_000) } ?? "∞"
        return [
            "NETQUOTA v1.0 // traffic surveillance kernel",
            "[ OK ] probing interfaces ........ en0 en5 en7",
            "[ OK ] attaching nettop probe ..... pid \(ProcessInfo.processInfo.processIdentifier)",
            "[ OK ] mounting sqlite journal .... WAL",
            "[ OK ] resolving gateway .......... \(collector.currentNetwork?.router ?? "offline")",
            "[ OK ] loading quota table ........ \(collector.focusName) \(quota)",
            "[ OK ] decrypting usage stream .... done",
            "",
            ">>> ACCESS GRANTED <<<",
        ]
    }

    var body: some View {
        if !finished && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let age = context.date.timeIntervalSince(startedAt)
                let shown = min(lines.count, Int(age / 0.11) + 1)
                let fade = age > 1.6 ? max(0, 1 - (age - 1.6) / 0.35) : 1
                ZStack(alignment: .topLeading) {
                    Color.black
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<shown, id: \.self) { index in
                            let line = lines[index]
                            Text(line)
                                .foregroundStyle(line.hasPrefix(">>>") ? theme.bad : theme.accent)
                                .font(.system(size: line.hasPrefix(">>>") ? 18 : 12, weight: .bold, design: .monospaced))
                                .glow(line.hasPrefix(">>>") ? theme.bad : theme.accent)
                        }
                        if shown < lines.count { BlinkingCursor() }
                    }
                    .padding(28)
                    Scanlines(color: .black.opacity(0.4))
                }
                .opacity(fade)
                .onChange(of: fade <= 0) { _, done in if done { finished = true } }
            }
            .allowsHitTesting(false)
        }
    }
}
