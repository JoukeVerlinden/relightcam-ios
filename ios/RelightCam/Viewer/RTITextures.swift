import Foundation
import Metal
import simd

/// GPU copies of a relight rgb PTM/HSH folder, shared by the 2D viewer and the 3D cloth viewer.
struct RTITextureSet {
    let info: RelightInfo
    let planes: MTLTexture    // 2D array, one slice per coefficient (RGB = coefficient for R, G, B)
    let normals: MTLTexture
}

enum RTITextures {
    static func load(dir: URL, device: MTLDevice, queue: MTLCommandQueue) throws -> RTITextureSet {
        let info = try RelightInfo.load(from: dir)
        let W = info.width, H = info.height, k = info.nCoeffs
        let td = MTLTextureDescriptor()
        td.textureType = .type2DArray
        td.pixelFormat = .rgba8Unorm
        td.width = W
        td.height = H
        td.arrayLength = k
        td.mipmapLevelCount = Int(log2(Double(max(W, H)))) + 1
        td.usage = .shaderRead
        guard let planes = device.makeTexture(descriptor: td) else { throw RelightError.invalid("Out of GPU memory") }
        for j in 0..<k {
            guard let img = ImageUtils.load(dir.appendingPathComponent("plane_\(j).\(info.format)")) else {
                throw RelightError.io("Missing plane_\(j)")
            }
            let px = ImageUtils.rgba(img, width: W, height: H)
            px.withUnsafeBytes {
                planes.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, slice: j,
                               withBytes: $0.baseAddress!, bytesPerRow: W * 4, bytesPerImage: W * H * 4)
            }
        }
        let nd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: true)
        nd.usage = .shaderRead
        guard let normals = device.makeTexture(descriptor: nd) else { throw RelightError.invalid("Out of GPU memory") }
        var npx = [UInt8](repeating: 0, count: W * H * 4)
        if let nimg = ImageUtils.load(dir.appendingPathComponent("normals.png")) {
            npx = ImageUtils.rgba(nimg, width: W, height: H)
        } else {
            for i in 0..<(W * H) { npx[i * 4] = 128; npx[i * 4 + 1] = 128; npx[i * 4 + 2] = 255; npx[i * 4 + 3] = 255 }
        }
        npx.withUnsafeBytes {
            normals.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: W * 4)
        }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: planes)
            blit.generateMipmaps(for: normals)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return RTITextureSet(info: info, planes: planes, normals: normals)
    }

    /// Cutout mask (rti/mask.png, white = textile). Returns the texture and a CPU lookup.
    static func mask(dir: URL, device: MTLDevice) -> (texture: MTLTexture?, lookup: ((SIMD2<Float>) -> Bool)?) {
        guard let img = ImageUtils.load(dir.appendingPathComponent("mask.png")) else { return (nil, nil) }
        let W = img.width, H = img.height
        let px = ImageUtils.rgba(img, width: W, height: H)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
        d.usage = .shaderRead
        let tex = device.makeTexture(descriptor: d)
        px.withUnsafeBytes { tex?.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: W * 4) }
        let lookup: (SIMD2<Float>) -> Bool = { uv in
            let x = min(W - 1, max(0, Int(uv.x * Float(W)))), y = min(H - 1, max(0, Int(uv.y * Float(H))))
            return px[(y * W + x) * 4] > 127
        }
        return (tex, lookup)
    }

    static func solid(device: MTLDevice, value: UInt8 = 255) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)
        var px: [UInt8] = [value, value, value, 255]
        t?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return t
    }
}
