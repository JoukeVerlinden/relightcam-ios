import SwiftUI

struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ProjectView: View {
    @Bindable var project: Project
    @State private var basis: RTIBasis = .hsh
    @State private var maxSide = 1536
    @State private var building = false
    @State private var buildProgress = 0.0
    @State private var buildStatus = ""
    @State private var errorText: String?
    @State private var share: ShareItem?
    @State private var exporting = false
    @State private var showCapture = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var showViewer = false
    @State private var showSphere = false
    @State private var showCloth = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    FrameThumb(url: project.frameURLs.first).frame(width: 84, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(project.meta.frames.count) photos").font(.headline)
                        if project.meta.frameWidth > 0 {
                            Text(verbatim: "\(project.meta.frameWidth)×\(project.meta.frameHeight)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(project.meta.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                NavigationLink { FramesView(project: project) } label: { Label("Photos", systemImage: "photo.stack") }
                    .disabled(project.meta.frames.isEmpty)
                Button { showCapture = true } label: { Label("Add photos with the camera", systemImage: "camera") }
            }

            Section {
                if project.lightsAreCurrent {
                    HStack(spacing: 14) {
                        LightPlot(project: project).frame(width: 96, height: 96)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(project.usableIndices.count) of \(project.meta.frames.count) usable").font(.headline)
                            Text("Each dot is one light position seen from above. Good coverage = dots all around, at several heights.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button { showSphere = true } label: {
                    Label(project.lightsAreCurrent ? "Adjust sphere & re-detect" : "Mark sphere & detect lights", systemImage: "circle.dashed")
                }
                .disabled(project.meta.frames.isEmpty)
            } header: { Text("1 · Light directions") }

            Section {
                Picker("Basis", selection: $basis) {
                    ForEach(RTIBasis.allCases) { Text($0.title).tag($0) }
                }
                Picker("Resolution", selection: $maxSide) {
                    Text("1024 px").tag(1024)
                    Text("1536 px").tag(1536)
                    Text("2048 px").tag(2048)
                }
                if building {
                    VStack(alignment: .leading) {
                        ProgressView(value: buildProgress)
                        Text(buildStatus).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button { Task { await build() } } label: { Label(project.hasRTI ? "Rebuild RTI" : "Build RTI", systemImage: "cube.transparent") }
                        .disabled(project.usableIndices.count < basis.nCoeffs + 2)
                }
            } header: { Text("2 · Build RTI") } footer: {
                Text("HSH handles shinier materials; PTM is the classic format. Both use relight's math and open in relight's OpenLIME viewer.")
            }

            Section {
                Button { showViewer = true } label: { Label("Open relightable image", systemImage: "light.max") }
                    .disabled(!project.hasRTI)
                Button { showCloth = true } label: { Label("Open in 3D cloth viewer", systemImage: "figure.stand.dress") }
                    .disabled(!project.hasRTI)
                if let r = project.meta.rti {
                    Text(verbatim: "\(r.basis.rawValue.uppercased()) · \(r.width)×\(r.height) · \(r.lightsUsed) lights · built in \(String(format: "%.1f", r.seconds)) s")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("3 · View") }

            Section {
                Button { export { try Exporter.exportRTI(project) } } label: {
                    Label("Share RTI (relight format + web viewer)", systemImage: "square.and.arrow.up")
                }
                .disabled(!project.hasRTI || exporting)
                Button { export { try Exporter.exportCapture(project) } } label: {
                    Label("Share photos + .lp file for RelightLab", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(project.meta.frames.isEmpty || exporting)
                if exporting { ProgressView() }
            } header: { Text("Export") } footer: {
                Text("Projects are also in the Files app under On My iPhone › relightCam › Projects.")
            }
        }
        .navigationTitle(project.meta.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename") { newName = project.meta.name; renaming = true }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { project.meta.name = n; project.save() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .sheet(item: $share) { ShareSheet(url: $0.url) }
        .fullScreenCover(isPresented: $showCapture) { CaptureView(project: project) }
        .navigationDestination(isPresented: $showViewer) { ViewerView(project: project) }
        .navigationDestination(isPresented: $showSphere) { SphereView(project: project) }
        .navigationDestination(isPresented: $showCloth) { ClothViewerView(project: project) }
        .onAppear {
            if let b = project.meta.rti?.basis { basis = b }
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-open-viewer") && project.hasRTI { showViewer = true }
            if args.contains("-open-sphere") { showSphere = true }
            if args.contains("-open-capture") { showCapture = true }
            if args.contains("-open-cloth") && project.hasRTI { showCloth = true }
        }
    }

    private func export(_ work: @escaping () throws -> URL) {
        exporting = true
        Task.detached(priority: .userInitiated) {
            do {
                let url = try work()
                await MainActor.run { exporting = false; share = ShareItem(url: url) }
            } catch {
                await MainActor.run { exporting = false; errorText = error.localizedDescription }
            }
        }
    }

    private func build() async {
        let idx = project.usableIndices
        guard let hs = project.meta.highlights else { return }
        let frames = idx.map { project.frameURLs[$0] }
        let lights = idx.map { hs[$0].dir }
        let b = basis, side = maxSide, out = project.rtiDir
        // keep the cloth viewer's cutout across rebuilds (the builder recreates rti/)
        let savedMask = try? Data(contentsOf: out.appendingPathComponent("mask.png"))
        let pixelSize: (Int) -> Double? = { [project] w in project.rtiPixelSizeMM(rtiWidth: w) }
        building = true
        buildProgress = 0
        buildStatus = "Starting…"
        do {
            let r = try await Task.detached(priority: .userInitiated) {
                try RTIBuilder.build(frames: frames, lights: lights, basis: b, maxSide: side, output: out, pixelSizeMM: pixelSize) { p, s in
                    Task { @MainActor in buildProgress = p; buildStatus = s }
                }
            }.value
            project.meta.rti = RTIMeta(basis: b, width: r.width, height: r.height, lightsUsed: r.lightsUsed, date: Date(), seconds: r.seconds)
            project.save()
            if let savedMask { try? savedMask.write(to: out.appendingPathComponent("mask.png")) }
            else if project.meta.source == "demo-textile" { DemoMask.write(for: project) }
        } catch {
            errorText = error.localizedDescription
        }
        building = false
    }
}

/// Async thumbnail loader with a small shared cache.
struct FrameThumb: View {
    let url: URL?
    var maxPixel = 240
    @State private var image: UIImage?
    private static let cache = NSCache<NSURL, UIImage>()

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            guard let url else { return }
            if let c = Self.cache.object(forKey: url as NSURL) { image = c; return }
            let px = maxPixel
            let img: UIImage? = await Task.detached(priority: .utility) {
                ImageUtils.load(url, maxPixel: px).map { UIImage(cgImage: $0) }
            }.value
            if let img { Self.cache.setObject(img, forKey: url as NSURL); image = img }
        }
    }
}

struct FramesView: View {
    @Bindable var project: Project
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 6)]

    var body: some View {
        ScrollView {
            if project.lightsAreCurrent {
                Text("Tap a photo to exclude it from the RTI (e.g. a blurred shot or a wrong highlight).")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(project.meta.frames.indices, id: \.self) { i in
                    let h = project.lightsAreCurrent ? project.meta.highlights?[i] : nil
                    let excluded = project.meta.excluded.contains(i)
                    ZStack(alignment: .bottomLeading) {
                        FrameThumb(url: project.frameURLs[i]).aspectRatio(4 / 3, contentMode: .fit)
                            .opacity(excluded ? 0.35 : 1)
                        HStack(spacing: 4) {
                            Text("\(i + 1)").font(.caption2.bold().monospacedDigit())
                            if let h {
                                Image(systemName: excluded ? "xmark.circle.fill" : (h.valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                                    .foregroundStyle(excluded ? .gray : (h.valid ? .green : .orange))
                                    .font(.caption2)
                            }
                        }
                        .padding(4).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white).padding(4)
                    }
                    .onTapGesture {
                        guard project.lightsAreCurrent else { return }
                        if let k = project.meta.excluded.firstIndex(of: i) { project.meta.excluded.remove(at: k) } else { project.meta.excluded.append(i) }
                        project.save()
                    }
                }
            }
            .padding(6)
        }
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
    }
}
