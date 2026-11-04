import Foundation
import CoreGraphics

/// A reflective sphere in full-resolution frame pixel coordinates (top-left origin, pixel centers at +0.5).
struct SphereCircle: Codable, Equatable {
    var cx: Double
    var cy: Double
    var r: Double
}

/// Detected specular highlight for one frame.
struct Highlight: Codable, Equatable {
    var x: Double          // highlight position, frame pixels
    var y: Double
    var valid: Bool        // false when the sphere is in shadow / nothing found
    var dir: [Double]      // unit light direction (x right, y up, z towards camera)
}

/// Port of relight's Sphere::findHighlight + Sphere::computeDirections (orthographic case).
enum LightDetector {
    /// relight only searches the inner part of the sphere ("slightly over 45°, hoping not to spot reflexes").
    static let maxAngle = 50.0 * Double.pi / 180.0

    static func searchRect(for s: SphereCircle, imageWidth: Int, imageHeight: Int) -> CGRect {
        let small = s.r * sin(maxAngle)
        let x0 = max(0, Int(floor(s.cx - small)))
        let y0 = max(0, Int(floor(s.cy - small)))
        let x1 = min(imageWidth, Int(ceil(s.cx + small + 1)))
        let y1 = min(imageHeight, Int(ceil(s.cy + small + 1)))
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    static func detect(image: CGImage, sphere: SphereCircle) -> Highlight {
        let rect = searchRect(for: sphere, imageWidth: image.width, imageHeight: image.height)
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 2, h > 2 else { return Highlight(x: 0, y: 0, valid: false, dir: [0, 0, 0]) }
        let px = ImageUtils.rgba(image, width: w, height: h, crop: rect)
        let x0 = Double(rect.minX), y0 = Double(rect.minY)
        let small = sphere.r * sin(maxAngle)

        // Gray values (Qt's qGray) of pixels inside the small circle.
        struct Sample { var x: Double; var y: Double; var g: Int }
        var samples: [Sample] = []
        samples.reserveCapacity(w * h)
        var gray = [Int](repeating: -1, count: w * h)
        var maxLuma = 0
        for j in 0..<h {
            let y = y0 + Double(j) + 0.5
            for i in 0..<w {
                let x = x0 + Double(i) + 0.5
                let dx = x - sphere.cx, dy = y - sphere.cy
                if dx * dx + dy * dy > small * small { continue }
                let o = (j * w + i) * 4
                let g = (Int(px[o]) * 11 + Int(px[o + 1]) * 16 + Int(px[o + 2]) * 5) / 32
                gray[j * w + i] = g
                maxLuma = max(maxLuma, g)
                samples.append(Sample(x: x, y: y, g: g))
            }
        }

        // Lower the threshold until the bright area is ~0.5% of the search square.
        var threshold = 240
        let highlightArea = (w * h) / 200
        var count = 0
        var bx = 0.0, by = 0.0
        var found = false
        while count < highlightArea && threshold > 100 {
            var sx = 0.0, sy = 0.0
            count = 0
            for s in samples where s.g >= threshold {
                sx += s.x; sy += s.y; count += 1
            }
            if count > 0 { bx = sx / Double(count); by = sy / Double(count); found = true }
            threshold -= 10
        }
        threshold += 10

        if !found || maxLuma < 127 {
            // Highlight in the mid greys: the sphere is probably in shadow.
            return Highlight(x: 0, y: 0, valid: false, dir: [0, 0, 0])
        }

        // Find the biggest spot by shrinking a window around the weighted barycenter.
        var radius = ceil(0.5 * Double(w))
        while radius > ceil(0.02 * Double(w)) {
            var nx = 0.0, ny = 0.0, weight = 0.0
            let ja = max(0, Int(floor(by - y0 - radius))), jb = min(h, Int(ceil(by - y0 + radius)))
            let ia = max(0, Int(floor(bx - x0 - radius))), ib = min(w, Int(ceil(bx - x0 + radius)))
            if ja < jb && ia < ib {
                for j in ja..<jb {
                    for i in ia..<ib {
                        let g = gray[j * w + i]
                        if g < threshold { continue }   // also skips pixels outside the circle (-1)
                        nx += (x0 + Double(i) + 0.5) * Double(g)
                        ny += (y0 + Double(j) + 0.5) * Double(g)
                        weight += Double(g)
                    }
                }
            }
            if weight == 0 { break }
            bx = nx / weight; by = ny / weight
            radius *= 0.5
        }
        return Highlight(x: bx, y: by, valid: true, dir: direction(hx: bx, hy: by, sphere: sphere))
    }

    /// Reflection on a mirror sphere seen orthographically: the light is at twice the surface angle.
    static func direction(hx: Double, hy: Double, sphere: SphereCircle) -> [Double] {
        var x = (hx - sphere.cx) / sphere.r
        var y = -(hy - sphere.cy) / sphere.r
        x = min(max(x, -1), 1)
        y = min(max(y, -1), 1)
        let d = (x * x + y * y).squareRoot()
        if d < 1e-9 { return [0, 0, 1] }
        let a = asin(min(d, 1)) * 2
        let r = sin(a)
        x *= r / d
        y *= r / d
        let z = max(0, 1 - x * x - y * y).squareRoot()
        return [x, y, z]
    }

    /// Detects the highlight in every frame. Decodes only as large as needed: a sphere radius of
    /// ~250 px is plenty for sub-pixel highlights, so big spheres are found on downscaled images.
    static func detectAll(frames: [URL], sphere: SphereCircle, frameWidth: Int, frameHeight: Int,
                          progress: ((Double) -> Void)? = nil) -> [Highlight] {
        let scale = min(1.0, max(0.25, 250 / sphere.r))
        let maxSide = Int(Double(max(frameWidth, frameHeight)) * scale)
        var out: [Highlight] = []
        for (i, u) in frames.enumerated() {
            autoreleasepool {
                guard let img = (scale < 1 ? ImageUtils.load(u, maxPixel: maxSide) : ImageUtils.load(u)) else {
                    out.append(Highlight(x: 0, y: 0, valid: false, dir: [0, 0, 0]))
                    return
                }
                let k = Double(img.width) / Double(frameWidth)
                let sc = SphereCircle(cx: sphere.cx * k, cy: sphere.cy * k, r: sphere.r * k)
                var h = detect(image: img, sphere: sc)
                h.x /= k
                h.y /= k
                out.append(h)
            }
            progress?(Double(i + 1) / Double(frames.count))
        }
        return out
    }

    /// Per-pixel maximum of all frames (what relight shows to place the sphere), downscaled to `maxSide`.
    static func maxComposite(frames: [URL], maxSide: Int, progress: ((Double) -> Void)? = nil) -> CGImage? {
        guard let first = frames.first, let size = ImageUtils.orientedSize(of: first) else { return nil }
        let (w, h) = ImageUtils.fit(width: size.width, height: size.height, maxSide: maxSide)
        var acc = [UInt8](repeating: 0, count: w * h * 4)
        for (n, url) in frames.enumerated() {
            autoreleasepool {
                guard let img = ImageUtils.load(url, maxPixel: max(w, h)) else { return }
                let px = ImageUtils.rgba(img, width: w, height: h)
                acc.withUnsafeMutableBufferPointer { a in
                    px.withUnsafeBufferPointer { p in
                        let count = a.count / 16
                        a.baseAddress!.withMemoryRebound(to: SIMD16<UInt8>.self, capacity: count) { av in
                            p.baseAddress!.withMemoryRebound(to: SIMD16<UInt8>.self, capacity: count) { pv in
                                for i in 0..<count { av[i] = pointwiseMax(av[i], pv[i]) }
                            }
                        }
                        for i in (count * 16)..<a.count { a[i] = max(a[i], p[i]) }
                    }
                }
            }
            progress?(Double(n + 1) / Double(frames.count))
        }
        for i in stride(from: 3, to: acc.count, by: 4) { acc[i] = 255 }
        return ImageUtils.makeImage(rgba: acc, width: w, height: h)
    }
}
