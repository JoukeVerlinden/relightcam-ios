import Foundation
import simd

/// One horizontal cross-section of a dress form: an ellipse with separate front and back depth.
struct FormSection {
    var y: Float        // height above the floor, metres
    var a: Float        // half width (x)
    var bf: Float       // front depth (+z, towards the default camera)
    var bb: Float       // back depth (−z)
    var zOff: Float = 0
}

enum FormPreset: String, Codable, CaseIterable, Identifiable {
    case modern, panniers1770, corset1860, bustle1880, straight1920
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modern: return "Modern form"
        case .panniers1770: return "1770s · stays + panniers"
        case .corset1860: return "1860s · corset + crinoline"
        case .bustle1880: return "1880s · bustle"
        case .straight1920: return "1920s · straight"
        }
    }

    /// Cross-sections from top to bottom (sizes roughly a European 38 / US 8).
    var sections: [FormSection] {
        let top: [FormSection] = [
            FormSection(y: 1.50, a: 0.048, bf: 0.048, bb: 0.050),
            FormSection(y: 1.45, a: 0.056, bf: 0.054, bb: 0.060),
            FormSection(y: 1.41, a: 0.190, bf: 0.080, bb: 0.085, zOff: -0.005),
            FormSection(y: 1.31, a: 0.175, bf: 0.100, bb: 0.095),
        ]
        switch self {
        case .modern:
            return top + [
                FormSection(y: 1.24, a: 0.165, bf: 0.125, bb: 0.095),
                FormSection(y: 1.15, a: 0.140, bf: 0.100, bb: 0.090),
                FormSection(y: 1.05, a: 0.125, bf: 0.085, bb: 0.085),
                FormSection(y: 0.95, a: 0.155, bf: 0.095, bb: 0.105),
                FormSection(y: 0.85, a: 0.175, bf: 0.105, bb: 0.120),
                FormSection(y: 0.72, a: 0.165, bf: 0.100, bb: 0.110),
            ]
        case .panniers1770:
            // conical stays: flat high front, narrow waist; panniers make wide flat hips
            return top + [
                FormSection(y: 1.24, a: 0.160, bf: 0.105, bb: 0.090),
                FormSection(y: 1.14, a: 0.130, bf: 0.090, bb: 0.085),
                FormSection(y: 1.05, a: 0.112, bf: 0.075, bb: 0.080),
                FormSection(y: 0.99, a: 0.260, bf: 0.120, bb: 0.140),
                FormSection(y: 0.93, a: 0.380, bf: 0.160, bb: 0.180),
                FormSection(y: 0.82, a: 0.420, bf: 0.170, bb: 0.190),
                FormSection(y: 0.72, a: 0.400, bf: 0.170, bb: 0.190),
            ]
        case .corset1860:
            return top + [
                FormSection(y: 1.24, a: 0.170, bf: 0.130, bb: 0.100),
                FormSection(y: 1.15, a: 0.130, bf: 0.095, bb: 0.085),
                FormSection(y: 1.06, a: 0.100, bf: 0.070, bb: 0.070),
                FormSection(y: 0.96, a: 0.165, bf: 0.100, bb: 0.115),
                FormSection(y: 0.86, a: 0.215, bf: 0.140, bb: 0.160),
                FormSection(y: 0.72, a: 0.300, bf: 0.200, bb: 0.220),
            ]
        case .bustle1880:
            return top + [
                FormSection(y: 1.24, a: 0.165, bf: 0.125, bb: 0.095),
                FormSection(y: 1.15, a: 0.130, bf: 0.095, bb: 0.085),
                FormSection(y: 1.05, a: 0.105, bf: 0.075, bb: 0.075),
                FormSection(y: 0.96, a: 0.160, bf: 0.100, bb: 0.200),
                FormSection(y: 0.88, a: 0.180, bf: 0.110, bb: 0.260),
                FormSection(y: 0.80, a: 0.180, bf: 0.120, bb: 0.240),
                FormSection(y: 0.72, a: 0.170, bf: 0.120, bb: 0.200),
            ]
        case .straight1920:
            return top + [
                FormSection(y: 1.24, a: 0.150, bf: 0.105, bb: 0.090),
                FormSection(y: 1.15, a: 0.145, bf: 0.098, bb: 0.090),
                FormSection(y: 1.05, a: 0.140, bf: 0.095, bb: 0.090),
                FormSection(y: 0.95, a: 0.152, bf: 0.098, bb: 0.100),
                FormSection(y: 0.85, a: 0.165, bf: 0.100, bb: 0.105),
                FormSection(y: 0.72, a: 0.160, bf: 0.100, bb: 0.105),
            ]
        }
    }
}

/// A smooth lofted dress form with an approximate signed distance for cloth collisions.
struct DressForm {
    let sections: [FormSection]   // sorted top → bottom
    let yTop: Float
    let yBottom: Float
    let maxRadius: Float

    init(_ preset: FormPreset) {
        sections = preset.sections.sorted { $0.y > $1.y }
        yTop = sections.first!.y
        yBottom = sections.last!.y
        maxRadius = sections.map { max($0.a, $0.bf + abs($0.zOff), $0.bb + abs($0.zOff)) }.max()!
    }

    /// Smoothly interpolated section at height y (cubic Hermite through the sections).
    func section(at y: Float) -> FormSection {
        let yc = min(max(y, yBottom), yTop)
        var k = 0
        while k < sections.count - 2 && yc < sections[k + 1].y { k += 1 }
        let s0 = sections[k], s1 = sections[k + 1]
        let t = (s0.y - yc) / (s0.y - s1.y)
        func interp(_ f: (FormSection) -> Float) -> Float {
            let p0 = f(s0), p1 = f(s1)
            let dy = s0.y - s1.y
            func slope(_ i: Int) -> Float {
                let a = sections[max(0, i - 1)], b = sections[min(sections.count - 1, i + 1)]
                return (f(b) - f(a)) / max(1e-4, a.y - b.y)
            }
            let m0 = slope(k) * dy, m1 = slope(k + 1) * dy
            let t2 = t * t, t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
        }
        return FormSection(y: yc, a: max(0.01, interp { $0.a }), bf: max(0.01, interp { $0.bf }),
                           bb: max(0.01, interp { $0.bb }), zOff: interp { $0.zOff })
    }

    /// Implicit function: < 0 inside, 0 on the surface. Closed with flat caps at the neck and the bottom.
    func implicit(_ p: SIMD3<Float>) -> Float {
        let s = section(at: p.y)
        let dz = p.z - s.zOff
        let b = dz > 0 ? s.bf : s.bb
        let rho = ((p.x / s.a) * (p.x / s.a) + (dz / b) * (dz / b)).squareRoot()
        var f = rho - 1
        if p.y > yTop { f = max(f, (p.y - yTop) * 25) }
        if p.y < yBottom { f = max(f, (yBottom - p.y) * 25) }
        return f
    }

    /// Approximate signed distance (first order: F/|∇F|) and outward normal.
    func distance(_ p: SIMD3<Float>) -> (d: Float, n: SIMD3<Float>) {
        let e: Float = 0.002
        let f = implicit(p)
        let g = SIMD3<Float>(
            implicit(p + SIMD3(e, 0, 0)) - implicit(p - SIMD3(e, 0, 0)),
            implicit(p + SIMD3(0, e, 0)) - implicit(p - SIMD3(0, e, 0)),
            implicit(p + SIMD3(0, 0, e)) - implicit(p - SIMD3(0, 0, e))) / (2 * e)
        let gl = simd_length(g)
        if gl < 1e-6 { return (1, SIMD3(0, 1, 0)) }
        return (f / gl, g / gl)
    }

    func quickReject(_ p: SIMD3<Float>, margin: Float) -> Bool {
        p.y > yTop + margin || p.y < yBottom - margin || (p.x * p.x + p.z * p.z) > (maxRadius + margin) * (maxRadius + margin)
    }

    /// Highest surface point straight above/below (x, z): where a pin on the shoulder should go.
    func surfaceTop(x: Float, z: Float) -> SIMD3<Float>? {
        var y = yTop + 0.01
        while y > yBottom {
            if implicit(SIMD3(x, y, z)) < 0 { return SIMD3(x, y + 0.002, z) }
            y -= 0.002
        }
        return nil
    }

    /// Front surface point at height y on the centre line (for placing pins).
    func frontPoint(y: Float, x: Float = 0) -> SIMD3<Float> {
        let s = section(at: y)
        let u = min(0.98, abs(x) / s.a)
        let z = s.zOff + s.bf * (1 - u * u).squareRoot()
        return SIMD3(x, y, z)
    }

    /// Triangle mesh of the form body, plus stand.
    func mesh(rings: Int = 72, around: Int = 64) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        var P: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        for r in 0...rings {
            let y = yTop - (yTop - yBottom) * Float(r) / Float(rings)
            let s = section(at: y)
            for k in 0..<around {
                let th = Float(k) / Float(around) * 2 * .pi
                let sn = sin(th)
                P.append(SIMD3(s.a * cos(th), y, s.zOff + (sn > 0 ? s.bf : s.bb) * sn))
            }
        }
        for r in 0..<rings {
            for k in 0..<around {
                let a = UInt32(r * around + k), b = UInt32(r * around + (k + 1) % around)
                let c = UInt32((r + 1) * around + k), d = UInt32((r + 1) * around + (k + 1) % around)
                idx += [a, b, c, b, d, c]
            }
        }
        // caps
        let topC = UInt32(P.count); P.append(SIMD3(0, yTop, sections.first!.zOff))
        for k in 0..<around { idx += [topC, UInt32((k + 1) % around), UInt32(k)] }
        let botC = UInt32(P.count); P.append(SIMD3(0, yBottom, sections.last!.zOff))
        let base = rings * around
        for k in 0..<around { idx += [botC, UInt32(base + k), UInt32(base + (k + 1) % around)] }
        var N = [SIMD3<Float>](repeating: .zero, count: P.count)
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let n = simd_cross(P[b] - P[a], P[c] - P[a])
            N[a] += n; N[b] += n; N[c] += n
        }
        N = N.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        return (P, N, idx)
    }
}
