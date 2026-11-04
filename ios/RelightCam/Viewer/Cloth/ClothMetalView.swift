import SwiftUI
import MetalKit
import CoreMotion
import Observation

@Observable
final class ClothModel {
    var settings: ClothSettings
    var tool: ClothTool = .move
    var mode: ViewerModel.Mode = .relight
    var gain: Float = 1
    var paused = false
    var recenter = 0
    var resetCloth = 0
    var resetCamera = 0
    var stats = ""
    var error: String?
    var exportRequest = 0
    var exporting = false
    var exportedURL: URL?
    @ObservationIgnored var savePins: (() -> ([ClothPin], String))?

    init(settings: ClothSettings) { self.settings = settings }
}

/// One finger: drag the cloth (or orbit when you miss it) · tap a pin to remove it · long-press to pin ·
/// pinch to zoom · two fingers to pan · double-tap to reset the view.
struct ClothMetalView: UIViewRepresentable {
    let dir: URL
    let versoDir: URL?
    let sampleSize: SIMD2<Float>
    let model: ClothModel
    // plain values so SwiftUI calls updateUIView when they change
    var settings: ClothSettings
    var tool: ClothTool
    var mode: ViewerModel.Mode
    var gain: Float
    var paused: Bool
    var recenter: Int
    var resetCloth: Int
    var resetCamera: Int
    var exportRequest: Int

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: ClothRenderer?
        var model: ClothModel?
        let motion = CMMotionManager()
        weak var view: MTKView?
        var last = (recenter: 0, resetCloth: 0, resetCamera: 0, export: 0)
        private var lastPan = CGPoint.zero
        private var lastPan2 = CGPoint.zero
        private var startPinch: CGFloat = 1

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let r = renderer, let v = g.view else { return }
            let p = g.location(in: v), t = g.translation(in: v)
            switch g.state {
            case .began:
                lastPan = .zero
                r.touchBegan(p)
            case .changed:
                r.touchMoved(p, delta: CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y))
                lastPan = t
            default:
                r.touchEnded(p)
            }
        }

        @objc func pan2(_ g: UIPanGestureRecognizer) {
            guard let r = renderer, let v = g.view else { return }
            let t = g.translation(in: v)
            if g.state == .began { lastPan2 = .zero }
            r.pan2(delta: CGPoint(x: t.x - lastPan2.x, y: t.y - lastPan2.y))
            lastPan2 = t
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let r = renderer else { return }
            if g.state == .began { startPinch = 1 }
            r.pinch(scale: Float(g.scale / startPinch))
            startPinch = g.scale
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            renderer?.tap(g.location(in: v))
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) { renderer?.resetCamera() }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let v = g.view else { return }
            renderer?.longPress(g.location(in: v))
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && o is UIPanGestureRecognizer) || (o is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
        }

        func setMotion(_ on: Bool) {
            if on == motion.isDeviceMotionActive { return }
            if on, motion.isDeviceMotionAvailable {
                motion.deviceMotionUpdateInterval = 1.0 / 60.0
                motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
                    guard let self, let m, let r = self.renderer else { return }
                    let d = SIMD3<Float>(Float(m.gravity.x), Float(m.gravity.y), Float(m.gravity.z))
                    let s: SIMD3<Float>
                    switch self.view?.window?.windowScene?.interfaceOrientation ?? .portrait {
                    case .landscapeLeft: s = SIMD3(d.y, -d.x, d.z)
                    case .landscapeRight: s = SIMD3(-d.y, d.x, d.z)
                    case .portraitUpsideDown: s = SIMD3(-d.x, -d.y, d.z)
                    default: s = d
                    }
                    if simd_length(s) > 0.1 { r.tiltUp = -simd_normalize(s) }
                }
            } else if !on {
                motion.stopDeviceMotionUpdates()
                renderer?.tiltUp = nil
                renderer?.recenterTilt()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.sampleCount = 4
        v.preferredFramesPerSecond = 60
        v.clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.1, alpha: 1)
        let c = context.coordinator
        c.view = v
        c.model = model
        do {
            let r = try ClothRenderer(dir: dir, settings: settings, sampleSize: sampleSize, versoDir: versoDir, view: v)
            let logStats = ProcessInfo.processInfo.arguments.contains("-log-stats")
            r.onStats = { [weak model] s in
                if logStats { print("cloth stats:", s) }
                DispatchQueue.main.async { model?.stats = s }
            }
            c.renderer = r
            v.delegate = r
            model.savePins = { [weak r] in r?.currentPins() ?? ([], "") }
        } catch {
            DispatchQueue.main.async { model.error = error.localizedDescription }
        }
        c.last = (recenter, resetCloth, resetCamera, exportRequest)
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pan2 = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan2(_:)))
        pan2.minimumNumberOfTouches = 2
        pan2.delegate = c
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = c
        let dbl = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: dbl)
        let lp = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPress(_:)))
        lp.minimumPressDuration = 0.45
        [pan, pan2, pinch, dbl, tap, lp].forEach(v.addGestureRecognizer)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        let c = context.coordinator
        guard let r = c.renderer else { return }
        r.apply(settings)
        r.tool = tool
        r.mode = mode.rawValue
        r.gain = gain
        r.paused = paused
        c.setMotion(settings.tiltMode != .off)
        if c.last.recenter != recenter { c.last.recenter = recenter; r.recenterTilt() }
        if c.last.resetCloth != resetCloth { c.last.resetCloth = resetCloth; r.resetCloth() }
        if c.last.resetCamera != resetCamera { c.last.resetCamera = resetCamera; r.resetCamera() }
        if c.last.export != exportRequest {
            c.last.export = exportRequest
            let name = "\(dir.deletingLastPathComponent().lastPathComponent) cloth"
            model.exporting = true
            DispatchQueue.main.async {
                do {
                    model.exportedURL = try r.exportUSDZ(name: name)
                } catch {
                    model.error = error.localizedDescription
                }
                model.exporting = false
            }
        }
    }

    static func dismantleUIView(_ v: MTKView, coordinator: Coordinator) {
        coordinator.motion.stopDeviceMotionUpdates()
        v.isPaused = true
    }
}
