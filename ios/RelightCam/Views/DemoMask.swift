import Foundation

/// The demo textile fills the frame, so its cutout only has to remove the calibration sphere.
enum DemoMask {
    static func write(for p: Project) {
        guard let s = p.meta.sphere, p.meta.frameWidth > 0, p.hasRTI else { return }
        let url = p.rtiDir.appendingPathComponent("mask.png")
        if FileManager.default.fileExists(atPath: url.path) { return }
        let mw = 512, mh = max(8, 512 * p.meta.frameHeight / p.meta.frameWidth)
        let k = Double(mw) / Double(p.meta.frameWidth)
        let cx = s.cx * k, cy = s.cy * k, r = s.r * k * 1.25
        var px = [UInt8](repeating: 255, count: mw * mh * 4)
        for y in 0..<mh {
            for x in 0..<mw {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy <= r * r { let o = (y * mw + x) * 4; px[o] = 0; px[o + 1] = 0; px[o + 2] = 0 }
            }
        }
        if let img = ImageUtils.makeImage(rgba: px, width: mw, height: mh) {
            try? ImageUtils.write(img, to: url, type: .png)
        }
    }
}
