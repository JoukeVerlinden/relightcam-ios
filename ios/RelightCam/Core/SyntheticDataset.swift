import Foundation
import CoreGraphics
import CoreText
import simd

/// Renders a fake RTI capture: an embossed tablet next to a glossy black sphere, lit from known
/// directions. Lets you try the whole pipeline without a tripod (and is what the tests use).
enum SyntheticDataset {
    struct Result {
        var files: [String]
        var lights: [[Double]]
        var sphere: SphereCircle
        var width: Int
        var height: Int
    }

    static func lightDirections() -> [[Double]] {
        let rings: [(el: Double, count: Int)] = [(20, 12), (40, 10), (60, 8), (80, 4)]
        var out: [[Double]] = []
        for (ri, ring) in rings.enumerated() {
            for a in 0..<ring.count {
                let az = (Double(a) + 0.5 * Double(ri % 2)) / Double(ring.count) * 2 * .pi
                let el = ring.el * .pi / 180
                out.append([cos(el) * cos(az), cos(el) * sin(az), sin(el)])
            }
        }
        return out
    }

    enum Kind { case tablet, textile }

    static func generate(into dir: URL, kind: Kind = .tablet, width W: Int = 1600, height H: Int = 1200,
                         progress: ((Double) -> Void)? = nil) throws -> Result {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let height = kind == .tablet ? reliefHeight(W, H) : weaveHeight(W, H)
        let sphere = SphereCircle(cx: Double(W) * 0.12, cy: Double(H) * 0.15, r: Double(min(W, H)) * 0.09)
        let lights = lightDirections()
        var files: [String] = []

        // Precompute normals and albedo once.
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: W * H)
        var albedo = [SIMD3<Float>](repeating: .zero, count: W * H)
        var shine = [Float](repeating: 0.18, count: W * H)
        let specPower: Float = kind == .tablet ? 40 : 28
        for y in 0..<H {
            for x in 0..<W {
                let xm = max(0, x - 1), xp = min(W - 1, x + 1), ym = max(0, y - 1), yp = min(H - 1, y + 1)
                let dx = (height.h[y * W + xp] - height.h[y * W + xm]) / Float(xp - xm)
                let dyImg = (height.h[yp * W + x] - height.h[ym * W + x]) / Float(yp - ym)
                // light space has y up, image rows go down
                normals[y * W + x] = simd_normalize(SIMD3(-dx, dyImg, 1))
                let fx = Float(x), fy = Float(y)
                if kind == .textile {
                    // gold weft floats (motif) on a red warp-faced satin ground; silk is glossy
                    let motif = height.mask[y * W + x]
                    let red = SIMD3<Float>(0.52, 0.07, 0.10), gold = SIMD3<Float>(0.86, 0.66, 0.30)
                    let wear = 0.92 + 0.08 * sin(fx * 0.004 + 2) * cos(fy * 0.005)
                    albedo[y * W + x] = (red * (1 - motif) + gold * motif) * wear
                    shine[y * W + x] = 0.35 + 0.25 * motif
                    continue
                }
                let mottling = 0.88 + 0.12 * sin(fx * 0.013 + 1.3) * cos(fy * 0.017 + 0.4) + 0.05 * sin(fx * 0.11) * sin(fy * 0.09)
                let base = SIMD3<Float>(0.80, 0.68, 0.50) * mottling
                let paint = SIMD3<Float>(0.62, 0.22, 0.16)
                let t = height.mask[y * W + x] * 0.65
                albedo[y * W + x] = base * (1 - t) + paint * t
            }
        }

        var rng = SystemRandomNumberGenerator()
        for (i, l) in lights.enumerated() {
            let L = simd_normalize(SIMD3<Float>(Float(l[0]), Float(l[1]), Float(l[2])))
            let Hv = simd_normalize(L + SIMD3(0, 0, 1))
            var px = [UInt8](repeating: 255, count: W * H * 4)
            let noiseSeed = UInt32.random(in: 0..<UInt32.max, using: &rng)
            px.withUnsafeMutableBufferPointer { out in
                let base = out.baseAddress!
                DispatchQueue.concurrentPerform(iterations: H) { y in
                    var seed = noiseSeed &+ UInt32(y) &* 2654435761
                    for x in 0..<W {
                        var c: SIMD3<Float>
                        let sx = (Double(x) + 0.5 - sphere.cx) / sphere.r
                        let sy = -(Double(y) + 0.5 - sphere.cy) / sphere.r
                        let d2 = sx * sx + sy * sy
                        if d2 < 1 {
                            let n = SIMD3<Float>(Float(sx), Float(sy), Float((1 - d2).squareRoot()))
                            let R = 2 * n.z * n - SIMD3(0, 0, 1)
                            let spec = pow(max(simd_dot(R, L), 0), 600) * 1.6
                            c = SIMD3(repeating: 0.03 + 0.04 * max(simd_dot(n, L), 0) + spec)
                        } else {
                            let n = normals[y * W + x]
                            let diff = max(simd_dot(n, L), 0)
                            let spec = shine[y * W + x] * pow(max(simd_dot(n, Hv), 0), specPower)
                            c = albedo[y * W + x] * (0.04 + 0.96 * diff) + SIMD3(repeating: spec)
                        }
                        seed = seed &* 1664525 &+ 1013904223
                        let noise = (Float(seed >> 24) / 255 - 0.5) * 2.0 / 255
                        let o = (y * W + x) * 4
                        base[o] = UInt8(max(0, min(255, (c.x + noise) * 255 + 0.5)))
                        base[o + 1] = UInt8(max(0, min(255, (c.y + noise) * 255 + 0.5)))
                        base[o + 2] = UInt8(max(0, min(255, (c.z + noise) * 255 + 0.5)))
                    }
                }
            }
            guard let img = ImageUtils.makeImage(rgba: px, width: W, height: H) else { throw RelightError.io("render failed") }
            let name = String(format: "frame_%03d.jpg", i)
            try ImageUtils.write(img, to: dir.appendingPathComponent(name), quality: 0.93)
            files.append(name)
            progress?(Double(i + 1) / Double(lights.count))
        }
        return Result(files: files, lights: lights, sphere: sphere, width: W, height: H)
    }

    /// A lampas-like silk: 5-end satin, warp-faced (vertical floats) in the ground and weft-faced
    /// (horizontal floats) in an ogee/medallion motif. `mask` is 1 in the motif.
    private static func weaveHeight(_ W: Int, _ H: Int) -> (h: [Float], mask: [Float]) {
        let pitch: Float = 7
        var h = [Float](repeating: 0, count: W * H)
        var m = [Float](repeating: 0, count: W * H)
        let rx: Float = 260, ry: Float = 200
        for y in 0..<H {
            for x in 0..<W {
                let fxp = Float(x) / pitch, fyp = Float(y) / pitch
                let ix = Int(floor(fxp)), iy = Int(floor(fyp))
                let fx = fxp - Float(ix), fy = fyp - Float(iy)
                // motif: staggered medallions with a four-petal flower inside
                let cxr = (Float(x) / rx).rounded(.down), cyr = (Float(y) / ry).rounded(.down)
                let ox = (Float(x) - (cxr + 0.5) * rx + (Int(cyr) % 2 == 0 ? 0 : rx * 0.5)).truncatingRemainder(dividingBy: rx)
                let dx = abs(ox) > rx / 2 ? rx - abs(ox) : abs(ox)
                let dy = abs(Float(y) - (cyr + 0.5) * ry)
                let diamond = dx / (rx * 0.42) + dy / (ry * 0.42)
                let ang = atan2(dy, dx), rr = (dx * dx + dy * dy).squareRoot()
                let petal = rr < 55 + 25 * abs(cos(2 * ang))
                let ring = diamond < 1 && diamond > 0.82
                let motif = petal || ring
                // satin binding points (step 2 on 5 shafts)
                let weftOnTop: Bool
                if motif {
                    weftOnTop = ((iy * 2 + ix) % 5 + 5) % 5 != 0
                } else {
                    weftOnTop = ((ix * 2 + iy) % 5 + 5) % 5 == 0
                }
                let across = weftOnTop ? fy : fx
                h[y * W + x] = 2.2 * pow(max(0, cos(.pi * (across - 0.5))), 0.6)
                m[y * W + x] = motif ? 1 : 0
            }
        }
        return (h, m)
    }

    /// Embossed lettering inside a raised ring, plus a gentle wavy surface.
    private static func reliefHeight(_ W: Int, _ H: Int) -> (h: [Float], mask: [Float]) {
        var mask = [UInt8](repeating: 0, count: W * H)
        mask.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            let cx = CGFloat(W) * 0.56, cy = CGFloat(H) * 0.5, rr = CGFloat(H) * 0.42
            ctx.setLineWidth(CGFloat(H) * 0.02)
            ctx.strokeEllipse(in: CGRect(x: cx - rr, y: cy - rr, width: 2 * rr, height: 2 * rr))
            for k in 0..<16 {
                let a = CGFloat(k) / 16 * 2 * .pi
                let r2 = rr * 0.9, d = CGFloat(H) * 0.025
                ctx.fillEllipse(in: CGRect(x: cx + r2 * cos(a) - d / 2, y: cy + r2 * sin(a) - d / 2, width: d, height: d))
            }
            for (text, size, y) in [("RELIGHT", CGFloat(H) * 0.16, cy + CGFloat(H) * 0.02), ("CNR · ISTI", CGFloat(H) * 0.07, cy - CGFloat(H) * 0.15)] {
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
                let attr = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ])
                let line = CTLineCreateWithAttributedString(attr)
                let b = CTLineGetBoundsWithOptions(line, [])
                ctx.textPosition = CGPoint(x: cx - b.width / 2 - b.minX, y: y)
                CTLineDraw(line, ctx)
            }
        }
        var m = mask.map { Float($0) / 255 }
        for _ in 0..<3 { boxBlur(&m, W, H, radius: 6) }
        var h = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let fx = Float(x), fy = Float(y)
                h[y * W + x] = 7 * m[y * W + x] + 1.2 * sin(fx * 0.021) * sin(fy * 0.017) + 0.4 * sin((fx + fy) * 0.06)
            }
        }
        return (h, m)
    }

    private static func boxBlur(_ a: inout [Float], _ W: Int, _ H: Int, radius r: Int) {
        var tmp = a
        let norm = 1 / Float(2 * r + 1)
        for y in 0..<H {
            var s: Float = 0
            for x in -r...r { s += a[y * W + min(max(x, 0), W - 1)] }
            for x in 0..<W {
                tmp[y * W + x] = s * norm
                s += a[y * W + min(x + r + 1, W - 1)] - a[y * W + max(x - r, 0)]
            }
        }
        for x in 0..<W {
            var s: Float = 0
            for y in -r...r { s += tmp[min(max(y, 0), H - 1) * W + x] }
            for y in 0..<H {
                a[y * W + x] = s * norm
                s += tmp[min(y + r + 1, H - 1) * W + x] - tmp[max(y - r, 0) * W + x]
            }
        }
    }
}
