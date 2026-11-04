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

    final class Coordinator: NSObject {
        var version = -1
        var camera: CameraController?
        weak var view: PreviewUIView?
        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view, let camera else { return }
            camera.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: g.location(in: view)))
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
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
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

    private let intervals: [(String, Double)] = [("Manual", 0), ("1 s", 1), ("2 s", 2), ("3 s", 3), ("5 s", 5)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.status {
            case .running, .idle:
                CameraPreview(camera: camera).ignoresSafeArea()
            case .denied:
                message("Camera access is off", "Allow camera access for RelightCam in Settings → Privacy & Security → Camera.")
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
                if project.meta.frames.isEmpty && !running { hint }
                controls
            }
        }
        .statusBarHidden()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.framesDir = project.framesDir
            camera.nextIndex = project.nextFrameIndex()
            camera.onSaved = { name, w, h in project.appendFrame(name, width: w, height: h) }
            camera.start()
            hudTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in camera.refreshExposureText() }
        }
        .onDisappear {
            stopInterval()
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
            if camera.availableLenses.count > 1 {
                Menu {
                    ForEach(camera.availableLenses) { l in
                        Button(l.rawValue) { camera.select(l) }
                    }
                } label: {
                    Text(camera.lens.rawValue).bold().frame(minWidth: 44).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
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

    private var hint: some View {
        Text("Tripod · dark room · glossy black sphere in view.\nTap to focus, lock exposure, then move a hand-held light around the object between shots: low and high, all directions, same distance.")
            .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white)
            .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal).padding(.bottom, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sun.max").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setBias(Float($0)) }), in: -3...2)
                    .disabled(camera.isLocked)
                Text(String(format: "%+.1f", camera.exposureBias)).font(.caption.monospacedDigit()).frame(width: 34)
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
                Picker("Interval", selection: $interval) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
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
                if interval > 0 && (running || countdown > 0) {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                } else {
                    Circle().fill(interval > 0 ? Color.red : Color.white).frame(width: 60, height: 60)
                }
            }
        }
        .disabled(camera.status != .running)
    }

    private func shutterTapped() {
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

    private func shoot() {
        guard camera.capture() else { return }
        AudioServicesPlaySystemSound(1108)
        flash = true
        withAnimation(.easeOut(duration: 0.25)) { flash = false }
    }

    private func stopInterval() {
        timer?.invalidate()
        timer = nil
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
