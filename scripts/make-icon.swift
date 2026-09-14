// QuickTerm icon, 1024×1024 (generated in code, no external assets)
// Design: Apple style — a single symbol (the ❯ prompt plus a cursor block), no scene detail;
// the sense of depth comes from the squircle body gradient + top rim light + top spherical sheen
// + bottom bounce light + glyph shadow.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Tokyo Night night sky: lighter at the top, darker at the bottom (light from above, the Apple
// icon convention)
let bodyTop = rgb(0x39456f)
let bodyBottom = rgb(0x11131d)
let accent = rgb(0x7aa2f7)
let glyph = rgb(0xf4f7ff)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// ── Squircle (824×824, centered, radius 185 — the macOS icon grid)
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

// Drop shadow (the icon floats above the desktop)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.shadowBlurRadius = 32
shadow.set()
bodyBottom.setFill()
squircle.fill()
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()

// Body gradient (vertical, light at the top to dark at the bottom = volume)
NSGradient(colors: [bodyTop, bodyBottom])?.draw(in: rect, angle: -90)

// Top spherical sheen (wide radial gradient, mimicking a light above hitting a curved surface)
if let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.16),
                                   NSColor.white.withAlphaComponent(0)]) {
    sheen.draw(fromCenter: NSPoint(x: rect.midX, y: rect.maxY + rect.height * 0.12),
               radius: 0,
               toCenter: NSPoint(x: rect.midX, y: rect.maxY + rect.height * 0.12),
               radius: rect.width * 0.78,
               options: [])
}

// Bottom bounce light (ambient light reflected up off the desk, killing the "sticker" look)
if let bounce = NSGradient(colors: [accent.withAlphaComponent(0.14),
                                    accent.withAlphaComponent(0)]) {
    bounce.draw(fromCenter: NSPoint(x: rect.midX, y: rect.minY),
                radius: 0,
                toCenter: NSPoint(x: rect.midX, y: rect.minY),
                radius: rect.width * 0.55,
                options: [])
}
NSGraphicsContext.current?.restoreGraphicsState()

// Rim light: a thin stroke around the edge, bright on top and dark below (glass-edge refraction)
NSGraphicsContext.current?.saveGraphicsState()
let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
ctx.addPath(rim.cgPath)
ctx.setLineWidth(5)
ctx.replacePathWithStrokedPath()
ctx.clip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.42),
                    NSColor.white.withAlphaComponent(0.04),
                    NSColor.black.withAlphaComponent(0.22)])?.draw(in: rect, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

// ── Symbol: ❯ + cursor block (the only content; round caps, an SF Symbols feel)
NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()

let stroke: CGFloat = 76
let spanX: CGFloat = 168
let spanY: CGFloat = 328
let cursorW: CGFloat = 88
let cursorH: CGFloat = 300
let pairGap: CGFloat = 62
let groupW = (spanX + stroke) + pairGap + cursorW
let gx = rect.midX - groupW / 2 + stroke / 2
let cy = rect.midY

// Glyph shadow: separates the symbol from the body gradient so it reads as floating above the face
let glyphShadow = NSShadow()
glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
glyphShadow.shadowOffset = NSSize(width: 0, height: -10)
glyphShadow.shadowBlurRadius = 24
glyphShadow.set()

let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: gx, y: cy + spanY / 2))
chevron.line(to: NSPoint(x: gx + spanX, y: cy))
chevron.line(to: NSPoint(x: gx, y: cy - spanY / 2))
chevron.lineWidth = stroke
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
glyph.setStroke()
chevron.stroke()

let cursor = NSBezierPath(
    roundedRect: NSRect(x: gx + spanX + stroke / 2 + pairGap, y: cy - cursorH / 2,
                        width: cursorW, height: cursorH),
    xRadius: cursorW / 2, yRadius: cursorW / 2)
accent.setFill()
cursor.fill()
NSGraphicsContext.current?.restoreGraphicsState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("render failed\n", stderr)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("OK: \(out)")
