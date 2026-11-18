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
    @State private var showRTIImporter = false
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
                        Button("Try the demo capture") { Task { await makeDemo(.textile) } }
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
            // a second file importer must sit on another view than the photo importer
            .fileImporter(isPresented: $showRTIImporter, allowedContentTypes: [.zip, .folder]) { result in
                if case .success(let url) = result { Task { await importRTI(url) } }
            }
            .navigationDestination(for: Project.self) { ProjectView(project: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { showPhotoPicker = true } label: { Label("Import from Photos", systemImage: "photo.on.rectangle") }
                        Button { showFileImporter = true } label: { Label("Import from Files", systemImage: "folder") }
                        Button { showRTIImporter = true } label: { Label("Import an RTI (relight .zip or folder)", systemImage: "cube.transparent") }
                        Button { Task { await makeDemo(.tablet) } } label: { Label("Demo capture: embossed tablet", systemImage: "wand.and.stars") }
                        Button { Task { await makeDemo(.textile) } } label: { Label("Demo capture: silk textile", systemImage: "wand.and.stars.inverse") }
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
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-autorun-textile") { await autorun(.textile) } else if args.contains("-autorun") { await autorun(.tablet) }
            if args.contains("-open-help") { showHelp = true }
            #if DEBUG
            // test hook -import-rti <path>: import an RTI zip or folder as the menu does
            if let i = args.firstIndex(of: "-import-rti"), i + 1 < args.count { await importRTI(URL(fileURLWithPath: args[i + 1])) }
            #endif
        }
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

    /// An RTI in relight's web format (relightCam's own "Share RTI" zip, or relight-cli PTM/HSH output).
    private func importRTI(_ url: URL) async {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(" RTI") { name = String(name.dropLast(4)) }
        guard let p = try? store.create(name: name, source: "rti-import") else { return }
        busy = "Importing RTI…"
        let dest = p.rtiDir
        let result: Result<RelightInfo, Error> = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return Result { try RTIImport.importRTI(from: url, to: dest) }
        }.value
        busy = nil
        switch result {
        case .success(let info):
            p.meta.rti = RTIMeta(basis: info.basis ?? .ptm, width: info.width, height: info.height,
                                 lightsUsed: (info.lights?.count ?? 0) / 3, date: Date(), seconds: 0)
            p.meta.frameWidth = info.width
            p.meta.frameHeight = info.height
            p.meta.pixelSizeMM = info.pixelSizeInMM
            p.save()
            path = [p]
        case .failure(let e):
            store.delete(p)
            errorText = e.localizedDescription
        }
    }

    /// Test hook (launch argument -autorun): demo capture → detect → HSH build → project screen.
    private func autorun(_ kind: SyntheticDataset.Kind) async {
        let source = kind == .tablet ? "demo" : "demo-textile"
        if let done = store.projects.first(where: { $0.meta.source == source && $0.hasRTI }) { path = [done]; return }
        await makeDemo(kind)
        guard let p = path.first, let sphere = p.meta.sphere else { return }
        busy = "Autorun: detecting lights…"
        let urls = p.frameURLs, fw = p.meta.frameWidth, fh = p.meta.frameHeight, out = p.rtiDir
        let hs = await Task.detached { LightDetector.detectAll(frames: urls, sphere: sphere, frameWidth: fw, frameHeight: fh) }.value
        p.meta.highlights = hs
        p.save()
        busy = "Autorun: building HSH…"
        let idx = p.usableIndices
        let frames = idx.map { urls[$0] }, lights = idx.map { hs[$0].dir }
        let pixelSize: (Int) -> Double? = { [p] w in p.rtiPixelSizeMM(rtiWidth: w) }
        if let r = try? await Task.detached(operation: {
            try RTIBuilder.build(frames: frames, lights: lights, basis: .hsh, maxSide: 1536, output: out, pixelSizeMM: pixelSize) { _, _ in }
        }).value {
            p.meta.rti = RTIMeta(basis: .hsh, width: r.width, height: r.height, lightsUsed: r.lightsUsed, date: Date(), seconds: r.seconds)
            p.save()
            if kind == .textile { DemoMask.write(for: p) }
        }
        busy = nil
        path = []
        path = [p]
    }

    private func makeDemo(_ kind: SyntheticDataset.Kind) async {
        let isTablet = kind == .tablet
        guard let p = try? store.create(name: isTablet ? "Demo tablet" : "Demo silk lampas", source: isTablet ? "demo" : "demo-textile") else { return }
        busy = "Rendering demo capture…"
        let dir = p.framesDir
        do {
            let r = try await Task.detached(priority: .userInitiated) { try SyntheticDataset.generate(into: dir, kind: kind) }.value
            if !isTablet { p.meta.sphereDiameterMM = 40 }
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
            FrameThumb(url: project.thumbnailURL).frame(width: 64, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.meta.name).font(.headline).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var status: String {
        if project.isImportedRTI, let r = project.meta.rti {
            return "Imported RTI · \(r.basis.rawValue.uppercased()) · \(r.width)×\(r.height)"
        }
        var parts = ["\(project.meta.frames.count) photos"]
        if project.lightsAreCurrent { parts.append("\(project.usableIndices.count) lights") }
        if let r = project.meta.rti { parts.append("\(r.basis.rawValue.uppercased()) ready") }
        return parts.joined(separator: " · ")
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    /// test hook -open-credits
    @State private var openCredits = ProcessInfo.processInfo.arguments.contains("-open-credits")
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section("What you need") {
                    Label("The iPhone on a tripod or copy stand, aimed at the object. It must not move.", systemImage: "camera.metering.center.weighted")
                    Label("A shiny black sphere next to the object, in the same plane (a ball bearing, a black glass marble or a snooker ball).", systemImage: "circle.fill")
                    Label("A separate hand-held light: a torch, an LED panel or a second phone's flashlight. The iPhone's own flash cannot move, so it won't work.", systemImage: "flashlight.on.fill")
                    Label("A dark room.", systemImage: "moon.fill")
                }
                Section("Capture") {
                    Text("1. Frame the object and the sphere (pinch to zoom), tap to focus or set it with the slider's ◎ mode, set the brightness with the light on, then tap Lock.")
                    Text("2. Choose an interval (2 s is a good start) and press the red button. After a 3-second countdown the app takes a photo at every click.")
                    Text("3. Between clicks, move the light to a new spot. Keep it at the same distance (roughly 3–4× the object size). Go all the way around at several heights, from low raking light (~15°) to high (~75°). 30–60 photos is plenty.")
                }
                Section("Light dome (optional)") {
                    Text("With a MIDI light dome, choose Dome in the capture screen's interval menu. Connect the dome's Arduino with a USB cable, frame with the framing LED on, tap Lock, then press the red button: relightCam lights each LED in turn and takes one photo per LED. The dome's light positions (a relight .lp file, the current 24-LED dome by default) give every photo its light direction, so no sphere is needed.")
                }
                Section("Process") {
                    Text("Mark the sphere, detect the lights, build the RTI, then explore it: drag to move the light, or switch on Tilt and tilt the phone.")
                    Text("For the highest quality, export the photos with the .lp file and process them in RelightLab on a desktop.")
                    Text("RTIs made elsewhere can be imported (import menu › Import an RTI): relight's web format as a zip or folder, PTM or HSH, such as relightCam's own exports.")
                }
                Section("About") {
                    VStack(alignment: .leading, spacing: 10) {
                        Image("UAntwerpenLogo").resizable().scaledToFit().frame(height: 48)
                            .accessibilityLabel("University of Antwerp")
                        Text("relightCam is developed at the University of Antwerp. It reimplements the capture-to-RTI pipeline of relight (CNR-ISTI Visual Computing Lab) natively for iOS: the same highlight detection, PTM/HSH bases and web format.")
                            .font(.footnote)
                    }
                    .padding(.vertical, 6)
                    NavigationLink { CreditsView() } label: {
                        Label("Credits and licenses", systemImage: "doc.text")
                    }
                    .id("credits")
                }
            }
            .onAppear {
                // test hook -scroll-help
                if ProcessInfo.processInfo.arguments.contains("-scroll-help") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo("credits", anchor: .bottom) }
                }
            }
            }
            .navigationDestination(isPresented: $openCredits) { CreditsView() }
            .navigationTitle("How it works")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
