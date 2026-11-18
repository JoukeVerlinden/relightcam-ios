import Foundation

/// Light directions from a relight `.lp` file: an optional first line with the number of lights, then one
/// line per light, `<image name> <x> <y> <z>`, in relight's convention (x right, y up, z towards the camera).
/// For a light dome, line n is LED n (MIDI note n − 1).
struct LightPositions: Equatable {
    var name: String
    var directions: [[Double]]

    var count: Int { directions.count }

    enum ParseError: LocalizedError {
        case empty
        case badLine(Int, String)
        case countMismatch(declared: Int, found: Int)

        var errorDescription: String? {
            switch self {
            case .empty: return "The file has no light positions."
            case .badLine(let n, let s): return "Line \(n) isn't a light position (“name x y z”): \(s)"
            case .countMismatch(let d, let f): return "The file says \(d) lights but lists \(f)."
            }
        }
    }

    /// Accepts spaces or tabs, Windows line ends, blank lines and `#` comments. Vectors are normalised, so a
    /// file with 3D light positions (relative to the object) gives their directions.
    static func parse(_ text: String, name: String) throws -> LightPositions {
        var lines: [(Int, String)] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let l = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !l.isEmpty && !l.hasPrefix("#") { lines.append((i + 1, l)) }
        }
        guard let first = lines.first else { throw ParseError.empty }
        var declared: Int?
        if let n = Int(first.1) {
            declared = n
            lines.removeFirst()
        }
        var dirs: [[Double]] = []
        for (n, l) in lines {
            let parts = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3,
                  let x = Double(parts[parts.count - 3]), let y = Double(parts[parts.count - 2]),
                  let z = Double(parts[parts.count - 1]) else { throw ParseError.badLine(n, l) }
            let len = (x * x + y * y + z * z).squareRoot()
            guard len > 1e-9 else { throw ParseError.badLine(n, l) }
            dirs.append([x / len, y / len, z / len])
        }
        if let d = declared, d != dirs.count { throw ParseError.countMismatch(declared: d, found: dirs.count) }
        guard !dirs.isEmpty else { throw ParseError.empty }
        return LightPositions(name: name, directions: dirs)
    }
}
