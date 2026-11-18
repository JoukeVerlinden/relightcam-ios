// macOS harness for RTI import (relight web format): builds a PTM and an HSH RTI from the synthetic capture,
// exports each with the app's Share RTI code, imports the zip again and compares every file; also zips from
// ditto/Finder and Info-ZIP (deflate and stored), the unzipped folder, and files that must be refused.
//   mkdir -p /tmp/ri && cp tools/rti_import_test.swift /tmp/ri/main.swift
//   swiftc -O RelightCam/Core/*.swift RelightCam/Cloth/*.swift /tmp/ri/main.swift -o /tmp/ri/test && /tmp/ri/test /tmp/ri/out
import Foundation
var fails = 0
func check(_ ok: Bool, _ m: String) { print((ok ? "ok   " : "FAIL ") + m); if !ok { fails += 1 } }
func sh(_ cmd: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]; try! p.run(); p.waitUntilExit() }
func same(_ a: URL, _ b: URL) -> Bool { (try? Data(contentsOf: a)) == (try? Data(contentsOf: b)) }
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1]); try? fm.removeItem(at: root)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
let ds = try! SyntheticDataset.generate(into: root.appendingPathComponent("frames"), kind: .textile)
let frames = ds.files.map { root.appendingPathComponent("frames").appendingPathComponent($0) }

for basis in [RTIBasis.ptm, .hsh] {
    // a project with a built RTI, exported with the app's own Share RTI code
    let pdir = root.appendingPathComponent("project-\(basis.rawValue)")
    try! fm.createDirectory(at: pdir.appendingPathComponent("frames"), withIntermediateDirectories: true)
    let p = Project(url: pdir, meta: ProjectMeta(name: "Silk \(basis.rawValue)", created: Date()))
    _ = try! RTIBuilder.build(frames: frames, lights: ds.lights, basis: basis, maxSide: 400, output: p.rtiDir,
                              pixelSizeMM: { _ in 0.25 }) { _, _ in }
    try! Data([1, 2, 3]).write(to: p.rtiDir.appendingPathComponent("mask.png"))   // stand-in cutout
    let zip = try! Exporter.exportRTI(p)
    let dest = root.appendingPathComponent("imported-\(basis.rawValue)")
    do {
        let info = try RTIImport.importRTI(from: zip, to: dest)
        check(info.basis == basis && info.width > 0 && info.pixelSizeInMM == 0.25, "\(basis): Share RTI zip imports (\(info.width)×\(info.height), \(info.nplanes) planes, 0.25 mm/px)")
        let names = try! fm.contentsOfDirectory(atPath: p.rtiDir.path).sorted()
        check(names.allSatisfy { same(p.rtiDir.appendingPathComponent($0), dest.appendingPathComponent($0)) },
              "\(basis): every RTI file comes back byte for byte (\(names.joined(separator: ", ")))")
        check((try? RTIRenderer.loadPlanes(dest)) != nil && (try? RelightInfo.load(from: dest)) != nil, "\(basis): the viewers' loaders read it")
    } catch { check(false, "\(basis): import failed: \(error.localizedDescription)") }
    // the same folder zipped by other tools, and unzipped
    let staged = zip.deletingPathExtension()
    sh("rm -rf '\(root.path)/z'; mkdir -p '\(root.path)/z'; cd '\(root.path)/z' && unzip -q '\(zip.path)' && "
       + "ditto -c -k --keepParent * ../ditto-\(basis).zip && zip -qr ../info-\(basis).zip * && zip -qr0 ../stored-\(basis).zip *")
    for kind in ["ditto", "info", "stored"] {
        let z = root.appendingPathComponent("\(kind)-\(basis).zip")
        let out = root.appendingPathComponent("x-\(kind)-\(basis)")
        let ok = (try? RTIImport.importRTI(from: z, to: out)) != nil && same(out.appendingPathComponent("plane_0.jpg"), dest.appendingPathComponent("plane_0.jpg"))
        check(ok, "\(basis): zip from \(kind == "info" ? "Info-ZIP (deflate)" : kind == "stored" ? "Info-ZIP (stored)" : "ditto/Finder") imports")
    }
    let folder = try! fm.contentsOfDirectory(at: root.appendingPathComponent("z"), includingPropertiesForKeys: nil).first!
    check((try? RTIImport.importRTI(from: folder, to: root.appendingPathComponent("f-\(basis)"))) != nil, "\(basis): the unzipped folder imports")
    _ = staged
}

// refusals
func refused(_ src: URL, _ label: String, contains: String) {
    do { _ = try RTIImport.importRTI(from: src, to: root.appendingPathComponent("no-\(UUID())")); check(false, "\(label): accepted") }
    catch { check(error.localizedDescription.contains(contains), "\(label): \(error.localizedDescription.prefix(70))…") }
}
let rbf = root.appendingPathComponent("rbf"); try! fm.createDirectory(at: rbf, withIntermediateDirectories: true)
try! #"{"width":10,"height":10,"format":"jpg","type":"rbf","colorspace":"ycc","nplanes":18,"materials":[{"scale":[1],"bias":[0]}]}"#.write(to: rbf.appendingPathComponent("info.json"), atomically: true, encoding: .utf8)
refused(rbf, "RBF/ycc RTI refused", contains: "rbf")
let nothing = root.appendingPathComponent("nothing"); try! fm.createDirectory(at: nothing, withIntermediateDirectories: true)
try! "hi".write(to: nothing.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
sh("cd '\(nothing.path)' && zip -q ../nothing.zip a.txt")
refused(root.appendingPathComponent("nothing.zip"), "zip without an RTI refused", contains: "info.json")
let holed = root.appendingPathComponent("holed"); sh("cp -R '\(root.path)/imported-ptm' '\(holed.path)' && rm '\(holed.path)/plane_3.jpg'")
refused(holed, "missing plane refused", contains: "plane_3")
try! "not a zip".write(to: root.appendingPathComponent("fake.zip"), atomically: true, encoding: .utf8)
refused(root.appendingPathComponent("fake.zip"), "non-zip refused", contains: "zip")
sh("python3 -I -c \"import zipfile; z=zipfile.ZipFile('\(root.path)/evil.zip','w'); z.writestr('../evil.txt','x'); z.close()\"")
refused(root.appendingPathComponent("evil.zip"), "path leaving the folder refused", contains: "unsafe")
check(!fm.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("evil.txt").path), "nothing written outside")
print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
