import Foundation
import Observation

struct RTIMeta: Codable, Equatable {
    var basis: RTIBasis
    var width: Int
    var height: Int
    var lightsUsed: Int
    var date: Date
    var seconds: Double
}

struct ProjectMeta: Codable {
    var name: String
    var created: Date
    var source: String = "camera"
    var frames: [String] = []
    var frameWidth: Int = 0
    var frameHeight: Int = 0
    var sphere: SphereCircle?
    var highlights: [Highlight]?
    var excluded: [Int] = []
    var compositeCount: Int?
    var rti: RTIMeta?
}

/// One capture session = one folder in Documents/Projects (visible in the Files app).
@Observable
final class Project: Identifiable, Hashable {
    let url: URL
    var meta: ProjectMeta
    var id: URL { url }

    init(url: URL, meta: ProjectMeta) {
        self.url = url
        self.meta = meta
    }

    static func == (a: Project, b: Project) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }

    var framesDir: URL { url.appendingPathComponent("frames", isDirectory: true) }
    var rtiDir: URL { url.appendingPathComponent("rti", isDirectory: true) }
    var compositeURL: URL { url.appendingPathComponent("composite.jpg") }
    var frameURLs: [URL] { meta.frames.map { framesDir.appendingPathComponent($0) } }

    var hasRTI: Bool {
        meta.rti != nil && FileManager.default.fileExists(atPath: rtiDir.appendingPathComponent("info.json").path)
    }

    /// Frames with a detected highlight that the user did not exclude.
    var usableIndices: [Int] {
        guard let hs = meta.highlights, hs.count == meta.frames.count else { return [] }
        let ex = Set(meta.excluded)
        return hs.indices.filter { hs[$0].valid && !ex.contains($0) }
    }

    var lightsAreCurrent: Bool { meta.highlights?.count == meta.frames.count && meta.sphere != nil }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(meta) {
            try? data.write(to: url.appendingPathComponent("project.json"), options: .atomic)
        }
    }

    func appendFrame(_ name: String, width: Int, height: Int) {
        meta.frames.append(name)
        if meta.frameWidth == 0 { meta.frameWidth = width; meta.frameHeight = height }
        save()
    }

    /// First free frame index, so "add more photos" never overwrites.
    func nextFrameIndex() -> Int {
        var i = meta.frames.count
        while FileManager.default.fileExists(atPath: framesDir.appendingPathComponent(String(format: "frame_%03d.jpg", i)).path) { i += 1 }
        return i
    }

    static func load(_ url: URL) -> Project? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("project.json")) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let meta = try? dec.decode(ProjectMeta.self, from: data) else { return nil }
        return Project(url: url, meta: meta)
    }
}

@Observable
final class ProjectStore {
    var projects: [Project] = []
    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        projects = dirs.compactMap(Project.load).sorted { $0.meta.created > $1.meta.created }
    }

    func create(name: String, source: String) throws -> Project {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        var url = root.appendingPathComponent(safe, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(safe) \(n)", isDirectory: true); n += 1
        }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let p = Project(url: url, meta: ProjectMeta(name: name, created: Date(), source: source))
        p.save()
        projects.insert(p, at: 0)
        return p
    }

    func delete(_ p: Project) {
        try? FileManager.default.removeItem(at: p.url)
        projects.removeAll { $0.url == p.url }
    }

    static func timestampName(_ prefix: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(prefix) \(f.string(from: Date()))"
    }
}
