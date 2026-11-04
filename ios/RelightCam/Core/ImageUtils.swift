import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Small CoreGraphics / ImageIO helpers shared by capture, detection and fitting.
/// Deliberately UIKit-free so the processing core also compiles for macOS tests.
enum ImageUtils {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Pixel size of an image file after applying its EXIF orientation.
    static func orientedSize(of url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return o >= 5 ? (h, w) : (w, h)
    }

    /// Decodes an image with its orientation applied. `maxPixel == nil` decodes at full size.
    static func load(_ url: URL, maxPixel: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var size = maxPixel
        if size == nil, let s = orientedSize(of: url) { size = max(s.width, s.height) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size ?? 4096,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Renders `image` (or the `crop` rectangle of it, top-left origin) into a width×height RGBX8 buffer.
    static func rgba(_ image: CGImage, width: Int, height: Int, crop: CGRect? = nil) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        var src = image
        if let crop, let c = image.cropping(to: crop.integral) { src = c }
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buf
    }

    static func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg, quality: Double = 0.92) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw RelightError.io("Cannot create \(url.lastPathComponent)")
        }
        var props: [CFString: Any] = [:]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw RelightError.io("Cannot write \(url.lastPathComponent)") }
    }

    /// Integer working size that fits in `maxSide`, never upscaling.
    static func fit(width: Int, height: Int, maxSide: Int) -> (Int, Int) {
        let s = min(1.0, Double(maxSide) / Double(max(width, height)))
        return (max(1, Int((Double(width) * s).rounded())), max(1, Int((Double(height) * s).rounded())))
    }
}

enum RelightError: LocalizedError {
    case io(String)
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .io(let s), .invalid(let s): return s
        }
    }
}
