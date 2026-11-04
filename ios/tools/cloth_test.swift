// macOS harness for the cloth simulation:
//   mkdir -p /tmp/ct && cp tools/cloth_test.swift /tmp/ct/main.swift
//   swiftc -O RelightCam/Cloth/*.swift RelightCam/Core/*.swift /tmp/ct/main.swift -o /tmp/ct/t && /tmp/ct/t
import Foundation
import simd

func run(_ name: String, _ s: ClothSettings, sample: SIMD2<Float>, seconds: Float = 3) -> ClothScene {
    let scene = ClothScene.make(settings: s, sampleSize: sample, mask: nil)
    let sim = scene.sim
    let t0 = Date()
    let frames = Int(seconds * 60)
    for _ in 0..<frames { sim.step(dt: 1.0 / 60) }
    let ms = Date().timeIntervalSince(t0) * 1000 / Double(frames)
    // structural stretch
    var maxStretch: Float = 0
    for j in 0..<sim.ny { for i in 0..<(sim.nx - 1) {
        let a = j * sim.nx + i, b = a + 1
        guard sim.active[a], sim.active[b] else { continue }
        let rest = simd_distance(sim.panel[a], sim.panel[b])
        maxStretch = max(maxStretch, simd_distance(sim.pos[a], sim.pos[b]) / rest - 1)
    } }
    var pen = 0
    var minY: Float = .infinity
    var ke: Float = 0
    for i in 0..<sim.count where sim.active[i] {
        minY = min(minY, sim.pos[i].y)
        ke += simd_length_squared(sim.vel[i])
        for c in sim.colliders { if let r = c.distance(sim.pos[i], margin: 0.01), r.d < -0.004 { pen += 1; break } }
    }
    print(String(format: "%-28@ %3dx%-3d %5.2f ms/frame  NaN:%@  maxStretch %5.1f%%  penetrating %4d  minY %6.3f  rms v %.3f",
                 name as NSString, sim.nx, sim.ny, ms, sim.hasNaN ? "YES" : "no", maxStretch * 100, pen, minY,
                 (ke / Float(sim.active.filter { $0 }.count)).squareRoot()))
    return scene
}

// 1. hanging free from two pinned corners, all materials
for m in ClothMaterial.allCases {
    var s = ClothSettings(); s.support = .free; s.material = m
    _ = run("free \(m.rawValue)", s, sample: SIMD2(0.5, 0.6))
}
// 2. bending: Peirce cantilever. An overhang of twice the bending length c should droop ≈ 41.5°.
for m in ClothMaterial.allCases {
    let c = m.bendingLength, over = 2 * c, clampLen: Float = 0.02
    var s = ClothSettings(); s.support = .free; s.material = m; s.selfCollision = false
    let L = over + clampLen
    let sim = ClothScene.make(settings: s, sampleSize: SIMD2(L, 0.02), mask: nil).sim
    sim.clearPins()
    for i in 0..<sim.count { sim.pos[i] = SIMD3(sim.panel[i].x, 0, -sim.panel[i].y); sim.prev[i] = sim.pos[i] }
    for j in 0..<sim.ny { for i in 0..<sim.nx where sim.panel[j * sim.nx + i].x < -L / 2 + clampLen { let k = j * sim.nx + i; sim.pin(k, at: sim.pos[k]) } }
    for _ in 0..<300 { sim.step(dt: 1.0 / 60) }
    var edge = 0; while sim.panel[edge].x < -L / 2 + clampLen { edge += 1 }
    var tip = SIMD3<Float>.zero, root = SIMD3<Float>.zero
    for j in 0..<sim.ny { tip += sim.pos[j * sim.nx + sim.nx - 1]; root += sim.pos[j * sim.nx + edge] }
    let ang = atan2(-(tip.y - root.y), tip.x - root.x) * 180 / .pi
    print(String(format: "Peirce %-9@ c=%.1f cm: droop %.1f° (target ≈ 41.5°)", m.rawValue as NSString, c * 100, ang))
}
// 4. dress forms: a 1 m length of fabric (tiling), and a swatch
for f in FormPreset.allCases {
    var d = ClothSettings(); d.support = .dressForm; d.form = f; d.material = .linen; d.tiling = .repeating
    _ = run("form \(f.rawValue) length", d, sample: SIMD2(0.3, 0.22), seconds: 4)
}
var sw = ClothSettings(); sw.support = .dressForm; sw.material = .silk
_ = run("form swatch silk", sw, sample: SIMD2(0.3, 0.22))
var bias = ClothSettings(); bias.support = .dressForm; bias.material = .silk; bias.tiling = .repeating; bias.grainAngle = 45
_ = run("form bias silk 45°", bias, sample: SIMD2(0.3, 0.22), seconds: 4)
// 5. texture mapping round trip
let tm = TextureMapping(grainAngle: 0, tiling: .off, sampleSize: SIMD2(0.3, 0.2), repeatRect: SIMD4(0, 0, 1, 1))
print("mapping corners:", tm.map(SIMD2(-0.15, 0.1)).uv, tm.map(SIMD2(0.15, -0.1)).uv)
