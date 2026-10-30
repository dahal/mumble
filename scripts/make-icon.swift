// Builds the macOS AppIcon set from a square source image of the icon artwork.
// Usage: swift scripts/make-icon.swift Design/AppIcon-macOS-source.png Mumble/Assets.xcassets/AppIcon.appiconset
//
// Two kinds of source artwork are handled:
// - Already shaped (transparent corners): the opaque rounded square is located automatically,
//   scaled to Apple's icon grid (an 824 px body on a 1024 px canvas), and anything outside it plus
//   a small glow margin is cleared, removing stray pixels left by image generators.
// - Full-bleed (opaque edge to edge): the artwork is clipped to the macOS rounded-square shape on
//   the same grid, with Apple's standard soft drop shadow underneath.
import AppKit

// Normalize to 8-bit RGBA so pixels can be read and edited directly.
let original = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let originalRep = original.representations.first!
let source = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: originalRep.pixelsWide, pixelsHigh: originalRep.pixelsHigh,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: originalRep.pixelsWide * 4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: source)
original.draw(in: NSRect(x: 0, y: 0, width: originalRep.pixelsWide, height: originalRep.pixelsHigh))
NSGraphicsContext.restoreGraphicsState()
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let pixels = source.bitmapData!
func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * source.pixelsWide + x) * 4 + 3] }

// Opaque corners mean full-bleed artwork that still needs the macOS shape.
let fullBleed = alpha(0, 0) > 230 && alpha(source.pixelsWide - 1, source.pixelsHigh - 1) > 230

// 1. Find the opaque body.
var minX = source.pixelsWide, minY = source.pixelsHigh, maxX = 0, maxY = 0
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where alpha(x, y) > 230 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
let bodyWidth = CGFloat(maxX - minX + 1), bodyHeight = CGFloat(maxY - minY + 1)
let body = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: bodyWidth, height: bodyHeight)  // top-left origin

// 2. Clear pixels farther than `margin` from the body (stray specks), keeping the soft glow.
let margin: CGFloat = 36
let keep = body.insetBy(dx: -margin, dy: -margin)
for y in 0..<source.pixelsHigh where !fullBleed {
    for x in 0..<source.pixelsWide where !keep.contains(CGPoint(x: x, y: y)) {
        let i = (y * source.pixelsWide + x) * 4
        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
    }
}
let cleaned = source
let cleanedImage = NSImage(size: NSSize(width: cleaned.pixelsWide, height: cleaned.pixelsHigh))
cleanedImage.addRepresentation(cleaned)

// 3. Render onto Apple's grid at every size.
func render(_ px: Int) -> Data {
    let canvas = CGFloat(px)
    let scale = (canvas * 824 / 1024) / max(bodyWidth, bodyHeight)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    if fullBleed {
        drawShaped(canvas)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    // Place the body's center at the canvas center (source y is top-down, AppKit is bottom-up).
    let srcSize = CGSize(width: CGFloat(source.pixelsWide), height: CGFloat(source.pixelsHigh))
    let drawSize = CGSize(width: srcSize.width * scale, height: srcSize.height * scale)
    let bodyCenter = CGPoint(x: body.midX * scale, y: (srcSize.height - body.midY) * scale)
    let origin = CGPoint(x: canvas / 2 - bodyCenter.x, y: canvas / 2 - bodyCenter.y)
    cleanedImage.draw(in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Apple's macOS icon template: an 824/1024 rounded square (corner radius 185/1024), centered,
/// with a soft shadow below it (offset 12, blur 28, 30% black at 1024 px).
func drawShaped(_ canvas: CGFloat) {
    let unit = canvas / 1024
    let side = 824 * unit
    let rect = NSRect(x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * unit, yRadius: 185 * unit)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12 * unit)
    shadow.shadowBlurRadius = 28 * unit
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    cleanedImage.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

try? FileManager.default.removeItem(at: outDir)
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
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
print("\(fullBleed ? "Full-bleed artwork, shaped to the macOS icon grid" : "Body \(Int(bodyWidth))×\(Int(bodyHeight)) px"); wrote \(images.count) icons to \(outDir.path)")
