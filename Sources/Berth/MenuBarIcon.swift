import AppKit

/// The menu bar glyph: the Berth star. Outlined when idle, filled when a
/// device is mounted. Drawn as a template image so the system tints it for
/// light/dark menu bars.
enum MenuBarIcon {

    private static let pointSize: CGFloat = 16

    /// Five-point star, one tip straight up, slightly tilted like the app icon.
    private static func starPath(center: NSPoint, outer: CGFloat, inner: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let tilt = 8.0 * .pi / 180
        for i in 0..<10 {
            let radius = i % 2 == 0 ? outer : inner
            let angle = .pi / 2 + tilt + Double(i) * .pi / 5   // AppKit y is up
            let point = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    static func image(mounted: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
            let center = NSPoint(x: pointSize / 2 + 0.3, y: pointSize / 2 - 0.2)
            let lineWidth: CGFloat = 1.3
            let path = starPath(center: center, outer: 6.6, inner: 3.1)
            NSColor.black.set()
            path.lineWidth = lineWidth
            if mounted {
                path.fill()
                path.stroke()   // rounds the tips
            } else {
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
