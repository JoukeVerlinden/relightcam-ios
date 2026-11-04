import Foundation
import CoreGraphics
import simd

/// Bakes the draped cloth (and its supports) into a USDZ for AR Quick Look. AR viewers can't evaluate an
/// RTI, so the cloth gets a PBR material: base colour = the RTI lit from straight above, normal map from
/// photometric stereo. Less faithful than the RTI viewer, but it can stand on a real table.
enum USDZExporter {
    static func export(scene: ClothScene, rtiDir: URL, settings: ClothSettings,
                       maskLookup: ((SIMD2<Float>) -> Bool)?, name: String) throws -> URL {
        let sim = scene.sim
        let planes = try RTIRenderer.loadPlanes(rtiDir)
        let W = planes.info.width, H = planes.info.height
        let base = RTIRenderer.render(planes, lx: 0, ly: 0)
        let normalsPx: [UInt8] = ImageUtils.load(rtiDir.appendingPathComponent("normals.png"))
            .map { ImageUtils.rgba($0, width: W, height: H) } ?? [UInt8](repeating: 128, count: W * H * 4)

        // Bake both maps in panel space, so tiling, mirroring and grain need no special UVs.
        let panel = scene.panelSize
        let bw = 1024, bh = max(16, Int(Float(bw) * panel.y / panel.x))
        var color = [UInt8](repeating: 0, count: bw * bh * 4)
        var normal = [UInt8](repeating: 0, count: bw * bh * 4)
        let mp = scene.mapping
        let useMask = settings.useMask && settings.tiling == .off
        func bilinear(_ px: [UInt8], _ uv: SIMD2<Float>, _ c: Int) -> Float {
            let x = min(Float(W - 1), max(0, uv.x * Float(W) - 0.5)), y = min(Float(H - 1), max(0, uv.y * Float(H) - 0.5))
            let x0 = Int(x), y0 = Int(y), x1 = min(W - 1, x0 + 1), y1 = min(H - 1, y0 + 1)
            let fx = x - Float(x0), fy = y - Float(y0)
            func v(_ xx: Int, _ yy: Int) -> Float { Float(px[(yy * W + xx) * 4 + c]) }
            return (v(x0, y0) * (1 - fx) + v(x1, y0) * fx) * (1 - fy) + (v(x0, y1) * (1 - fx) + v(x1, y1) * fx) * fy
        }
        let cg = cos(mp.grainAngle), sg = sin(mp.grainAngle)
        for by in 0..<bh {
            for bx in 0..<bw {
                let p = SIMD2((Float(bx) + 0.5) / Float(bw) - 0.5, 0.5 - (Float(by) + 0.5) / Float(bh)) * panel
                let m = mp.map(p)
                let o = (by * bw + bx) * 4
                guard m.inside, !(useMask && !(maskLookup?(m.uv) ?? true)) else { continue }
                for c in 0..<3 { color[o + c] = UInt8(bilinear(base, m.uv, c)) }
                color[o + 3] = 255
                var n = SIMD3<Float>(bilinear(normalsPx, m.uv, 0), bilinear(normalsPx, m.uv, 1), bilinear(normalsPx, m.uv, 2)) / 255 * 2 - 1
                n.x *= m.flip.x
                n.y *= m.flip.y
                let nx = cg * n.x - sg * n.y, ny = sg * n.x + cg * n.y
                normal[o] = UInt8(max(0, min(255, (nx * 0.5 + 0.5) * 255)))
                normal[o + 1] = UInt8(max(0, min(255, (ny * 0.5 + 0.5) * 255)))
                normal[o + 2] = UInt8(max(0, min(255, (n.z * 0.5 + 0.5) * 255)))
                normal[o + 3] = 255
            }
        }
        guard let colorImg = makeRGBA(color, bw, bh), let normalImg = makeRGBA(normal, bw, bh) else {
            throw RelightError.io("Could not bake textures")
        }

        // Geometry (shifted so it stands on the floor).
        var minY = Float.infinity
        for i in 0..<sim.count where sim.active[i] { minY = min(minY, sim.pos[i].y) }
        let exportProps = scene.props.filter(\.exportable)
        for p in exportProps { for v in p.positions { minY = min(minY, v.y) } }
        let lift = SIMD3<Float>(0, -minY, 0)

        var remap = [Int](repeating: -1, count: sim.count)
        var pts: [SIMD3<Float>] = [], nrms: [SIMD3<Float>] = [], sts: [SIMD2<Float>] = []
        let (N, _) = sim.frames()
        for i in 0..<sim.count where sim.active[i] {
            remap[i] = pts.count
            pts.append(sim.pos[i] + lift)
            nrms.append(N[i])
            sts.append(SIMD2(sim.panel[i].x / panel.x + 0.5, sim.panel[i].y / panel.y + 0.5))
        }
        let tris = sim.triangleIndices().map { remap[Int($0)] }

        var usda = """
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Root"
        {
            def Mesh "Cloth"
            {
                uniform bool doubleSided = 1
                uniform token subdivisionScheme = "none"
                int[] faceVertexCounts = [\(Array(repeating: "3", count: tris.count / 3).joined(separator: ","))]
                int[] faceVertexIndices = [\(tris.map(String.init).joined(separator: ","))]
                point3f[] points = [\(pts.map(vec3).joined(separator: ","))]
                normal3f[] normals = [\(nrms.map(vec3).joined(separator: ","))] (interpolation = "vertex")
                texCoord2f[] primvars:st = [\(sts.map(vec2).joined(separator: ","))] (interpolation = "vertex")
                rel material:binding = </Root/Materials/Cloth>
            }

        """
        for (k, p) in exportProps.enumerated() {
            usda += """
                def Mesh "Support\(k)"
                {
                    uniform token subdivisionScheme = "none"
                    int[] faceVertexCounts = [\(Array(repeating: "3", count: p.indices.count / 3).joined(separator: ","))]
                    int[] faceVertexIndices = [\(p.indices.map { String($0) }.joined(separator: ","))]
                    point3f[] points = [\(p.positions.map { vec3($0 + lift) }.joined(separator: ","))]
                    normal3f[] normals = [\(p.normals.map(vec3).joined(separator: ","))] (interpolation = "vertex")
                    rel material:binding = </Root/Materials/Support\(k)>
                }

            """
        }
        usda += """
            def Scope "Materials"
            {
                def Material "Cloth"
                {
                    token outputs:surface.connect = </Root/Materials/Cloth/PBR.outputs:surface>
                    def Shader "PBR"
                    {
                        uniform token info:id = "UsdPreviewSurface"
                        color3f inputs:diffuseColor.connect = </Root/Materials/Cloth/Base.outputs:rgb>
                        float inputs:opacity.connect = </Root/Materials/Cloth/Base.outputs:a>
                        float inputs:opacityThreshold = 0.5
                        normal3f inputs:normal.connect = </Root/Materials/Cloth/Normal.outputs:rgb>
                        float inputs:roughness = \(settings.sheenEnabled ? "0.45" : "0.85")
                        token outputs:surface
                    }
                    def Shader "ST"
                    {
                        uniform token info:id = "UsdPrimvarReader_float2"
                        token inputs:varname = "st"
                        float2 outputs:result
                    }
                    def Shader "Base"
                    {
                        uniform token info:id = "UsdUVTexture"
                        asset inputs:file = @base.png@
                        float2 inputs:st.connect = </Root/Materials/Cloth/ST.outputs:result>
                        token inputs:sourceColorSpace = "sRGB"
                        float3 outputs:rgb
                        float outputs:a
                    }
                    def Shader "Normal"
                    {
                        uniform token info:id = "UsdUVTexture"
                        asset inputs:file = @normal.png@
                        float2 inputs:st.connect = </Root/Materials/Cloth/ST.outputs:result>
                        token inputs:sourceColorSpace = "raw"
                        float4 inputs:scale = (2, 2, 2, 1)
                        float4 inputs:bias = (-1, -1, -1, 0)
                        float3 outputs:rgb
                    }
                }

        """
        for (k, p) in exportProps.enumerated() {
            usda += """
                    def Material "Support\(k)"
                    {
                        token outputs:surface.connect = </Root/Materials/Support\(k)/PBR.outputs:surface>
                        def Shader "PBR"
                        {
                            uniform token info:id = "UsdPreviewSurface"
                            color3f inputs:diffuseColor = \(vec3(p.color))
                            float inputs:roughness = 0.9
                            token outputs:surface
                        }
                    }

            """
        }
        usda += "    }\n}\n"

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("usdz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let baseURL = tmp.appendingPathComponent("base.png"), normalURL = tmp.appendingPathComponent("normal.png")
        try ImageUtils.write(colorImg, to: baseURL, type: .png)
        try ImageUtils.write(normalImg, to: normalURL, type: .png)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).usdz")
        try writeUSDZ(to: out, files: [("cloth.usda", Data(usda.utf8)),
                                      ("base.png", try Data(contentsOf: baseURL)),
                                      ("normal.png", try Data(contentsOf: normalURL))])
        try? FileManager.default.removeItem(at: tmp)
        return out
    }

    private static func vec3(_ v: SIMD3<Float>) -> String { String(format: "(%.5f,%.5f,%.5f)", v.x, v.y, v.z) }
    private static func vec2(_ v: SIMD2<Float>) -> String { String(format: "(%.5f,%.5f)", v.x, v.y) }

    private static func makeRGBA(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: ImageUtils.sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: USDZ = uncompressed zip with every file's data aligned to 64 bytes

    static func writeUSDZ(to url: URL, files: [(String, Data)]) throws {
        var out = Data()
        var central = Data()
        func u16(_ v: Int, _ d: inout Data) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        for (name, data) in files {
            let nameData = Data(name.utf8)
            let offset = out.count
            let crc = crc32(data)
            var pad = (64 - (offset + 30 + nameData.count + 4) % 64) % 64
            let extraLen = 4 + pad
            u32(0x0403_4b50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out)
            u16(nameData.count, &out); u16(extraLen, &out)
            out.append(nameData)
            u16(0x1986, &out); u16(pad, &out)
            while pad > 0 { out.append(0); pad -= 1 }
            out.append(data)
            u32(0x0201_4b50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(crc, &central); u32(UInt32(data.count), &central); u32(UInt32(data.count), &central)
            u16(nameData.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(UInt32(offset), &central)
            central.append(nameData)
        }
        let cdOffset = out.count
        out.append(central)
        u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(central.count), &out); u32(UInt32(cdOffset), &out); u16(0, &out)
        try out.write(to: url)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for byte in b { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
