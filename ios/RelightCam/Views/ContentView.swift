import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ProjectStore.self) private var store
    @State private var path: [Project] = []
    @State private var captureProject: Project?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showHelp = false
    @State private var busy: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView {
                        Label("No captures yet", systemImage: "light.max")
                    } description: {
                        Text("Shoot a series of photos with a moving light and a shiny sphere in view, or try the demo capture first.")
                    } actions: {
                        Button("New capture") { newCapture() }.buttonStyle(.borderedProminent)
                        Button("Try the demo capture") { Task { await makeDemo() } }
                        Button("How to capture an RTI") { showHelp = true }
                    }
                } else {
                    List {
                        ForEach(store.projects) { p in
                            NavigationLink(value: p) { ProjectRow(project: p) }
                        }
                        .onDelete { idx in idx.map { store.projects[$0] }.forEach(store.delete) }
                    }
                }
            }
            .navigationTitle("relightCam")
            .navigationDestination(for: Project.self) { ProjectView(project: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { showPhotoPicker = true } label: { Label("Import from Photos", systemImage: "photo.on.rectangle") }
                        Button { showFileImporter = true } label: { Label("Import from Files", systemImage: "folder") }
                        Button { Task { await makeDemo() } } label: { Label("Generate demo capture", systemImage: "wand.and.stars") }
                    } label: { Image(systemName: "square.and.arrow.down") }
                    Button { newCapture() } label: { Image(systemName: "camera.fill") }
                }
            }
            .overlay {
                if let busy {
                    VStack(spacing: 10) { ProgressView(); Text(busy).font(.footnote) }
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .fullScreenCover(item: $captureProject) { p in
            CaptureView(project: p) {
                if p.meta.frames.isEmpty { store.delete(p) } else { path = [p] }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: nil, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items); photoItems = [] }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await importFiles(urls) } }
        }
        .sheet(isPresented: $showHelp) { HelpView() }
        .task { if ProcessInfo.processInfo.arguments.contains("-autorun") { await autorun() } }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func newCapture() {
        do { captureProject = try store.create(name: ProjectStore.timestampName("Capture"), source: "camera") } catch { errorText = error.localizedDescription }
    }

    private func finishImport(_ p: Project, names: [String]) {
        guard let first = names.first, let size = ImageUtils.orientedSize(of: p.framesDir.appendingPathComponent(first)) else {
            store.delete(p)
            errorText = "No readable images were imported."
            return
        }
        p.meta.frames = names
        p.meta.frameWidth = size.width
        p.meta.frameHeight = size.height
        p.save()
        path = [p]
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard let p = try? store.create(name: ProjectStore.timestampName("Import"), source: "photos") else { return }
        busy = "Importing \(items.count) photos…"
        var names: [String] = []
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let name = String(format: "frame_%03d.%@", i, ext)
            if (try? data.write(to: p.framesDir.appendingPathComponent(name))) != nil { names.append(name) }
        }
        busy = nil
        finishImport(p, names: names)
    }

    private func importFiles(_ urls: [URL]) async {
        guard let p = try? store.create(name: ProjectStore.timestampName("Import"), source: "files") else { return }
        busy = "Importing \(urls.count) files…"
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let dir = p.framesDir
        let names: [String] = await Task.detached {
            var names: [String] = []
            for (i, u) in sorted.enumerated() {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                let name = String(format: "frame_%03d.%@", i, u.pathExtension.isEmpty ? "jpg" : u.pathExtension.lowercased())
                if (try? FileManager.default.copyItem(at: u, to: dir.appendingPathComponent(name))) != nil { names.append(name) }
            }
            return names
        }.value
        busy = nil
        finishImport(p, names: names)
    }

    /// Test hook (launch argument -autorun): demo capture → detect → HSH build → project screen.
    private func autorun() async {
        if let done = store.projects.first(where: { $0.meta.source == "demo" && $0.hasRTI }) { path = [done]; return }
        await makeDemo()
        guard let p = path.first, let sphere = p.meta.sphere else { return }
        busy = "Autorun: detecting lights…"
        let urls = p.frameURLs, fw = p.meta.frameWidth, fh = p.meta.frameHeight, out = p.rtiDir
        let hs = await Task.detached { LightDetector.detectAll(frames: urls, sphere: sphere, frameWidth: fw, frameHeight: fh) }.value
        p.meta.highlights = hs
        p.save()
        busy = "Autorun: building HSH…"
        let idx = p.usableIndices
        let frames = idx.map { urls[$0] }, lights = idx.map { hs[$0].dir }
        if let r = try? await Task.detached(operation: {
            try RTIBuilder.build(frames: frames, lights: lights, basis: .hsh, maxSide: 1536, output: out) { _, _ in }
        }).value {
            p.meta.rti = RTIMeta(basis: .hsh, width: r.width, height: r.height, lightsUsed: r.lightsUsed, date: Date(), seconds: r.seconds)
            p.save()
        }
        busy = nil
        path = []
        path = [p]
    }

    private func makeDemo() async {
        guard let p = try? store.create(name: "Demo tablet", source: "demo") else { return }
        busy = "Rendering demo capture…"
        let dir = p.framesDir
        do {
            let r = try await Task.detached(priority: .userInitiated) { try SyntheticDataset.generate(into: dir) }.value
            p.meta.frames = r.files
            p.meta.frameWidth = r.width
            p.meta.frameHeight = r.height
            // start slightly off so there is something to adjust
            p.meta.sphere = SphereCircle(cx: r.sphere.cx + 6, cy: r.sphere.cy - 4, r: r.sphere.r * 0.97)
            p.save()
            busy = nil
            path = [p]
        } catch {
            busy = nil
            store.delete(p)
            errorText = error.localizedDescription
        }
    }
}

struct ProjectRow: View {
    let project: Project
    var body: some View {
        HStack(spacing: 12) {
            FrameThumb(url: project.frameURLs.first).frame(width: 64, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.meta.name).font(.headline).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var status: String {
        var parts = ["\(project.meta.frames.count) photos"]
        if project.lightsAreCurrent { parts.append("\(project.usableIndices.count) lights") }
        if let r = project.meta.rti { parts.append("\(r.basis.rawValue.uppercased()) ready") }
        return parts.joined(separator: " · ")
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("What you need") {
                    Label("The iPhone on a tripod or copy stand, aimed at the object. It must not move.", systemImage: "camera.metering.center.weighted")
                    Label("A shiny black sphere next to the object, in the same plane (a ball bearing, a black glass marble or a snooker ball).", systemImage: "circle.fill")
                    Label("A separate hand-held light: a torch, an LED panel or a second phone's flashlight. The iPhone's own flash cannot move, so it won't work.", systemImage: "flashlight.on.fill")
                    Label("A dark room.", systemImage: "moon.fill")
                }
                Section("Capture") {
                    Text("1. Frame the object and the sphere, tap to focus, set the brightness with the light on, then tap Lock.")
                    Text("2. Choose an interval (2 s is a good start) and press the red button. After a 3-second countdown the app takes a photo at every click.")
                    Text("3. Between clicks, move the light to a new spot. Keep it at the same distance (roughly 3–4× the object size). Go all the way around at several heights, from low raking light (~15°) to high (~75°). 30–60 photos is plenty.")
                }
                Section("Process") {
                    Text("Mark the sphere, detect the lights, build the RTI, then explore it: drag to move the light, or switch on Tilt and tilt the phone.")
                    Text("For the highest quality, export the photos with the .lp file and process them in RelightLab on a desktop.")
                }
                Section("About") {
                    Text("relightCam reimplements the capture-to-RTI pipeline of relight (cnr-isti-vclab/relight, CNR-ISTI Visual Computing Lab) natively for iOS: the same highlight detection, PTM/HSH bases and web format. Exports include the OpenLIME viewer (GPL-3.0). relightCam is GPL-3.0.")
                        .font(.footnote)
                }
            }
            .navigationTitle("How it works")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
