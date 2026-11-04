import SwiftUI

extension Project {
    /// Real size of the RTI image: from the sphere's known diameter, a manual override, or a 30 cm guess.
    /// Largest rectangle of the image (normalized, v down) that keeps clear of the calibration sphere,
    /// used as the default pattern-repeat region.
    func defaultRepeatRect() -> [Double] {
        guard let s = meta.sphere, meta.frameWidth > 0, meta.frameHeight > 0 else { return [0, 0, 1, 1] }
        let fw = Double(meta.frameWidth), fh = Double(meta.frameHeight)
        let m = 1.3
        let x0 = max(0, (s.cx - s.r * m) / fw), x1 = min(1, (s.cx + s.r * m) / fw)
        let y0 = max(0, (s.cy - s.r * m) / fh), y1 = min(1, (s.cy + s.r * m) / fh)
        let candidates: [[Double]] = [[0, 0, x0, 1], [x1, 0, 1 - x1, 1], [0, 0, 1, y0], [0, y1, 1, 1 - y1]]
        let best = candidates.filter { $0[2] > 0.2 && $0[3] > 0.2 }.max { $0[2] * $0[3] < $1[2] * $1[3] }
        return best ?? [0, 0, 1, 1]
    }

    func clothSampleSize(override: Double?) -> (size: SIMD2<Float>, note: String) {
        let fw = max(1, meta.frameWidth), fh = max(1, meta.frameHeight)
        let aspect = Float(fh) / Float(fw)
        if let o = override, o > 0 {
            return (SIMD2(Float(o), Float(o) * aspect), "set by hand")
        }
        if let d = meta.sphereDiameterMM, d > 0, let s = meta.sphere, s.r > 0 {
            let w = Float(Double(fw) * d / (2 * s.r) / 1000)
            return (SIMD2(w, w * aspect), String(format: "from the %.0f mm sphere", d))
        }
        return (SIMD2(0.30, 0.30 * aspect), "assumed: enter the sphere diameter under Sphere & lights")
    }
}

struct ClothViewerView: View {
    @Bindable var project: Project
    @Environment(ProjectStore.self) private var store
    @State private var model: ClothModel
    @State private var showSettings = false
    @State private var showMask = false
    @State private var arItem: ShareItem?
    @State private var maskVersion = 0
    @State private var showPanel = true

    init(project: Project) {
        self.project = project
        var s = project.meta.cloth ?? ClothSettings()
        if project.meta.cloth == nil && project.meta.source != "demo-textile" {
            // small samples (most captures) only cover a patch of a form: repeat them into a length of fabric
            if project.clothSampleSize(override: nil).size.x < 0.5 {
                s.tiling = .repeating
                s.repeatRect = project.defaultRepeatRect()
                s.panelWidth = 1.0
                s.panelHeight = 1.1
            }
        }
        if project.meta.cloth == nil && project.meta.source == "demo-textile" {
            // a length of the demo silk on the form: tile a seamless block of the pattern (3 × 2 motif repeats)
            s.material = .silk
            s.support = .dressForm
            s.tiling = .repeating
            s.repeatRect = [0.3, 0.3, 0.4875, 0.6667]
            s.panelWidth = 1.0
            s.panelHeight = 1.1
            s.lightAzimuth = ClothViewerView.defaultAzimuth(.dressForm)
        }
        // test hooks for screenshots: -cloth-support -cloth-form -cloth-light -cloth-mode -cloth-grain -cloth-material
        let args = ProcessInfo.processInfo.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let v = arg("-cloth-support"), let sup = ClothSupport(rawValue: v) {
            s.support = sup
            s.lightAzimuth = ClothViewerView.defaultAzimuth(sup)
        }
        if let v = arg("-cloth-form"), let f = FormPreset(rawValue: v) { s.form = f }
        if let v = arg("-cloth-light"), let l = ClothLightMode(rawValue: v) { s.lightMode = l }
        if let v = arg("-cloth-grain"), let g = Double(v) { s.grainAngle = g }
        if let v = arg("-cloth-material"), let m = ClothMaterial(rawValue: v) { s.material = m }
        let m = ClothModel(settings: s)
        if let v = arg("-cloth-mode"), let i = Int(v), let mode = ViewerModel.Mode(rawValue: i) { m.mode = mode }
        if args.contains("-cloth-ar") { m.arMode = true }
        _model = State(initialValue: m)
    }

    /// Lamp from the front-left above: in the dome's frame that's upper-left for upright supports and
    /// lower-left (towards the viewer) for horizontal ones.
    static func defaultAzimuth(_ s: ClothSupport) -> Double {
        switch s {
        case .board, .free: return 135
        case .dressForm: return 225
        }
    }

    private var versoDir: URL? {
        guard let v = model.settings.verso else { return nil }
        return store.projects.first { $0.url.lastPathComponent == v && $0.hasRTI }?.rtiDir
    }

    var body: some View {
        let sample = project.clothSampleSize(override: model.settings.sampleWidthOverride)
        ZStack(alignment: .bottom) {
            ClothMetalView(dir: project.rtiDir, versoDir: versoDir, sampleSize: sample.size, model: model,
                           settings: model.settings, tool: model.tool, mode: model.mode, gain: model.gain,
                           paused: model.paused, recenter: model.recenter, resetCloth: model.resetCloth,
                           resetCamera: model.resetCamera, exportRequest: model.exportRequest, arMode: model.arMode,
                           suspended: showSettings || showMask || arItem != nil)
                .id("\(model.settings.verso ?? "")|\(maskVersion)|\(sample.size)")
                .ignoresSafeArea()
            if let e = model.error {
                Text(e).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            }
            if model.exporting {
                ProgressView("Preparing 3D model…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if model.arMode, let h = model.arHint {
                VStack {
                    Text(h).font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                    Spacer()
                }
                .environment(\.colorScheme, .dark)
                .allowsHitTesting(false)
            }
            if showPanel { panel.environment(\.colorScheme, .dark) }
        }
        .navigationTitle(model.arMode ? "AR" : "3D cloth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black.opacity(0.55), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showMask = true } label: { Image(systemName: "scissors") }
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                Button { model.arMode.toggle() } label: {
                    Image(systemName: "arkit").symbolVariant(model.arMode ? .fill : .none)
                        .foregroundStyle(model.arMode ? Color.yellow : Color.primary)
                }
                .disabled(!model.arAvailable)
                Button { model.exportRequest += 1 } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(model.exporting)
                Button { withAnimation { showPanel.toggle() } } label: {
                    Image(systemName: showPanel ? "rectangle.bottomthird.inset.filled" : "rectangle")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ClothSettingsView(model: model, project: project, sampleNote: sample.note, sampleSize: sample.size)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showMask) {
            MaskEditorView(project: project, repeatRect: $model.settings.repeatRect) { maskVersion += 1 }
        }
        .sheet(item: $arItem) { ShareSheet(url: $0.url) }
        .onChange(of: model.exportedURL) { _, url in
            guard let url else { return }
            if ProcessInfo.processInfo.arguments.contains("-log-stats") {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                print("cloth export:", url.lastPathComponent, size / 1024, "KB")
            }
            arItem = ShareItem(url: url)
            model.exportedURL = nil
        }
        .onChange(of: model.arHint) { _, h in
            if ProcessInfo.processInfo.arguments.contains("-log-stats") { print("cloth AR:", h ?? "-") }
        }
        .onChange(of: model.error) { _, e in
            if ProcessInfo.processInfo.arguments.contains("-log-stats"), let e { print("cloth error:", e) }
        }
        .onDisappear { save() }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-cloth-open-settings") { showSettings = true }
            if args.contains("-cloth-open-mask") { showMask = true }
            if args.contains("-cloth-export-test") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { model.exportRequest += 1 }
            }
        }
        .onChange(of: model.settings.support) { old, new in
            if Self.defaultAzimuth(old) != Self.defaultAzimuth(new) { model.settings.lightAzimuth = Self.defaultAzimuth(new) }
        }
    }

    private func save() {
        var s = model.settings
        if let (pins, key) = model.savePins?() {
            s.pins = pins
            s.pinsKey = key
        }
        project.meta.cloth = s
        project.save()
    }

    private var panel: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ClothSupport.allCases) { sup in
                        Button { model.settings.support = sup } label: {
                            VStack(spacing: 2) {
                                Image(systemName: sup.symbol).font(.system(size: 17))
                                Text(sup.title).font(.caption2)
                            }
                            .frame(width: 62, height: 44)
                            .background(model.settings.support == sup ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 10) {
                Menu {
                    Picker("Fabric", selection: $model.settings.material) {
                        ForEach(ClothMaterial.allCases) { Text($0.title).tag($0) }
                    }
                } label: { chip(model.settings.material.title, "square.grid.3x3.square") }
                if model.settings.support == .dressForm {
                    Menu {
                        Picker("Form", selection: $model.settings.form) {
                            ForEach(FormPreset.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { chip(model.settings.form.title, "figure.stand.dress") }
                }
                Spacer(minLength: 0)
                if model.settings.support != .board {
                    Picker("Tool", selection: $model.tool) {
                        ForEach(ClothTool.allCases) { Image(systemName: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                LightDomeControl(azimuth: $model.settings.lightAzimuth, elevation: $model.settings.lightElevation,
                                 orbit: model.settings.lightMode == .orbit)
                    .frame(width: 70, height: 70)
                VStack(spacing: 8) {
                    Picker("Light", selection: $model.settings.lightMode) {
                        ForEach(ClothLightMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 8) {
                        if !model.arMode {
                        Menu {
                            Picker("Tilt", selection: $model.settings.tiltMode) {
                                ForEach(ClothTiltMode.allCases) { Text($0.title).tag($0) }
                            }
                            if model.settings.tiltMode != .off { Button("Re-center") { model.recenter += 1 } }
                        } label: { chip(model.settings.tiltMode == .off ? "Tilt off" : "Tilt: \(model.settings.tiltMode.title)", "iphone.gen3.radiowaves.left.and.right") }
                        }
                        Menu {
                            Picker("View", selection: $model.mode) {
                                ForEach(ViewerModel.Mode.allCases) { Text($0.title).tag($0) }
                            }
                        } label: { chip(model.mode.title, "eye") }
                        Slider(value: $model.gain, in: 0.5...2.5)
                    }
                }
            }
            HStack {
                if model.settings.support != .board {
                    Button { model.resetCloth += 1 } label: { Label("Reset cloth", systemImage: "arrow.counterclockwise") }
                    Button { model.paused.toggle() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill") }
                }
                Spacer()
                Text(model.stats).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .font(.caption.bold())
            Text(hint).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var hint: String {
        if model.arMode {
            return model.settings.lightMode == .headlamp
                ? "Headlamp: the light comes from your iPhone. Walk around the textile to relight it."
                : "Drag the cloth to move it · long-press to pin · drag beside it to turn it · tap a surface to move it there."
        }
        if model.settings.support == .board { return "Drag to turn the board · pinch to zoom · drag the light dome to move the lamp." }
        switch model.tool {
        case .move: return "Drag the cloth to move it · long-press to pin · tap a pin to remove it · drag empty space to turn around."
        case .pin: return "Tap the cloth to pin it · drag a point and let go on the form to pin it there · tap a pin to remove it."
        case .smooth: return "Stroke over the cloth to smooth it onto the form, like pressing it flat by hand."
        }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption.bold()).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.1), in: Capsule())
    }
}

/// Top view of the light dome: drag to set the lamp's direction (centre = straight above the axis).
struct LightDomeControl: View {
    @Binding var azimuth: Double
    @Binding var elevation: Double
    var orbit: Bool

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2 - 3
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let rho = cos(elevation * .pi / 180)
            let p = CGPoint(x: c.x + CGFloat(rho * cos(azimuth * .pi / 180)) * r, y: c.y - CGFloat(rho * sin(azimuth * .pi / 180)) * r)
            ZStack {
                Circle().fill(Color.black.opacity(0.35))
                Circle().stroke(Color.white.opacity(0.55), lineWidth: 1)
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 1).padding(r * 0.5)
                if orbit {
                    Circle().stroke(Color.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: 2 * r * CGFloat(rho), height: 2 * r * CGFloat(rho))
                } else {
                    Path { $0.move(to: c); $0.addLine(to: p) }.stroke(Color.yellow.opacity(0.6), lineWidth: 1)
                    Circle().fill(Color.yellow).frame(width: 12, height: 12).position(p)
                }
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let dx = Double((v.location.x - c.x) / r), dy = Double(-(v.location.y - c.y) / r)
                let rr = min(1, (dx * dx + dy * dy).squareRoot())
                if !orbit || rr > 0.05 { azimuth = atan2(dy, dx) * 180 / .pi }
                elevation = max(4, acos(rr) * 180 / .pi)
            })
        }
    }
}

struct ClothSettingsView: View {
    @Bindable var model: ClothModel
    let project: Project
    let sampleNote: String
    let sampleSize: SIMD2<Float>
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var overrideCM = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Grain angle")
                            Spacer()
                            Text(String(format: "%.0f°%@", model.settings.grainAngle, abs(model.settings.grainAngle - 45) < 1 ? " · bias" : ""))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $model.settings.grainAngle, in: 0...90, step: 1)
                        Text("0° = warp vertical (straight grain). 45° = cut on the bias: the fabric stretches and clings more.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Tiling", selection: $model.settings.tiling) {
                        ForEach(ClothTiling.allCases) { Text($0.title).tag($0) }
                    }
                    if model.settings.tiling != .off {
                        LabeledContent("Panel width", value: String(format: "%.0f cm", model.settings.panelWidth * 100))
                        Slider(value: $model.settings.panelWidth, in: 0.2...1.6, step: 0.05)
                        LabeledContent("Panel height", value: String(format: "%.0f cm", model.settings.panelHeight * 100))
                        Slider(value: $model.settings.panelHeight, in: 0.2...1.6, step: 0.05)
                        Text("The textile repeats over the panel (on the dress form and free cloth; the board always shows the sample itself). Mark one pattern repeat with the scissors tool (Repeat region).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Fabric") }

                Section {
                    Toggle("Sheen (silk, metal threads)", isOn: Binding(get: { model.settings.sheenEnabled }, set: { model.settings.sheen = $0 }))
                    Toggle("Show warp grainline", isOn: $model.settings.showGrainline)
                    Toggle("Use cutout", isOn: $model.settings.useMask)
                    Toggle("Cloth-on-cloth collisions", isOn: $model.settings.selfCollision)
                    Picker("Reverse side", selection: $model.settings.verso) {
                        Text("None (plain back)").tag(String?.none)
                        ForEach(store.projects.filter { $0.hasRTI && $0.url != project.url }) { p in
                            Text(p.meta.name).tag(String?.some(p.url.lastPathComponent))
                        }
                    }
                } header: { Text("Look") } footer: {
                    Text("Sheen keeps highlights where they belong when a fold is seen at an angle. It's an approximation: the RTI was captured from straight above.")
                }

                Section {
                    LabeledContent("Sample size", value: String(format: "%.1f × %.1f cm", sampleSize.x * 100, sampleSize.y * 100))
                    Text(sampleNote).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Width in cm (override)", text: $overrideCM).keyboardType(.decimalPad)
                        Button("Set") {
                            if let v = Double(overrideCM.replacingOccurrences(of: ",", with: ".")), v > 0 { model.settings.sampleWidthOverride = v / 100 }
                        }
                        Button("Auto") { model.settings.sampleWidthOverride = nil; overrideCM = "" }
                    }
                } header: { Text("Real scale") }

                Section {
                    Text("This is a visual study, not a prediction: the drape uses fabric presets, and views at an angle are approximated from a capture taken from above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cloth settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
