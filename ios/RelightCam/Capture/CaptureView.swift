import SwiftUI
import AVFoundation
import AudioToolbox

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var observation: NSKeyValueObservation?

    func attach(_ camera: CameraController) {
        guard let device = camera.device else { return }
        let rc = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        camera.rotationCoordinator = rc
        previewLayer.connection?.videoRotationAngle = rc.videoRotationAngleForHorizonLevelPreview
        observation = rc.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] rc, _ in
            DispatchQueue.main.async { self?.previewLayer.connection?.videoRotationAngle = rc.videoRotationAngleForHorizonLevelPreview }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: CameraController
    /// pinch to zoom (off during a run and once the project has photos, so all photos match)
    var zoomEnabled = true

    final class Coordinator: NSObject {
        var version = -1
        var camera: CameraController?
        var zoomEnabled = true
        private var startZoom: CGFloat = 1
        weak var view: PreviewUIView?
        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view, let camera, !camera.isLocked else { return }
            let p = g.location(in: view)
            camera.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: p))
            // show where it focuses
            let box = UIView(frame: CGRect(x: p.x - 36, y: p.y - 36, width: 72, height: 72))
            box.layer.borderColor = UIColor.systemYellow.cgColor
            box.layer.borderWidth = 1.5
            box.isUserInteractionEnabled = false
            box.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
            view.addSubview(box)
            UIView.animate(withDuration: 0.2) { box.transform = .identity }
            UIView.animate(withDuration: 0.4, delay: 1.0, options: []) { box.alpha = 0 } completion: { _ in box.removeFromSuperview() }
        }
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard zoomEnabled, let camera else { return }
            switch g.state {
            case .began: startZoom = camera.zoom
            case .changed: camera.setZoom(startZoom * g.scale)
            default: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = camera.session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        context.coordinator.view = v
        context.coordinator.camera = camera
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        v.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
        context.coordinator.zoomEnabled = zoomEnabled
        if context.coordinator.version != camera.deviceVersion {
            context.coordinator.version = camera.deviceVersion
            v.attach(camera)
        }
    }
}

struct CaptureView: View {
    let project: Project
    var onFinish: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraController()
    @State private var interval: Double = 2
    @State private var running = false
    @State private var countdown = 0
    @State private var timer: Timer?
    @State private var hudTimer: Timer?
    @State private var flash = false
    @State private var dome = DomeMIDI.shared
    @AppStorage("dome.mode") private var domeMode = false
    @State private var domeTask: Task<Void, Never>?
    @State private var domeLED: Int?
    @State private var domeMessage: String?
    @State private var showDomeSettings = false
    @State private var onScreen = false
    /// the slider sets brightness or focus
    @State private var focusSlider = false

    private let intervals: [(String, Double)] = [("Manual", 0), ("1 s", 1), ("2 s", 2), ("3 s", 3), ("5 s", 5)]
    /// interval picker tag for the light dome
    private let domeTag: Double = -1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.status {
            case .running, .idle:
                CameraPreview(camera: camera, zoomEnabled: !running && project.meta.frames.isEmpty).ignoresSafeArea()
            case .denied:
                message("Camera access is off", "Allow camera access for relightCam in Settings → Privacy & Security → Camera.")
            case .failed(let s):
                message("Camera unavailable", s + "\nYou can still import photos or generate a demo capture from the main screen.")
            }
            if flash { Color.white.opacity(0.35).ignoresSafeArea().allowsHitTesting(false) }
            if countdown > 0 {
                Text("\(countdown)").font(.system(size: 120, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .shadow(radius: 8)
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                if let n = domeLED {
                    Text("LED \(n + 1) of \(dome.ledCount)")
                        .font(.headline.monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 8)
                } else if let m = domeMessage {
                    note(m)
                } else if project.meta.frames.isEmpty && !running {
                    domeMode ? note(domeHint) : note(hintText)
                }
                controls
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showDomeSettings) { DomeSettingsView(dome: dome) }
        .onChange(of: domeMode) { _, on in
            domeMessage = nil
            if on { dome.refresh(); dome.showPreview() } else { dome.allOff() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.framesDir = project.framesDir
            camera.nextIndex = project.nextFrameIndex()
            camera.onSaved = { name, w, h in
                project.appendFrame(name, width: w, height: h)
                // light dome: the photo gets its LED's direction from the dome's light file
                if project.meta.leds?[name] != nil, let l = dome.lights, dome.useLights {
                    project.applyDomeLights(source: l.name) { dome.direction(forLED: $0) }
                }
            }
            camera.start()
            hudTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in camera.refreshExposureText() }
            onScreen = true
            if domeMode { dome.refresh(); dome.showPreview() }
            #if DEBUG
            // test hook -zoom a,b,c: set these zooms one after another, 2 s apart
            let args = ProcessInfo.processInfo.arguments
            // (a trailing "s" = lens preset, e.g. 1s), and -focus p: set the lens position after that
            if let i = args.firstIndex(of: "-zoom"), i + 1 < args.count {
                for (k, item) in args[i + 1].split(separator: ",").enumerated() {
                    let snap = item.hasSuffix("s")
                    guard let z = Double(snap ? item.dropLast() : item) else { continue }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2 + 2 * Double(k)) { camera.setZoom(z, snap: snap) }
                }
            }
            if let i = args.firstIndex(of: "-focus"), i + 1 < args.count, let f = Float(args[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    camera.setFocus(f)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        let d = camera.device
                        print("[focus] set \(f): lens position \(d?.lensPosition ?? -1), mode \(d?.focusMode.rawValue ?? -1), zoom \(camera.zoom)")
                    }
                }
            }
            // test hook -dome-autostart: start a dome run after the camera has settled
            if args.contains("-dome-autostart") {
                domeMode = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if !running { startDome() } }
            }
            #endif
        }
        .onDisappear {
            onScreen = false
            stopInterval()
            if domeMode { dome.allOff() }
            hudTimer?.invalidate()
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                stopInterval()
                onFinish()
                dismiss()
            } label: {
                Text("Done").bold().padding(.horizontal, 14).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            VStack(spacing: 2) {
                Text("\(project.meta.frames.count) photos").font(.headline.monospacedDigit())
                Text([camera.resolutionText, camera.exposureText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            Spacer()
            if !camera.availableLenses.isEmpty {
                Menu {
                    ForEach(camera.availableLenses.sorted { camera.base($0) < camera.base($1) }) { l in
                        Button(CameraController.zoomLabel(camera.base(l))) { camera.setZoom(camera.base(l), snap: true) }
                    }
                } label: {
                    Text(CameraController.zoomLabel(camera.zoom)).bold().monospacedDigit()
                        .frame(minWidth: 44).padding(.vertical, 8).padding(.horizontal, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .disabled(running || !project.meta.frames.isEmpty)
            } else {
                Color.clear.frame(width: 44, height: 1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private let hintText = "Tripod · dark room · glossy black sphere in view.\nPinch to zoom, tap to focus (or set focus with the ◎ slider), lock, then move a hand-held light around the object between shots: low and high, all directions, same distance."

    private var domeHint: String {
        guard dome.hasOutput else { return "Light dome: no MIDI device yet. Connect the dome's Arduino to the iPhone with a USB cable." }
        let what = dome.useLights && dome.lights != nil
            ? "the object (no sphere needed: the light file gives the directions)" : "the object and the sphere"
        let lit = dome.previewOn ? " with LED \(dome.previewLED + 1) on" : ""
        return "Light dome: frame \(what)\(lit). Pinch to zoom, tap or use the ◎ slider to focus, then Lock. The red button lights each LED in turn and takes one photo per LED."
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white)
            .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal).padding(.bottom, 8)
    }

    private var domeRow: some View {
        Button { showDomeSettings = true } label: {
            HStack(spacing: 8) {
                Image(systemName: dome.hasOutput ? "light.recessed.fill" : "light.recessed")
                Text(dome.hasOutput ? "\(dome.ledCount) LEDs · \(dome.outputSummary)" : "Light dome: no MIDI device")
                    .font(.subheadline).lineLimit(1)
                Spacer()
                Image(systemName: "gearshape")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(running)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if domeMode { domeRow }
            HStack(spacing: 12) {
                Button { focusSlider.toggle() } label: {
                    Image(systemName: focusSlider ? "scope" : "sun.max")
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.15), in: Circle())
                }
                .accessibilityLabel(focusSlider ? "Slider sets focus; switch to brightness" : "Slider sets brightness; switch to focus")
                if focusSlider {
                    Slider(value: Binding(get: { Double(camera.lensPosition) }, set: { camera.setFocus(Float($0)) }), in: 0...1)
                        .disabled(camera.isLocked)
                    Text(camera.manualFocus ? String(format: "%.2f", camera.lensPosition) : "AF")
                        .font(.caption.monospacedDigit()).frame(width: 34)
                } else {
                    Slider(value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setBias(Float($0)) }), in: -3...2)
                        .disabled(camera.isLocked)
                    Text(String(format: "%+.1f", camera.exposureBias)).font(.caption.monospacedDigit()).frame(width: 34)
                }
                Button {
                    camera.setLocked(!camera.isLocked)
                } label: {
                    Label(camera.isLocked ? "Locked" : "Lock", systemImage: camera.isLocked ? "lock.fill" : "lock.open")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(camera.isLocked ? Color.yellow : Color.white.opacity(0.2), in: Capsule())
                        .foregroundStyle(camera.isLocked ? .black : .white)
                }
                .disabled(running)
            }
            HStack {
                Picker("Interval", selection: Binding(get: { domeMode ? domeTag : interval },
                                                      set: { v in if v == domeTag { domeMode = true } else { domeMode = false; interval = v } })) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                    Text("Dome").tag(domeTag)
                }
                .pickerStyle(.menu)
                .tint(.white)
                .disabled(running)
                .frame(width: 110, alignment: .leading)
                Spacer()
                shutter
                Spacer()
                Group {
                    if let t = camera.lastThumbnail {
                        Image(uiImage: t).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.15)
                    }
                }
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(width: 110, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(.ultraThinMaterial.opacity(0.9))
    }

    private var shutter: some View {
        Button(action: shutterTapped) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                if (interval > 0 || domeMode) && (running || countdown > 0) {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                } else {
                    Circle().fill(interval > 0 || domeMode ? Color.red : Color.white).frame(width: 60, height: 60)
                }
            }
        }
        .disabled(camera.status != .running)
    }

    private func shutterTapped() {
        if domeMode {
            if running { stopInterval() } else { startDome() }
            return
        }
        if !camera.isLocked { camera.setLocked(true) }
        if interval == 0 {
            shoot()
            return
        }
        if running || countdown > 0 { stopInterval(); return }
        countdown = 3
        AudioServicesPlaySystemSound(1103)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            countdown -= 1
            if countdown > 0 {
                AudioServicesPlaySystemSound(1103)
            } else {
                t.invalidate()
                running = true
                shoot()
                timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in shoot() }
            }
        }
    }

    @discardableResult
    private func shoot() -> String? {
        guard let name = camera.capture() else { return nil }
        AudioServicesPlaySystemSound(1108)
        flash = true
        withAnimation(.easeOut(duration: 0.25)) { flash = false }
        return name
    }

    /// Light dome: one photo per LED, switched over MIDI (see DomeMIDI).
    private func startDome() {
        domeMessage = nil
        dome.refresh()
        guard dome.hasOutput else { showDomeSettings = true; return }
        // lock with the framing LED still on, so exposure fits one LED
        if !camera.isLocked { camera.setLocked(true) }
        running = true
        let count = dome.ledCount
        dome.log("run started: \(count) LEDs, \(dome.settleMS) ms light, camera \(camera.exposureText)")
        domeTask = Task { @MainActor in
            // give the lock a moment to apply before the framing LED goes off
            try? await Task.sleep(for: .milliseconds(150))
            var current = 0
            let reason = await dome.runSequence(
                count: count,
                waitLit: {
                    await camera.waitForSaves(max: 1)
                    let ok = await camera.waitForFreshFrame()
                    if camera.lastFrameWait != "ok" { dome.log("frame wait: \(camera.lastFrameWait)") }
                    return ok
                },
                shoot: { n in
                    if let name = shoot() {
                        var leds = project.meta.leds ?? [:]
                        leds[name] = n
                        project.meta.leds = leds
                        dome.log("LED \(n + 1): photo \(name)")
                    } else {
                        dome.log("LED \(n + 1): no camera frame to save")
                    }
                },
                progress: { domeLED = $0; current = $0 })
            domeLED = nil
            running = false
            domeTask = nil
            switch reason {
            case .finished:
                domeMessage = dome.useLights && dome.lights != nil
                    ? "\(count) LEDs done, with light directions from \(dome.lights!.name). Tap Done to build the RTI, or the red button to capture again."
                    : "\(count) LEDs done. Tap Done to mark the sphere, or the red button to capture again."
            case .cancelled: domeMessage = "Stopped. The photos taken so far are kept."
            case .noFrames: domeMessage = "The camera stopped delivering frames at LED \(current + 1), so the run was stopped. The photos taken so far are kept."
            }
            if onScreen && domeMode { dome.showPreview() }
        }
    }

    private func stopInterval() {
        timer?.invalidate()
        timer = nil
        domeTask?.cancel()
        domeTask = nil
        domeLED = nil
        running = false
        countdown = 0
    }

    private func message(_ title: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text(title).font(.headline)
            Text(text).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white).padding(40)
    }
}
