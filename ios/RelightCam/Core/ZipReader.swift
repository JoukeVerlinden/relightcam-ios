import Foundation
import Compression

/// Minimal .zip extraction (iOS has no unzip API): stored and deflated entries, as written by Finder,
/// `ditto`, Info-ZIP and the iOS share sheet. Not supported: encryption, ZIP64 (> 4 GB) and other methods.
enum ZipReader {
    enum ZipError: LocalizedError {
        case notZip
        case unsupported(String)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notZip: return "This isn't a zip file."
            case .unsupported(let s): return "This zip uses \(s), which relightCam can't unpack."
            case .corrupt(let s): return "The zip file is damaged (\(s))."
            }
        }
    }

    /// Unpacks `url` into `dir` and returns the relative paths written. Skips folders, macOS resource
    /// forks (`__MACOSX/`, `._*`), and refuses paths that would leave `dir`.
    @discardableResult
    static func extract(_ url: URL, to dir: URL) throws -> [String] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let n = data.count
        guard n >= 22 else { throw ZipError.notZip }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        // end of central directory record: the last signature within the final 64 KiB (+ 22 bytes)
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65_535)
        while i >= stop {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        let cdOffset = u32(eocd + 16)
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }

        let fm = FileManager.default
        var written: [String] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4b50 else { throw ZipError.corrupt("central directory") }
            let flags = u16(p + 8), method = u16(p + 10)
            let csize = u32(p + 20), usize = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            guard p + 46 + nameLen <= n else { throw ZipError.corrupt("file name") }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let name = String(data: nameData, encoding: flags & 0x800 != 0 ? .utf8 : .isoLatin1)
                ?? String(decoding: nameData, as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            let comps = name.split(separator: "/").map(String.init)
            let last = comps.last ?? ""
            if name.hasSuffix("/") || comps.first == "__MACOSX" || last.hasPrefix("._") || comps.isEmpty { continue }
            guard !name.hasPrefix("/"), !comps.contains(".."), !name.contains("\\") else {
                throw ZipError.corrupt("unsafe path \(name)")
            }
            if flags & 1 != 0 { throw ZipError.unsupported("encryption") }
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || local == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
            guard local + 30 <= n, u32(local) == 0x0403_4b50 else { throw ZipError.corrupt("header of \(name)") }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= n else { throw ZipError.corrupt(name) }

            let out: Data
            switch method {
            case 0:
                out = data.subdata(in: start..<(start + csize))
            case 8:
                if usize == 0 { out = Data(); break }
                var buf = Data(count: usize)
                let got = buf.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                    data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                        // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), as stored in zip entries
                        compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, usize,
                                                  src.bindMemory(to: UInt8.self).baseAddress! + start, csize,
                                                  nil, COMPRESSION_ZLIB)
                    }
                }
                guard got == usize else { throw ZipError.corrupt(name) }
                out = buf
            default:
                throw ZipError.unsupported("compression method \(method)")
            }
            let target = comps.reduce(dir) { $0.appendingPathComponent($1) }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: target)
            written.append(comps.joined(separator: "/"))
        }
        return written
    }
}
