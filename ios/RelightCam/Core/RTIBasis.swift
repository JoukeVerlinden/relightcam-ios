import Foundation

/// Light-dependent basis functions, identical to relight's Rti::lightWeightsPtm / lightWeightsHsh,
/// so the coefficient planes we write can be rendered by relight.js / OpenLIME.
enum RTIBasis: String, Codable, CaseIterable, Identifiable {
    case ptm
    case hsh

    var id: String { rawValue }
    var nCoeffs: Int { self == .ptm ? 6 : 9 }
    var title: String { self == .ptm ? "PTM (6 coeff.)" : "HSH (9 coeff.)" }

    func weights(lx: Double, ly: Double) -> [Double] {
        switch self {
        case .ptm:
            // relight ordering: 1, x, y, xx, xy, yy
            return [1, lx, ly, lx * lx, lx * ly, ly * ly]
        case .hsh:
            let lz = max(0, 1 - lx * lx - ly * ly).squareRoot()
            var phi = atan2(ly, lx)
            if phi < 0 { phi += 2 * .pi }
            let theta = min(acos(min(1, lz)), .pi / 2 - 0.01)
            let cosP = cos(phi), sinP = sin(phi)
            let cosT = cos(theta)
            let cosT2 = cosT * cosT
            let s = max(0, cosT - cosT2).squareRoot()
            return [
                1 / (2 * Double.pi).squareRoot(),
                (6 / Double.pi).squareRoot() * cosP * s,
                (3 / (2 * Double.pi)).squareRoot() * (-1 + 2 * cosT),
                (6 / Double.pi).squareRoot() * s * sinP,
                (30 / Double.pi).squareRoot() * cos(2 * phi) * (-cosT + cosT2),
                (30 / Double.pi).squareRoot() * cosP * (-1 + 2 * cosT) * s,
                (5 / (2 * Double.pi)).squareRoot() * (1 - 6 * cosT + 6 * cosT2),
                (30 / Double.pi).squareRoot() * (-1 + 2 * cosT) * s * sinP,
                (30 / Double.pi).squareRoot() * (-cosT + cosT2) * sin(2 * phi),
            ]
        }
    }
}

/// Tiny dense linear algebra for the k×k normal equations (k ≤ 9).
enum LinAlg {
    /// Returns P = (AᵀA + λI)⁻¹ Aᵀ, i.e. the least-squares solve operator (cols × rows), row-major.
    static func pseudoInverse(_ a: [[Double]], ridge: Double = 1e-6) -> [[Double]]? {
        guard let n = a.first?.count, !a.isEmpty else { return nil }
        let m = a.count
        var ata = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in 0..<n { var s = 0.0; for r in 0..<m { s += a[r][i] * a[r][j] }; ata[i][j] = s } }
        var trace = 0.0
        for i in 0..<n { trace += ata[i][i] }
        for i in 0..<n { ata[i][i] += ridge * trace / Double(n) }
        guard let inv = invert(ata) else { return nil }
        var p = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for i in 0..<n { for r in 0..<m { var s = 0.0; for k in 0..<n { s += inv[i][k] * a[r][k] }; p[i][r] = s } }
        return p
    }

    static func invert(_ m: [[Double]]) -> [[Double]]? {
        let n = m.count
        var a = m
        var inv = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for c in 0..<n {
            var piv = c
            for r in c..<n where abs(a[r][c]) > abs(a[piv][c]) { piv = r }
            if abs(a[piv][c]) < 1e-12 { return nil }
            a.swapAt(c, piv); inv.swapAt(c, piv)
            let d = a[c][c]
            for k in 0..<n { a[c][k] /= d; inv[c][k] /= d }
            for r in 0..<n where r != c {
                let f = a[r][c]
                if f == 0 { continue }
                for k in 0..<n { a[r][k] -= f * a[c][k]; inv[r][k] -= f * inv[c][k] }
            }
        }
        return inv
    }
}
