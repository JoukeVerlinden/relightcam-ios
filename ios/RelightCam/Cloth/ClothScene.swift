import Foundation
import simd

/// Panel (metres, x right, y up, origin at the panel centre) → RTI texture coordinates.
/// Mirrors the shader in ClothShaders.swift exactly.
struct TextureMapping {
    var grainAngle: Float          // radians
    var tiling: ClothTiling
    var sampleSize: SIMD2<Float>   // physical size of the whole RTI image, metres
    var repeatRect: SIMD4<Float>   // u0, v0, du, dv (image coords, v down)

    var tileSize: SIMD2<Float> { SIMD2(sampleSize.x * repeatRect.z, sampleSize.y * repeatRect.w) }

    /// Panel → textile frame (rotation by −grain).
    func textile(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let c = cos(grainAngle), s = sin(grainAngle)
        return SIMD2(c * p.x + s * p.y, -s * p.x + c * p.y)
    }

    /// Returns uv, the mirror flips (±1) and whether the point has texture at all.
    func map(_ p: SIMD2<Float>) -> (uv: SIMD2<Float>, flip: SIMD2<Float>, inside: Bool) {
        let q = textile(p)
        if tiling == .off {
            let uv = SIMD2(q.x / sampleSize.x + 0.5, 0.5 - q.y / sampleSize.y)
            return (uv, SIMD2(1, 1), uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1)
        }
        let t = SIMD2(q.x / tileSize.x, -q.y / tileSize.y) + 0.5
        let cell = floor(t)
        var f = t - cell
        var flip = SIMD2<Float>(1, 1)
        if tiling == .mirrored {
            if Int(abs(cell.x)) % 2 == 1 { f.x = 1 - f.x; flip.x = -1 }
            if Int(abs(cell.y)) % 2 == 1 { f.y = 1 - f.y; flip.y = -1 }
        }
        return (SIMD2(repeatRect.x, repeatRect.y) + f * SIMD2(repeatRect.z, repeatRect.w), flip, true)
    }
}

struct PropMesh {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    var color: SIMD3<Float>
    /// floors are left out of AR exports (AR has a real floor)
    var exportable = true
}

/// Everything the cloth viewer needs for one support: simulation, props, camera and light frames.
struct ClothScene {
    var sim: ClothSimulation
    var mapping: TextureMapping
    var panelSize: SIMD2<Float>
    var props: [PropMesh]
    var cameraTarget: SIMD3<Float>
    var cameraDistance: Float
    /// half width / half height of what the default view should show (the camera fits it to the screen)
    var fitHalf: SIMD2<Float>
    var cameraYaw: Float
    var cameraPitch: Float
    /// Frame for the light dome / orbit: (right, dome-up, axis). The axis is the "zenith" of the dome.
    var lightFrame: (right: SIMD3<Float>, up: SIMD3<Float>, axis: SIMD3<Float>)
    var boundsCenter: SIMD3<Float>
    var boundsRadius: Float
    var pinsKey: String

    static func make(settings: ClothSettings, sampleSize: SIMD2<Float>, mask: ((SIMD2<Float>) -> Bool)?) -> ClothScene {
        let grain = Float(settings.grainAngle * .pi / 180)
        let rr = settings.repeatRect.count == 4 ? SIMD4<Float>(settings.repeatRect.map { Float($0) }) : SIMD4(0, 0, 1, 1)
        // the board stands for a mounted sample, so it always shows the sample itself
        let tiling: ClothTiling = settings.support == .board ? .off : settings.tiling
        let mapping = TextureMapping(grainAngle: grain, tiling: tiling, sampleSize: sampleSize, repeatRect: rr)

        // Panel: the rotated sample's bounding box, or the requested size when tiling.
        var panel: SIMD2<Float>
        if tiling == .off {
            let c = abs(cos(grain)), s = abs(sin(grain))
            panel = SIMD2(sampleSize.x * c + sampleSize.y * s, sampleSize.x * s + sampleSize.y * c)
        } else {
            panel = SIMD2(Float(settings.panelWidth), Float(settings.panelHeight))
        }
        let support = settings.support
        let maxN: Int = support == .board ? 48 : (support == .dressForm ? 84 : 64)
        let aspect = panel.y / panel.x
        let nx = aspect <= 1 ? maxN : max(8, Int((Float(maxN) / aspect).rounded()))
        let ny = aspect <= 1 ? max(8, Int((Float(maxN) * aspect).rounded())) : maxN

        // Which particles carry fabric (inside the sample and the cutout mask).
        var active = [Bool](repeating: true, count: nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                let p = SIMD2((Float(i) / Float(nx - 1) - 0.5) * panel.x, (0.5 - Float(j) / Float(ny - 1)) * panel.y)
                let m = mapping.map(p)
                var on = m.inside
                if on, tiling == .off, settings.useMask, let mask { on = mask(m.uv) }
                active[j * nx + i] = on
            }
        }
        // Drop isolated particles (no active 4-neighbour): they'd float around.
        var cleaned = active
        for j in 0..<ny {
            for i in 0..<nx where active[j * nx + i] {
                var k = 0
                if i > 0 && active[j * nx + i - 1] { k += 1 }
                if i < nx - 1 && active[j * nx + i + 1] { k += 1 }
                if j > 0 && active[(j - 1) * nx + i] { k += 1 }
                if j < ny - 1 && active[(j + 1) * nx + i] { k += 1 }
                if k == 0 { cleaned[j * nx + i] = false }
            }
        }
        active = cleaned
        if !active.contains(true) { active = [Bool](repeating: true, count: nx * ny) }

        let mat = settings.material
        var props: [PropMesh] = []
        let size = max(panel.x, panel.y)
        var target = SIMD3<Float>(0, 0, 0)
        var dist = size * 1.9
        var fit = SIMD2<Float>(panel.x * 0.5, panel.y * 0.5) * 1.08
        var yaw: Float = 0, pitch: Float = 0
        var frame = (right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 1, 0), axis: SIMD3<Float>(0, 0, 1))
        var bc = SIMD3<Float>(0, 0, 0)
        var br = size * 0.8
        var colliders: [ClothCollider] = []
        let place: (SIMD2<Float>) -> SIMD3<Float>
        var autoPins: [(SIMD2<Float>, SIMD3<Float>?)] = []   // panel point, optional target

        switch support {
        case .board:
            place = { SIMD3($0.x, $0.y, 0) }
            props.append(Self.box(center: SIMD3(0, 0, -0.006), half: SIMD3(panel.x * 0.5 + 0.01, panel.y * 0.5 + 0.01, 0.005),
                                  color: SIMD3(0.32, 0.30, 0.28)))
            dist = size * 1.7
        case .free:
            place = { SIMD3($0.x, $0.y, 0) }
            // floor (hidden in AR, where it only catches shadows) at the height the AR view hangs the cloth
            props.append(Self.floorPlane(y: -(panel.y * 0.5 + 0.15), half: max(1, size * 1.5), color: SIMD3(0.30, 0.29, 0.28)))
            autoPins = [(SIMD2(-panel.x * 0.5, panel.y * 0.5), nil), (SIMD2(panel.x * 0.5, panel.y * 0.5), nil)]
            target = SIMD3(0, -panel.y * 0.05, 0)
            fit = SIMD2(panel.x * 0.5 + 0.05, panel.y * 0.62)
            br = size
        case .dressForm:
            let form = DressForm(settings.form)
            colliders.append(.form(form))
            colliders.append(.plane(y: 0))
            let fm = form.mesh()
            props.append(PropMesh(positions: fm.positions, normals: fm.normals, indices: fm.indices, color: SIMD3(0.80, 0.76, 0.68)))
            props.append(Self.cylinderY(x: 0, z: 0, radius: 0.014, y0: 0.02, y1: form.yBottom, color: SIMD3(0.25, 0.22, 0.2)))
            props.append(Self.cylinderY(x: 0, z: 0, radius: 0.2, y0: 0, y1: 0.02, color: SIMD3(0.25, 0.22, 0.2)))
            props.append(Self.floorPlane(y: 0, half: 1.6, color: SIMD3(0.42, 0.40, 0.38)))
            let bust = form.section(at: 1.24)
            if tiling == .off && size < 0.6 {
                // swatch: pin its top corners on the front of the form, above the bust
                let y = min(form.yTop - 0.12, 1.24 + panel.y * 0.5)
                let zFront = bust.zOff + bust.bf + 0.06
                place = { SIMD3($0.x, y - panel.y * 0.5 + $0.y, zFront) }
                let hw = min(panel.x * 0.5, bust.a * 0.8)
                autoPins = [(SIMD2(-panel.x * 0.5, panel.y * 0.5), form.frontPoint(y: y, x: -hw) + SIMD3(0, 0, mat.thickness)),
                            (SIMD2(panel.x * 0.5, panel.y * 0.5), form.frontPoint(y: y, x: hw) + SIMD3(0, 0, mat.thickness))]
            } else {
                // a length of fabric: top edge at the shoulders, falling over the front
                let topY = form.yTop - 0.06
                let zFront = bust.zOff + bust.bf + 0.08
                place = { SIMD3($0.x, topY - panel.y * 0.5 + $0.y, zFront) }
                let sh = form.section(at: 1.41)
                let px = sh.a * 0.62
                let lp = (form.surfaceTop(x: -px, z: sh.zOff + 0.01) ?? SIMD3(-px, 1.43, 0)) + SIMD3(0, mat.thickness, 0)
                let rp = (form.surfaceTop(x: px, z: sh.zOff + 0.01) ?? SIMD3(px, 1.43, 0)) + SIMD3(0, mat.thickness, 0)
                autoPins = [(SIMD2(-min(panel.x * 0.5, px * 1.2), panel.y * 0.5), lp),
                            (SIMD2(min(panel.x * 0.5, px * 1.2), panel.y * 0.5), rp)]
            }
            target = SIMD3(0, 0.98, 0)
            fit = SIMD2(0.45, 0.80)
            dist = 2.1
            pitch = -0.08
            frame = (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0))
            bc = SIMD3(0, 0.95, 0)
            br = 1.0
        }

        let sim = ClothSimulation(nx: nx, ny: ny, width: panel.x, height: panel.y, active: active, material: mat,
                                  grainAngle: grain, place: place)
        sim.colliders = colliders
        sim.rigid = support == .board
        sim.selfCollision = settings.selfCollision && support != .board
        sim.substeps = support == .dressForm ? 7 : 8
        sim.iterations = 2

        let key = "\(support.rawValue)|\(settings.form.rawValue)|\(nx)x\(ny)|\(settings.tiling.rawValue)|\(settings.grainAngle)|\(settings.panelWidth)x\(settings.panelHeight)"
        if settings.pinsKey == key && !settings.pins.isEmpty {
            for p in settings.pins { sim.pin(p.particle, at: SIMD3(p.x, p.y, p.z)) }
        } else {
            for (pp, t) in autoPins {
                if let i = Self.nearestActive(sim, to: pp) { sim.pin(i, at: t ?? sim.pos[i], glide: t != nil) }
            }
        }
        return ClothScene(sim: sim, mapping: mapping, panelSize: panel, props: props, cameraTarget: target,
                          cameraDistance: dist, fitHalf: fit, cameraYaw: yaw, cameraPitch: pitch, lightFrame: frame,
                          boundsCenter: bc, boundsRadius: br, pinsKey: key)
    }

    static func nearestActive(_ sim: ClothSimulation, to p: SIMD2<Float>) -> Int? {
        var best: Int?
        var bd = Float.infinity
        for i in 0..<sim.count where sim.active[i] {
            let d = simd_distance_squared(sim.panel[i], p)
            if d < bd { bd = d; best = i }
        }
        return best
    }

    // MARK: prop geometry

    static func box(center c: SIMD3<Float>, half h: SIMD3<Float>, color: SIMD3<Float>) -> PropMesh {
        var P: [SIMD3<Float>] = [], N: [SIMD3<Float>] = [], I: [UInt32] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)), (SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1)),
            (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)), (SIMD3(0, -1, 0), SIMD3(0, 0, -1), SIMD3(1, 0, 0)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
        ]
        for (n, u, v) in faces {
            let base = UInt32(P.count)
            for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                P.append(c + (n + u * a + v * b) * h)
                N.append(n)
            }
            I += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return PropMesh(positions: P, normals: N, indices: I, color: color)
    }

    static func cylinderY(x: Float, z: Float, radius r: Float, y0: Float, y1: Float, color: SIMD3<Float>, seg: Int = 40) -> PropMesh {
        var P: [SIMD3<Float>] = [], N: [SIMD3<Float>] = [], I: [UInt32] = []
        for k in 0...seg {
            let a = Float(k) / Float(seg) * 2 * .pi
            let n = SIMD3<Float>(cos(a), 0, sin(a))
            P.append(SIMD3(x, y0, z) + n * r); N.append(n)
            P.append(SIMD3(x, y1, z) + n * r); N.append(n)
        }
        for k in 0..<seg {
            let b = UInt32(k * 2)
            I += [b, b + 1, b + 2, b + 1, b + 3, b + 2]
        }
        // top disc
        let c = UInt32(P.count)
        P.append(SIMD3(x, y1, z)); N.append(SIMD3(0, 1, 0))
        for k in 0...seg {
            let a = Float(k) / Float(seg) * 2 * .pi
            P.append(SIMD3(x + r * cos(a), y1, z + r * sin(a))); N.append(SIMD3(0, 1, 0))
        }
        for k in 0..<seg { I += [c, c + 1 + UInt32(k + 1), c + 1 + UInt32(k)] }
        return PropMesh(positions: P, normals: N, indices: I, color: color)
    }

    static func floorPlane(y: Float, half: Float, color: SIMD3<Float>) -> PropMesh {
        PropMesh(positions: [SIMD3(-half, y, -half), SIMD3(half, y, -half), SIMD3(half, y, half), SIMD3(-half, y, half)],
                 normals: [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: 4), indices: [0, 2, 1, 0, 3, 2], color: color,
                 exportable: false)
    }
}
