// Renders the app icon (a white waveform on a dark rounded square) at every macOS size.
// Usage: swift scripts/make-icon.swift Mumble/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(colors: [NSColor(calibratedWhite: 0.16, alpha: 1), NSColor(calibratedWhite: 0.02, alpha: 1)])!
        .draw(in: path, angle: -90)

    let heights: [CGFloat] = [0.18, 0.34, 0.56, 0.40, 0.70, 0.46, 0.28, 0.16]
    let barW = body.width * 0.062, gap = body.width * 0.04
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    for (i, h) in heights.enumerated() {
        let height = body.height * h
        let bar = NSRect(x: x, y: body.midY - height / 2, width: barW, height: height)
        let t = CGFloat(i) / CGFloat(heights.count - 1)
        NSColor(calibratedRed: 0.35 + 0.5 * t, green: 0.85 - 0.25 * t, blue: 1.0, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! render(pt * scale).write(to: outDir.appending(path: name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appending(path: "Contents.json"))
print("Wrote \(images.count) icons to \(outDir.path)")
