import Foundation

enum Exporter {
    /// Zips a folder with the system's built-in archiver (NSFileCoordinator .forUploading).
    static func zip(_ dir: URL, as name: String) throws -> URL {
        var coordError: NSError?
        var result: Result<URL, Error> = .failure(RelightError.io("Zip failed"))
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { zipURL in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: zipURL, to: dest)
                result = .success(dest)
            } catch {
                result = .failure(error)
            }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    private static func stage(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
    }

    /// relight web format + the OpenLIME viewer page from relight's demo folder.
    static func exportRTI(_ project: Project) throws -> URL {
        let name = safe("\(project.meta.name) RTI")
        let dir = try stage(name)
        let fm = FileManager.default
        for f in try fm.contentsOfDirectory(atPath: project.rtiDir.path) {
            try fm.copyItem(at: project.rtiDir.appendingPathComponent(f), to: dir.appendingPathComponent(f))
        }
        for res in ["index.html", "openlime.min.js", "skin.css", "skin.svg"] {
            let parts = res.split(separator: ".", maxSplits: 1).map(String.init)
            if let src = Bundle.main.url(forResource: parts[0], withExtension: parts[1]) {
                try fm.copyItem(at: src, to: dir.appendingPathComponent(res))
            }
        }
        let rti = project.meta.rti
        let readme = """
        RelightCam export — \(project.meta.name)

        info.json + plane_*.jpg   relight web format (type "\(rti?.basis.rawValue ?? "?")", colorspace "rgb"),
                                  \(rti?.width ?? 0)×\(rti?.height ?? 0), fitted from \(rti?.lightsUsed ?? 0) photos.
        normals.png               photometric-stereo normal map (x right, y up, z towards the camera).
        index.html                OpenLIME viewer (from cnr-isti-vclab/relight/demo).

        Browsers block local files, so serve the folder instead of double-clicking index.html:
            cd "<this folder>" && python3 -m http.server 8000
        then open http://localhost:8000. Any static web host works too.
        """
        try readme.write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return try zip(dir, as: name)
    }

    /// Photos + a relight .lp file (light directions), ready for RelightLab / relight-cli on a desktop.
    static func exportCapture(_ project: Project) throws -> URL {
        let name = safe("\(project.meta.name) photos")
        let dir = try stage(name)
        let fm = FileManager.default
        let usable = project.usableIndices
        let indices = usable.isEmpty ? Array(project.meta.frames.indices) : usable
        var lp = "\(indices.count)\n"
        for i in indices {
            let f = project.meta.frames[i]
            let src = project.framesDir.appendingPathComponent(f)
            let dst = dir.appendingPathComponent(f)
            do { try fm.linkItem(at: src, to: dst) } catch { try fm.copyItem(at: src, to: dst) }
            if let d = project.meta.highlights?[i].dir, !usable.isEmpty {
                lp += String(format: "%@ %.6f %.6f %.6f\n", f, d[0], d[1], d[2])
            }
        }
        if !usable.isEmpty {
            try lp.write(to: dir.appendingPathComponent("\(safe(project.meta.name)).lp"), atomically: true, encoding: .utf8)
        }
        return try zip(dir, as: name)
    }
}
