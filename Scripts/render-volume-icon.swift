import AppKit
import Foundation

// Volume (Finder sidebar) glyph: a white tablet on Berth blue, with the
// Berth star as a badge in the lower-right corner.

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let field = NSColor(srgbRed: 0x17 / 255, green: 0x2E / 255, blue: 0xB0 / 255, alpha: 1)
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                      xRadius: size * 0.22, yRadius: size * 0.22)
field.setFill()
bg.fill()

if let sym = NSImage(systemSymbolName: "ipad", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.56, weight: .regular)
    let configured = sym.withSymbolConfiguration(cfg) ?? sym
    let drawSize = configured.size
    // Tint white: fill white, then keep it only where the symbol has alpha.
    let white = NSImage(size: drawSize)
    white.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: drawSize).fill()
    configured.draw(in: NSRect(origin: .zero, size: drawSize), from: .zero, operation: .destinationIn, fraction: 1.0)
    white.unlockFocus()
    let x = (size - drawSize.width) / 2 - size * 0.04
    let y = (size - drawSize.height) / 2 + size * 0.03
    white.draw(in: NSRect(x: x, y: y, width: drawSize.width, height: drawSize.height),
               from: .zero, operation: .sourceOver, fraction: 1.0)
}

// Star badge
func hex(_ v: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
let colors = [hex(0x4285F4), hex(0xEA4335), hex(0xFBBC04), hex(0x34A853), hex(0x8AB4F8)]
let c = NSPoint(x: size * 0.70, y: size * 0.26)
let outer = size * 0.20, inner = size * 0.093
let rot = (8.0 + 90.0) * .pi / 180   // clockwise from just left of straight up, like the app icon
func vertex(_ i: Int) -> NSPoint {
    let r = i % 2 == 0 ? outer : inner
    let a = rot - Double(i) * .pi / 5   // clockwise
    return NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
}
// Backing disc so the star reads on top of the tablet
let disc = NSBezierPath(ovalIn: NSRect(x: c.x - outer * 1.25, y: c.y - outer * 1.25, width: outer * 2.5, height: outer * 2.5))
field.setFill()
disc.fill()
for i in 0..<5 {
    let kite = NSBezierPath()
    kite.move(to: c)
    kite.line(to: vertex((2 * i + 9) % 10))
    kite.line(to: vertex(2 * i))
    kite.line(to: vertex(2 * i + 1))
    kite.close()
    kite.lineJoinStyle = .round
    kite.lineWidth = size * 0.016
    colors[i].setFill()
    colors[i].setStroke()
    kite.fill()
    kite.stroke()
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/volume-icon.png"
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
