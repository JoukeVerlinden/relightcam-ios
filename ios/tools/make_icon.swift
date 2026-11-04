// relightCam app icon: flat, one colour plus a white symbol: a light, and a textile hanging from a rod whose
// folds are lit or shaded.
//   mkdir -p /tmp/icon && cp tools/make_icon.swift /tmp/icon/main.swift
//   swiftc /tmp/icon/main.swift -o /tmp/icon/mk && /tmp/icon/mk RelightCam/Assets.xcassets/AppIcon.appiconset/icon.png
// Optional second argument: the background colour as hex (default 9E1B32).
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

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let bgHex = CommandLine.arguments.count > 2 ? UInt32(CommandLine.arguments[2], radix: 16) ?? 0x9E1B32 : 0x9E1B32
let bg = rgb(bgHex), fg = rgb(0xFFFFFF)

ctx.setFillColor(bg)
ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))

// the light, upper left
let sun = CGPoint(x: 0.205, y: 0.205)
ctx.setFillColor(fg)
ctx.fillEllipse(in: CGRect(x: sun.x - 0.05, y: sun.y - 0.05, width: 0.1, height: 0.1))
ctx.setStrokeColor(fg)
ctx.setLineWidth(0.028)
ctx.setLineCap(.round)
for k in 0..<8 {
    let a = CGFloat(k) / 8 * 2 * .pi
    ctx.move(to: CGPoint(x: sun.x + cos(a) * 0.082, y: sun.y + sin(a) * 0.082))
    ctx.addLine(to: CGPoint(x: sun.x + cos(a) * 0.11, y: sun.y + sin(a) * 0.11))
}
ctx.strokePath()

// the rod
let rodY: CGFloat = 0.335, rodL: CGFloat = 0.31, rodR: CGFloat = 0.81
ctx.setLineWidth(0.044)
ctx.move(to: CGPoint(x: rodL, y: rodY))
ctx.addLine(to: CGPoint(x: rodR, y: rodY))
ctx.strokePath()

// the textile below the rod, in four folds: the ones facing the light white, the others shaded
// (white mixed into the background, still one flat colour each)
func mixed(_ t: CGFloat) -> CGColor {
    let c = bg.components!
    return CGColor(red: c[0] + (1 - c[0]) * t, green: c[1] + (1 - c[1]) * t, blue: c[2] + (1 - c[2]) * t, alpha: 1)
}
let shade = mixed(0.62)
let top: CGFloat = 0.385, hem: CGFloat = 0.80
let tl: CGFloat = 0.355, tr: CGFloat = 0.765, hl: CGFloat = 0.285, hr: CGFloat = 0.835
let n = 4
for k in 0..<n {
    let t0 = tl + CGFloat(k) * (tr - tl) / CGFloat(n), t1 = tl + CGFloat(k + 1) * (tr - tl) / CGFloat(n)
    let h0 = hl + CGFloat(k) * (hr - hl) / CGFloat(n), h1 = hl + CGFloat(k + 1) * (hr - hl) / CGFloat(n)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: t0, y: top))
    p.addLine(to: CGPoint(x: t1, y: top))
    p.addLine(to: CGPoint(x: h1, y: hem))
    p.addQuadCurve(to: CGPoint(x: h0, y: hem), control: CGPoint(x: (h0 + h1) / 2, y: hem + 0.07))
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(k % 2 == 0 ? fg : shade)
    ctx.fillPath()
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
