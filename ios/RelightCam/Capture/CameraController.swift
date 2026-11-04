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

    func setLocked(_ lock: Bool) {
        captureRotation = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        isLocked = lock
        sessionQueue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            if lock {
                if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
            } else {
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
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

    /// `point` in device coordinates (0…1, from the preview layer).
    func focus(at point: CGPoint) {
        guard !isLocked else { return }
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
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        latestBuffer = pb
        bufferLock.unlock()
    }

    /// Saves the most recent frame as a JPEG. Returns false when no frame is available yet.
    @discardableResult
    func capture() -> Bool {
        bufferLock.lock()
        let pb = latestBuffer
        bufferLock.unlock()
        guard let pb, let dir = framesDir else { return false }
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
        return true
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
