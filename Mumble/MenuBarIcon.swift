import AppKit

/// The menu bar icon: a crisp vector miniature of the app icon (pink-to-amber rounded square with
/// a cream voice wave), in full color so it stands out. While recording it inverts to a white
/// square with a coral wave.
///
/// Drawn rather than downscaled: at 18 pt the glossy artwork's wave turns to mush.
enum MenuBarIcon {
    static let idle = make(recording: false)
    static let recording = make(recording: true)

    // Sampled from Design/AppIcon-macOS-source.png.
    private static let pink = NSColor(srgbRed: 0.99, green: 0.07, blue: 0.40, alpha: 1)    // #FC1165
    private static let coral = NSColor(srgbRed: 0.99, green: 0.19, blue: 0.31, alpha: 1)   // #FC314E
    private static let amber = NSColor(srgbRed: 0.99, green: 0.69, blue: 0.23, alpha: 1)   // #FCB03A
    private static let cream = NSColor(srgbRed: 1.00, green: 0.97, blue: 0.93, alpha: 1)   // #FFF8ED

    /// The wave's shape in the artwork, as (x, y) fractions of the square, y measured from the top.
    private static let wave: [CGPoint] = [
        (0.00, 0.50), (0.12, 0.50), (0.22, 0.42), (0.315, 0.58), (0.455, 0.26),
        (0.57, 0.70), (0.68, 0.40), (0.78, 0.56), (0.87, 0.47), (0.95, 0.50), (1.00, 0.50),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    static func make(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let square = NSRect(x: 1, y: 0.5, width: 18, height: 17)
            let shape = NSBezierPath(roundedRect: square, xRadius: 4.8, yRadius: 4.8)
            if recording {
                NSColor.white.setFill()
                shape.fill()
                // Faint outline so the white square still has an edge on a light menu bar.
                NSColor(white: 0, alpha: 0.18).setStroke()
                shape.lineWidth = 0.5
                shape.stroke()
            } else {
                NSGradient(colors: [pink, coral, amber])!.draw(in: shape, angle: 45)
            }

            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let path = smoothPath(through: wave.map {
                CGPoint(x: square.minX + $0.x * square.width, y: square.maxY - $0.y * square.height)
            })
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            (recording ? coral : cream).setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = recording ? "Mumble – recording" : "Mumble"
        return image
    }

    /// Catmull-Rom spline through the points, as cubic Béziers.
    private static func smoothPath(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }
}
