// Draws the nxtch app icon: one line that runs along the top, drops to trace the notch, and
// beats inside it. Ultraviolet to lilac on black.
// Usage: swift Resources/make-icon.swift <output.png>     (build.sh does not run this;
// Resources/AppIcon.icns is checked in. Re-run it and rebuild the .icns to change the icon.)
import AppKit

let N: CGFloat = 1024
func rgb(_ h: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
let body = CGRect(x: 100, y: 100, width: 824, height: 824)   // macOS icon grid
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
let ultraviolet = 0x6A00FF, lilac = 0xD3B4FF

let ctx = CGContext(data: nil, width: Int(N), height: Int(N), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0.35))
ctx.addPath(squircle); ctx.setFillColor(rgb(0)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(squircle); ctx.clip()

// Black, with the faintest violet lift at the top so the shape reads on a dark Dock.
let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x100A1C), rgb(0x000000)] as CFArray, locations: [0, 0.6])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [.drawsAfterEndLocation])

// The line: top edge, down around the notch, a heartbeat on the notch's floor, back up.
let cx = N / 2, y0: CGFloat = 640, w: CGFloat = 470, h: CGFloat = 260, r: CGFloat = 56, by = y0 - h
let line = CGMutablePath()
line.move(to: CGPoint(x: body.minX - 20, y: y0))
line.addLine(to: CGPoint(x: cx - w / 2 - r, y: y0))
line.addQuadCurve(to: CGPoint(x: cx - w / 2, y: y0 - r), control: CGPoint(x: cx - w / 2, y: y0))
line.addLine(to: CGPoint(x: cx - w / 2, y: by + r))
line.addQuadCurve(to: CGPoint(x: cx - w / 2 + r, y: by), control: CGPoint(x: cx - w / 2, y: by))
for (dx, dy) in [(-0.16, 0.0), (-0.08, 0.95), (0.06, -0.6), (0.14, 0.0)] as [(CGFloat, CGFloat)] {
    line.addLine(to: CGPoint(x: cx + dx * w, y: by + dy * 150))
}
line.addLine(to: CGPoint(x: cx + w / 2 - r, y: by))
line.addQuadCurve(to: CGPoint(x: cx + w / 2, y: by + r), control: CGPoint(x: cx + w / 2, y: by))
line.addLine(to: CGPoint(x: cx + w / 2, y: y0 - r))
line.addQuadCurve(to: CGPoint(x: cx + w / 2 + r, y: y0), control: CGPoint(x: cx + w / 2, y: y0))
line.addLine(to: CGPoint(x: body.maxX + 20, y: y0))

func strokedLine() {
    ctx.setLineWidth(38); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.addPath(line); ctx.replacePathWithStrokedPath()
}
// Glow first, then the line itself with the gradient running left to right.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 52, color: rgb(0x7A2BFF, 0.95))
strokedLine(); ctx.setFillColor(rgb(ultraviolet)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
strokedLine(); ctx.clip()
let fade = CGGradient(colorsSpace: nil, colors: [rgb(ultraviolet), rgb(lilac)] as CFArray, locations: nil)!
ctx.drawLinearGradient(fade, start: CGPoint(x: body.minX, y: 0), end: CGPoint(x: body.maxX, y: 0), options: [])
ctx.restoreGState()

let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
