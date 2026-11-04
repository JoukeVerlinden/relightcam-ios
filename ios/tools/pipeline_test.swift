// macOS harness: swiftc -O RelightCam/Core/*.swift tools/pipeline_test.swift -o /tmp/x && /tmp/x <outdir>
import Foundation
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/relightcam-test")
let frames = out.appendingPathComponent("frames")
try? FileManager.default.removeItem(at: out)
var t = Date()
let ds = try SyntheticDataset.generate(into: frames)
print(String(format: "generated %d frames %dx%d in %.2fs", ds.files.count, ds.width, ds.height, Date().timeIntervalSince(t)))
let urls = ds.files.map { frames.appendingPathComponent($0) }

// 1. Light detection vs ground truth
t = Date()
var errs: [Double] = []
var detected: [[Double]] = []
for (i, u) in urls.enumerated() {
    let img = ImageUtils.load(u)!
    let h = LightDetector.detect(image: img, sphere: ds.sphere)
    let g = ds.lights[i]
    let dot = h.dir[0]*g[0] + h.dir[1]*g[1] + h.dir[2]*g[2]
    let e = acos(min(1, max(-1, dot))) * 180 / .pi
    errs.append(h.valid ? e : 999)
    detected.append(h.dir)
}
errs.sort()
print(String(format: "detection %.2fs: median %.2f°, max %.2f°, invalid %d", Date().timeIntervalSince(t), errs[errs.count/2], errs.last!, errs.filter { $0 == 999 }.count))

// 2. Composite
t = Date()
let comp = LightDetector.maxComposite(frames: urls, maxSide: 3072)!
try ImageUtils.write(comp, to: out.appendingPathComponent("composite.jpg"))
print(String(format: "composite %dx%d %.2fs", comp.width, comp.height, Date().timeIntervalSince(t)))

// 3. Fit + reproduce training images
for basis in RTIBasis.allCases {
    let dir = out.appendingPathComponent("rti_\(basis.rawValue)")
    t = Date()
    let r = try RTIBuilder.build(frames: urls, lights: detected, basis: basis, maxSide: 1024, output: dir) { _, _ in }
    let fitTime = Date().timeIntervalSince(t)
    let planes = try RTIRenderer.loadPlanes(dir)
    var se = 0.0, cnt = 0.0
    for (i, u) in urls.enumerated() where i % 3 == 0 {
        let ref = ImageUtils.rgba(ImageUtils.load(u, maxPixel: max(r.width, r.height))!, width: r.width, height: r.height)
        let img = RTIRenderer.render(planes, lx: detected[i][0], ly: detected[i][1])
        for p in 0..<(r.width*r.height) {
            let x = Double(p % r.width) / Double(r.width), y = Double(p / r.width) / Double(r.height)
            if x < 0.25 && y < 0.3 { continue } // skip the sphere corner
            for c in 0..<3 { let d = Double(img[p*4+c]) - Double(ref[p*4+c]); se += d*d; cnt += 1 }
        }
        if i == 0 {
            try ImageUtils.write(ImageUtils.makeImage(rgba: img, width: r.width, height: r.height)!, to: dir.appendingPathComponent("relit_0.jpg"))
        }
    }
    print(String(format: "%@ fit %dx%d in %.2fs; reproduction RMSE %.2f / 255", basis.rawValue, r.width, r.height, fitTime, (se/cnt).squareRoot()))
}
let raking = try RTIRenderer.loadPlanes(out.appendingPathComponent("rti_hsh"))
let rk = RTIRenderer.render(raking, lx: 0.94, ly: 0.2)
try ImageUtils.write(ImageUtils.makeImage(rgba: rk, width: raking.info.width, height: raking.info.height)!, to: out.appendingPathComponent("hsh_raking.jpg"))
print("ok")
