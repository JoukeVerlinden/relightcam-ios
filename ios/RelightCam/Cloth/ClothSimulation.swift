import Foundation
import simd

enum ClothCollider {
    case plane(y: Float)
    case form(DressForm)

    /// Signed distance and outward normal (nil when far away).
    func distance(_ p: SIMD3<Float>, margin: Float) -> (d: Float, n: SIMD3<Float>)? {
        switch self {
        case .plane(let y):
            return (p.y - y, SIMD3(0, 1, 0))
        case .form(let f):
            if f.quickReject(p, margin: margin + 0.02) { return nil }
            let r = f.distance(p)
            return r.d > margin ? nil : r
        }
    }
}

/// Small-step XPBD cloth on a regular grid (Macklin et al. 2019), Gauss–Seidel, one iteration per substep.
final class ClothSimulation {
    struct Constraint {
        var a: Int32
        var b: Int32
        var rest: Float
        var compliance: Float   // dimensionless: correction is −C / (wa + wb + compliance · w)
    }

    let nx: Int
    let ny: Int
    let spacing: Float
    var pos: [SIMD3<Float>]
    var prev: [SIMD3<Float>]
    var vel: [SIMD3<Float>]
    var w: [Float]
    var active: [Bool]
    let panel: [SIMD2<Float>]
    private(set) var constraints: [Constraint] = []
    struct Bend {
        var i: Int32
        var a: Int32
        var b: Int32
        var compliance: Float   // physical XPBD compliance (1/(N·m)), divided by h² when solving
    }
    private(set) var bends: [Bend] = []
    let particleW: Float
    var gravity = SIMD3<Float>(0, -9.81, 0)
    var colliders: [ClothCollider] = []
    /// pin → where it should end up; the pinned point glides there instead of teleporting
    private(set) var pins: [Int: SIMD3<Float>] = [:]
    private var pinCurrent: [Int: SIMD3<Float>] = [:]
    /// Long-range attachments (Kim et al. 2012): a point may never be farther from a pin than its
    /// distance along the fabric. Keeps pinned cloth inextensible without many iterations.
    private var lra: [(particle: Int32, pin: Int32, rest: Float)] = []
    private var lraDirty = true
    var pinSpeed: Float = 0.6   // m/s
    private(set) var grabbed: Int?
    private var grabTarget = SIMD3<Float>.zero
    var friction: Float
    var thickness: Float
    var damping: Float
    var selfCollision = false
    var rigid = false
    var substeps = 8
    /// distance-constraint passes per substep
    var iterations = 1
    var count: Int { nx * ny }

    init(nx: Int, ny: Int, width: Float, height: Float, active: [Bool], material: ClothMaterial,
         grainAngle: Float, place: (SIMD2<Float>) -> SIMD3<Float>) {
        self.nx = nx
        self.ny = ny
        let dx = width / Float(nx - 1), dy = height / Float(ny - 1)
        spacing = min(dx, dy)
        var pn: [SIMD2<Float>] = []
        pn.reserveCapacity(nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                pn.append(SIMD2((Float(i) / Float(nx - 1) - 0.5) * width, (0.5 - Float(j) / Float(ny - 1)) * height))
            }
        }
        panel = pn
        pos = pn.map(place)
        prev = pos
        vel = [SIMD3<Float>](repeating: .zero, count: nx * ny)
        self.active = active
        let pw = 1 / max(1e-7, material.density * dx * dy)
        particleW = pw
        w = active.map { $0 ? pw : 0 }
        friction = material.friction
        thickness = material.thickness
        damping = material.damping

        // Anisotropy: stiff along warp and weft, stretchy along the bias.
        let c = cos(grainAngle), s = sin(grainAngle)
        func biasFactor(_ e: SIMD2<Float>) -> Float {
            let t = SIMD2(c * e.x + s * e.y, -s * e.x + c * e.y)
            let l2 = simd_length_squared(t)
            if l2 < 1e-12 { return 0 }
            let f = 2 * t.x * t.y / l2
            return f * f
        }
        func add(_ a: Int, _ b: Int, _ comp: Float) {
            guard active[a], active[b] else { return }
            constraints.append(Constraint(a: Int32(a), b: Int32(b), rest: simd_distance(pos[a], pos[b]), compliance: comp))
        }
        func id(_ i: Int, _ j: Int) -> Int { j * nx + i }
        for j in 0..<ny {
            for i in 0..<nx {
                let p = id(i, j)
                for (di, dj) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
                    let i2 = i + di, j2 = j + dj
                    guard i2 < nx, j2 >= 0, j2 < ny else { continue }
                    let q = id(i2, j2)
                    let e = pn[q] - pn[p]
                    let b = biasFactor(e)
                    add(p, q, material.threadCompliance * (1 - b) + material.biasCompliance * b)
                }
            }
        }
        // Bending: straighten every row/column triple (discrete curvature). Energy (B/2)∫κ² with
        // κ ≈ 2|x_i − (x_a + x_b)/2| / s² over a strip of width s gives XPBD compliance α = s² / (4B).
        // A one-iteration solver only spreads stiffness one particle per pass, so curvature is also
        // constrained over spans of 3 and 9 particles (α = k³s²/4B, the same rigidity at a coarser scale).
        // Stiff fabrics then hold their shape at any grid resolution; soft ones stay compliant.
        let B = max(1e-9, material.bendingRigidity)
        for k in [1, 3, 9] {
            let kf = Float(k)
            for j in 0..<ny {
                for i in 0..<nx {
                    let p = id(i, j)
                    guard active[p] else { continue }
                    if i - k >= 0 && i + k < nx && active[p - k] && active[p + k] {
                        bends.append(Bend(i: Int32(p), a: Int32(p - k), b: Int32(p + k), compliance: kf * kf * kf * dx * dx / (4 * B)))
                    }
                    if j - k >= 0 && j + k < ny && active[p - k * nx] && active[p + k * nx] {
                        bends.append(Bend(i: Int32(p), a: Int32(p - k * nx), b: Int32(p + k * nx), compliance: kf * kf * kf * dy * dy / (4 * B)))
                    }
                }
            }
        }
        // Interleave the constraint order a little so Gauss–Seidel doesn't sweep in one direction only.
        constraints = constraints.enumerated().sorted { ($0.offset % 7, $0.offset) < ($1.offset % 7, $1.offset) }.map(\.element)
    }

    /// Test hook: drop constraints matching a predicate.
    func removeConstraints(where pred: (Constraint) -> Bool) { constraints.removeAll(where: pred) }

    // MARK: pins and grabbing

    /// Pins particle i. With `glide`, it travels to `p` at pinSpeed (used when placing fabric on a form).
    func pin(_ i: Int, at p: SIMD3<Float>, glide: Bool = false) {
        guard i >= 0, i < count, active[i] else { return }
        pins[i] = p
        pinCurrent[i] = glide ? pos[i] : p
        if !glide { pos[i] = p; prev[i] = p }
        vel[i] = .zero
        w[i] = 0
        lraDirty = true
    }

    func unpin(_ i: Int) {
        pins[i] = nil
        pinCurrent[i] = nil
        if grabbed != i, active[i] { w[i] = particleW }
        lraDirty = true
    }

    private func rebuildLRA() {
        lra.removeAll(keepingCapacity: true)
        lraDirty = false
        let pinList = Array(pins.keys)
        if pinList.isEmpty { return }
        for i in 0..<count where active[i] && pins[i] == nil {
            // the two nearest pins along the fabric
            var best: [(Int, Float)] = []
            for k in pinList {
                let d = simd_distance(panel[i], panel[k])
                if best.count < 2 { best.append((k, d)); best.sort { $0.1 < $1.1 } }
                else if d < best[1].1 { best[1] = (k, d); best.sort { $0.1 < $1.1 } }
            }
            for (k, d) in best { lra.append((Int32(i), Int32(k), d * 1.01)) }
        }
    }

    func clearPins() {
        for i in pins.keys { unpin(i) }
    }

    func grab(_ i: Int, target: SIMD3<Float>) {
        if let g = grabbed, g != i { release() }
        grabbed = i
        grabTarget = target
        w[i] = 0
    }

    func moveGrab(to t: SIMD3<Float>) { grabTarget = t }

    func release() {
        guard let g = grabbed else { return }
        grabbed = nil
        if pins[g] == nil && active[g] { w[g] = particleW }
    }

    // MARK: stepping

    func step(dt: Float) {
        if rigid { return }
        let h = dt / Float(substeps)
        let n = count
        let damp = max(0, 1 - damping * h)
        if lraDirty { rebuildLRA() }
        // glide pins toward their targets
        for (k, target) in pins {
            let cur = pinCurrent[k] ?? target
            let d = target - cur
            let l = simd_length(d)
            let stepLen = pinSpeed * dt
            pinCurrent[k] = l <= stepLen ? target : cur + d * (stepLen / l)
        }
        let pinNow = pinCurrent
        pos.withUnsafeMutableBufferPointer { P in
            prev.withUnsafeMutableBufferPointer { Q in
                vel.withUnsafeMutableBufferPointer { V in
                    w.withUnsafeBufferPointer { W in
                        constraints.withUnsafeBufferPointer { C in
                          bends.withUnsafeBufferPointer { B in
                            for _ in 0..<substeps {
                                for i in 0..<n {
                                    Q[i] = P[i]
                                    if W[i] > 0 {
                                        V[i] += gravity * h
                                        P[i] += V[i] * h
                                    }
                                }
                                for (k, p) in pinNow { P[k] = p }
                                if let g = grabbed {
                                    // move the grabbed point smoothly toward the finger
                                    P[g] = P[g] + (grabTarget - P[g]) * 0.35
                                }
                                for _ in 0..<iterations {
                                for c in C {
                                    let a = Int(c.a), b = Int(c.b)
                                    let wa = W[a], wb = W[b]
                                    let ws = wa + wb
                                    if ws == 0 { continue }
                                    let d = P[a] - P[b]
                                    let len = simd_length(d)
                                    if len < 1e-9 { continue }
                                    let dl = -(len - c.rest) / (ws + c.compliance * particleW)
                                    let corr = d * (dl / len)
                                    P[a] += corr * wa
                                    P[b] -= corr * wb
                                }
                                }
                                let invH2 = 1 / (h * h)
                                for bnd in B {
                                    let i = Int(bnd.i), a = Int(bnd.a), b = Int(bnd.b)
                                    let wi = W[i], wa = W[a], wb = W[b]
                                    let den = wi + 0.25 * (wa + wb) + bnd.compliance * invH2
                                    if wi + wa + wb == 0 { continue }
                                    let d = P[i] - (P[a] + P[b]) * 0.5
                                    let c = simd_length(d)
                                    if c < 1e-9 { continue }
                                    let nrm = d / c
                                    let dl = -c / den
                                    P[i] += nrm * (dl * wi)
                                    P[a] -= nrm * (dl * wa * 0.5)
                                    P[b] -= nrm * (dl * wb * 0.5)
                                }
                                for att in lra {
                                    let i = Int(att.particle)
                                    if W[i] == 0 { continue }
                                    let anchor = P[Int(att.pin)]
                                    let d = P[i] - anchor
                                    let l = simd_length(d)
                                    if l > att.rest { P[i] = anchor + d * (att.rest / l) }
                                }
                                if !colliders.isEmpty {
                                    for i in 0..<n where W[i] > 0 {
                                        var p = P[i]
                                        for col in colliders {
                                            if let r = col.distance(p, margin: thickness), r.d < thickness {
                                                // Coulomb friction scaled by the contact push (Macklin et al. 2014):
                                                // static below μs·depth, kinetic above.
                                                let depth = thickness - r.d
                                                p += r.n * depth
                                                let disp = p - Q[i]
                                                let tangential = disp - r.n * simd_dot(disp, r.n)
                                                let lt = simd_length(tangential)
                                                if lt < friction * 1.3 * depth {
                                                    p -= tangential
                                                } else if lt > 0 {
                                                    p -= tangential * min(friction * depth / lt, 1)
                                                }
                                            }
                                        }
                                        P[i] = p
                                    }
                                }
                                for i in 0..<n {
                                    V[i] = W[i] > 0 ? (P[i] - Q[i]) / h * damp : .zero
                                }
                            }
                          }
                        }
                    }
                }
            }
        }
        if selfCollision { collideSelf() }
    }

    // MARK: cloth-on-cloth (spatial hash)

    private var hashStart: [Int32] = []
    private var hashEntries: [Int32] = []

    private func collideSelf() {
        let n = count
        let cell = spacing
        let minDist = spacing * 0.6
        let tableSize = 2 * n
        if hashStart.count != tableSize + 1 { hashStart = [Int32](repeating: 0, count: tableSize + 1) }
        if hashEntries.count != n { hashEntries = [Int32](repeating: 0, count: n) }
        @inline(__always) func key(_ x: Int, _ y: Int, _ z: Int) -> Int {
            let h = (x &* 92837111) ^ (y &* 689287499) ^ (z &* 283923481)
            return abs(h) % tableSize
        }
        @inline(__always) func cellOf(_ p: SIMD3<Float>) -> (Int, Int, Int) {
            (Int(floor(p.x / cell)), Int(floor(p.y / cell)), Int(floor(p.z / cell)))
        }
        for i in 0..<hashStart.count { hashStart[i] = 0 }
        for i in 0..<n where active[i] {
            let c = cellOf(pos[i])
            hashStart[key(c.0, c.1, c.2)] += 1
        }
        var acc: Int32 = 0
        for i in 0..<tableSize { acc += hashStart[i]; hashStart[i] = acc }
        hashStart[tableSize] = acc
        for i in 0..<n where active[i] {
            let c = cellOf(pos[i])
            let k = key(c.0, c.1, c.2)
            hashStart[k] -= 1
            hashEntries[Int(hashStart[k])] = Int32(i)
        }
        for i in 0..<n where active[i] {
            let pi = pos[i]
            let c = cellOf(pi)
            let ii = i % nx, ji = i / nx
            for x in (c.0 - 1)...(c.0 + 1) {
                for y in (c.1 - 1)...(c.1 + 1) {
                    for z in (c.2 - 1)...(c.2 + 1) {
                        let k = key(x, y, z)
                        var e = Int(hashStart[k])
                        let end = Int(hashStart[k + 1])
                        while e < end {
                            let j = Int(hashEntries[e])
                            e += 1
                            if j <= i { continue }
                            if abs(j % nx - ii) <= 2 && abs(j / nx - ji) <= 2 { continue }
                            let d = pos[j] - pos[i]
                            let l2 = simd_length_squared(d)
                            if l2 >= minDist * minDist || l2 < 1e-12 { continue }
                            let wi = w[i], wj = w[j]
                            if wi + wj == 0 { continue }
                            let l = l2.squareRoot()
                            let corr = d * ((minDist - l) / l / (wi + wj))
                            pos[i] -= corr * wi
                            pos[j] += corr * wj
                        }
                    }
                }
            }
        }
    }

    // MARK: smoothing (a hand pressing the cloth flat)

    func smooth(_ indices: [Int]) {
        for i in indices where active[i] && w[i] > 0 {
            var sum = SIMD3<Float>.zero
            var k: Float = 0
            let ii = i % nx, jj = i / nx
            for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let a = ii + di, b = jj + dj
                guard a >= 0, a < nx, b >= 0, b < ny else { continue }
                let q = b * nx + a
                if active[q] { sum += pos[q]; k += 1 }
            }
            var p = pos[i]
            if k > 0 { p = p * 0.5 + (sum / k) * 0.5 }
            // press onto the nearest support within 6 cm
            var best: (d: Float, n: SIMD3<Float>)?
            for c in colliders {
                if let r = c.distance(p, margin: 0.06), r.d < 0.06, r.d < (best?.d ?? .infinity) { best = r }
            }
            if let b = best { p -= b.n * (b.d - thickness) * 0.8 }
            pos[i] = p
            prev[i] = p
            vel[i] = .zero
        }
    }

    // MARK: geometry for rendering

    /// Per-vertex normals and tangents (tangent = direction of increasing panel x).
    func frames() -> (normals: [SIMD3<Float>], tangents: [SIMD3<Float>]) {
        let n = count
        var N = [SIMD3<Float>](repeating: .zero, count: n)
        var T = [SIMD3<Float>](repeating: .zero, count: n)
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let a = j * nx + i, b = a + nx, c = a + 1, d = b + 1
                if active[a] && active[b] && active[c] {
                    let fn = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
                    N[a] += fn; N[b] += fn; N[c] += fn
                }
                if active[b] && active[d] && active[c] {
                    let fn = simd_cross(pos[d] - pos[b], pos[c] - pos[b])
                    N[b] += fn; N[d] += fn; N[c] += fn
                }
            }
        }
        for j in 0..<ny {
            for i in 0..<nx {
                let p = j * nx + i
                let l = (i > 0 && active[p - 1]) ? p - 1 : p
                let r = (i < nx - 1 && active[p + 1]) ? p + 1 : p
                T[p] = pos[r] - pos[l]
                let nl = simd_length(N[p])
                N[p] = nl > 1e-12 ? N[p] / nl : SIMD3(0, 0, 1)
                let t = T[p] - N[p] * simd_dot(N[p], T[p])
                let tl = simd_length(t)
                T[p] = tl > 1e-12 ? t / tl : SIMD3(1, 0, 0)
            }
        }
        return (N, T)
    }

    /// Triangles over active quads, wound so that T × B points along the front normal.
    func triangleIndices() -> [UInt32] {
        var out: [UInt32] = []
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let a = j * nx + i, b = a + nx, c = a + 1, d = b + 1
                if active[a] && active[b] && active[c] { out += [UInt32(a), UInt32(b), UInt32(c)] }
                if active[b] && active[d] && active[c] { out += [UInt32(b), UInt32(d), UInt32(c)] }
            }
        }
        return out
    }

    var hasNaN: Bool { pos.contains { !$0.x.isFinite || !$0.y.isFinite || !$0.z.isFinite } }
}
