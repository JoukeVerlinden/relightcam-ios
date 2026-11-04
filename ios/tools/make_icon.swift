import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// relightCam icon: a draped silk lampas under a raking light, two pins, and a glossy calibration sphere.
let S = 2048          // rendered at 2× and downsampled for antialiasing
let OUT = 1024
var px = [UInt8](repeating: 255, count: S * S * 4)

func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}
func norm(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
    let l = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
    return (v.0 / l, v.1 / l, v.2 / l)
}
func dot(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { a.0 * b.0 + a.1 * b.1 + a.2 * b.2 }

let L = norm((-0.62, 0.55, 0.56))          // light from the upper left (y up)
let V = (0.0, 0.0, 1.0)
let H = norm((L.0 + V.0, L.1 + V.1, L.2 + V.2))
let red = (0.58, 0.06, 0.10), gold = (0.95, 0.74, 0.32)

// folds: z(u, v) and dz/du
func folds(_ u: Double, _ v: Double) -> (z: Double, dz: Double) {
    let a = 0.018 + 0.05 * v
    let k1 = 2 * Double.pi * 4.2, k2 = 2 * Double.pi * 7.3, k3 = 2 * Double.pi * 11.0
    let p2 = 1.7 + 2.2 * v
    let z = a * (0.62 * sin(k1 * u + 0.4) + 0.28 * sin(k2 * u + p2) + 0.12 * sin(k3 * u + 0.3))
    let dz = a * (0.62 * k1 * cos(k1 * u + 0.4) + 0.28 * k2 * cos(k2 * u + p2) + 0.12 * k3 * cos(k3 * u + 0.3))
    return (z, dz)
}

func cloth(_ x: Double, _ y: Double) -> (Double, Double, Double, Double)? {
    // y measured downwards from the top (0…1)
    let top = 0.165 + 0.012 * sin(x * 9)
    let left = 0.175 - 0.045 * clamp((y - top) / 0.7), right = 0.825 + 0.045 * clamp((y - top) / 0.7)
    guard x >= left, x <= right, y >= top else { return nil }
    let u = (x - left) / (right - left)
    let hem = 0.855 + 0.03 * sin(2 * Double.pi * 4.2 * u + 0.4 + Double.pi / 2) + 0.01 * sin(2 * Double.pi * 7.3 * u + 3.9)
    guard y <= hem else { return nil }
    let v = (y - top) / (hem - top)
    let f = folds(u, v)
    // normal of the surface (x right, y up, z out): strong horizontal variation from the folds
    let n = norm((-f.dz * 0.55, 0.06 * v, 1))
    // pattern coordinates follow the cloth (shifted by the fold depth so motifs bend over the folds)
    let pu = u * 7.0 + f.z * 3.2, pv = v * 7.6
    let col = Int(floor(pu))
    let fu = pu - floor(pu), fv = (pv + (col % 2 == 0 ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
    let diamond = abs(fu - 0.5) * 2 + abs(fv - 0.5) * 2
    let inGold = diamond < 0.72
    let edge = clamp((0.72 - diamond) / 0.07)            // soft motif edge
    let base = mix(red, gold, inGold ? edge : 0)
    let diff = max(0, dot(n, L))
    let shine = inGold ? 0.85 : 0.45
    let spec = pow(max(0, dot(n, H)), inGold ? 22 : 34) * shine
    let occl = 0.55 + 0.45 * clamp(0.5 + f.z * 12)       // valleys between folds are darker
    let hemShade = 1 - 0.25 * pow(v, 3)
    var c = (base.0 * (0.12 + 0.95 * diff) * occl * hemShade + spec,
             base.1 * (0.12 + 0.95 * diff) * occl * hemShade + spec * 0.95,
             base.2 * (0.12 + 0.95 * diff) * occl * hemShade + spec * 0.8)
    // weave texture: fine threads
    let thread = 0.94 + 0.06 * sin(x * S.double * 0.55) * sin(y * S.double * 0.55)
    c = (c.0 * thread, c.1 * thread, c.2 * thread)
    return (clamp(c.0), clamp(c.1), clamp(c.2), 1)
}

extension Int { var double: Double { Double(self) } }

for j in 0..<S {
    for i in 0..<S {
        let x = (Double(i) + 0.5) / Double(S), y = (Double(j) + 0.5) / Double(S)
        // background: dark blue-grey with a warm glow where the light comes from
        let g = exp(-((x - 0.08) * (x - 0.08) + (y - 0.05) * (y - 0.05)) * 5) * 0.55
        var c = (0.055 + 0.06 * (1 - y) + g * 1.0, 0.06 + 0.05 * (1 - y) + g * 0.72, 0.09 + 0.05 * (1 - y) + g * 0.36)
        // soft shadow of the cloth on the back wall, offset down-right
        if cloth(x - 0.035, y - 0.03) != nil {
            c = (c.0 * 0.55, c.1 * 0.55, c.2 * 0.55)
        }
        if let cl = cloth(x, y) { c = (cl.0, cl.1, cl.2) }
        // two pins at the top
        for px0 in [0.29, 0.71] {
            let d = ((x - px0) * (x - px0) + (y - 0.175) * (y - 0.175)).squareRoot()
            if d < 0.024 {
                let n = norm(((x - px0) / 0.024, -(y - 0.175) / 0.024, max(0.05, 1 - d / 0.024)))
                let s = pow(max(0, dot(n, H)), 30)
                c = (clamp(0.80 * (0.3 + 0.7 * max(0, dot(n, L))) + s), clamp(0.10 + s), clamp(0.12 + s))
            }
        }
        // glossy black calibration sphere, lower left, in front of the hem
        let sx = 0.215, sy = 0.835, sr = 0.085
        let dx = (x - sx) / sr, dy = -(y - sy) / sr
        let d2 = dx * dx + dy * dy
        if d2 < 1 {
            let n = (dx, dy, (1 - d2).squareRoot())
            let R = (2 * n.2 * n.0, 2 * n.2 * n.1, 2 * n.2 * n.2 - 1)
            let rl = max(0, dot(R, L))
            let s = pow(rl, 180) * 1.6 + pow(rl, 14) * 0.18
            let rim = pow(1 - n.2, 3) * 0.25
            c = (clamp(0.02 + 0.05 * max(0, dot(n, L)) + s + rim * 0.9),
                 clamp(0.02 + 0.05 * max(0, dot(n, L)) + s * 0.97 + rim * 0.7),
                 clamp(0.03 + 0.06 * max(0, dot(n, L)) + s * 0.9 + rim * 0.5))
        }
        let o = (j * S + i) * 4
        px[o] = UInt8(clamp(c.0) * 255)
        px[o + 1] = UInt8(clamp(c.1) * 255)
        px[o + 2] = UInt8(clamp(c.2) * 255)
        px[o + 3] = 255
    }
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let big = CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: S * 4, space: cs,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
let ctx = CGContext(data: nil, width: OUT, height: OUT, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high
ctx.draw(big, in: CGRect(x: 0, y: 0, width: OUT, height: OUT))
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
CGImageDestinationFinalize(d)
