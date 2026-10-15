// 產生 Resources/AppIcon.icns
//   SDKROOT=$(xcode-select -p)/SDKs/MacOSX.sdk swift scripts/make_icon.swift
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // macOS 圖示網格：824×824 圓角方塊置中
    let card = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: card, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [
        NSColor(red: 0.16, green: 0.20, blue: 0.32, alpha: 1).cgColor,
        NSColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // 格線
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.setLineWidth(4)
    for y in stride(from: 300.0, through: 750.0, by: 150.0) {
        ctx.move(to: CGPoint(x: 160, y: y)); ctx.addLine(to: CGPoint(x: 864, y: y))
    }
    ctx.strokePath()

    // 昨收虛線
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
    ctx.setLineWidth(6)
    ctx.setLineDash(phase: 0, lengths: [18, 14])
    ctx.move(to: CGPoint(x: 160, y: 470)); ctx.addLine(to: CGPoint(x: 864, y: 470))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // 走勢線（紅漲）
    let pts: [CGPoint] = [
        CGPoint(x: 160, y: 430), CGPoint(x: 250, y: 400), CGPoint(x: 330, y: 470), CGPoint(x: 420, y: 455),
        CGPoint(x: 500, y: 560), CGPoint(x: 580, y: 530), CGPoint(x: 660, y: 640), CGPoint(x: 740, y: 610),
        CGPoint(x: 864, y: 760),
    ]
    let line = CGMutablePath()
    line.addLines(between: pts)
    let fill = line.mutableCopy()!
    fill.addLine(to: CGPoint(x: 864, y: 200)); fill.addLine(to: CGPoint(x: 160, y: 200)); fill.closeSubpath()
    ctx.saveGState()
    ctx.addPath(fill); ctx.clip()
    let red = NSColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 1)
    let area = CGGradient(colorsSpace: nil, colors: [red.withAlphaComponent(0.45).cgColor, red.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(area, start: CGPoint(x: 0, y: 760), end: CGPoint(x: 0, y: 220), options: [])
    ctx.restoreGState()

    ctx.addPath(line)
    ctx.setStrokeColor(red.cgColor)
    ctx.setLineWidth(30)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()

    // 最新價圓點
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: 864 - 30, y: 760 - 30, width: 60, height: 60))
    ctx.setFillColor(red.cgColor)
    ctx.fillEllipse(in: CGRect(x: 864 - 18, y: 760 - 18, width: 36, height: 36))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(base * scale).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✅ Resources/AppIcon.icns" : "iconutil failed")
