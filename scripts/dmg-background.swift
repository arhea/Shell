// Renders the disk image window background: a dark terminal scene in the app
// icon's palette with a chevron trail from Shell.app to /Applications.
//
//   swift scripts/dmg-background.swift <version> <out.png> [scale]
//
// The canvas is 660×400 points. make-dmg.sh places the icons at the centers
// below, so keep the two in sync.
import AppKit

let width: CGFloat = 660, height: CGFloat = 400
let appCenter = CGPoint(x: 180, y: 190)
let appsCenter = CGPoint(x: 480, y: 190)

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: dmg-background.swift <version> <out.png> [scale]\n".data(using: .utf8)!)
    exit(2)
}
let version = args[1], outPath = args[2]
let scale = args.count > 3 ? CGFloat(Double(args[3]) ?? 1) : 1

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let bgTop = rgb(0x12141D), bgBottom = rgb(0x0B0C12)
let blue = rgb(0x7AA2F7), green = rgb(0x9ECE6A), cyan = rgb(0x7DCFFF)
let text = rgb(0xC0CAF5), dim = rgb(0x565F89), muted = rgb(0xA9B1D6)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
// The context is already scaled to points; flip it to a top-left origin,
// matching Finder's icon coordinates.
cg.translateBy(x: 0, y: height)
cg.scaleBy(x: 1, y: -1)
let ctx = NSGraphicsContext(cgContext: cg, flipped: true)
NSGraphicsContext.current = ctx

// Base gradient.
NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

// Soft glows behind each icon.
func glow(_ c: CGPoint, _ color: NSColor, radius: CGFloat) {
    NSGradient(starting: color, ending: color.withAlphaComponent(0))!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: radius, options: [])
}
glow(appCenter, blue.withAlphaComponent(0.20), radius: 190)
glow(appsCenter, green.withAlphaComponent(0.13), radius: 190)

// Dot grid that fades out toward the edges.
let grid: CGFloat = 22
for gy in stride(from: grid / 2, to: height, by: grid) {
    for gx in stride(from: grid / 2, to: width, by: grid) {
        let dx = (gx - width / 2) / (width / 2), dy = (gy - height / 2) / (height / 2)
        let a = max(0, 0.09 * (1 - (dx * dx + dy * dy) * 0.55))
        rgb(0xFFFFFF, a).setFill()
        NSBezierPath(ovalIn: NSRect(x: gx - 0.8, y: gy - 0.8, width: 1.6, height: 1.6)).fill()
    }
}

// CRT scanlines.
rgb(0x000000, 0.16).setFill()
for sy in stride(from: CGFloat(0), to: height, by: 3) {
    NSRect(x: 0, y: sy, width: width, height: 1).fill()
}

// Monospaced text helpers.
func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .monospacedSystemFont(ofSize: size, weight: weight)
}
func run(_ s: String, _ color: NSColor, _ font: NSFont) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: 0.2])
}
func line(_ parts: [NSAttributedString]) -> NSAttributedString {
    let m = NSMutableAttributedString()
    parts.forEach(m.append)
    return m
}

// Prompt: the command the drag performs, with a block cursor.
let body = mono(13, .medium)
let prompt = line([run("~", cyan, body), run(" ❯ ", green, mono(13, .bold)),
                   run("cp -R Shell.app /Applications", text, body)])
let promptOrigin = CGPoint(x: 28, y: 26)
prompt.draw(at: promptOrigin)
let cursorX = promptOrigin.x + prompt.size().width + 4
green.withAlphaComponent(0.9).setFill()
NSRect(x: cursorX, y: promptOrigin.y + 1, width: 8, height: prompt.size().height - 2).fill()
run("# or drag Shell onto Applications below", dim, mono(12)).draw(at: CGPoint(x: 28, y: 48))

// Chevron trail from app to Applications, echoing the icon's chevron.
cg.saveGState()
cg.setShadow(offset: .zero, blur: 10, color: blue.withAlphaComponent(0.8).cgColor)
let chevrons = 5
for i in 0..<chevrons {
    let t = CGFloat(i) / CGFloat(chevrons - 1)
    let x = 281 + CGFloat(i) * 22, y = appCenter.y
    let color = blue.blended(withFraction: t * 0.35, of: green) ?? blue
    color.withAlphaComponent(0.18 + 0.82 * t).setStroke()
    let p = NSBezierPath()
    p.move(to: CGPoint(x: x, y: y - 11))
    p.line(to: CGPoint(x: x + 11, y: y))
    p.line(to: CGPoint(x: x, y: y + 11))
    p.lineWidth = 4
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.stroke()
}
cg.restoreGState()

// Chips behind Finder's icon labels. Finder draws labels black in light mode
// and white in dark mode, with no way to choose, so the chip is a mid-tone
// (~4.6:1 against both) instead of the dark background.
let labelY: CGFloat = 273   // Label center Finder uses for 128pt icons at 13pt text.
let chip = rgb(0x6B76A6)
for (label, center) in [("Shell.app", appCenter), ("Applications", appsCenter)] {
    let w = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13)]).size().width + 22
    let r = NSRect(x: center.x - w / 2, y: labelY - 11, width: w, height: 22)
    chip.setFill()
    NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11).fill()
    rgb(0xFFFFFF, 0.12).setStroke()
    let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5)
    border.lineWidth = 1
    border.stroke()
}

let hint = run("drag to install", dim, mono(11, .medium))
hint.draw(at: CGPoint(x: width / 2 - hint.size().width / 2 + 5, y: appCenter.y + 22))

// Version badge, top right across from the prompt. Nothing goes along the
// bottom edge: Finder's path bar, when a user has it on, covers it.
let tag = line([run("v\(version)", muted, mono(11, .medium)), run("  ", dim, mono(11)),
                run("● ", green, mono(9)), run("ready", muted, mono(11))])
let badge = run("SHELL", bgBottom, mono(11, .bold))
let tagX = width - 28 - tag.size().width
let badgeRect = NSRect(x: tagX - 10 - badge.size().width - 12, y: promptOrigin.y,
                       width: badge.size().width + 12, height: prompt.size().height)
blue.setFill()
NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3).fill()
badge.draw(at: CGPoint(x: badgeRect.minX + 6, y: badgeRect.midY - badge.size().height / 2))
tag.draw(at: CGPoint(x: tagX, y: badgeRect.midY - tag.size().height / 2))

let platform = run("arm64 · macOS 26+", dim, mono(12))
platform.draw(at: CGPoint(x: width - 28 - platform.size().width, y: 48))

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
