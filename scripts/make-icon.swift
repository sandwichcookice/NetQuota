// 產生 App 圖示：swift scripts/make-icon.swift <輸出的 .icns 路徑>
// 設計：深藍漸層圓角方塊 + 用量儀表弧（綠→橘→紅）+ 中央下載／上傳箭頭。
import AppKit

let size: CGFloat = 1024

func drawIcon(in ctx: CGContext) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // macOS 圖示格線：824×824 的主體，置中。
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1B2550))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: colorSpace,
                                colors: [color(0x2F5BD8), color(0x1A2463)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // 上方柔光
    let glow = CGGradient(colorsSpace: colorSpace,
                          colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])
    ctx.restoreGState()

    // 儀表弧：從左下 225° 順時針到右下 -45°，共 270°。
    let center = CGPoint(x: 512, y: 490)
    let radius: CGFloat = 290
    let width: CGFloat = 64
    let start: CGFloat = 225, sweep: CGFloat = 270
    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    ctx.setStrokeColor(color(0xFFFFFF, 0.16))
    ctx.addArc(center: center, radius: radius, startAngle: start * .pi / 180,
               endAngle: (start - sweep) * .pi / 180, clockwise: true)
    ctx.strokePath()

    // 已用的部分（約 68%），顏色依角度由綠漸變到橘。
    let filled: CGFloat = 0.68
    let steps = 120
    let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
        (0, (0.20, 0.85, 0.45)), (0.6, (0.98, 0.80, 0.20)), (1, (1.0, 0.45, 0.25)),
    ]
    func gaugeColor(_ t: CGFloat) -> CGColor {
        for i in 0..<(stops.count - 1) where t <= stops[i + 1].0 {
            let (t0, c0) = stops[i], (t1, c1) = stops[i + 1]
            let k = (t - t0) / (t1 - t0)
            return CGColor(red: c0.0 + (c1.0 - c0.0) * k, green: c0.1 + (c1.1 - c0.1) * k,
                           blue: c0.2 + (c1.2 - c0.2) * k, alpha: 1)
        }
        return CGColor(red: 1, green: 0.45, blue: 0.25, alpha: 1)
    }
    ctx.setLineCap(.butt)
    for i in 0..<steps {
        let t0 = CGFloat(i) / CGFloat(steps) * filled
        let t1 = CGFloat(i + 1) / CGFloat(steps) * filled + 0.002
        ctx.setStrokeColor(gaugeColor(t0 / filled * filled))
        ctx.addArc(center: center, radius: radius, startAngle: (start - sweep * t0) * .pi / 180,
                   endAngle: (start - sweep * min(t1, filled)) * .pi / 180, clockwise: true)
        ctx.strokePath()
    }
    // 圓頭端點
    for (t, c) in [(CGFloat(0), gaugeColor(0)), (filled, gaugeColor(filled))] {
        let angle = (start - sweep * t) * .pi / 180
        let p = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
    }

    // 中央箭頭：左邊下載（向下、淺藍），右邊上傳（向上、粉紫）。
    func arrow(x: CGFloat, up: Bool, fill: CGColor) {
        let shaftW: CGFloat = 56, headW: CGFloat = 150, headH: CGFloat = 120, total: CGFloat = 330
        let top = center.y + total / 2, bottom = center.y - total / 2
        let path = CGMutablePath()
        if up {
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x + headW / 2, y: top - headH))
            path.addLine(to: CGPoint(x: x + shaftW / 2, y: top - headH))
            path.addLine(to: CGPoint(x: x + shaftW / 2, y: bottom))
            path.addLine(to: CGPoint(x: x - shaftW / 2, y: bottom))
            path.addLine(to: CGPoint(x: x - shaftW / 2, y: top - headH))
            path.addLine(to: CGPoint(x: x - headW / 2, y: top - headH))
        } else {
            path.move(to: CGPoint(x: x, y: bottom))
            path.addLine(to: CGPoint(x: x + headW / 2, y: bottom + headH))
            path.addLine(to: CGPoint(x: x + shaftW / 2, y: bottom + headH))
            path.addLine(to: CGPoint(x: x + shaftW / 2, y: top))
            path.addLine(to: CGPoint(x: x - shaftW / 2, y: top))
            path.addLine(to: CGPoint(x: x - shaftW / 2, y: bottom + headH))
            path.addLine(to: CGPoint(x: x - headW / 2, y: bottom + headH))
        }
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.3))
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }
    arrow(x: center.x - 85, up: false, fill: color(0x8FD3FF))
    arrow(x: center.x + 85, up: true, fill: color(0xF3A6FF))
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    drawIcon(in: ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("NetQuota-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(pixels: 1024).write(to: output.deletingPathExtension().appendingPathExtension("png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard task.terminationStatus == 0 else { fatalError("iconutil 失敗") }
print("已產生 \(output.path)")
