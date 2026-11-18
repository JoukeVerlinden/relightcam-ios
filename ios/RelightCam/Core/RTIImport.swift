import Foundation

/// Imports an RTI in relight's web format (info.json + plane_N images), as a .zip or a folder: relightCam's
/// own "Share RTI" export, or relight-cli with `-b ptm -p 18` or `-b hsh -p 27` (rgb colorspace).
enum RTIImport {
    enum ImportError: LocalizedError {
        case noRTI
        case unsupported(type: String, colorspace: String)
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .noRTI:
                return "No info.json found: this isn't an RTI in relight's web format (a zip or folder with info.json and plane_0, plane_1, …)."
            case .unsupported(let t, let c):
                return "This RTI is type “\(t)”, colorspace “\(c)”. relightCam opens PTM and HSH RTIs in the rgb colorspace, such as its own exports or relight-cli with -b ptm -p 18 or -b hsh -p 27."
            case .missing(let f):
                return "The RTI is incomplete: \(f) is missing."
            }
        }
    }

    /// Copies the RTI found in `source` (a .zip or a folder) into `dest` (created) and returns its info.
    static func importRTI(from source: URL, to dest: URL) throws -> RelightInfo {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("rti-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        var isDir: ObjCBool = false
        let root: URL
        if fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue {
            root = source
        } else {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try ZipReader.extract(source, to: work)
            root = work
        }
        guard let dir = findInfo(in: root) else { throw ImportError.noRTI }

        // the same checks the viewers make, with a clearer message for other relight types
        let raw = try Data(contentsOf: dir.appendingPathComponent("info.json"))
        let info: RelightInfo
        do {
            info = try JSONDecoder().decode(RelightInfo.self, from: raw)
        } catch {
            throw ImportError.noRTI
        }
        guard info.colorspace == "rgb", info.basis != nil, info.nplanes == 3 * (info.basis?.nCoeffs ?? 0),
              info.materials.first?.scale.count == info.nplanes, info.materials.first?.bias.count == info.nplanes else {
            throw ImportError.unsupported(type: info.type, colorspace: info.colorspace)
        }
        let planes = (0..<(info.nplanes / 3)).map { "plane_\($0).\(info.format)" }
        for p in planes where !fm.fileExists(atPath: dir.appendingPathComponent(p).path) {
            throw ImportError.missing(p)
        }

        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for f in ["info.json"] + planes + ["normals.png", "mask.png"] {
            let src = dir.appendingPathComponent(f)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dest.appendingPathComponent(f)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        return info
    }

    /// The shallowest folder under `root` (root included) that holds an info.json.
    static func findInfo(in root: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("info.json").path) { return root }
        var best: (URL, Int)?
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.lastPathComponent == "info.json" {
                let depth = u.pathComponents.count
                if best == nil || depth < best!.1 { best = (u.deletingLastPathComponent(), depth) }
            }
        }
        return best?.0
    }
}
