// Renders Vaultkit's app icon at 1024x1024: a navy squircle carrying one bold
// white mark. It is flat by design, with no grain and no glow, which is what keeps it a
// sibling of Auger's icon rather than a different visual family.
//
// The artwork sits on Apple's macOS icon grid: an 816pt shape inside the 1024pt
// canvas, with a shadow. That inset is not cosmetic. macOS 26 renders an app's
// icon from its asset catalog, and a bundle carrying only a full-bleed .icns is
// treated as legacy: the system shrinks the art and drops it onto a default
// light plate, so a full-bleed design ends up looking like a sticker inside a
// grey frame. Drawing on the grid the platform expects avoids that.
//
// The mark is three vault plates: two sealed and dim, the front one lit and
// keyed. Dependency-free; run with `swift MakeIcon.swift out.png`.
import AppKit

func hex(_ s: String, _ a: CGFloat = 1) -> CGColor {
    var h = s; if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt32(h, radix: 16) ?? 0
    return CGColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: a)
}
func env(_ k: String, _ d: String) -> String { ProcessInfo.processInfo.environment[k] ?? d }

// Sampled from Auger's icon so the gradient matches exactly.
let BG_TOP = env("ICON_BG_TOP", "#24446D")
let BG_BOT = env("ICON_BG_BOT", "#091626")

let S: CGFloat = 1024
let INSET: CGFloat = 104                                   // matches Apple's own apps
let SHAPE = CGRect(x: INSET, y: INSET, width: S - INSET * 2, height: S - INSET * 2)
/// Every dimension below is authored against a 1024pt shape, then scaled to
/// whatever the grid leaves us, so the mark keeps its proportions.
let k = SHAPE.width / 1024

/// Superellipse: the continuous corner Apple's icon grid uses.
func squircle(_ r: CGRect, n: Double = 8) -> CGPath {
    let p = CGMutablePath()
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    let steps = 1440
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        let pt = CGPoint(x: cx + a * CGFloat(x), y: cy + b * CGFloat(y))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath(); return p
}
func roundRect(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let c = gctx.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// the shadow Apple's grid expects beneath the shape
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
c.addPath(squircle(SHAPE)); c.setFillColor(hex(BG_BOT)); c.fillPath()
c.restoreGState()

c.saveGState()
c.addPath(squircle(SHAPE)); c.clip()

let bg = CGGradient(colorsSpace: space, colors: [hex(BG_TOP), hex(BG_BOT)] as CFArray,
                    locations: [0, 1])!
c.drawLinearGradient(bg, start: CGPoint(x: SHAPE.midX, y: SHAPE.maxY),
                     end: CGPoint(x: SHAPE.midX, y: SHAPE.minY), options: [])

// MARK: - the mark
let cxm = SHAPE.midX
let frontW = 604 * k, frontH = 424 * k
let frontY = SHAPE.midY - 268 * k                      // optically centred, mark sits high
let frontRect = CGRect(x: cxm - frontW / 2, y: frontY, width: frontW, height: frontH)

// the two sealed vaults behind
for (w, dy, alpha) in [(420 * k, 186 * k, CGFloat(0.24)),
                       (516 * k, 96 * k,  CGFloat(0.44))] {
    c.addPath(roundRect(CGRect(x: cxm - w / 2, y: frontY + dy, width: w, height: frontH), 76 * k))
    c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha)); c.fillPath()
}

// the open one, with the keyhole cut clean through to the gradient
c.addPath(roundRect(frontRect, 92 * k))
c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); c.fillPath()

// One continuous outline: a circular head flaring into the shaft, built as a
// single path so there is no seam at the junction. The hole is filled by
// repainting the *background* gradient through it, so it reads as cut clean
// through the whole stack rather than exposing the plates behind.
let keyC = CGPoint(x: cxm, y: frontY + frontH * 0.60)
let kr = 66 * k, hw = 62 * k, shaftLen = 176 * k
let a0 = -35.0 * .pi / 180, a1 = 215.0 * .pi / 180
let key = CGMutablePath()
key.move(to: CGPoint(x: keyC.x + kr * CGFloat(cos(a0)), y: keyC.y + kr * CGFloat(sin(a0))))
key.addArc(center: keyC, radius: kr, startAngle: CGFloat(a0), endAngle: CGFloat(a1),
           clockwise: false)
key.addLine(to: CGPoint(x: keyC.x - hw, y: keyC.y - shaftLen))
key.addLine(to: CGPoint(x: keyC.x + hw, y: keyC.y - shaftLen))
key.closeSubpath()

c.saveGState()
c.addPath(key); c.clip()
c.drawLinearGradient(bg, start: CGPoint(x: SHAPE.midX, y: SHAPE.maxY),
                     end: CGPoint(x: SHAPE.midX, y: SHAPE.minY), options: [])
c.restoreGState()

c.restoreGState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
