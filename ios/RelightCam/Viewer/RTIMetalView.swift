import SwiftUI
import MetalKit
import Observation
import CoreMotion
import simd

@Observable
final class ViewerModel {
    enum Mode: Int, CaseIterable, Identifiable {
        case relight, specular, shaded, normals
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .relight: return "RTI"
            case .specular: return "Specular"
            case .shaded: return "Shaded"
            case .normals: return "Normals"
            }
        }
    }
    var light = SIMD3<Float>(0, 0, 1)
    var mode: Mode = .relight
    var gain: Float = 1
    var tilt = false
    var recenter = 0
    var error: String?
}

/// Same math as relight.js' rgb fragment shader: color = Σ_j w_j(light) · (tex_j − bias) · scale.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    const float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    return o;
}

fragment float4 fmain(VOut in [[stage_in]],
                      constant float *u [[buffer(0)]],
                      texture2d_array<float> planes [[texture(0)]],
                      texture2d<float> normals [[texture(1)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 vs = float2(u[0], u[1]);
    float2 is = float2(u[2], u[3]);
    float sc = min(vs.x / is.x, vs.y / is.y) * u[4];
    float2 origin = (vs - is * sc) * 0.5 + float2(u[5], u[6]);
    float2 uv = (in.pos.xy - origin) / (is * sc);
    if (uv.x < 0 || uv.y < 0 || uv.x > 1 || uv.y > 1) return float4(0.06, 0.06, 0.07, 1);

    int mode = int(u[7]);
    float3 L = float3(u[8], u[9], u[10]);
    int k = int(u[11]);
    float3 nrgb = normals.sample(s, uv).rgb;
    float3 n = normalize(nrgb * 2.0 - 1.0);
    if (mode == 3) return float4(nrgb, 1);
    if (mode == 2) {
        float d = max(dot(n, L), 0.0);
        return float4(float3(0.04 + 0.92 * d), 1);
    }
    float3 rgb = float3(0);
    for (int j = 0; j < k; j++) {
        float3 c = planes.sample(s, uv, uint(j)).rgb;
        float3 scl = float3(u[21 + j * 3], u[22 + j * 3], u[23 + j * 3]);
        float3 bia = float3(u[48 + j * 3], u[49 + j * 3], u[50 + j * 3]);
        rgb += u[12 + j] * (c - bia) * scl;
    }
    if (mode == 1) {
        float3 h = normalize(L + float3(0, 0, 1));
        float sp = pow(max(dot(n, h), 0.0), 24.0);
        rgb = rgb * 0.8 + float3(sp * 0.65);
    }
    return float4(saturate(rgb * u[75]), 1);
}
"""

final class RTIMetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let planes: MTLTexture
    private let normals: MTLTexture
    let info: RelightInfo
    var light = SIMD3<Float>(0, 0, 1)
    var mode = 0
    var gain: Float = 1
    var zoom: CGFloat = 1
    var pan = CGPoint.zero   // points

    init(dir: URL, view: MTKView) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else {
            throw RelightError.invalid("Metal is not available")
        }
        self.device = device
        queue = q
        info = try RelightInfo.load(from: dir)

        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "vmain")
        pd.fragmentFunction = lib.makeFunction(name: "fmain")
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: pd)

        let set = try RTITextures.load(dir: dir, device: device, queue: q)
        planes = set.planes
        normals = set.normals
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var u = [Float](repeating: 0, count: 96)
        let scale = Float(view.contentScaleFactor)
        u[0] = Float(view.drawableSize.width)
        u[1] = Float(view.drawableSize.height)
        u[2] = Float(info.width)
        u[3] = Float(info.height)
        u[4] = Float(zoom)
        u[5] = Float(pan.x) * scale
        u[6] = Float(pan.y) * scale
        u[7] = Float(mode)
        u[8] = light.x; u[9] = light.y; u[10] = light.z
        let k = info.nCoeffs
        u[11] = Float(k)
        let w = info.basis!.weights(lx: Double(light.x), ly: Double(light.y))
        for j in 0..<k { u[12 + j] = Float(w[j]) }
        let m = info.materials[0]
        for p in 0..<(3 * k) {
            u[21 + p] = Float(m.scale[p])
            u[48 + p] = Float(m.bias[p])
        }
        u[75] = gain
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: u.count * MemoryLayout<Float>.size, index: 0)
        enc.setFragmentTexture(planes, index: 0)
        enc.setFragmentTexture(normals, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

/// One finger moves the light (like relight's viewer), pinch zooms, two fingers pan, double tap resets.
struct RTIMetalView: UIViewRepresentable {
    let dir: URL
    let model: ViewerModel
    // plain values so SwiftUI re-runs updateUIView whenever they change
    var mode: ViewerModel.Mode = .relight
    var gain: Float = 1
    var light = SIMD3<Float>(0, 0, 1)
    var tilt = false
    var recenter = 0

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: RTIMetalRenderer?
        var model: ViewerModel?
        weak var view: MTKView?
        private var startZoom: CGFloat = 1
        private var lastPan = CGPoint.zero
        let motion = CMMotionManager()
        private var tiltReference: SIMD3<Double>?
        var lastRecenter = 0

        func apply(_ l: SIMD3<Float>) {
            renderer?.light = l
            model?.light = l
            view?.setNeedsDisplay()
        }

        /// Tilt mode: the light stays fixed in the room while the phone (and the object on it) tilts,
        /// like turning a coin under a lamp. The tilt angle is doubled so the screen stays readable.
        func setTilt(_ on: Bool) {
            if on == motion.isDeviceMotionActive { return }
            if on, motion.isDeviceMotionAvailable {
                tiltReference = nil
                motion.deviceMotionUpdateInterval = 1.0 / 60.0
                motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
                    if let m { self?.tilt(gravity: m.gravity) }
                }
            } else if !on {
                motion.stopDeviceMotionUpdates()
            }
        }

        func recenterTilt() { tiltReference = nil }

        private func tilt(gravity g: CMAcceleration) {
            // device axes (portrait: x right, y up) -> current screen axes
            let d = SIMD3<Double>(g.x, g.y, g.z)
            let s: SIMD3<Double>
            switch view?.window?.windowScene?.interfaceOrientation ?? .portrait {
            case .landscapeLeft: s = SIMD3(d.y, -d.x, d.z)
            case .landscapeRight: s = SIMD3(-d.y, d.x, d.z)
            case .portraitUpsideDown: s = SIMD3(-d.x, -d.y, d.z)
            default: s = d
            }
            guard simd_length(s) > 0.1 else { return }
            let up = -simd_normalize(s)
            if tiltReference == nil { tiltReference = up }
            let u0 = tiltReference!
            // minimal rotation taking the reference "up" to the current one, applied to the reference light (0,0,1)
            let axis = simd_cross(u0, up)
            let sinA = simd_length(axis)
            var L = SIMD3<Double>(0, 0, 1)
            if sinA > 1e-6 {
                let angle = min(atan2(sinA, simd_dot(u0, up)) * 2, 85 * Double.pi / 180)
                L = simd_quatd(angle: angle, axis: axis / sinA).act(L)
            }
            apply(SIMD3<Float>(Float(L.x), Float(L.y), Float(max(0, L.z))))
        }

        func setLight(at p: CGPoint, in v: UIView) {
            let R = min(v.bounds.width, v.bounds.height) * 0.45
            var x = Float((p.x - v.bounds.midX) / R)
            var y = Float(-(p.y - v.bounds.midY) / R)
            let r = (x * x + y * y).squareRoot()
            if r > 0.995 { x *= 0.995 / r; y *= 0.995 / r }
            apply(SIMD3<Float>(x, y, max(0, 1 - x * x - y * y).squareRoot()))
        }

        @objc func light(_ g: UIPanGestureRecognizer) {
            guard let v = g.view, model?.tilt != true else { return }
            setLight(at: g.location(in: v), in: v)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let r = renderer, let v = g.view else { return }
            if g.state == .began { startZoom = r.zoom }
            let newZoom = min(max(startZoom * g.scale, 1), 30)
            // keep the image point under the fingers fixed
            let a = g.location(in: v)
            let G = v.bounds.size
            let F = CGSize(width: r.info.width, height: r.info.height)
            let s0 = min(G.width / F.width, G.height / F.height)
            let s = s0 * r.zoom, s1 = s0 * newZoom
            let o = CGPoint(x: (G.width - F.width * s) / 2 + r.pan.x, y: (G.height - F.height * s) / 2 + r.pan.y)
            let p = CGPoint(x: (a.x - o.x) / s, y: (a.y - o.y) / s)
            r.pan = CGPoint(x: a.x - (G.width - F.width * s1) / 2 - p.x * s1, y: a.y - (G.height - F.height * s1) / 2 - p.y * s1)
            r.zoom = newZoom
            view?.setNeedsDisplay()
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let r = renderer, let v = g.view else { return }
            let t = g.translation(in: v)
            if g.state == .began { lastPan = .zero }
            r.pan.x += t.x - lastPan.x
            r.pan.y += t.y - lastPan.y
            lastPan = t
            view?.setNeedsDisplay()
        }

        @objc func reset(_ g: UITapGestureRecognizer) {
            renderer?.zoom = 1
            renderer?.pan = .zero
            view?.setNeedsDisplay()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer || o is UIPinchGestureRecognizer)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.framebufferOnly = true
        let c = context.coordinator
        c.view = v
        c.model = model
        do {
            let r = try RTIMetalRenderer(dir: dir, view: v)
            c.renderer = r
            v.delegate = r
        } catch {
            DispatchQueue.main.async { model.error = error.localizedDescription }
        }
        let light = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.light(_:)))
        light.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = c
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.delegate = c
        let dbl = UITapGestureRecognizer(target: c, action: #selector(Coordinator.reset(_:)))
        dbl.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapLight(_:)))
        tap.require(toFail: dbl)
        [light, pinch, pan, dbl, tap].forEach(v.addGestureRecognizer)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        let c = context.coordinator
        guard let r = c.renderer else { return }
        r.mode = mode.rawValue
        r.gain = gain
        r.light = light
        c.setTilt(tilt)
        if c.lastRecenter != recenter {
            c.lastRecenter = recenter
            c.recenterTilt()
        }
        v.setNeedsDisplay()
    }

    static func dismantleUIView(_ v: MTKView, coordinator: Coordinator) {
        coordinator.motion.stopDeviceMotionUpdates()
    }
}

extension RTIMetalView.Coordinator {
    @objc func tapLight(_ g: UITapGestureRecognizer) {
        guard let v = g.view, model?.tilt != true else { return }
        setLight(at: g.location(in: v), in: v)
    }
}
