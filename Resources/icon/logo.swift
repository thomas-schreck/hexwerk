import AppKit
import CoreGraphics

// Renders the hexwerk app icon (variant A, chosen 2026-11-06; B and C were
// the alternatives). Usage: logo A <size> <out.png> — `make icon` builds
// Resources/AppIcon.icns from it.
let args = CommandLine.arguments
let variant = args[1], size = CGFloat(Double(args[2])!), out = args[3]

func hexagon(center c: CGPoint, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3 + .pi / 6       // pointy top
        let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let s = size / 1024
// macOS icon grid: 824×824 squircle-ish rounded rect centered in 1024.
let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ a: UInt32, _ b: UInt32) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: [color(a), color(b)] as CFArray, locations: [0, 1])!
}

// Soft drop shadow under the tile, like system icons.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x101218))
ctx.fillPath()
ctx.restoreGState()

let center = CGPoint(x: 512 * s, y: 512 * s)
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
switch variant {
case "A", "B":
    ctx.drawLinearGradient(gradient(0x1E2230, 0x0B0D13), start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
default:
    ctx.drawLinearGradient(gradient(0xFFFFFF, 0xE9ECF5), start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
}
ctx.restoreGState()

let hex = hexagon(center: center, radius: 290 * s)
func drawText(_ text: String, size fs: CGFloat, color c: NSColor, weight: NSFont.Weight, dy: CGFloat = 0) {
    let font = NSFont.monospacedSystemFont(ofSize: fs, weight: weight)
    let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c, .kern: -fs * 0.04])
    let line = CTLineCreateWithAttributedString(attr)
    let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: center.x - b.midX, y: center.y - b.midY + dy)
    CTLineDraw(line, ctx)
}

switch variant {
case "A":
    // Hexagon outline in a teal→blue gradient, "0x" inside.
    ctx.saveGState()
    ctx.addPath(hex)
    // Small sizes get a heavier line and bolder text, or the details vanish.
    let small = size <= 64
    ctx.setLineWidth((small ? 78 : 46) * s)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient(0x5EEAD4, 0x3B82F6), start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()
    drawText("0x", size: (small ? 290 : 250) * s, color: .white, weight: small ? .heavy : .semibold, dy: 6 * s)
case "B":
    // Filled gradient hexagon, dark "h".
    ctx.saveGState()
    ctx.addPath(hex)
    ctx.clip()
    ctx.drawLinearGradient(gradient(0x5EEAD4, 0x3B82F6), start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()
    drawText("h", size: 360 * s, color: NSColor(cgColor: color(0x0B0D13))!, weight: .bold, dy: 4 * s)
default:
    // Light tile, indigo hexagon outline with a 2×2 byte grid.
    ctx.addPath(hex)
    ctx.setLineWidth(40 * s)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0x4F46E5))
    ctx.strokePath()
    let cell: CGFloat = 92 * s, gap: CGFloat = 26 * s
    for (i, col) in [0x4F46E5, 0x818CF8, 0x818CF8, 0x4F46E5].enumerated() {
        let x = center.x - cell - gap / 2 + CGFloat(i % 2) * (cell + gap)
        let y = center.y - cell - gap / 2 + CGFloat(i / 2) * (cell + gap)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: cell, height: cell), cornerWidth: 18 * s, cornerHeight: 18 * s, transform: nil))
        ctx.setFillColor(color(UInt32(col)))
        ctx.fillPath()
    }
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
