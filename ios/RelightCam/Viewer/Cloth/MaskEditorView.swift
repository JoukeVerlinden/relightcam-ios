import SwiftUI
import Vision

/// The mask pixels (white = textile) and the red overlay that shows the cut-away parts, edited in place.
/// A class on purpose: with the mask in a @State array, every pixel write was a SwiftUI state change that
/// copied the whole mask and compared it with the old one. A brush dab touches ~1,000 pixels, so painting
/// stalled the main thread for seconds and iOS killed the app.
final class MaskCanvas {
    private(set) var w = 0
    private(set) var h = 0
    private(set) var px: [UInt8] = []
    private var rgba: [UInt8] = []
    /// Previous touch of the current stroke (mask pixels), so fast strokes are joined up.
    var lastPoint: CGPoint?
    var lastRefresh: CFTimeInterval = 0

    var isEmpty: Bool { w == 0 }

    func reset(_ m: [UInt8], w: Int, h: Int) {
        self.w = w
        self.h = h
        px = m
        rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { tint(i, m[i]) }
    }

    func fill(_ v: UInt8) { reset([UInt8](repeating: v, count: w * h), w: w, h: h) }

    /// A round brush of radius r swept from a to b (mask pixels).
    func stroke(from a: CGPoint, to b: CGPoint, radius r: Double, value v: UInt8) {
        guard w > 0 else { return }
        let ax = Double(a.x), ay = Double(a.y), bx = Double(b.x), by = Double(b.y)
        let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
        let x0 = max(0, Int(min(ax, bx) - r)), x1 = min(w - 1, Int(max(ax, bx) + r) + 1)
        let y0 = max(0, Int(min(ay, by) - r)), y1 = min(h - 1, Int(max(ay, by) + r) + 1)
        guard x0 <= x1, y0 <= y1 else { return }
        let r2 = r * r
        for y in y0...y1 {
            let py = Double(y) + 0.5
            for x in x0...x1 {
                let pxx = Double(x) + 0.5
                // distance from the pixel to the segment
                let t = len2 > 0 ? min(1, max(0, ((pxx - ax) * dx + (py - ay) * dy) / len2)) : 0
                let ex = pxx - (ax + t * dx), ey = py - (ay + t * dy)
                if ex * ex + ey * ey <= r2 { set(y * w + x, v) }
            }
        }
    }

    /// Clears a disc (mask pixels).
    func clear(cx: Double, cy: Double, r: Double) {
        stroke(from: CGPoint(x: cx, y: cy), to: CGPoint(x: cx, y: cy), radius: r, value: 0)
    }

    func overlay() -> UIImage? {
        guard w > 0, let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: ImageUtils.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: img)
    }

    func maskImage() -> CGImage? {
        guard w > 0 else { return nil }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { out[i * 4] = px[i]; out[i * 4 + 1] = px[i]; out[i * 4 + 2] = px[i] }
        return ImageUtils.makeImage(rgba: out, width: w, height: h)
    }

    @inline(__always) private func set(_ i: Int, _ v: UInt8) {
        if px[i] != v { px[i] = v; tint(i, v) }
    }

    /// Cut-away pixels get a translucent red (premultiplied (200, 30, 40) at alpha 150).
    @inline(__always) private func tint(_ i: Int, _ v: UInt8) {
        let o = i * 4
        if v < 128 { rgba[o] = 118; rgba[o + 1] = 18; rgba[o + 2] = 24; rgba[o + 3] = 150 }
        else { rgba[o] = 0; rgba[o + 1] = 0; rgba[o + 2] = 0; rgba[o + 3] = 0 }
    }
}

/// Cut the textile out of its background (and the calibration sphere), and mark one pattern repeat for tiling.
/// Saves rti/mask.png (white = textile); relight's own viewers ignore the file.
struct MaskEditorView: View {
    let project: Project
    @Binding var repeatRect: [Double]
    var onSave: () -> Void

    enum Tool: String, CaseIterable, Identifiable {
        case add, erase, repeatRegion
        var id: String { rawValue }
        var title: String { ["Add", "Erase", "Repeat region"][Tool.allCases.firstIndex(of: self)!] }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var base: UIImage?
    @State private var canvas = MaskCanvas()
    @State private var overlay: UIImage?
    /// Edited here and written back on Save, so dragging the rectangle doesn't update the cloth viewer behind
    /// the sheet on every touch, and Cancel discards it.
    @State private var region: [Double]
    @State private var tool: Tool = .add
    @State private var brush: Double = 0.04
    @State private var busy: String?
    @State private var message: String?
    @State private var rectStart: CGPoint?

    init(project: Project, repeatRect: Binding<[Double]>, onSave: @escaping () -> Void) {
        self.project = project
        _repeatRect = repeatRect
        self.onSave = onSave
        _region = State(initialValue: repeatRect.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let aspect = CGFloat(max(1, project.meta.frameHeight)) / CGFloat(max(1, project.meta.frameWidth))
                    let w = min(geo.size.width, geo.size.height / aspect), h = w * aspect
                    let origin = CGPoint(x: (geo.size.width - w) / 2, y: (geo.size.height - h) / 2)
                    ZStack(alignment: .topLeading) {
                        Color.black
                        if let base {
                            Image(uiImage: base).resizable().frame(width: w, height: h).offset(x: origin.x, y: origin.y)
                        }
                        if let overlay {
                            Image(uiImage: overlay).resizable().interpolation(.none)
                                .frame(width: w, height: h).offset(x: origin.x, y: origin.y)
                                .allowsHitTesting(false)
                        }
                        if region.count == 4, !(region == [0, 0, 1, 1]) {
                            Rectangle().stroke(Color.yellow, lineWidth: 2)
                                .frame(width: w * region[2], height: h * region[3])
                                .offset(x: origin.x + w * region[0], y: origin.y + h * region[1])
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        drag(to: CGPoint(x: (v.location.x - origin.x) / w, y: (v.location.y - origin.y) / h))
                    }.onEnded { _ in endDrag() })
                }
                VStack(spacing: 10) {
                    if let busy { ProgressView(busy) }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Picker("Tool", selection: $tool) {
                        ForEach(Tool.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if tool == .repeatRegion {
                        HStack {
                            Text("Drag a rectangle around one pattern repeat (used when Tiling is on).").font(.caption)
                            Spacer()
                            Button("Whole image") { region = [0, 0, 1, 1] }.font(.caption)
                        }
                    } else {
                        HStack {
                            Image(systemName: "circle.fill").font(.caption2)
                            Slider(value: $brush, in: 0.01...0.15)
                            Image(systemName: "circle.fill").font(.title3)
                        }
                    }
                    HStack {
                        Button { Task { await autoMask() } } label: { Label("Auto", systemImage: "wand.and.stars") }
                        Spacer()
                        Button("Keep all") { canvas.fill(255); refresh() }
                        Spacer()
                        Button("Remove sphere") { removeSphere(); refresh() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy != nil)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Cutout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(); dismiss() } }
            }
            .task {
                await load()
                if ProcessInfo.processInfo.arguments.contains("-mask-test-stroke") { await testStroke() }
            }
        }
        // painting downwards shouldn't pull the sheet away
        .interactiveDismissDisabled()
    }

    private func drag(to uv: CGPoint) {
        switch tool {
        case .add, .erase:
            guard !canvas.isEmpty else { return }
            let p = CGPoint(x: uv.x * CGFloat(canvas.w), y: uv.y * CGFloat(canvas.h))
            canvas.stroke(from: canvas.lastPoint ?? p, to: p, radius: brush * Double(max(canvas.w, canvas.h)),
                          value: tool == .add ? 255 : 0)
            canvas.lastPoint = p
            // a new overlay image per touch event is more than the screen needs; 30 Hz is plenty
            if CACurrentMediaTime() - canvas.lastRefresh > 1.0 / 30 { refresh() }
        case .repeatRegion:
            if rectStart == nil { rectStart = uv }
            let a = rectStart!
            let x0 = max(0, min(a.x, uv.x)), y0 = max(0, min(a.y, uv.y))
            let x1 = min(1, max(a.x, uv.x)), y1 = min(1, max(a.y, uv.y))
            if x1 - x0 > 0.02 && y1 - y0 > 0.02 { region = [x0, y0, x1 - x0, y1 - y0] }
        }
    }

    private func endDrag() {
        canvas.lastPoint = nil
        rectStart = nil
        refresh()
    }

    private func load() async {
        busy = "Rendering…"
        let dir = project.rtiDir
        let result: (UIImage?, [UInt8], Int, Int)? = await Task.detached {
            guard let planes = try? RTIRenderer.loadPlanes(dir) else { return nil }
            let W = planes.info.width, H = planes.info.height
            let px = RTIRenderer.render(planes, lx: 0, ly: 0)
            let img = ImageUtils.makeImage(rgba: px, width: W, height: H).map { UIImage(cgImage: $0) }
            let s = min(1.0, 512.0 / Double(max(W, H)))
            let mw = max(8, Int(Double(W) * s)), mh = max(8, Int(Double(H) * s))
            var m = [UInt8](repeating: 255, count: mw * mh)
            if let mi = ImageUtils.load(dir.appendingPathComponent("mask.png")) {
                let r = ImageUtils.rgba(mi, width: mw, height: mh)
                for i in 0..<(mw * mh) { m[i] = r[i * 4] }
            }
            return (img, m, mw, mh)
        }.value
        busy = nil
        guard let result else { message = "Build the RTI first."; return }
        base = result.0
        canvas.reset(result.1, w: result.2, h: result.3)
        refresh()
    }

    /// Test hook (-mask-test-stroke): a 60-point stroke at touch rate through the real drag handler, then
    /// Remove sphere, timed.
    private func testStroke() async {
        tool = .erase
        var worst = 0.0
        let t0 = CACurrentMediaTime()
        for k in 0..<60 {
            let t = Double(k) / 59
            let e0 = CACurrentMediaTime()
            drag(to: CGPoint(x: 0.2 + 0.6 * t, y: 0.5 + 0.2 * sin(t * 6)))
            worst = max(worst, CACurrentMediaTime() - e0)
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        endDrag()
        let t1 = CACurrentMediaTime()
        removeSphere(); refresh()
        let t2 = CACurrentMediaTime()
        print(String(format: "mask test: 60-point stroke %.0f ms incl. 480 ms of sleeps, worst event %.1f ms, remove sphere %.1f ms",
                     (t1 - t0) * 1000, worst * 1000, (t2 - t1) * 1000))
    }

    /// Clears the calibration sphere (plus a margin) from the mask.
    private func removeSphere() {
        guard let s = project.meta.sphere, project.meta.frameWidth > 0, !canvas.isEmpty else { return }
        let k = Double(canvas.w) / Double(project.meta.frameWidth)
        canvas.clear(cx: s.cx * k, cy: s.cy * k, r: s.r * k * 1.25)
    }

    private func autoMask() async {
        guard let cg = base?.cgImage else { return }
        busy = "Finding the textile…"
        let w = canvas.w, h = canvas.h
        let result: Result<[UInt8], Error> = await Task.detached {
            do {
                let req = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: cg)
                try handler.perform([req])
                guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
                    throw RelightError.invalid("No foreground object found. Paint the cutout by hand.")
                }
                let pb = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
                guard let basePtr = CVPixelBufferGetBaseAddress(pb) else { throw RelightError.invalid("Empty mask") }
                let isFloat = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent32Float
                var m = [UInt8](repeating: 0, count: w * h)
                for y in 0..<h {
                    for x in 0..<w {
                        let sx = min(pw - 1, x * pw / w), sy = min(ph - 1, y * ph / h)
                        let v: Float
                        if isFloat {
                            v = basePtr.advanced(by: sy * row).assumingMemoryBound(to: Float.self)[sx]
                        } else {
                            v = Float(basePtr.advanced(by: sy * row).assumingMemoryBound(to: UInt8.self)[sx]) / 255
                        }
                        m[y * w + x] = v > 0.5 ? 255 : 0
                    }
                }
                return .success(m)
            } catch {
                return .failure(error)
            }
        }.value
        busy = nil
        switch result {
        case .success(let m):
            canvas.reset(m, w: w, h: h)
            removeSphere()
            refresh()
            message = "Check the edges and touch up with Add / Erase."
        case .failure(let e):
            message = e.localizedDescription
        }
    }

    private func refresh() {
        canvas.lastRefresh = CACurrentMediaTime()
        overlay = canvas.overlay()
    }

    private func save() {
        repeatRect = region
        if let img = canvas.maskImage() {
            try? ImageUtils.write(img, to: project.rtiDir.appendingPathComponent("mask.png"), type: .png)
        }
        onSave()
    }
}
