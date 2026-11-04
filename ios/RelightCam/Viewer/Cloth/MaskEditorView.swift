import SwiftUI
import Vision

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
    @State private var mask: [UInt8] = []
    @State private var mw = 0
    @State private var mh = 0
    @State private var overlay: UIImage?
    @State private var tool: Tool = .add
    @State private var brush: Double = 0.04
    @State private var busy: String?
    @State private var message: String?
    @State private var rectStart: CGPoint?

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
                            Image(uiImage: overlay).resizable().frame(width: w, height: h).offset(x: origin.x, y: origin.y)
                                .allowsHitTesting(false)
                        }
                        if repeatRect.count == 4, !(repeatRect == [0, 0, 1, 1]) {
                            Rectangle().stroke(Color.yellow, lineWidth: 2)
                                .frame(width: w * repeatRect[2], height: h * repeatRect[3])
                                .offset(x: origin.x + w * repeatRect[0], y: origin.y + h * repeatRect[1])
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let uv = CGPoint(x: (v.location.x - origin.x) / w, y: (v.location.y - origin.y) / h)
                        switch tool {
                        case .add, .erase: paint(at: uv, value: tool == .add ? 255 : 0)
                        case .repeatRegion:
                            if rectStart == nil { rectStart = uv }
                            let a = rectStart!
                            let x0 = max(0, min(a.x, uv.x)), y0 = max(0, min(a.y, uv.y))
                            let x1 = min(1, max(a.x, uv.x)), y1 = min(1, max(a.y, uv.y))
                            if x1 - x0 > 0.02 && y1 - y0 > 0.02 { repeatRect = [x0, y0, x1 - x0, y1 - y0] }
                        }
                    }.onEnded { _ in rectStart = nil })
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
                            Button("Whole image") { repeatRect = [0, 0, 1, 1] }.font(.caption)
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
                        Button("Keep all") { fill(255) }
                        Spacer()
                        Button("Remove sphere") { removeSphere(); refresh() }
                    }
                    .buttonStyle(.bordered)
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
            .task { await load() }
        }
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
        mask = result.1
        mw = result.2
        mh = result.3
        refresh()
    }

    private func paint(at uv: CGPoint, value: UInt8) {
        guard mw > 0 else { return }
        let cx = Double(uv.x) * Double(mw), cy = Double(uv.y) * Double(mh)
        let r = brush * Double(max(mw, mh))
        for y in max(0, Int(cy - r))..<min(mh, Int(cy + r) + 1) {
            for x in max(0, Int(cx - r))..<min(mw, Int(cx + r) + 1) {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy <= r * r { mask[y * mw + x] = value }
            }
        }
        refresh()
    }

    private func fill(_ v: UInt8) {
        mask = [UInt8](repeating: v, count: mw * mh)
        refresh()
    }

    /// Clears the calibration sphere (plus a margin) from the mask.
    private func removeSphere() {
        guard let s = project.meta.sphere, project.meta.frameWidth > 0, mw > 0 else { return }
        let k = Double(mw) / Double(project.meta.frameWidth)
        let cx = s.cx * k, cy = s.cy * k, r = s.r * k * 1.25
        for y in 0..<mh {
            for x in 0..<mw {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy <= r * r { mask[y * mw + x] = 0 }
            }
        }
    }

    private func autoMask() async {
        guard let cg = base?.cgImage else { return }
        busy = "Finding the textile…"
        let w = mw, h = mh
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
            mask = m
            removeSphere()
            refresh()
            message = "Check the edges and touch up with Add / Erase."
        case .failure(let e):
            message = e.localizedDescription
        }
    }

    private func refresh() {
        guard mw > 0 else { return }
        var px = [UInt8](repeating: 0, count: mw * mh * 4)
        for i in 0..<(mw * mh) where mask[i] < 128 {
            px[i * 4] = 200; px[i * 4 + 1] = 30; px[i * 4 + 2] = 40; px[i * 4 + 3] = 150
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: mw, height: mh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: mw * 4,
                                space: ImageUtils.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        overlay = UIImage(cgImage: img)
    }

    private func save() {
        guard mw > 0 else { return }
        var px = [UInt8](repeating: 255, count: mw * mh * 4)
        for i in 0..<(mw * mh) { px[i * 4] = mask[i]; px[i * 4 + 1] = mask[i]; px[i * 4 + 2] = mask[i] }
        if let img = ImageUtils.makeImage(rgba: px, width: mw, height: mh) {
            try? ImageUtils.write(img, to: project.rtiDir.appendingPathComponent("mask.png"), type: .png)
        }
        onSave()
    }
}
