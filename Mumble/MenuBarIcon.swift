import AppKit

/// The menu bar icon: a miniature of the app icon (dark rounded square with gradient bars),
/// drawn in full color rather than as a template so it stands out. While recording, the
/// square turns red and the bars white.
enum MenuBarIcon {
    static let idle = make(recording: false)
    static let recording = make(recording: true)

    private static let barHeights: [CGFloat] = [0.30, 0.55, 0.85, 0.60, 0.95, 0.50, 0.30]

    static func make(recording: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let square = NSRect(x: 1, y: 0.5, width: 18, height: 17)
            let path = NSBezierPath(roundedRect: square, xRadius: 4.5, yRadius: 4.5)
            if recording {
                NSGradient(colors: [
                    NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.27, alpha: 1),
                    NSColor(calibratedRed: 0.85, green: 0.12, blue: 0.16, alpha: 1),
                ])!.draw(in: path, angle: -90)
            } else {
                NSGradient(colors: [NSColor(calibratedWhite: 0.22, alpha: 1), NSColor(calibratedWhite: 0.04, alpha: 1)])!
                    .draw(in: path, angle: -90)
                // Hairline so the square reads on a dark menu bar too.
                NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }

            let barWidth: CGFloat = 1.5, gap: CGFloat = 0.9
            let total = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
            var x = square.midX - total / 2
            let maxHeight = square.height - 6
            for (i, h) in barHeights.enumerated() {
                let height = max(barWidth, maxHeight * h)
                let bar = NSRect(x: x, y: square.midY - height / 2, width: barWidth, height: height)
                if recording {
                    NSColor.white.setFill()
                } else {
                    let t = CGFloat(i) / CGFloat(barHeights.count - 1)
                    NSColor(calibratedRed: 0.35 + 0.5 * t, green: 0.85 - 0.25 * t, blue: 1.0, alpha: 1).setFill()
                }
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = recording ? "Mumble – recording" : "Mumble"
        return image
    }
}
