import MetalKit
import ARKit
import simd

extension simd_float4x4 {
    /// Right-handed perspective with Metal's 0…1 depth.
    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovy * 0.5), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye), s = simd_normalize(simd_cross(f, up)), u = simd_cross(s, f)
        return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                                       SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(v, 1)
        return m
    }

    static func rotationY(_ a: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(cos(a), 0, -sin(a), 0), SIMD4(0, 1, 0, 0), SIMD4(sin(a), 0, cos(a), 0), SIMD4(0, 0, 0, 1)))
    }

    static func rotationX(_ a: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cos(a), sin(a), 0), SIMD4(0, -sin(a), cos(a), 0), SIMD4(0, 0, 0, 1)))
    }

    static func scale(_ k: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(k, k, k, 1))
    }

    static func ortho(_ l: Float, _ r: Float, _ b: Float, _ t: Float, _ n: Float, _ f: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(2 / (r - l), 0, 0, 0), SIMD4(0, 2 / (t - b), 0, 0), SIMD4(0, 0, -1 / (f - n), 0),
                                SIMD4(-(r + l) / (r - l), -(t + b) / (t - b), -n / (f - n), 1)))
    }
}

/// 3D cloth viewer: XPBD cloth + per-fragment RTI relighting in the cloth's local frame, with shadows.
final class ClothRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var clothPipeline: MTLRenderPipelineState!
    private var propPipeline: MTLRenderPipelineState!
    private var pinPipeline: MTLRenderPipelineState!
    private var shadowClothPipeline: MTLRenderPipelineState!
    private var shadowPropPipeline: MTLRenderPipelineState!
    private var depthLess: MTLDepthStencilState!
    private var depthAlways: MTLDepthStencilState!
    private let shadowTex: MTLTexture
    private let front: RTITextureSet
    private var verso: RTITextureSet?
    private let maskTex: MTLTexture
    private let maskLookup: ((SIMD2<Float>) -> Bool)?
    private let white: MTLTexture
    let rtiDir: URL
    let sampleSize: SIMD2<Float>

    private(set) var scene: ClothScene
    private(set) var settings: ClothSettings
    private var sceneKey = ""
    var mode = 0
    var gain: Float = 1
    var tool: ClothTool = .move
    var paused = false

    // camera
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 1
    var yaw: Float = 0
    var pitch: Float = 0
    private var walkBase: (yaw: Float, pitch: Float)?

    // light and tilt
    private var orbitAngle: Float = 0
    private(set) var lightWorld = SIMD3<Float>(0, 0, 1)
    var tiltUp: SIMD3<Float>?           // current "up" in screen coordinates from CoreMotion
    private var tiltRef: SIMD3<Float>?

    // buffers
    private var vbuffers: [MTLBuffer] = []
    private var vIndex = 0
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var props: [(vb: MTLBuffer, ib: MTLBuffer, count: Int, color: SIMD4<Float>, floor: Bool)] = []

    // AR: the same cloth and renderer over the camera image, anchored on a real surface
    private(set) var arSession: ARSession?
    private var textureCache: CVMetalTextureCache?
    private var bgPipeline: MTLRenderPipelineState!
    private var catcherPipeline: MTLRenderPipelineState!
    private var arAnchor: simd_float4x4?
    var arYaw: Float = 0
    var arScale: Float = 1
    private var arModel = matrix_identity_float4x4
    var onARHint: ((String?) -> Void)?
    private var lastHint: String?? = .none
    var isAR: Bool { arSession != nil }
    private var pinBuffer: MTLBuffer?
    private let inflight = DispatchSemaphore(value: 3)
    private var lastTime = CACurrentMediaTime()
    private var lastViewProj = matrix_identity_float4x4
    private var viewSize = CGSize(width: 1, height: 1)
    private var frameTimes: [Double] = []
    var onStats: ((String) -> Void)?

    // The simulation runs on its own serial queue; the main thread draws the latest finished step.
    // Main-thread code never touches the simulation directly: it queues operations on `simQueue` and
    // reads positions from `snapshot`.
    private let simQueue = DispatchQueue(label: "relightcam.cloth.sim", qos: .userInteractive)
    private var simInFlight = false
    private struct Snapshot {
        var verts: [SIMD4<Float>]       // per particle: position, normal, tangent, panel
        var pinIndices: Set<Int>
        var pinPositions: [SIMD3<Float>]
        var ms: Double
    }
    private var snapshot: Snapshot?
    private var grabTarget: SIMD3<Float>?
    private var gravity = SIMD3<Float>(0, -9.81, 0)
    private var pendingRebuild: (time: CFTimeInterval, resetCamera: Bool)?

    private static func makeSnapshot(_ sim: ClothSimulation, ms: Double) -> Snapshot {
        let (N, T) = sim.frames()
        var v = [SIMD4<Float>](repeating: .zero, count: sim.count * 4)
        for i in 0..<sim.count {
            v[i * 4] = SIMD4(sim.pos[i], 1)
            v[i * 4 + 1] = SIMD4(N[i], 0)
            v[i * 4 + 2] = SIMD4(T[i], 0)
            v[i * 4 + 3] = SIMD4(sim.panel[i].x, sim.panel[i].y, 0, 0)
        }
        let keys = Array(sim.pins.keys)
        return Snapshot(verts: v, pinIndices: Set(keys), pinPositions: keys.map { sim.pos[$0] }, ms: ms)
    }

    private func snapshotPos(_ i: Int) -> SIMD3<Float> {
        guard let s = snapshot, i * 4 < s.verts.count else { return .zero }
        let v = s.verts[i * 4]
        return SIMD3(v.x, v.y, v.z)
    }

    /// Runs `op` on the simulation thread, in order with the steps.
    private func simOp(_ op: @escaping (ClothSimulation) -> Void) {
        let sim = scene.sim
        simQueue.async { op(sim) }
    }

    private func kickSimulation(dt: Float) {
        guard !simInFlight else { return }
        simInFlight = true
        let sim = scene.sim
        let g = gravity, target = grabTarget, run = !paused
        simQueue.async { [weak self] in
            let t0 = CACurrentMediaTime()
            sim.gravity = g
            if let target { sim.moveGrab(to: target) }
            if run { sim.step(dt: dt) }
            let ms = run ? (CACurrentMediaTime() - t0) * 1000 : 0
            let snap = Self.makeSnapshot(sim, ms: ms)
            DispatchQueue.main.async {
                guard let self else { return }
                self.simInFlight = false
                if sim === self.scene.sim { self.snapshot = snap }
            }
        }
    }

    init(dir: URL, settings: ClothSettings, sampleSize: SIMD2<Float>, versoDir: URL?, view: MTKView) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else {
            throw RelightError.invalid("Metal is not available")
        }
        self.device = device
        queue = q
        rtiDir = dir
        self.sampleSize = sampleSize
        self.settings = settings
        front = try RTITextures.load(dir: dir, device: device, queue: q)
        if let versoDir { verso = try? RTITextures.load(dir: versoDir, device: device, queue: q) }
        let m = RTITextures.mask(dir: dir, device: device)
        guard let w = RTITextures.solid(device: device) else { throw RelightError.invalid("Out of GPU memory") }
        white = w
        maskTex = m.texture ?? w
        maskLookup = m.lookup
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        guard let st = device.makeTexture(descriptor: sd) else { throw RelightError.invalid("Out of GPU memory") }
        shadowTex = st
        scene = ClothScene.make(settings: settings, sampleSize: sampleSize, mask: maskLookup)
        super.init()
        try buildPipelines(view: view)
        installScene(resetCamera: true)
        sceneKey = Self.key(settings)
    }

    private func buildPipelines(view: MTKView) throws {
        let lib = try device.makeLibrary(source: clothShaderSource, options: nil)
        func pipe(_ vs: String, _ fs: String?, color: Bool, samples: Int) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = fs.flatMap { lib.makeFunction(name: $0) }
            if color { d.colorAttachments[0].pixelFormat = view.colorPixelFormat }
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = samples
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let n = view.sampleCount
        clothPipeline = try pipe("clothVS", "clothFS", color: true, samples: n)
        propPipeline = try pipe("propVS", "propFS", color: true, samples: n)
        pinPipeline = try pipe("pinVS", "pinFS", color: true, samples: n)
        shadowClothPipeline = try pipe("clothShadowVS", nil, color: false, samples: 1)
        shadowPropPipeline = try pipe("propShadowVS", nil, color: false, samples: 1)
        bgPipeline = try pipe("bgVS", "bgFS", color: true, samples: n)
        let cd = MTLRenderPipelineDescriptor()
        cd.vertexFunction = lib.makeFunction(name: "propVS")
        cd.fragmentFunction = lib.makeFunction(name: "catcherFS")
        cd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        cd.colorAttachments[0].isBlendingEnabled = true
        cd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        cd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        cd.colorAttachments[0].sourceAlphaBlendFactor = .one
        cd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        cd.depthAttachmentPixelFormat = .depth32Float
        cd.rasterSampleCount = n
        catcherPipeline = try device.makeRenderPipelineState(descriptor: cd)
        let dl = MTLDepthStencilDescriptor()
        dl.depthCompareFunction = .less
        dl.isDepthWriteEnabled = true
        depthLess = device.makeDepthStencilState(descriptor: dl)
        let da = MTLDepthStencilDescriptor()
        da.depthCompareFunction = .always
        da.isDepthWriteEnabled = false
        depthAlways = device.makeDepthStencilState(descriptor: da)
    }

    static func key(_ s: ClothSettings) -> String {
        "\(s.support)|\(s.material)|\(s.form)|\(s.grainAngle)|\(s.tiling)|\(s.panelWidth)|\(s.panelHeight)|\(s.repeatRect)|\(s.useMask)|\(s.selfCollision)|\(s.sampleWidthOverride ?? 0)"
    }

    /// Applies new settings; rebuilds the cloth when the scene itself changed.
    func apply(_ s: ClothSettings) {
        let k = Self.key(s)
        let supportChanged = s.support != settings.support || s.form != settings.form
        settings = s
        if k != sceneKey {
            sceneKey = k
            // a new support rebuilds at once; slider drags (panel size, grain) wait until they settle
            let reset = supportChanged || (pendingRebuild?.resetCamera ?? false)
            pendingRebuild = (supportChanged ? 0 : CACurrentMediaTime(), reset)
        }
        if s.tiltMode != .walkAround { walkBase = nil }
    }

    func resetCloth() {
        var s = settings
        s.pins = []
        s.pinsKey = ""
        settings = s
        scene = ClothScene.make(settings: s, sampleSize: sampleSize, mask: maskLookup)
        installScene(resetCamera: false)
    }

    func resetCamera() {
        arYaw = 0
        arScale = 1
        target = scene.cameraTarget
        distance = scene.cameraDistance
        yaw = scene.cameraYaw
        pitch = scene.cameraPitch
        walkBase = nil
        needsFit = true
    }

    /// The title bar covers the top ~11% of the screen and the controls the bottom ~38%:
    /// fit the scene into the band between them.
    var topInset: Float = 0.11
    var bottomInset: Float = 0.38
    private var needsFit = true

    private func fitCamera(aspect: Float) {
        let t = tan(Float(0.75) / 2)
        let band = 1 - topInset - bottomInset
        let halfV = max(scene.fitHalf.y / band, scene.fitHalf.x / max(0.1, aspect)) * 1.04
        distance = halfV / t
        // shift the target so the scene's centre lands in the middle of the visible band
        let bandCentre = ((1 - 2 * topInset) + (-1 + 2 * bottomInset)) / 2   // in NDC
        let C = cameraBasis()
        target = scene.cameraTarget - C.columns.1 * (bandCentre * halfV)
        needsFit = false
    }

    func recenterTilt() {
        tiltRef = nil
        walkBase = nil
    }

    /// Pins as stored in the project (only restored for the same scene layout).
    func currentPins() -> (pins: [ClothPin], key: String) {
        let sim = scene.sim, key = scene.pinsKey
        let pins = simQueue.sync { sim.pins.map { ClothPin(particle: $0.key, x: $0.value.x, y: $0.value.y, z: $0.value.z) } }
        return (pins, key)
    }

    private func installScene(resetCamera reset: Bool) {
        let sim = scene.sim
        let len = sim.count * MemoryLayout<SIMD4<Float>>.stride * 4
        vbuffers = (0..<3).compactMap { _ in device.makeBuffer(length: len, options: .storageModeShared) }
        let idx = sim.triangleIndices()
        indexCount = idx.count
        indexBuffer = idx.isEmpty ? nil : device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared)
        props = scene.props.compactMap { p in
            var v: [SIMD4<Float>] = []
            for i in 0..<p.positions.count {
                v.append(SIMD4(p.positions[i], 1))
                v.append(SIMD4(p.normals[i], 0))
            }
            guard let vb = device.makeBuffer(bytes: v, length: v.count * 16, options: .storageModeShared),
                  let ib = device.makeBuffer(bytes: p.indices, length: p.indices.count * 4, options: .storageModeShared) else { return nil }
            return (vb, ib, p.indices.count, SIMD4(p.color, 1), !p.exportable)
        }
        pinBuffer = device.makeBuffer(length: 512 * 16, options: .storageModeShared)
        grabTarget = nil
        drag = .none
        snapshot = Self.makeSnapshot(sim, ms: 0)   // the new sim isn't running yet, so this is safe here
        if reset { resetCamera() }
    }

    // MARK: AR

    /// Starts world tracking; the scene is placed on the first horizontal surface found at the screen centre.
    func startAR() -> Bool {
        guard ARWorldTrackingConfiguration.isSupported else { return false }
        let session = ARSession()
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        session.run(config)
        arSession = session
        arAnchor = nil
        arYaw = 0
        arScale = 1
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        return true
    }

    func stopAR() {
        arSession?.pause()
        arSession = nil
        arAnchor = nil
        textureCache = nil
        needsFit = true
        reportHint(nil)
    }

    private func reportHint(_ h: String?) {
        if case .some(let last) = lastHint, last == h { return }
        lastHint = .some(h)
        onARHint?(h)
    }

    /// How each support stands in the room: a board lies flat like a sample on a table, free cloth hangs from
    /// its pins in the air, the dress form stands on the floor.
    private func supportTransform() -> simd_float4x4 {
        switch settings.support {
        case .board: return .translation(SIMD3(0, 0.006, 0)) * .rotationX(-.pi / 2)
        case .free: return .translation(SIMD3(0, scene.panelSize.y * 0.5 + 0.15, 0))
        case .dressForm: return matrix_identity_float4x4
        }
    }

    /// Places the scene where a ray through `imagePoint` (normalized image coordinates) hits a horizontal surface.
    @discardableResult
    private func placeAR(frame: ARFrame, imagePoint: CGPoint) -> Bool {
        guard let session = arSession else { return false }
        let q = frame.raycastQuery(from: imagePoint, allowing: .estimatedPlane, alignment: .horizontal)
        guard let hit = session.raycast(q).first else { return false }
        let p = hit.worldTransform.columns.3
        let cam = frame.camera.transform.columns.3
        let facing = atan2(cam.x - p.x, cam.z - p.z)   // the scene's front (+z) faces the camera
        arAnchor = .translation(SIMD3(p.x, p.y, p.z)) * .rotationY(facing)
        arYaw = 0
        return true
    }

    func placeAR(at screenPoint: CGPoint) {
        guard let f = arSession?.currentFrame, viewSize.width > 0 else { return }
        let orient = UIInterfaceOrientation.portrait
        let t = f.displayTransform(for: currentOrientation ?? orient, viewportSize: viewSize).inverted()
        let ip = CGPoint(x: screenPoint.x / viewSize.width, y: screenPoint.y / viewSize.height).applying(t)
        placeAR(frame: f, imagePoint: ip)
    }

    private var currentOrientation: UIInterfaceOrientation?
    private var bgQuad: [SIMD4<Float>] = []
    private var bgY: MTLTexture?
    private var bgC: MTLTexture?
    private var bgRetain: [CVMetalTexture] = []

    private func updateCamera(_ f: ARFrame, orientation: UIInterfaceOrientation) {
        let pb = f.capturedImage
        guard let cache = textureCache, CVPixelBufferGetPlaneCount(pb) >= 2 else { return }
        func tex(_ plane: Int, _ fmt: MTLPixelFormat) -> (MTLTexture?, CVMetalTexture?) {
            var cv: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, CVPixelBufferGetWidthOfPlane(pb, plane),
                                                      CVPixelBufferGetHeightOfPlane(pb, plane), plane, &cv)
            return (cv.flatMap { CVMetalTextureGetTexture($0) }, cv)
        }
        let y = tex(0, .r8Unorm), c = tex(1, .rg8Unorm)
        bgY = y.0
        bgC = c.0
        bgRetain = [y.1, c.1].compactMap { $0 }
        let t = f.displayTransform(for: orientation, viewportSize: viewSize).inverted()
        bgQuad = [(-1, -1), (1, -1), (-1, 1), (1, 1)].map { (x: Float, yy: Float) -> SIMD4<Float> in
            let uv = CGPoint(x: CGFloat((x + 1) / 2), y: CGFloat((1 - yy) / 2)).applying(t)
            return SIMD4(x, yy, Float(uv.x), Float(uv.y))
        }
    }

    // MARK: camera & light

    private func eye() -> SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * sin(yaw), -sin(pitch), cos(pitch) * cos(yaw))
    }

    /// Camera-to-world rotation (columns: right, up, back).
    private func cameraBasis() -> simd_float3x3 {
        let f = simd_normalize(target - eye())
        let r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
        let u = simd_cross(r, f)
        return simd_float3x3(columns: (r, u, -f))
    }

    /// Rotation taking the reference tilt "up" to the current one, with the angle scaled.
    private func tiltRotation(scale: Float) -> simd_quatf? {
        guard let u = tiltUp else { return nil }
        if tiltRef == nil { tiltRef = u }
        let u0 = tiltRef!
        let axis = simd_cross(u0, u)
        let s = simd_length(axis)
        if s < 1e-5 { return simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }
        let angle = min(atan2(s, simd_dot(u0, u)) * scale, 1.4)
        return simd_quatf(angle: angle, axis: axis / s)
    }

    private func updateLight(dt: Float, arEye: SIMD3<Float>? = nil) {
        let el = Float(settings.lightElevation * .pi / 180)
        var az = Float(settings.lightAzimuth * .pi / 180)
        if settings.lightMode == .orbit {
            orbitAngle += dt * 0.5
            az += orbitAngle
        }
        let C = cameraBasis()
        var L: SIMD3<Float>
        if settings.lightMode == .headlamp, let e = arEye {
            // AR: the light comes from the phone, like holding a torch
            L = e - scene.boundsCenter
        } else if settings.lightMode == .headlamp {
            L = C * SIMD3(cos(el) * cos(az), cos(el) * sin(az), sin(el))
        } else {
            let f = scene.lightFrame
            L = cos(el) * cos(az) * f.right + cos(el) * sin(az) * f.up + sin(el) * f.axis
        }
        if arEye == nil, settings.tiltMode == .room, let q = tiltRotation(scale: 2) {
            L = C * q.act(C.transpose * L)
        }
        lightWorld = simd_normalize(L)

        var g = SIMD3<Float>(0, -9.81, 0)
        if arEye == nil, settings.tiltMode == .room, let q = tiltRotation(scale: 1) {
            g = C * q.act(C.transpose * g)
        }
        gravity = g

        if arEye == nil, settings.tiltMode == .walkAround, let u = tiltUp {
            if tiltRef == nil { tiltRef = u }
            if walkBase == nil { walkBase = (yaw, pitch) }
            let u0 = tiltRef!
            let ax = atan2(u.x, u.z) - atan2(u0.x, u0.z)
            let ay = atan2(u.y, u.z) - atan2(u0.y, u0.z)
            yaw = walkBase!.yaw - ax * 1.5
            pitch = min(1.4, max(-1.4, walkBase!.pitch + ay * 1.5))
        }
    }

    // MARK: drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(1.0 / 30, max(0, now - lastTime)))
        lastTime = now
        viewSize = view.bounds.size
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        currentOrientation = orientation
        var arVP: simd_float4x4?
        var arEye: SIMD3<Float>?
        if let session = arSession, let f = session.currentFrame {
            updateCamera(f, orientation: orientation)
            if arAnchor == nil, case .normal = f.camera.trackingState {
                placeAR(frame: f, imagePoint: CGPoint(x: 0.5, y: 0.5))
            }
            if arAnchor == nil {
                reportHint("Move your iPhone slowly to find the floor or a table…")
            } else {
                reportHint("Tap a surface to move it · drag around it to turn · pinch to scale")
            }
            arModel = (arAnchor ?? .translation(SIMD3(0, -10, 0))) * .rotationY(arYaw) * .scale(arScale) * supportTransform()
            let viewM = f.camera.viewMatrix(for: orientation)
            let proj = f.camera.projectionMatrix(for: orientation, viewportSize: viewSize, zNear: 0.01, zFar: 40)
            arVP = proj * viewM * arModel
            let c4 = arModel.inverse * f.camera.transform.columns.3
            arEye = SIMD3(c4.x, c4.y, c4.z) / c4.w
        }
        updateLight(dt: dt, arEye: arEye)
        if let p = pendingRebuild, now - p.time > 0.25 {
            pendingRebuild = nil
            scene = ClothScene.make(settings: settings, sampleSize: sampleSize, mask: maskLookup)
            installScene(resetCamera: p.resetCamera)
        }
        kickSimulation(dt: dt > 0 ? dt : 1.0 / 60)
        let simMs = snapshot?.ms ?? 0

        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        inflight.wait()
        guard let cb = queue.makeCommandBuffer() else { inflight.signal(); return }
        let retained = bgRetain
        cb.addCompletedHandler { [weak self] _ in
            _ = retained   // keep the camera textures alive until the GPU is done
            self?.inflight.signal()
        }

        // vertices
        let sim = scene.sim
        let vb = vbuffers[vIndex]
        vIndex = (vIndex + 1) % vbuffers.count
        if let snap = snapshot {
            snap.verts.withUnsafeBytes { memcpy(vb.contents(), $0.baseAddress!, min($0.count, vb.length)) }
        }
        var pinCount = 0
        if let pb = pinBuffer, let snap = snapshot {
            let pp = pb.contents().bindMemory(to: SIMD4<Float>.self, capacity: 512)
            for p in snap.pinPositions where pinCount < 512 {
                pp[pinCount] = SIMD4(p, Float(16 * view.contentScaleFactor))
                pinCount += 1
            }
        }

        // matrices
        let size = view.drawableSize
        if needsFit && size.width > 0 { fitCamera(aspect: Float(size.width / max(1, size.height))) }
        let proj = simd_float4x4.perspective(fovy: 0.75, aspect: Float(size.width / max(1, size.height)), near: 0.01, far: 30)
        let e = arEye ?? eye()
        let vp = arVP ?? proj * simd_float4x4.lookAt(eye: e, target: target, up: SIMD3(0, 1, 0))
        lastViewProj = vp
        let R = scene.boundsRadius, c = scene.boundsCenter
        let L = lightWorld
        let lup: SIMD3<Float> = abs(L.y) > 0.95 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
        let lvp = simd_float4x4.ortho(-R, R, -R, R, 0.01, R * 6) * simd_float4x4.lookAt(eye: c + L * (R * 3), target: c, up: lup)

        var u = uniforms(vp: vp, lvp: lvp, eye: e)

        // shadow pass
        let spd = MTLRenderPassDescriptor()
        spd.depthAttachment.texture = shadowTex
        spd.depthAttachment.loadAction = .clear
        spd.depthAttachment.storeAction = .store
        spd.depthAttachment.clearDepth = 1
        if let enc = cb.makeRenderCommandEncoder(descriptor: spd) {
            enc.setDepthStencilState(depthLess)
            enc.setDepthBias(0.0015, slopeScale: 2.0, clamp: 0.01)
            enc.setCullMode(.none)
            enc.setVertexBytes(&u, length: u.count * 4, index: 1)
            if let ib = indexBuffer {
                enc.setRenderPipelineState(shadowClothPipeline)
                enc.setVertexBuffer(vb, offset: 0, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
            }
            enc.setRenderPipelineState(shadowPropPipeline)
            for p in props {
                enc.setVertexBuffer(p.vb, offset: 0, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: p.count, indexType: .uint32, indexBuffer: p.ib, indexBufferOffset: 0)
            }
            enc.endEncoding()
        }

        // main pass
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.1, alpha: 1)
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setDepthStencilState(depthLess)
            enc.setCullMode(.none)
            enc.setFrontFacing(.counterClockwise)
            enc.setVertexBytes(&u, length: u.count * 4, index: 1)
            enc.setFragmentBytes(&u, length: u.count * 4, index: 1)
            enc.setFragmentTexture(shadowTex, index: 3)
            if isAR, let y = bgY, let c = bgC, bgQuad.count == 4 {
                enc.setRenderPipelineState(bgPipeline)
                enc.setDepthStencilState(depthAlways)
                var quad = bgQuad
                enc.setVertexBytes(&quad, length: 64, index: 0)
                enc.setFragmentTexture(y, index: 0)
                enc.setFragmentTexture(c, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.setDepthStencilState(depthLess)
                enc.setFragmentTexture(shadowTex, index: 3)
            }
            let showScene = !isAR || arAnchor != nil
            enc.setRenderPipelineState(propPipeline)
            for p in props where showScene && !(isAR && p.floor) {
                var col = p.color
                enc.setVertexBuffer(p.vb, offset: 0, index: 0)
                enc.setFragmentBytes(&col, length: 16, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: p.count, indexType: .uint32, indexBuffer: p.ib, indexBufferOffset: 0)
            }
            if isAR && showScene {
                // real floor: only the shadows are drawn
                enc.setRenderPipelineState(catcherPipeline)
                for p in props where p.floor {
                    enc.setVertexBuffer(p.vb, offset: 0, index: 0)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: p.count, indexType: .uint32, indexBuffer: p.ib, indexBufferOffset: 0)
                }
            }
            if let ib = indexBuffer, showScene {
                enc.setRenderPipelineState(clothPipeline)
                enc.setVertexBuffer(vb, offset: 0, index: 0)
                enc.setFragmentTexture(front.planes, index: 0)
                enc.setFragmentTexture(front.normals, index: 1)
                enc.setFragmentTexture(maskTex, index: 2)
                enc.setFragmentTexture(verso?.planes ?? front.planes, index: 4)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
            }
            if pinCount > 0, showScene, let pb = pinBuffer {
                enc.setRenderPipelineState(pinPipeline)
                enc.setDepthStencilState(depthAlways)
                enc.setVertexBuffer(pb, offset: 0, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pinCount)
            }
            enc.endEncoding()
        }
        cb.present(drawable)
        cb.commit()

        frameTimes.append(now)
        if frameTimes.count > 30 { frameTimes.removeFirst(frameTimes.count - 30) }
        if frameTimes.count == 30, Int(now * 2) != Int((now - Double(dt)) * 2) {
            let fps = 29 / (frameTimes.last! - frameTimes.first!)
            let n = sim.active.filter { $0 }.count
            onStats?(String(format: "%d points · %.0f fps · sim %.1f ms", n, fps, simMs))
        }
    }

    /// Layout matches `struct U` in ClothShaders.swift (176 floats).
    private func uniforms(vp: simd_float4x4, lvp: simd_float4x4, eye: SIMD3<Float>) -> [Float] {
        var u = [Float](repeating: 0, count: 176)
        func put(_ m: simd_float4x4, _ o: Int) {
            for c in 0..<4 { for r in 0..<4 { u[o + c * 4 + r] = m[c][r] } }
        }
        put(vp, 0)
        put(lvp, 16)
        u[32] = eye.x; u[33] = eye.y; u[34] = eye.z
        u[36] = lightWorld.x; u[37] = lightWorld.y; u[38] = lightWorld.z
        let mp = scene.mapping
        u[40] = cos(mp.grainAngle); u[41] = sin(mp.grainAngle)
        u[42] = Float(ClothTiling.allCases.firstIndex(of: mp.tiling)!)
        u[44] = mp.sampleSize.x; u[45] = mp.sampleSize.y; u[46] = mp.tileSize.x; u[47] = mp.tileSize.y
        u[48] = mp.repeatRect.x; u[49] = mp.repeatRect.y; u[50] = mp.repeatRect.z; u[51] = mp.repeatRect.w
        u[52] = Float(front.info.nCoeffs)
        u[53] = front.info.basis == .hsh ? 1 : 0
        u[54] = gain
        u[55] = Float(mode)
        u[56] = settings.sheenEnabled ? 1 : 0
        u[57] = (settings.useMask && maskLookup != nil && scene.mapping.tiling == .off) ? 1 : 0
        u[58] = verso != nil ? 1 : 0
        u[59] = settings.showGrainline ? 1 : 0
        u[60] = Float(verso?.info.nCoeffs ?? 0)
        u[61] = verso?.info.basis == .hsh ? 1 : 0
        u[62] = 0.14
        u[63] = 0.0015
        let m = front.info.materials[0]
        for p in 0..<min(27, m.scale.count) { u[64 + p] = Float(m.scale[p]); u[92 + p] = Float(m.bias[p]) }
        if let v = verso?.info.materials.first {
            for p in 0..<min(27, v.scale.count) { u[120 + p] = Float(v.scale[p]); u[148 + p] = Float(v.bias[p]) }
        }
        return u
    }

    // MARK: interaction

    private func screen(_ p: SIMD3<Float>) -> (pt: CGPoint, z: Float)? {
        let c = lastViewProj * SIMD4(p, 1)
        if c.w <= 1e-5 { return nil }
        let n = SIMD3(c.x, c.y, c.z) / c.w
        return (CGPoint(x: CGFloat(n.x * 0.5 + 0.5) * viewSize.width, y: CGFloat(0.5 - n.y * 0.5) * viewSize.height), n.z)
    }

    private func unproject(_ pt: CGPoint, z: Float) -> SIMD3<Float> {
        let nx = Float(pt.x / viewSize.width) * 2 - 1, ny = 1 - Float(pt.y / viewSize.height) * 2
        let w = lastViewProj.inverse * SIMD4(nx, ny, z, 1)
        return SIMD3(w.x, w.y, w.z) / w.w
    }

    /// Front-most particle under the finger.
    func pick(_ pt: CGPoint, radius: CGFloat = 34) -> Int? {
        let sim = scene.sim
        var cands: [(Int, CGFloat, Float)] = []
        for i in 0..<sim.count where sim.active[i] {
            guard let s = screen(snapshotPos(i)) else { continue }
            let d = hypot(s.pt.x - pt.x, s.pt.y - pt.y)
            if d < radius { cands.append((i, d, s.z)) }
        }
        guard let zMin = cands.map(\.2).min() else { return nil }
        let frontLayer = cands.filter { $0.2 < zMin + (1 - zMin) * 0.02 }
        return frontLayer.min { $0.1 < $1.1 }?.0
    }

    private enum Drag { case none, orbit, arTurn, particle(Int, Float), smooth }
    private var drag: Drag = .none

    func touchBegan(_ pt: CGPoint) {
        if scene.sim.rigid { drag = isAR ? .arTurn : .orbit; return }
        if let i = pick(pt) {
            switch tool {
            case .move, .pin:
                let p = snapshotPos(i)
                let z = screen(p)?.z ?? 0.5
                grabTarget = p
                simOp { sim in
                    if sim.pins[i] != nil { sim.unpin(i) }
                    sim.grab(i, target: p)
                }
                drag = .particle(i, z)
            case .smooth:
                drag = .smooth
                smooth(at: pt)
            }
        } else {
            drag = isAR ? .arTurn : .orbit
        }
    }

    func touchMoved(_ pt: CGPoint, delta: CGPoint) {
        switch drag {
        case .arTurn:
            arYaw += Float(delta.x) * 0.01
        case .orbit:
            yaw -= Float(delta.x) * 0.008
            pitch = min(1.45, max(-1.45, pitch + Float(delta.y) * 0.006))
            walkBase = nil
        case .particle(_, let z):
            grabTarget = unproject(pt, z: z)
        case .smooth:
            smooth(at: pt)
        case .none:
            break
        }
    }

    func touchEnded(_ pt: CGPoint) {
        if case .particle(let i, let z) = drag {
            if tool == .pin {
                var p = unproject(pt, z: z)
                // drop onto the nearest support if it is close: that's how a pin goes into the form
                var best: (d: Float, n: SIMD3<Float>)?
                for c in scene.sim.colliders {
                    if let r = c.distance(p, margin: 0.05), r.d < 0.05, r.d < (best?.d ?? .infinity) { best = r }
                }
                if let b = best { p -= b.n * (b.d - scene.sim.thickness) }
                let target = p
                simOp { sim in
                    sim.release()
                    sim.pin(i, at: target)
                }
            } else {
                simOp { $0.release() }
            }
        }
        grabTarget = nil
        drag = .none
    }

    func tap(_ pt: CGPoint) {
        let hit = scene.sim.rigid ? nil : pick(pt, radius: 26)
        if hit == nil && isAR { placeAR(at: pt); return }
        guard let i = hit else { return }
        if snapshot?.pinIndices.contains(i) == true {
            simOp { $0.unpin(i) }
        } else if tool == .pin {
            let p = snapshotPos(i)
            simOp { $0.pin(i, at: p) }
        }
    }

    func longPress(_ pt: CGPoint) {
        guard !scene.sim.rigid, let i = pick(pt) else { return }
        let p = snapshotPos(i)
        simOp { $0.pin(i, at: p) }
    }

    func pinch(scale: Float) {
        if isAR { arScale = min(3, max(0.1, arScale * scale)) } else { distance = min(8, max(0.08, distance / scale)) }
    }

    func pan2(delta: CGPoint) {
        if isAR { return }
        let C = cameraBasis()
        let k = distance * 0.0016
        target += (-C.columns.0 * Float(delta.x) + C.columns.1 * Float(delta.y)) * k
    }

    private func smooth(at pt: CGPoint) {
        let sim = scene.sim
        var idx: [Int] = []
        for i in 0..<sim.count where sim.active[i] {
            guard let s = screen(snapshotPos(i)) else { continue }
            if hypot(s.pt.x - pt.x, s.pt.y - pt.y) < 40 { idx.append(i) }
        }
        simOp { $0.smooth(idx) }
    }

    // MARK: AR export

    func exportUSDZ(name: String) throws -> URL {
        // serialised with the simulation steps, so the drape can't change while it's being baked
        let scene = self.scene, settings = self.settings, lookup = maskLookup, dir = rtiDir
        return try simQueue.sync { try USDZExporter.export(scene: scene, rtiDir: dir, settings: settings, maskLookup: lookup, name: name) }
    }
}
