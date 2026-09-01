// QuickTerm 图标 1024×1024（程序化，无外部资产）
// 设计：Big Sur 圆角方 + Tokyo Night 渐变底 + scrolling 画布签名场景
// （激活列 accent 边框与 ❯ 提示符、暗色邻列、右缘露边第三列、顶部微型状态条）
// 用法：swift scripts/make-icon.swift <输出.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

// Tokyo Night
let bg0 = NSColor(red: 0x24 / 255, green: 0x28 / 255, blue: 0x3b / 255, alpha: 1)
let bg1 = NSColor(red: 0x16 / 255, green: 0x16 / 255, blue: 0x1e / 255, alpha: 1)
let paneBG = NSColor(red: 0x1a / 255, green: 0x1b / 255, blue: 0x26 / 255, alpha: 1)
let accent = NSColor(red: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255, alpha: 1)
let green = NSColor(red: 0x9e / 255, green: 0xce / 255, blue: 0x6a / 255, alpha: 1)
let magenta = NSColor(red: 0xbb / 255, green: 0x9a / 255, blue: 0xf7 / 255, alpha: 1)
let muted = NSColor(red: 0x56 / 255, green: 0x5f / 255, blue: 0x89 / 255, alpha: 1)
let inactiveBorder = NSColor(white: 0x59 / 255.0, alpha: 0.9)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// ── Big Sur 圆角方（824×824 居中，半径 185）
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

// 底部投影（轻微，贴合系统图标习惯）
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
bg1.setFill()
squircle.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// 渐变底（对角，Tokyo Night 夜空感）
NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [bg0, bg1])?.draw(in: rect, angle: -60)

// ── 内容区几何
let pad: CGFloat = 92
let content = rect.insetBy(dx: pad, dy: pad)

// 顶部微型状态条：◆ + 工作区点
let barH: CGFloat = 46
let barY = content.maxY - barH
func diamond(at center: NSPoint, r: CGFloat, color: NSColor) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: center.x, y: center.y + r))
    p.line(to: NSPoint(x: center.x + r, y: center.y))
    p.line(to: NSPoint(x: center.x, y: center.y - r))
    p.line(to: NSPoint(x: center.x - r, y: center.y))
    p.close()
    color.setFill()
    p.fill()
}
diamond(at: NSPoint(x: content.minX + 24, y: barY + barH / 2), r: 20, color: accent)
for i in 0..<4 {
    let dot = NSRect(x: content.minX + 72 + CGFloat(i) * 42, y: barY + barH / 2 - 7,
                     width: 14, height: 14)
    (i == 0 ? accent : muted).setFill()
    NSBezierPath(rect: dot).fill()
}
// 状态条右侧：时钟刻度线
muted.setFill()
NSBezierPath(rect: NSRect(x: content.maxX - 150, y: barY + barH / 2 - 5,
                          width: 150, height: 10)).fill()

// ── 三列 scrolling 场景（激活 + 暗列 + 右缘露边）
let gap: CGFloat = 26
let paneTop = barY - 34
let paneBottom = content.minY
let paneH = paneTop - paneBottom
let activeW = content.width * 0.46
let dimW = content.width * 0.40
let border: CGFloat = 10

func pane(_ r: NSRect, borderColor: NSColor, fill: NSColor) {
    fill.setFill()
    NSBezierPath(rect: r).fill()
    borderColor.setStroke()
    let b = NSBezierPath(rect: r.insetBy(dx: border / 2, dy: border / 2))
    b.lineWidth = border
    b.stroke()
}

// 激活列（左）
let active = NSRect(x: content.minX, y: paneBottom, width: activeW, height: paneH)
pane(active, borderColor: accent, fill: paneBG)

// ❯ 提示符 + 光标块（整体在列内水平居中，光标不越过边框）
let promptFont = NSFont(name: "Monaco", size: 260) ?? .monospacedSystemFont(ofSize: 260, weight: .bold)
let prompt = NSAttributedString(string: "❯", attributes: [
    .font: promptFont, .foregroundColor: green,
])
let ps = prompt.size()
let cursorW: CGFloat = 54
let cursorGap: CGFloat = 26
let groupW = ps.width + cursorGap + cursorW
let groupX = active.minX + (active.width - groupW) / 2
prompt.draw(at: NSPoint(x: groupX, y: active.midY - ps.height / 2 + 8))
accent.setFill()
let cursorX = min(groupX + ps.width + cursorGap, active.maxX - border - 24 - cursorW)
NSBezierPath(rect: NSRect(x: cursorX, y: active.midY - 80,
                          width: cursorW, height: 168)).fill()

// 暗列（中）：三条内容示意线
let dim = NSRect(x: active.maxX + gap, y: paneBottom, width: dimW, height: paneH)
pane(dim, borderColor: inactiveBorder, fill: bg1)
let lineWidths: [CGFloat] = [0.62, 0.45, 0.72]
let lineColors: [NSColor] = [magenta.withAlphaComponent(0.55),
                             muted, accent.withAlphaComponent(0.45)]
for (i, w) in lineWidths.enumerated() {
    lineColors[i].setFill()
    NSBezierPath(rect: NSRect(
        x: dim.minX + 44,
        y: dim.maxY - 96 - CGFloat(i) * 74,
        width: dim.width * w, height: 26)).fill()
}

// 露边列（右缘，被圆角裁掉一部分——scrolling 的"右边还有"）
let peek = NSRect(x: dim.maxX + gap, y: paneBottom,
                  width: rect.maxX - (dim.maxX + gap), height: paneH)
pane(peek, borderColor: inactiveBorder, fill: bg1)

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
