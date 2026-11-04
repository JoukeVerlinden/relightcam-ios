import Foundation
import CoreGraphics
import Accelerate

/// relight's web format (info.json + plane_N.jpg). For colorspace "rgb", plane_j.jpg stores
/// coefficient j for R, G and B; value = (byte/255 - bias[3j+c]) * scale[3j+c].
struct RelightInfo: Codable {
    struct Material: Codable {
        var scale: [Double]
        var bias: [Double]
    }
    var width: Int
    var height: Int
    var format: String
    var type: String
    var colorspace: String
    var lights: [Double]?
    var nplanes: Int
    var quality: Int?
    var materials: [Material]

    var basis: RTIBasis? { RTIBasis(rawValue: type) }
    var nCoeffs: Int { nplanes / 3 }

    static func load(from dir: URL) throws -> RelightInfo {
        let data = try Data(contentsOf: dir.appendingPathComponent("info.json"))
        let info = try JSONDecoder().decode(RelightInfo.self, from: data)
        guard info.colorspace == "rgb", info.basis != nil, info.materials.first?.scale.count == info.nplanes else {
            throw RelightError.invalid("Only rgb PTM/HSH relight folders are supported")
        }
        return info
    }
}

struct RTIBuildResult {
    var width: Int
    var height: Int
    var lightsUsed: Int
    var seconds: Double
}

enum RTIBuilder {
    /// Streaming least-squares fit: because every pixel shares the same light directions, the
    /// solve operator P = (AᵀA)⁻¹Aᵀ is computed once and each photo is accumulated into the
    /// coefficient planes as soon as it is decoded. Memory is O(planes × pixels), not O(photos × pixels).
    static func build(frames: [URL], lights: [[Double]], basis: RTIBasis, maxSide: Int, output: URL,
                      jpegQuality: Double = 1.0, computeNormals: Bool = true,
                      progress: (Double, String) -> Void) throws -> RTIBuildResult {
        let t0 = Date()
        let k = basis.nCoeffs
        guard frames.count == lights.count else { throw RelightError.invalid("Frames and lights mismatch") }
        guard frames.count >= k + 2 else {
            throw RelightError.invalid("\(basis.rawValue.uppercased()) needs at least \(k + 2) photos with a detected light (have \(frames.count)).")
        }
        guard let size = ImageUtils.orientedSize(of: frames[0]) else { throw RelightError.io("Cannot read first photo") }
        let (W, H) = ImageUtils.fit(width: size.width, height: size.height, maxSide: maxSide)
        let npx = W * H
        let n = vDSP_Length(npx)
        let nplanes = 3 * k
        let N = frames.count

        let A = lights.map { basis.weights(lx: $0[0], ly: $0[1]) }
        guard let P = LinAlg.pseudoInverse(A, ridge: 1e-7) else {
            throw RelightError.invalid("Light directions are degenerate: spread the light around more.")
        }
        let Q = computeNormals ? LinAlg.pseudoInverse(lights.map { [$0[0], $0[1], $0[2]] }, ridge: 1e-7) : nil

        let coef = UnsafeMutablePointer<Float>.allocate(capacity: nplanes * npx)
        coef.initialize(repeating: 0, count: nplanes * npx)
        defer { coef.deallocate() }
        let nrm = UnsafeMutablePointer<Float>.allocate(capacity: 3 * npx)
        nrm.initialize(repeating: 0, count: 3 * npx)
        defer { nrm.deallocate() }
        let ch = UnsafeMutablePointer<Float>.allocate(capacity: 4 * npx)   // r, g, b, luminance
        defer { ch.deallocate() }

        for i in 0..<N {
            try autoreleasepool {
                guard let img = ImageUtils.load(frames[i], maxPixel: max(W, H)) else {
                    throw RelightError.io("Cannot decode \(frames[i].lastPathComponent)")
                }
                if W != H && (img.width > img.height) != (W > H) {
                    throw RelightError.invalid("\(frames[i].lastPathComponent) has a different orientation than the first photo")
                }
                let px = ImageUtils.rgba(img, width: W, height: H)
                px.withUnsafeBufferPointer { p in
                    var s: Float = 1.0 / 255.0
                    for c in 0..<3 {
                        vDSP_vfltu8(p.baseAddress! + c, 4, ch + c * npx, 1, n)
                        vDSP_vsmul(ch + c * npx, 1, &s, ch + c * npx, 1, n)
                    }
                }
                var wr: Float = 0.299, wg: Float = 0.587, wb: Float = 0.114
                let lum = ch + 3 * npx
                vDSP_vsmul(ch, 1, &wr, lum, 1, n)
                vDSP_vsma(ch + npx, 1, &wg, lum, 1, lum, 1, n)
                vDSP_vsma(ch + 2 * npx, 1, &wb, lum, 1, lum, 1, n)

                DispatchQueue.concurrentPerform(iterations: k + 1) { j in
                    if j < k {
                        for c in 0..<3 {
                            var w = Float(P[j][i])
                            let dst = coef + (j * 3 + c) * npx
                            vDSP_vsma(ch + c * npx, 1, &w, dst, 1, dst, 1, n)
                        }
                    } else if let Q {
                        for d in 0..<3 {
                            var w = Float(Q[d][i])
                            let dst = nrm + d * npx
                            vDSP_vsma(lum, 1, &w, dst, 1, dst, 1, n)
                        }
                    }
                }
            }
            progress(0.85 * Double(i + 1) / Double(N), "Fitting photo \(i + 1) of \(N)")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)

        // Quantize each coefficient plane to 8 bits with its own scale/bias, three planes per JPEG.
        var scale = [Double](repeating: 1, count: nplanes)
        var bias = [Double](repeating: 0, count: nplanes)
        var out = [UInt8](repeating: 255, count: npx * 4)
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: npx)
        defer { tmp.deallocate() }
        for j in 0..<k {
            for c in 0..<3 {
                let p = j * 3 + c
                let src = coef + p * npx
                let (lo, hi) = robustRange(src, count: npx)
                let sc = max(hi - lo, 1e-6)
                scale[p] = Double(sc)
                bias[p] = Double(-lo / sc)
                var a = -lo
                vDSP_vsadd(src, 1, &a, tmp, 1, n)
                var m = 255 / sc
                vDSP_vsmul(tmp, 1, &m, tmp, 1, n)
                var z: Float = 0, top: Float = 255
                vDSP_vclip(tmp, 1, &z, &top, tmp, 1, n)
                out.withUnsafeMutableBufferPointer { vDSP_vfixru8(tmp, 1, $0.baseAddress! + c, 4, n) }
            }
            guard let cg = ImageUtils.makeImage(rgba: out, width: W, height: H) else { throw RelightError.io("Encoding failed") }
            // Quality 1.0: ImageIO only disables chroma subsampling at maximum quality, and the three
            // channels hold unrelated coefficients that must not be blurred together.
            try ImageUtils.write(cg, to: output.appendingPathComponent("plane_\(j).jpg"), quality: jpegQuality)
            progress(0.85 + 0.12 * Double(j + 1) / Double(k), "Writing plane \(j + 1) of \(k)")
        }

        if Q != nil {
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<npx {
                    let x = nrm[i], y = nrm[npx + i], z = nrm[2 * npx + i]
                    let l = (x * x + y * y + z * z).squareRoot()
                    if l > 1e-8 {
                        o[i * 4] = UInt8(max(0, min(255, (x / l * 0.5 + 0.5) * 255 + 0.5)))
                        o[i * 4 + 1] = UInt8(max(0, min(255, (y / l * 0.5 + 0.5) * 255 + 0.5)))
                        o[i * 4 + 2] = UInt8(max(0, min(255, (z / l * 0.5 + 0.5) * 255 + 0.5)))
                    } else {
                        o[i * 4] = 128; o[i * 4 + 1] = 128; o[i * 4 + 2] = 255
                    }
                }
            }
            if let cg = ImageUtils.makeImage(rgba: out, width: W, height: H) {
                try ImageUtils.write(cg, to: output.appendingPathComponent("normals.png"), type: .png)
            }
        }

        let info = RelightInfo(width: W, height: H, format: "jpg", type: basis.rawValue, colorspace: "rgb",
                               lights: lights.flatMap { $0.map { ($0 * 1000).rounded() / 1000 } },
                               nplanes: nplanes, quality: Int(jpegQuality * 100),
                               materials: [.init(scale: scale, bias: bias)])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try enc.encode(info).write(to: output.appendingPathComponent("info.json"))
        progress(1, "Done")
        return RTIBuildResult(width: W, height: H, lightsUsed: N, seconds: Date().timeIntervalSince(t0))
    }

    /// 0.02% / 99.98% percentiles from a subsample: keeps 8-bit precision from being wasted on a few outliers.
    static func robustRange(_ p: UnsafePointer<Float>, count: Int) -> (Float, Float) {
        let step = max(1, count / 250_000)
        var s: [Float] = []
        s.reserveCapacity(count / step + 1)
        var i = 0
        while i < count { s.append(p[i]); i += step }
        s.sort()
        let lo = s[Int(Double(s.count - 1) * 0.0002)]
        let hi = s[Int(Double(s.count - 1) * 0.9998)]
        return (lo, hi)
    }
}

/// CPU reference renderer for relight rgb PTM/HSH folders (used for previews and tests).
enum RTIRenderer {
    struct Planes {
        let info: RelightInfo
        let planes: [[UInt8]]   // RGBX per coefficient
    }

    static func loadPlanes(_ dir: URL) throws -> Planes {
        let info = try RelightInfo.load(from: dir)
        var planes: [[UInt8]] = []
        for j in 0..<info.nCoeffs {
            guard let img = ImageUtils.load(dir.appendingPathComponent("plane_\(j).\(info.format)")) else {
                throw RelightError.io("Missing plane_\(j)")
            }
            planes.append(ImageUtils.rgba(img, width: info.width, height: info.height))
        }
        return Planes(info: info, planes: planes)
    }

    /// Returns RGBX8 relit at light (lx, ly).
    static func render(_ p: Planes, lx: Double, ly: Double) -> [UInt8] {
        let info = p.info
        let w = info.basis!.weights(lx: lx, ly: ly)
        let sc = info.materials[0].scale, bi = info.materials[0].bias
        let npx = info.width * info.height
        var out = [UInt8](repeating: 255, count: npx * 4)
        // color = Σ_j w_j (byte/255 - bias) * scale  =  Σ_j (w_j*scale/255) byte  -  Σ_j w_j*scale*bias
        var mul = [[Float]](repeating: [0, 0, 0], count: w.count)
        var add: [Float] = [0, 0, 0]
        for j in 0..<w.count {
            for c in 0..<3 {
                mul[j][c] = Float(w[j] * sc[j * 3 + c] / 255)
                add[c] -= Float(w[j] * sc[j * 3 + c] * bi[j * 3 + c])
            }
        }
        for i in 0..<npx {
            for c in 0..<3 {
                var v = add[c]
                for j in 0..<w.count { v += mul[j][c] * Float(p.planes[j][i * 4 + c]) }
                out[i * 4 + c] = UInt8(max(0, min(255, v * 255 + 0.5)))
            }
        }
        return out
    }
}
