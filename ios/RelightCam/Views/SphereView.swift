import SwiftUI

/// Place a circle on the reflective sphere (over the max-composite of all photos, like RelightLab),
/// then detect the highlight in every photo.
struct SphereView: View {
    @Bindable var project: Project
    @State private var composite: UIImage?
    @State private var compositeProgress = 0.0
    @State private var circle = SphereCircle(cx: 0, cy: 0, r: 0)
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var gestureStart: (zoom: CGFloat, pan: CGSize)?
    @State private var circleStart: SphereCircle?
    @State private var detecting = false
    @State private var detectProgress = 0.0
    @State private var canvasSize: CGSize = .zero

    private var F: CGSize { CGSize(width: max(1, project.meta.frameWidth), height: max(1, project.meta.frameHeight)) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let G = geo.size
                let s0 = min(G.width / F.width, G.height / F.height)
                let s = s0 * zoom
                let o = CGPoint(x: (G.width - F.width * s) / 2 + pan.width, y: (G.height - F.height * s) / 2 + pan.height)
                let c = CGPoint(x: o.x + circle.cx * s, y: o.y + circle.cy * s)
                ZStack {
                    Color.black
                    if let composite {
                        Image(uiImage: composite).resizable().interpolation(.medium)
                            .frame(width: F.width * s, height: F.height * s)
                            .position(x: o.x + F.width * s / 2, y: o.y + F.height * s / 2)
                    } else {
                        ProgressView(value: compositeProgress) { Text("Combining photos…") }
                            .tint(.white).foregroundStyle(.white).padding(40)
                    }
                    if let hs = project.meta.highlights, hs.count == project.meta.frames.count, project.meta.sphere == circle {
                        let ex = Set(project.meta.excluded)
                        ForEach(hs.indices, id: \.self) { i in
                            if hs[i].valid {
                                Circle().stroke(ex.contains(i) ? Color.gray : Color.green, lineWidth: 1.5)
                                    .frame(width: 9, height: 9)
                                    .position(x: o.x + hs[i].x * s, y: o.y + hs[i].y * s)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    if composite != nil {
                        // search area used by the detector
                        Circle().stroke(Color.yellow.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .frame(width: 2 * circle.r * sin(LightDetector.maxAngle) * s, height: 2 * circle.r * sin(LightDetector.maxAngle) * s)
                            .position(c).allowsHitTesting(false)
                        Circle().stroke(Color.yellow, lineWidth: 2)
                            .background(Circle().fill(Color.yellow.opacity(0.06)))
                            .frame(width: 2 * circle.r * s, height: 2 * circle.r * s)
                            .contentShape(Circle())
                            .position(c)
                            .gesture(DragGesture().onChanged { v in
                                if circleStart == nil { circleStart = circle }
                                circle.cx = circleStart!.cx + v.translation.width / s
                                circle.cy = circleStart!.cy + v.translation.height / s
                            }.onEnded { _ in circleStart = nil })
                        Circle().fill(Color.yellow).frame(width: 26, height: 26)
                            .overlay(Image(systemName: "arrow.left.and.right").font(.caption2.bold()).foregroundStyle(.black))
                            .position(x: c.x + circle.r * s, y: c.y)
                            .gesture(DragGesture(coordinateSpace: .named("canvas")).onChanged { v in
                                let d = hypot(v.location.x - c.x, v.location.y - c.y)
                                circle.r = max(4, d / s)
                            })
                    }
                }
                .coordinateSpace(name: "canvas")
                .contentShape(Rectangle())
                .gesture(panZoomGesture)
                .onAppear { canvasSize = G }
                .onChange(of: G) { _, n in canvasSize = n }
            }
            .clipped()
            panel
        }
        .navigationTitle("Sphere & lights")
        .navigationBarTitleDisplayMode(.inline)
        .task { await prepare() }
        .onDisappear { project.save() }
    }

    private var panGesture: some Gesture {
        DragGesture().onChanged { v in
            if gestureStart == nil { gestureStart = (zoom, pan) }
            pan = CGSize(width: gestureStart!.pan.width + v.translation.width, height: gestureStart!.pan.height + v.translation.height)
        }.onEnded { _ in gestureStart = nil }
    }

    private var panZoomGesture: some Gesture {
        SimultaneousGesture(panGesture, MagnifyGesture().onChanged { v in
            if gestureStart == nil { gestureStart = (zoom, pan) }
            let z = min(max(gestureStart!.zoom * v.magnification, 1), 40)
            let f = z / gestureStart!.zoom
            zoom = z
            pan = CGSize(width: gestureStart!.pan.width * f, height: gestureStart!.pan.height * f)
        }.onEnded { _ in gestureStart = nil })
    }

    private var panel: some View {
        VStack(spacing: 10) {
            if detecting {
                ProgressView(value: detectProgress) { Text("Finding highlights…").font(.footnote) }
            } else if let hs = project.meta.highlights, hs.count == project.meta.frames.count, project.meta.sphere == circle {
                HStack(spacing: 12) {
                    LightPlot(project: project).frame(width: 90, height: 90)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(project.usableIndices.count) of \(hs.count) photos have a usable highlight").font(.subheadline.bold())
                        Text("Green rings mark highlights. If any sit off the sphere's reflection, refine the circle and detect again, or exclude photos in the Photos list.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Drag the yellow circle onto the shiny sphere and drag the handle to match its edge. Pinch to zoom in for precision.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Sphere diameter").font(.footnote)
                TextField("mm", value: $project.meta.sphereDiameterMM, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 80)
                    .onSubmit { project.save() }
                Text("mm").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text("gives real size for the 3D viewer").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button { zoomToSphere() } label: { Label("Zoom to sphere", systemImage: "scope") }
                    .buttonStyle(.bordered)
                Spacer()
                Button { Task { await detect() } } label: { Label("Detect lights", systemImage: "light.max") }
                    .buttonStyle(.borderedProminent)
                    .disabled(composite == nil || detecting || circle.r < 4)
            }
        }
        .padding()
        .background(.bar)
    }

    private func zoomToSphere() {
        let G = canvasSize
        guard G.width > 0 else { return }
        let s0 = min(G.width / F.width, G.height / F.height)
        let s = 0.7 * min(G.width, G.height) / (2 * circle.r)
        withAnimation {
            zoom = max(1, s / s0)
            let sz = s0 * zoom
            pan = CGSize(width: (F.width / 2 - circle.cx) * sz, height: (F.height / 2 - circle.cy) * sz)
        }
    }

    private func prepare() async {
        circle = project.meta.sphere ?? SphereCircle(cx: F.width * 0.15, cy: F.height * 0.18, r: min(F.width, F.height) * 0.08)
        let urls = project.frameURLs
        let compURL = project.compositeURL
        if project.meta.compositeCount == urls.count, let img = UIImage(contentsOfFile: compURL.path) {
            composite = img
            return
        }
        let img: CGImage? = await Task.detached(priority: .userInitiated) {
            let cg = LightDetector.maxComposite(frames: urls, maxSide: 3072) { p in
                Task { @MainActor in compositeProgress = p }
            }
            if let cg { try? ImageUtils.write(cg, to: compURL, quality: 0.9) }
            return cg
        }.value
        if let img {
            composite = UIImage(cgImage: img)
            project.meta.compositeCount = urls.count
            project.save()
        }
    }

    private func detect() async {
        detecting = true
        detectProgress = 0
        let sphere = circle
        let urls = project.frameURLs
        let fw = project.meta.frameWidth, fh = project.meta.frameHeight
        let results = await Task.detached(priority: .userInitiated) {
            LightDetector.detectAll(frames: urls, sphere: sphere, frameWidth: fw, frameHeight: fh) { p in
                Task { @MainActor in detectProgress = p }
            }
        }.value
        project.meta.sphere = sphere
        project.meta.highlights = results
        project.meta.excluded = []
        project.save()
        detecting = false
    }
}

/// Top view of all detected light directions (rings at 30° and 60° elevation).
struct LightPlot: View {
    let project: Project
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 3
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for f in [1.0, cos(Double.pi / 6), cos(Double.pi / 3)] {
                let rr = r * f
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                           with: .color(.secondary.opacity(f == 1 ? 0.8 : 0.35)), lineWidth: 1)
            }
            guard let hs = project.meta.highlights else { return }
            let ex = Set(project.meta.excluded)
            for (i, h) in hs.enumerated() where h.valid {
                let p = CGPoint(x: c.x + h.dir[0] * r, y: c.y - h.dir[1] * r)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                         with: .color(ex.contains(i) ? .gray : .orange))
            }
        }
    }
}
