// relightCam app icon (flat, symbolic): a light, a pinned textile with gold motifs and folds,
// and the black calibration sphere with its highlight.
//   mkdir -p /tmp/icon && cp tools/make_icon.swift /tmp/icon/main.swift
//   swiftc /tmp/icon/main.swift -o /tmp/icon/mk && /tmp/icon/mk RelightCam/Assets.xcassets/AppIcon.appiconset/icon.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// work in a top-left origin, unit coordinates
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: S, y: -S)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// background
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x232B45), rgb(0x0B0E19)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0.2, y: 0), end: CGPoint(x: 0.8, y: 1),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// the light: a small sun, upper left
let sun = CGPoint(x: 0.205, y: 0.19)
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFC857, 0.35), rgb(0xFFC857, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 0.2, options: [])
ctx.setFillColor(rgb(0xFFC857))
ctx.fillEllipse(in: CGRect(x: sun.x - 0.05, y: sun.y - 0.05, width: 0.1, height: 0.1))
ctx.setStrokeColor(rgb(0xFFC857))
ctx.setLineWidth(0.016)
ctx.setLineCap(.round)
for k in 0..<8 {
    let a = CGFloat(k) / 8 * 2 * .pi
    ctx.move(to: CGPoint(x: sun.x + cos(a) * 0.075, y: sun.y + sin(a) * 0.075))
    ctx.addLine(to: CGPoint(x: sun.x + cos(a) * 0.105, y: sun.y + sin(a) * 0.105))
}
ctx.strokePath()

// the textile: pinned along the top, three scallops at the hem
let top: CGFloat = 0.30, hem: CGFloat = 0.80
let xl: CGFloat = 0.33, xr: CGFloat = 0.83
let cloth = CGMutablePath()
cloth.move(to: CGPoint(x: xl, y: top))
cloth.addLine(to: CGPoint(x: xr, y: top))
cloth.addLine(to: CGPoint(x: xr + 0.035, y: hem))
let w = (xr + 0.035 - (xl - 0.035)) / 3
for k in 0..<3 {
    let x1 = xr + 0.035 - CGFloat(k) * w, x0 = x1 - w
    cloth.addQuadCurve(to: CGPoint(x: x0, y: hem), control: CGPoint(x: (x0 + x1) / 2, y: hem + 0.06))
}
cloth.addLine(to: CGPoint(x: xl, y: top))
cloth.closeSubpath()

// soft shadow on the wall
ctx.saveGState()
ctx.translateBy(x: 0.025, y: 0.025)
ctx.addPath(cloth)
ctx.setFillColor(rgb(0x000000, 0.35))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(cloth)
ctx.clip()
ctx.setFillColor(rgb(0xB0122C))
ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
// fold bands: darker valleys between the scallops
for k in 1..<3 {
    let xb = xl - 0.035 + CGFloat(k) * w
    let band = CGMutablePath()
    band.move(to: CGPoint(x: xb - 0.012, y: top))
    band.addLine(to: CGPoint(x: xb + 0.012, y: top))
    band.addLine(to: CGPoint(x: xb + 0.05, y: hem + 0.02))
    band.addLine(to: CGPoint(x: xb - 0.03, y: hem + 0.02))
    band.closeSubpath()
    ctx.addPath(band)
    ctx.setFillColor(rgb(0x7A0A1F))
    ctx.fillPath()
}
// gold diamonds (the lampas motif)
for r in 0..<4 {
    for c in 0..<4 {
        let cx = xl + 0.065 + CGFloat(c) * 0.125 + CGFloat(r) * 0.012
        let cy = top + 0.075 + CGFloat(r) * 0.125
        let s: CGFloat = 0.036
        let d = CGMutablePath()
        d.move(to: CGPoint(x: cx, y: cy - s))
        d.addLine(to: CGPoint(x: cx + s, y: cy))
        d.addLine(to: CGPoint(x: cx, y: cy + s))
        d.addLine(to: CGPoint(x: cx - s, y: cy))
        d.closeSubpath()
        ctx.addPath(d)
        ctx.setFillColor(rgb(0xF2C14E))
        ctx.fillPath()
    }
}
// raking light: a sheen along the lit side of the first fold
let sheen = CGMutablePath()
sheen.move(to: CGPoint(x: xl + 0.02, y: top))
sheen.addLine(to: CGPoint(x: xl + 0.07, y: top))
sheen.addLine(to: CGPoint(x: xl + 0.06, y: hem + 0.03))
sheen.addLine(to: CGPoint(x: xl - 0.01, y: hem + 0.03))
sheen.closeSubpath()
ctx.addPath(sheen)
ctx.setFillColor(rgb(0xFFFFFF, 0.18))
ctx.fillPath()
ctx.restoreGState()

// pins
for x in [xl + 0.03, xr - 0.03] {
    ctx.setFillColor(rgb(0xF2C14E))
    ctx.fillEllipse(in: CGRect(x: x - 0.024, y: top - 0.024, width: 0.048, height: 0.048))
}

// the calibration sphere with its highlight towards the light
let sc = CGPoint(x: 0.29, y: 0.77), sr: CGFloat = 0.125
ctx.setFillColor(rgb(0x05060A))
ctx.fillEllipse(in: CGRect(x: sc.x - sr, y: sc.y - sr, width: 2 * sr, height: 2 * sr))
// a thin even outline separates the black sphere from the dark background
ctx.setStrokeColor(rgb(0x3B4770))
ctx.setLineWidth(0.008)
ctx.strokeEllipse(in: CGRect(x: sc.x - sr, y: sc.y - sr, width: 2 * sr, height: 2 * sr))
ctx.setFillColor(rgb(0xFFFFFF))
let hl = CGPoint(x: sc.x - sr * 0.38, y: sc.y - sr * 0.42)
ctx.fillEllipse(in: CGRect(x: hl.x - 0.026, y: hl.y - 0.026, width: 0.052, height: 0.052))

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
