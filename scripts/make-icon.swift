// 生成 QuickTerm 图标 1024×1024 PNG（Tokyo Night 圆角方 + accent ◆ + 平铺格线）
// 用法：swift scripts/make-icon.swift <输出.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Big Sur 风格：留边距的圆角方
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSColor(red: 0x1a / 255.0, green: 0x1b / 255.0, blue: 0x26 / 255.0, alpha: 1).setFill()
path.fill()

let accent = NSColor(red: 0x7a / 255.0, green: 0xa2 / 255.0, blue: 0xf7 / 255.0, alpha: 1)

// 平铺格线（dwindle 示意：左右分 + 右侧上下分）
accent.withAlphaComponent(0.55).setStroke()
let grid = NSBezierPath()
grid.lineWidth = 14
let midX = rect.midX + 40
grid.move(to: NSPoint(x: midX, y: rect.minY + 90))
grid.line(to: NSPoint(x: midX, y: rect.maxY - 90))
grid.move(to: NSPoint(x: midX, y: rect.midY))
grid.line(to: NSPoint(x: rect.maxX - 90, y: rect.midY))
grid.stroke()

// 左格 prompt ❯
let promptAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "Monaco", size: 240) ?? NSFont.monospacedSystemFont(ofSize: 240, weight: .bold),
    .foregroundColor: accent,
]
let prompt = NSAttributedString(string: "❯", attributes: promptAttrs)
prompt.draw(at: NSPoint(x: rect.minX + 110, y: rect.midY - 130))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("render failed\n", stderr)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("OK: \(out)")
