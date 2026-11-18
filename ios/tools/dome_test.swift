// macOS harness for the dome LED sequence (DomeMIDI). It creates a virtual MIDI device, runs the
// sequence with a fake camera and checks the order and timing of the MIDI messages:
//   mkdir -p /tmp/dt && cp tools/dome_test.swift /tmp/dt/main.swift &&
//   swiftc RelightCam/Capture/DomeMIDI.swift RelightCam/Core/LightPositions.swift /tmp/dt/main.swift -o /tmp/dt/test &&
//   /tmp/dt/test   (run from the ios folder: it reads RelightCam/Capture/DomeDefault.lp.txt)
import Foundation
import CoreMIDI

struct Event { let t: Double; let what: String; let n: Int }
let lock = NSLock()
var events: [Event] = []
let t0 = Date()
func log(_ what: String, _ n: Int) {
    lock.lock(); events.append(Event(t: Date().timeIntervalSince(t0) * 1000, what: what, n: n)); lock.unlock()
}
func snapshot() -> [Event] { lock.lock(); defer { lock.unlock() }; return events }
func clearEvents() { lock.lock(); events.removeAll(); lock.unlock() }

// the "Arduino": a virtual MIDI destination that records what it receives
var client = MIDIClientRef()
MIDIClientCreateWithBlock("dome-test" as CFString, &client, nil)
var dest = MIDIEndpointRef()
let st = MIDIDestinationCreateWithProtocol(client, "Fake dome" as CFString, ._1_0, &dest) { list, _ in
    var p = list.pointee.packet
    for _ in 0..<list.pointee.numPackets {
        let words = Mirror(reflecting: p.words).children.prefix(Int(p.wordCount)).map { $0.value as! UInt32 }
        for w in words where w >> 28 == 0x2 {
            let status = UInt8((w >> 16) & 0xFF), d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
            switch status & 0xF0 {
            case 0x90: log(d2 > 0 ? "on" : "off", d1)
            case 0x80: log("off", d1)
            case 0xB0 where d1 == 123: log("allnotesoff", 0)
            default: log(String(format: "other %02X", status), d1)
            }
        }
        p = MIDIEventPacketNext(&p).pointee
    }
}
guard st == noErr else { print("FAIL: could not create the virtual MIDI device (\(st))"); exit(1) }

let defaults = UserDefaults(suiteName: "dome-test-\(UUID().uuidString)")!
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dome-test-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let dome = DomeMIDI(clientName: "relightCam-test", defaults: defaults, lightsFile: tmp.appendingPathComponent("dome-lights.lp"))
dome.refresh()
var failures = 0
func check(_ ok: Bool, _ msg: String) { print((ok ? "ok   " : "FAIL ") + msg); if !ok { failures += 1 } }

check(dome.outputs.contains { $0.name == "Fake dome" }, "the virtual device is listed as an output (\(dome.outputs.map(\.name)))")
check(dome.hasOutput, "has an output")
dome.selectedOutput = dome.outputs.first { $0.name == "Fake dome" }?.id

let count = 55
dome.ledCount = count
dome.settleMS = 40

Task { @MainActor in
    var shots: [Int] = []
    let start = Date()
    let reason = await dome.runSequence(
        count: count,
        waitLit: { try? await Task.sleep(for: .milliseconds(15)); return true },
        shoot: { n in log("shoot", n); shots.append(n) },
        progress: { _ in })
    let total = Date().timeIntervalSince(start)
    try? await Task.sleep(for: .milliseconds(200)) // let the last messages arrive
    let ev = snapshot()

    check(reason == .finished, "sequence finished (\(reason))")
    check(shots == Array(0..<count), "one photo per LED, in order (\(shots.count) photos)")
    check(ev.first?.what == "allnotesoff", "starts with All Notes Off")
    let lastOn = ev.lastIndex { $0.what == "on" } ?? 0
    check(ev[lastOn...].contains { $0.what == "allnotesoff" }, "ends with All Notes Off")

    var orderOK = true, settleOK = true, minSettle = 1e9
    for n in 0..<count {
        guard let on = ev.firstIndex(where: { $0.what == "on" && $0.n == n }),
              let shot = ev.firstIndex(where: { $0.what == "shoot" && $0.n == n }),
              let off = ev[shot...].firstIndex(where: { $0.what == "off" && $0.n == n }) else { orderOK = false; continue }
        if !(on < shot && shot < off) { orderOK = false }
        if n + 1 < count, let next = ev.firstIndex(where: { $0.what == "on" && $0.n == n + 1 }), next < off { orderOK = false }
        let s = ev[shot].t - ev[on].t
        minSettle = min(minSettle, s)
        if s < Double(dome.settleMS) { settleOK = false }
    }
    check(orderOK, "each LED: on → photo → off, and off before the next LED")
    check(settleOK, String(format: "photo at least %d ms after Note On (min %.0f ms)", dome.settleMS, minSettle))
    // at most one LED lit at any time
    var litNow = Set<Int>(), maxLit = 0
    for e in ev {
        if e.what == "on" { litNow.insert(e.n) } else if e.what == "off" { litNow.remove(e.n) } else if e.what == "allnotesoff" { litNow.removeAll() }
        maxLit = max(maxLit, litNow.count)
    }
    check(maxLit == 1, "never more than one LED on (max \(maxLit))")
    check(litNow.isEmpty, "all LEDs off at the end")
    print(String(format: "%d LEDs in %.2f s (%.0f ms per LED with %d ms settle + 15 ms fake frame wait)",
                 count, total, total * 1000 / Double(count), dome.settleMS))

    // cancelling half-way still turns everything off
    clearEvents()
    let task = Task { @MainActor in
        await dome.runSequence(count: count, waitLit: { try? await Task.sleep(for: .milliseconds(15)); return true },
                               shoot: { _ in }, progress: { _ in })
    }
    try? await Task.sleep(for: .milliseconds(300))
    task.cancel()
    let r2 = await task.value
    try? await Task.sleep(for: .milliseconds(200))
    let ev2 = snapshot()
    var lit2 = Set<Int>()
    for e in ev2 {
        if e.what == "on" { lit2.insert(e.n) } else if e.what == "off" { lit2.remove(e.n) } else if e.what == "allnotesoff" { lit2.removeAll() }
    }
    check(r2 == .cancelled && lit2.isEmpty, "cancel stops the run and leaves every LED off (\(r2))")

    // a camera that never delivers a frame stops the run
    let r3 = await dome.runSequence(count: 5, waitLit: { false }, shoot: { _ in }, progress: { _ in })
    check(r3 == .noFrames, "no camera frames stops the run (\(r3))")

    // preview LED
    clearEvents()
    dome.previewLED = 27
    dome.previewOn = true
    dome.showPreview()
    dome.previewLED = 3
    dome.showPreview()
    try? await Task.sleep(for: .milliseconds(150))
    let ev4 = snapshot()
    let seq = ev4.map { "\($0.what)\($0.what == "allnotesoff" ? "" : String($0.n))" }
    check(seq == ["on27", "off27", "on3"], "preview LED moves from 28 to 4 (\(seq))")
    dome.allOff()

    // light positions (.lp)
    let lpURL = URL(fileURLWithPath: "RelightCam/Capture/DomeDefault.lp.txt")
    if let text = try? String(contentsOf: lpURL, encoding: .utf8), let l = try? LightPositions.parse(text, name: "default") {
        let d0 = l.directions[0], d23 = l.directions[23]
        check(l.count == 24, "default .lp: 24 LEDs (\(l.count))")
        check(abs(d0[0] - 0.150384) < 1e-6 && abs(d0[1] + 0.086824) < 1e-6 && abs(d0[2] - 0.984808) < 1e-6, "default .lp (v3): LED 1 = (0.150, -0.087, 0.985)")
        check(abs(d23[0] - 0.709406) < 1e-6 && abs(d23[1] + 0.409576) < 1e-6 && abs(d23[2] - 0.573576) < 1e-6, "default .lp (v3): LED 24 = (0.709, -0.410, 0.574)")
        let lens = l.directions.map { ($0[0] * $0[0] + $0[1] * $0[1] + $0[2] * $0[2]).squareRoot() }
        check(lens.allSatisfy { abs($0 - 1) < 1e-6 }, "default .lp: all unit vectors")
    } else {
        check(false, "default .lp found and parsed (run from the ios folder)")
    }
    let unix = (try? LightPositions.parse("2\na.jpg 1 0 1\nb.jpg 0 2 0\n", name: "u"))?.directions
    check(unix?.count == 2 && abs((unix?[0][0] ?? 0) - 0.7071068) < 1e-6 && unix?[1] == [0, 1, 0], "parse: normalises, LF line ends")
    check((try? LightPositions.parse("# comment\r\n\r\nx 0 0 1\r\ny\t0\t1\t0\r\n", name: "c"))?.count == 2, "parse: no count line, CRLF, tabs, comments")
    check((try? LightPositions.parse("my photo 01.jpg 0 0 1", name: "s"))?.count == 1, "parse: spaces in the image name")
    var errs: [String] = []
    for bad in ["", "3\na 0 0 1\nb 0 1 0", "2\na 0 0 1\nb zero 1 0", "1\na 0 0 0"] {
        do { _ = try LightPositions.parse(bad, name: "b"); errs.append("accepted") } catch { errs.append("\(error.localizedDescription.prefix(18))") }
    }
    check(!errs.contains("accepted"), "parse rejects empty, count mismatch, bad numbers, zero vector (\(errs))")
    // import a custom file: it is kept, sets the LED count, and maps LEDs to directions
    let custom = tmp.appendingPathComponent("my dome.lp")
    try? "3\nf1 1 0 0.1\nf2 0 1 0.1\nf3 0 0 1\n".write(to: custom, atomically: true, encoding: .utf8)
    dome.ledCount = 55
    do { try dome.importLights(from: custom) } catch { check(false, "import: \(error)") }
    check(dome.lights?.name == "my dome.lp" && dome.ledCount == 3 && dome.lightsAreCustom, "import: name, LED count 3, custom")
    check(dome.direction(forLED: 2) == [0, 0, 1] && dome.direction(forLED: 3) == nil, "LED 3 → (0,0,1), no LED 4")
    dome.useLights = false
    check(dome.direction(forLED: 2) == nil, "switched off: no directions")
    dome.useLights = true
    let reloaded = DomeMIDI(clientName: "relightCam-test2", defaults: defaults, lightsFile: tmp.appendingPathComponent("dome-lights.lp"))
    check(reloaded.lights?.count == 3 && reloaded.lights?.name == "my dome.lp", "the imported file is kept for the next launch")
    dome.useDefaultLights()
    check(!dome.lightsAreCustom && !FileManager.default.fileExists(atPath: tmp.appendingPathComponent("dome-lights.lp").path),
          "back to the default removes the copy")
    try? FileManager.default.removeItem(at: tmp)

    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
