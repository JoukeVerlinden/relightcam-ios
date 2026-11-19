// relightCam app icon: a light dome seen from above. LEDs on rings around a gold lampas motif in relief on
// red silk; one LED (top left) is lit and rakes the motif, which casts its shadow away from it.
// Large icons (60 pt and up, and the App Store) show two rings of LEDs like the real dome; small ones (40 pt and
// below: Spotlight, Settings, notifications) one ring of bigger LEDs and a bigger motif, so they stay legible.
// Every size is drawn at its own pixel size, in three appearances: default, dark and tinted (both on a
// transparent background, as iOS expects). Writes the PNGs and Contents.json into the icon set:
//   mkdir -p /tmp/icon && cp tools/make_icon.swift /tmp/icon/main.swift
//   swiftc -O /tmp/icon/main.swift -o /tmp/icon/mk && /tmp/icon/mk RelightCam/Assets.xcassets/AppIcon.appiconset
// Optional second argument: a folder for 1024 px previews of all six versions.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let previewDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
var S: CGFloat = 1024   // pixel size of the icon being drawn

enum Look: String { case light = "", dark = "-dark", tinted = "-tinted" }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func ch(_ h: UInt32, _ s: UInt32) -> CGFloat { CGFloat((h >> s) & 0xFF) / 255 }
    let t = max(0, min(1, t))
    return CGColor(red: ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t, green: ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t,
                   blue: ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t, alpha: 1)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}
func linear(_ c: CGContext, _ colors: [CGColor], _ p0: CGPoint, _ p1: CGPoint, _ locs: [CGFloat]? = nil) {
    c.drawLinearGradient(gradient(colors, locs), start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radial(_ c: CGContext, _ colors: [CGColor], _ p: CGPoint, _ r: CGFloat, _ locs: [CGFloat]? = nil) {
    c.drawRadialGradient(gradient(colors, locs), startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [.drawsAfterEndLocation])
}
/// shadow offset in unit coordinates (+dy is down on screen)
func shadow(_ c: CGContext, _ dx: CGFloat, _ dy: CGFloat, _ blur: CGFloat, _ col: CGColor) {
    c.setShadow(offset: CGSize(width: dx * S, height: -dy * S), blur: blur * S, color: col)
}
func glow(_ c: CGContext, _ p: CGPoint, _ r: CGFloat, _ hex: UInt32, _ a: CGFloat) {
    radial(c, [rgb(hex, a), rgb(hex, a * 0.35), rgb(hex, 0)], p, r, [0, 0.35, 1])
}

let ctr = P(0.5, 0.5)

/// the gold lampas motif in relief, lit from `light`
func diamond(_ c: CGContext, _ m: CGPoint, _ h: CGFloat, light: CGPoint) {
    var L = P(light.x - m.x, light.y - m.y)
    let l = (L.x * L.x + L.y * L.y).squareRoot(); L = P(L.x / l, L.y / l)
    let v = [P(m.x, m.y - h), P(m.x + h, m.y), P(m.x, m.y + h), P(m.x - h, m.y)]
    let d = CGMutablePath(); d.addLines(between: v); d.closeSubpath()
    c.saveGState()
    shadow(c, -L.x * 0.045, -L.y * 0.045, 0.03, rgb(0x14000A, 0.8))
    c.addPath(d); c.setFillColor(rgb(0xC9963F)); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(d); c.clip()
    linear(c, [rgb(0xFFF2C2), rgb(0xE6B85A), rgb(0x8A5B1C)], P(m.x + L.x * h, m.y + L.y * h), P(m.x - L.x * h, m.y - L.y * h), [0, 0.45, 1])
    if S >= 120 {   // woven floats; below that they are only noise
        c.setStrokeColor(rgb(0x5A3A0E, 0.25)); c.setLineWidth(0.005)
        var t = -2 * h
        while t < 2 * h { c.move(to: P(m.x + t - h, m.y - h)); c.addLine(to: P(m.x + t + h, m.y + h)); t += 0.022 }
        c.strokePath()
    }
    c.restoreGState()
    c.setLineWidth(0.016); c.setLineCap(.round)
    for k in 0..<4 {
        let a = v[k], b = v[(k + 1) % 4]
        let mid = P((a.x + b.x) / 2 - m.x, (a.y + b.y) / 2 - m.y)
        let facing = (mid.x * L.x + mid.y * L.y) / (mid.x * mid.x + mid.y * mid.y).squareRoot()
        c.setStrokeColor(facing > 0 ? mix(0xF1C46A, 0xFFF8E0, facing) : mix(0xB8862F, 0x4A2E08, -facing))
        c.move(to: a); c.addLine(to: b); c.strokePath()
    }
}

struct Design { let rings: [(r: CGFloat, n: Int, phase: CGFloat)]; let dot: CGFloat; let line: CGFloat
                let lit: (ring: Int, index: Int); let litR: CGFloat; let motif: CGFloat }
let twoRings = Design(rings: [(0.27, 6, 1.0 / 12), (0.42, 8, 0)], dot: 0.034, line: 0.008, lit: (1, 5), litR: 0.055, motif: 0.15)
let oneRing = Design(rings: [(0.385, 8, 0)], dot: 0.044, line: 0.01, lit: (0, 5), litR: 0.062, motif: 0.2)

func ledPosition(_ d: Design, ring: Int, index: Int) -> CGPoint {
    let r = d.rings[ring]
    let a = (CGFloat(index) / CGFloat(r.n) + r.phase) * 2 * .pi
    return P(ctr.x + cos(a) * r.r, ctr.y + sin(a) * r.r)
}

func render(px: Int, design d: Design, look: Look) -> CGImage {
    S = CGFloat(px)
    let opaque = look == .light   // the default icon must not have an alpha channel
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
    c.translateBy(x: 0, y: S); c.scaleBy(x: S, y: -S)
    let lit = ledPosition(d, ring: d.lit.ring, index: d.lit.index)
    if opaque {
        radial(c, [rgb(0xD84A5D), rgb(0x9E1B32), rgb(0x4C0A17)], lit, 1.15, [0, 0.4, 1])
    } else {
        c.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    c.setStrokeColor(rgb(0xFFE7C2, opaque ? 0.26 : 0.34)); c.setLineWidth(d.line)
    for r in d.rings { c.addEllipse(in: CGRect(x: ctr.x - r.r, y: ctr.y - r.r, width: 2 * r.r, height: 2 * r.r)) }
    c.strokePath()
    for (ri, r) in d.rings.enumerated() {
        for k in 0..<r.n where !(ri == d.lit.ring && k == d.lit.index) {
            let p = ledPosition(d, ring: ri, index: k)
            c.setFillColor(rgb(0xFFEBC8))
            c.fillEllipse(in: CGRect(x: p.x - d.dot, y: p.y - d.dot, width: 2 * d.dot, height: 2 * d.dot))
        }
    }
    diamond(c, ctr, d.motif, light: lit)
    glow(c, lit, 0.42, 0xFFE9B0, 0.75)
    c.setFillColor(rgb(0xFFFBEE))
    c.fillEllipse(in: CGRect(x: lit.x - d.litR, y: lit.y - d.litR, width: 2 * d.litR, height: 2 * d.litR))
    if look == .tinted, let data = c.data {   // grey levels only: iOS applies the tint
        let p = data.bindMemory(to: UInt8.self, capacity: c.bytesPerRow * px)
        for y in 0..<px {
            for x in 0..<px {
                let i = y * c.bytesPerRow + x * 4
                let l = UInt8(min(255, 0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])))
                p[i] = l; p[i + 1] = l; p[i + 2] = l
            }
        }
    }
    return c.makeImage()!
}

func write(_ img: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

// iOS "All Sizes": points and scales
let sizes: [(pt: Double, scales: [Int])] = [(20, [2, 3]), (29, [2, 3]), (38, [2, 3]), (40, [2, 3]), (60, [2, 3]),
                                            (64, [2, 3]), (68, [2]), (76, [2]), (83.5, [2]), (1024, [1])]
func ptString(_ pt: Double) -> String { pt == pt.rounded() ? String(Int(pt)) : String(pt) }

var images: [[String: Any]] = []
for s in sizes {
    for scale in s.scales {
        let px = Int((s.pt * Double(scale)).rounded())
        let design = s.pt >= 60 ? twoRings : oneRing
        for look in [Look.light, .dark, .tinted] {
            let name = s.pt == 1024 ? "icon-1024\(look.rawValue).png" : "icon-\(ptString(s.pt))@\(scale)x\(look.rawValue).png"
            write(render(px: px, design: design, look: look), "\(outDir)/\(name)")
            var e: [String: Any] = ["filename": name, "idiom": "universal", "platform": "ios",
                                    "size": "\(ptString(s.pt))x\(ptString(s.pt))"]
            if s.pt != 1024 { e["scale"] = "\(scale)x" }
            if look != .light { e["appearances"] = [["appearance": "luminosity", "value": look == .dark ? "dark" : "tinted"]] }
            images.append(e)
        }
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]],
                                       options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
if let pv = previewDir {
    for (name, design) in [("two-rings", twoRings), ("one-ring", oneRing)] {
        for look in [Look.light, .dark, .tinted] { write(render(px: 1024, design: design, look: look), "\(pv)/\(name)\(look.rawValue).png") }
    }
}
print("wrote \(images.count) icons")
