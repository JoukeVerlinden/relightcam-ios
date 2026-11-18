import AVFoundation
import CoreImage
import UIKit
import Observation

/// Grabs full-resolution frames from the video pipeline. For RTI every photo must share the same
/// focus, exposure and white balance, so frames are only taken while those are locked.
@Observable
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Lens: String, CaseIterable, Identifiable {
        case ultraWide = "0.5×", wide = "1×", tele = "Tele"
        var id: String { rawValue }
        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            case .ultraWide: return .builtInUltraWideCamera
            case .wide: return .builtInWideAngleCamera
            case .tele: return .builtInTelephotoCamera
            }
        }
    }

    enum Status: Equatable { case idle, running, denied, failed(String) }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "relightcam.session")
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "relightcam.video")
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "relightcam.save")
    @ObservationIgnored private let bufferLock = NSLock()
    @ObservationIgnored private var latestBuffer: CVPixelBuffer?
    @ObservationIgnored private var latestPTS = CMTime.invalid
    @ObservationIgnored private var frameCount = 0
    /// light dome: what the last frame wait saw, for the message after a failed run
    @ObservationIgnored private(set) var lastFrameWait = ""
    @ObservationIgnored private let ciContext = CIContext()
    @ObservationIgnored private var input: AVCaptureDeviceInput?
    @ObservationIgnored private let output = AVCaptureVideoDataOutput()
    @ObservationIgnored private(set) var device: AVCaptureDevice?
    @ObservationIgnored var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var captureRotation: CGFloat = 90
    @ObservationIgnored var framesDir: URL?
    @ObservationIgnored var nextIndex = 0
    @ObservationIgnored var onSaved: ((String, Int, Int) -> Void)?

    var status: Status = .idle
    var availableLenses: [Lens] = []
    var lens: Lens = .wide
    var isLocked = false
    var exposureBias: Float = 0
    var resolutionText = ""
    var exposureText = ""
    var pendingSaves = 0
    var lastThumbnail: UIImage?
    var deviceVersion = 0
    /// zoom relative to the 1× (wide) camera, as in the Camera app: 0.5 = ultra wide
    var zoom: CGFloat = 1
    private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    /// lens position 0 (closest) … 1 (far); follows autofocus until set by hand
    var lensPosition: Float = 0.5
    /// focus set with the slider instead of autofocus
    private(set) var manualFocus = false
    /// each lens's zoom (0.5, 1, 2…5), measured from the cameras' fields of view
    @ObservationIgnored private var lensBase: [Lens: CGFloat] = [:]

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.configure() : (self.status = .denied) }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func select(_ newLens: Lens) {
        guard newLens != lens else { return }
        lens = newLens
        isLocked = false
        sessionQueue.async { self.setupSession(lens: newLens) }
    }

    private func configure() {
        let lenses = Lens.allCases.filter { AVCaptureDevice.default($0.deviceType, for: .video, position: .back) != nil }
        availableLenses = lenses
        guard !lenses.isEmpty else {
            status = .failed("No camera available on this device.")
            return
        }
        if !lenses.contains(lens) { lens = lenses.contains(.wide) ? .wide : lenses[0] }
        // each lens's zoom from its field of view (same 4:3 format on all of them)
        func fov(_ l: Lens) -> CGFloat? {
            guard let d = AVCaptureDevice.default(l.deviceType, for: .video, position: .back),
                  let f = Self.bestFormat(d) else { return nil }
            return CGFloat(f.videoFieldOfView)
        }
        let ref = fov(.wide) ?? fov(lenses[0]) ?? 70
        var bases: [Lens: CGFloat] = [:]
        for l in lenses {
            if let f = fov(l), f > 0 {
                let b = tan(ref / 2 * .pi / 180) / tan(f / 2 * .pi / 180)
                bases[l] = (b * 10).rounded() / 10   // 0.5, 1, 2.5, 3, 5…
            } else {
                bases[l] = l == .ultraWide ? 0.5 : l == .wide ? 1 : 3
            }
        }
        lensBase = bases
        let lo = bases.values.min() ?? 1, hi = bases.values.max() ?? 1
        zoomRange = lo...min(15, max(hi * 4, 4))
        zoom = bases[lens] ?? 1
        #if DEBUG
        print("[zoom] lenses: \(lenses.map { "\($0.rawValue)=\(bases[$0] ?? 0)" }), range \(zoomRange)")
        #endif
        let l = lens
        sessionQueue.async { self.setupSession(lens: l) }
    }

    private func setupSession(lens: Lens) {
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        guard let dev = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
              let inp = try? AVCaptureDeviceInput(device: dev), session.canAddInput(inp) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.status = .failed("Could not open the \(lens.rawValue) camera.") }
            return
        }
        session.addInput(inp)
        input = inp
        device = dev
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.sessionPreset = .inputPriority
        if let best = Self.bestFormat(dev), (try? dev.lockForConfiguration()) != nil {
            dev.activeFormat = best
            if best.isVideoHDRSupported {
                dev.automaticallyAdjustsVideoHDREnabled = false
                dev.isVideoHDREnabled = false
            }
            if dev.isLowLightBoostSupported { dev.automaticallyEnablesLowLightBoostWhenAvailable = false }
            dev.unlockForConfiguration()
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        DispatchQueue.main.async {
            self.status = .running
            self.resolutionText = "\(dims.width)×\(dims.height)"
            self.isLocked = false
            self.exposureBias = 0
            self.manualFocus = false
            self.deviceVersion += 1
        }
    }

    /// Largest 8-bit 4:2:0 format (≈12 MP 4:3 on recent iPhones), so frames are as sharp as photos.
    static func bestFormat(_ dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let ok: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        func px(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        return dev.formats.filter { f in
            ok.contains(CMFormatDescriptionGetMediaSubType(f.formatDescription)) &&
                (f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) >= 10
        }.max { a, b in
            if px(a) != px(b) { return px(a) < px(b) }
            return CMFormatDescriptionGetMediaSubType(a.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    func base(_ l: Lens) -> CGFloat { lensBase[l] ?? 1 }

    /// "0.5×", "1×", "2.3×"
    static func zoomLabel(_ z: CGFloat) -> String {
        let r = (z * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))×" : String(format: "%.1f×", r)
    }

    /// Pinch or preset zoom: picks the longest lens that covers `z` and zooms digitally on it. Moving up to a
    /// longer lens waits until 3 % past its zoom, so a pinch near the boundary doesn't flip between lenses.
    /// `snap`: a lens preset, which goes straight to that lens (no 3 % margin).
    func setZoom(_ target: CGFloat, snap: Bool = false) {
        guard !availableLenses.isEmpty else { return }
        let z = min(max(target, zoomRange.lowerBound), zoomRange.upperBound)
        zoom = z
        let sorted = availableLenses.sorted { base($0) < base($1) }
        var pick = sorted[0]
        for l in sorted where base(l) <= z + 0.001 { pick = l }
        if !snap, pick != lens, base(pick) > base(lens), base(lens) <= z, z < base(pick) * 1.03 { pick = lens }
        if pick != lens { select(pick) }   // reconfigures the session; the zoom below is queued after it
        let b = base(pick)
        sessionQueue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            let f = min(max(z / b, 1), min(dev.maxAvailableVideoZoomFactor, 16))
            dev.videoZoomFactor = f
            dev.unlockForConfiguration()
            #if DEBUG
            print(String(format: "[zoom] %.2fx: %@ lens, factor %.2f", z, pick.rawValue, f))
            #endif
        }
    }

    func setLocked(_ lock: Bool) {
        captureRotation = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        isLocked = lock
        sessionQueue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            if lock {
                if dev.isFocusModeSupported(.locked) && dev.focusMode != .locked { dev.focusMode = .locked }
                if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
            } else {
                // a focus set by hand stays; otherwise back to autofocus
                if !self.manualFocus && dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
            dev.unlockForConfiguration()
        }
    }

    func setBias(_ b: Float) {
        exposureBias = b
        sessionQueue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            dev.setExposureTargetBias(min(max(b, dev.minExposureTargetBias), dev.maxExposureTargetBias))
            dev.unlockForConfiguration()
        }
    }

    /// Manual focus: 0 = closest, 1 = far.
    func setFocus(_ p: Float) {
        guard !isLocked else { return }
        let p = min(max(p, 0), 1)
        lensPosition = p
        manualFocus = true
        sessionQueue.async {
            guard let dev = self.device, dev.isLockingFocusWithCustomLensPositionSupported,
                  (try? dev.lockForConfiguration()) != nil else { return }
            dev.setFocusModeLocked(lensPosition: p, completionHandler: nil)
            dev.unlockForConfiguration()
        }
    }

    /// `point` in device coordinates (0…1, from the preview layer; these follow the zoom, like the preview).
    /// Back to autofocus at that point.
    func focus(at point: CGPoint) {
        guard !isLocked else { return }
        manualFocus = false
        sessionQueue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = point; dev.focusMode = .autoFocus }
            if dev.isExposurePointOfInterestSupported { dev.exposurePointOfInterest = point; dev.exposureMode = .continuousAutoExposure }
            dev.unlockForConfiguration()
        }
    }

    func refreshExposureText() {
        guard let dev = device else { return }
        let t = CMTimeGetSeconds(dev.exposureDuration)
        let shutter = t >= 0.5 ? String(format: "%.1f s", t) : "1/\(Int((1 / max(t, 1e-6)).rounded())) s"
        exposureText = "ISO \(Int(dev.iso.rounded())) · \(shutter)"
        if !manualFocus { lensPosition = dev.lensPosition }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        bufferLock.lock()
        latestBuffer = pb
        latestPTS = pts
        frameCount += 1
        bufferLock.unlock()
    }

    private func newestFrame() -> (time: CMTime, count: Int) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return (latestPTS, frameCount)
    }

    /// For the light dome: waits until a frame arrives whose exposure began after this call, so a light
    /// switched on before the call is in it. The timestamp may mark the start or the middle of the
    /// exposure, so the exposure time is added to be safe. If the frame timestamps can't be compared with
    /// the clock, the third frame that arrives after the call is used instead (by then the camera
    /// pipeline holds no frame exposed before the call). Returns false after `timeout` seconds.
    @MainActor
    func waitForFreshFrame(timeout: Double = 3) async -> Bool {
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        var exposure = device?.exposureDuration ?? CMTime(value: 1, timescale: 30)
        if !exposure.isValid { exposure = CMTime(value: 1, timescale: 30) }
        let now = CMClockGetTime(clock)
        let after = CMTimeAdd(now, exposure)
        let start = newestFrame()
        let began = Date()
        while Date().timeIntervalSince(began) < timeout && !Task.isCancelled {
            let f = newestFrame()
            if f.time.isValid && CMTimeCompare(f.time, after) >= 0 { lastFrameWait = "ok"; return true }
            if f.count - start.count >= 3 {
                lastFrameWait = String(format: "used frame count (frame time %.3f s, clock %.3f s)",
                                       CMTimeGetSeconds(f.time), CMTimeGetSeconds(now))
                return true
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
        let f = newestFrame()
        lastFrameWait = String(format: "%d new frames in %.1f s; frame time %.3f s, clock %.3f s, exposure %.3f s",
                               f.count - start.count, timeout, CMTimeGetSeconds(f.time),
                               CMTimeGetSeconds(now), CMTimeGetSeconds(exposure))
        return false
    }

    /// Waits until at most `n` photos are still being written, so held camera buffers can't run out.
    @MainActor
    func waitForSaves(max n: Int) async {
        while pendingSaves > n && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Saves the most recent frame as a JPEG. Returns its file name, or nil when no frame is available yet.
    @discardableResult
    func capture() -> String? {
        bufferLock.lock()
        let pb = latestBuffer
        bufferLock.unlock()
        guard let pb, let dir = framesDir else { return nil }
        let name = String(format: "frame_%03d.jpg", nextIndex)
        nextIndex += 1
        let orientation = Self.orientation(for: captureRotation)
        pendingSaves += 1
        saveQueue.async {
            let img = CIImage(cvPixelBuffer: pb).oriented(orientation)
            let ext = img.extent
            var thumb: UIImage?
            var ok = true
            do {
                try self.ciContext.writeJPEGRepresentation(
                    of: img, to: dir.appendingPathComponent(name), colorSpace: ImageUtils.sRGB,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.93])
                let s = 200 / max(ext.width, ext.height)
                let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
                if let cg = self.ciContext.createCGImage(small, from: small.extent) { thumb = UIImage(cgImage: cg) }
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                self.pendingSaves -= 1
                if ok {
                    self.lastThumbnail = thumb
                    self.onSaved?(name, Int(ext.width), Int(ext.height))
                }
            }
        }
        return name
    }

    static func orientation(for angle: CGFloat) -> CGImagePropertyOrientation {
        switch (Int(angle.rounded()) % 360 + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }
}
