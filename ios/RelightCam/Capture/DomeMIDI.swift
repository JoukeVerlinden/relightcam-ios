import Foundation
import CoreMIDI
import Observation

/// Drives a light dome over CoreMIDI, for example an Arduino that shows up as a USB or Bluetooth MIDI device.
///
/// Protocol (channel 1): LED n (counted from 0) is MIDI note n. Note On (velocity 127) lights it,
/// Note Off turns it off. "All off" sends Control Change 123 (All Notes Off) and a Note Off for every LED.
/// See docs/dome-midi.md for the Arduino side.
@Observable
final class DomeMIDI {
    struct Output: Identifiable, Hashable {
        let id: MIDIUniqueID
        let name: String
    }

    static let shared = DomeMIDI()

    private(set) var outputs: [Output] = []
    /// nil sends to every output
    var selectedOutput: MIDIUniqueID? { didSet { defaults.set(selectedOutput.map { Int($0) }, forKey: "dome.output") } }
    var ledCount: Int { didSet { defaults.set(ledCount, forKey: "dome.ledCount") } }
    /// how long each LED is lit before the exposure that is saved starts (the "flash" time)
    var settleMS: Int { didSet { defaults.set(settleMS, forKey: "dome.settleMS") } }
    /// LED that stays on while framing, so focus and exposure can be set (0-based)
    var previewLED: Int { didSet { defaults.set(previewLED, forKey: "dome.previewLED") } }
    var previewOn: Bool { didSet { defaults.set(previewOn, forKey: "dome.previewOn") } }
    /// Note On velocity, 1…127: the LED brightness (the example sketch maps 127 to full white)
    var velocity: Int { didSet { defaults.set(velocity, forKey: "dome.velocity") } }
    private(set) var lit: Int?
    private(set) var lastError: String?
    /// the last few dome events, shown in the dome settings to diagnose a run
    private(set) var recent: [String] = []

    func log(_ s: String) {
        let t = Date()
        let ms = Int(t.timeIntervalSince1970 * 1000) % 1000
        recent.append(String(format: "%@.%03d %@", Self.clock.string(from: t), ms, s))
        if recent.count > 80 { recent.removeFirst(recent.count - 80) }
        #if DEBUG
        print("[dome] \(recent.last!)")
        #endif
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let maxLEDs = 128

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var port = MIDIPortRef()
    @ObservationIgnored private let channel: UInt8 = 0

    init(clientName: String = "relightCam", defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledCount = (defaults.object(forKey: "dome.ledCount") as? Int) ?? 24
        settleMS = (defaults.object(forKey: "dome.settleMS") as? Int) ?? 200
        previewLED = (defaults.object(forKey: "dome.previewLED") as? Int) ?? 0
        previewOn = (defaults.object(forKey: "dome.previewOn") as? Bool) ?? true
        velocity = (defaults.object(forKey: "dome.velocity") as? Int) ?? 127
        selectedOutput = (defaults.object(forKey: "dome.output") as? Int).map { MIDIUniqueID($0) }
        var status = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        if status == noErr { status = MIDIOutputPortCreate(client, "LEDs" as CFString, &port) }
        if status != noErr { lastError = "CoreMIDI error \(status)"; log(lastError!) }
        refresh()
    }

    /// Re-reads the list of MIDI outputs (also called automatically when devices come and go).
    func refresh() {
        var list: [Output] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let e = MIDIGetDestination(i)
            guard e != 0 else { continue }
            let name = Self.string(e, kMIDIPropertyDisplayName) ?? Self.string(e, kMIDIPropertyName) ?? "MIDI output \(i + 1)"
            // iOS always lists the network session; it is never the dome
            if name.hasPrefix("Network Session") { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &uid)
            list.append(Output(id: uid, name: name))
        }
        outputs = list
    }

    var hasOutput: Bool { !targets.isEmpty }

    /// Name for the status line: the chosen output, or the outputs that "all" reaches.
    var outputSummary: String {
        if let id = selectedOutput {
            return outputs.first { $0.id == id }?.name ?? "chosen output not connected"
        }
        switch outputs.count {
        case 0: return "no MIDI device"
        case 1: return outputs[0].name
        default: return "\(outputs.count) MIDI outputs"
        }
    }

    private var targets: [MIDIEndpointRef] {
        var out: [MIDIEndpointRef] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let e = MIDIGetDestination(i)
            guard e != 0 else { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &uid)
            if let sel = selectedOutput {
                if uid == sel { out.append(e) }
            } else if outputs.contains(where: { $0.id == uid }) {
                out.append(e)
            }
        }
        return out
    }

    // MARK: - Messages

    func ledOn(_ n: Int) {
        guard (0..<Self.maxLEDs).contains(n) else { return }
        if let l = lit, l != n { send(0x80 | channel, UInt8(l), 0) }
        let reached = send(0x90 | channel, UInt8(n), UInt8(max(1, min(127, velocity))))
        lit = n
        log("LED \(n + 1) on → \(reached) output\(reached == 1 ? "" : "s")")
    }

    func ledOff(_ n: Int) {
        guard (0..<Self.maxLEDs).contains(n) else { return }
        send(0x80 | channel, UInt8(n), 0)
        if lit == n { lit = nil }
    }

    func allOff() {
        let reached = send(0xB0 | channel, 123, 0)
        log("all off → \(reached) output\(reached == 1 ? "" : "s")")
        for n in 0..<min(max(ledCount, lit.map { $0 + 1 } ?? 0), Self.maxLEDs) { send(0x80 | channel, UInt8(n), 0) }
        lit = nil
    }

    /// Lights the preview LED, or turns everything off when the preview is switched off.
    func showPreview() {
        if previewOn { ledOn(min(previewLED, ledCount - 1)) } else if lit != nil { allOff() }
    }

    /// Sends one message; returns how many outputs it went to.
    @discardableResult
    private func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> Int {
        let dests = targets
        guard !dests.isEmpty else { return 0 }
        // MIDI 1.0 channel voice message as a Universal MIDI Packet (type 2, group 0)
        var word = UInt32(0x2) << 28 | UInt32(status) << 16 | UInt32(d1 & 0x7F) << 8 | UInt32(d2 & 0x7F)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        for d in dests {
            let s = MIDISendEventList(port, d, &list)
            if s != noErr { lastError = "MIDI send failed (\(s))"; log(lastError!) }
        }
        return dests.count
    }

    private static func string(_ obj: MIDIObjectRef, _ prop: CFString) -> String? {
        var s: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, prop, &s) == noErr, let v = s?.takeRetainedValue() else { return nil }
        return v as String
    }

    #if DEBUG
    @ObservationIgnored private var testDome = MIDIEndpointRef()
    /// Test hook (-dome-virtual): a virtual MIDI device inside the app that logs what it receives.
    func addVirtualTestDome() {
        guard testDome == 0 else { return }
        let st = MIDIDestinationCreateWithProtocol(client, "Simulated dome" as CFString, ._1_0, &testDome) { list, _ in
            var p = list.pointee.packet
            for _ in 0..<list.pointee.numPackets {
                let w = p.words.0
                if w >> 28 == 0x2 {
                    let st = (w >> 16) & 0xF0, d1 = (w >> 8) & 0x7F, d2 = w & 0x7F
                    let what = st == 0x90 && d2 > 0 ? "on LED \(d1 + 1) velocity \(d2)" : st == 0x80 || st == 0x90 ? "off LED \(d1 + 1)" : st == 0xB0 ? "CC \(d1)" : "other"
                    NSLog("[dome] %@", what)
                }
                p = MIDIEventPacketNext(&p).pointee
            }
        }
        NSLog("[dome] simulated dome: status %d", st)
        refresh()
    }
    #endif

    // MARK: - Capture sequence

    enum StopReason: Equatable { case finished, cancelled, noFrames }

    /// Lights LEDs 0..<count one at a time and takes one photo per LED:
    /// Note On → settle → wait for a frame exposed after the LED came on → shoot → Note Off.
    /// `waitLit` must return once a frame whose exposure started after the call is available, or false on a
    /// timeout. `shoot(led)` saves the newest frame. Turns all LEDs off at the start and at the end.
    @MainActor
    func runSequence(count: Int,
                     waitLit: @escaping () async -> Bool,
                     shoot: @escaping (Int) async -> Void,
                     progress: @escaping (Int) -> Void) async -> StopReason {
        allOff()
        var reason = StopReason.finished
        for n in 0..<min(count, Self.maxLEDs) {
            if Task.isCancelled { reason = .cancelled; break }
            progress(n)
            ledOn(n)
            try? await Task.sleep(for: .milliseconds(max(0, settleMS)))
            if Task.isCancelled { reason = .cancelled; break }
            let t = Date()
            guard await waitLit() else { reason = Task.isCancelled ? .cancelled : .noFrames; break }
            log("LED \(n + 1): frame after \(Int(Date().timeIntervalSince(t) * 1000)) ms")
            await shoot(n)
            ledOff(n)
        }
        allOff()
        log("run ended: \(reason)")
        return reason
    }
}
