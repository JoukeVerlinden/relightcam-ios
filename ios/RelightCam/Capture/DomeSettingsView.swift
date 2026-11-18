import SwiftUI
import CoreMIDI
import CoreAudioKit

/// Settings for capturing with a MIDI light dome (see DomeMIDI).
struct DomeSettingsView: View {
    @Bindable var dome: DomeMIDI
    @Environment(\.dismiss) private var dismiss
    @State private var showBluetooth = false
    @State private var testRun: Task<Void, Never>?
    @State private var testLED: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if dome.outputs.isEmpty {
                        Label("No MIDI device connected", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Send to", selection: $dome.selectedOutput) {
                        Text("All MIDI outputs").tag(MIDIUniqueID?.none)
                        ForEach(dome.outputs) { Text($0.name).tag(MIDIUniqueID?.some($0.id)) }
                    }
                    Button { showBluetooth = true } label: {
                        Label("Connect a Bluetooth MIDI device", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Dome controller")
                } footer: {
                    Text("Pair the dome's Arduino here over Bluetooth MIDI, or connect it by USB if it is a USB MIDI device.")
                }

                Section {
                    Stepper("LEDs: \(dome.ledCount)", value: $dome.ledCount, in: 1...DomeMIDI.maxLEDs)
                    VStack(alignment: .leading) {
                        Text("Brightness: \(Int((Double(dome.velocity) / 127 * 100).rounded())) %")
                        Slider(value: Binding(get: { Double(dome.velocity) }, set: { dome.velocity = Int($0) }), in: 1...127)
                    }
                    Stepper("Light before each photo: \(dome.settleMS) ms", value: $dome.settleMS, in: 0...2000, step: 50)
                } header: {
                    Text("LEDs")
                } footer: {
                    Text("Each LED is lit this long before its photo, then the app saves the first camera frame exposed entirely under it and turns the LED off. Longer is steadier; shorter is faster.")
                }

                Section {
                    Toggle("Light an LED while framing", isOn: $dome.previewOn)
                    Stepper("Framing LED: \(dome.previewLED + 1)", value: $dome.previewLED, in: 0...max(0, dome.ledCount - 1))
                        .disabled(!dome.previewOn)
                } footer: {
                    Text("Set focus and exposure with this LED on, then tap Lock.")
                }

                Section {
                    Button {
                        if testRun == nil { runThrough() } else { stopTest() }
                    } label: {
                        if let n = testLED {
                            Label("Stop (LED \(n + 1) of \(dome.ledCount))", systemImage: "stop.fill")
                        } else {
                            Label("Light each LED in turn", systemImage: "play.fill")
                        }
                    }
                    .disabled(!dome.hasOutput)
                    Button { stopTest(); dome.allOff() } label: { Label("All LEDs off", systemImage: "lightbulb.slash") }
                        .disabled(!dome.hasOutput)
                } header: {
                    Text("Test")
                } footer: {
                    Text("LED 1 is MIDI note 0, LED 2 is note 1, and so on, on channel 1. Note On lights an LED (velocity = brightness), Note Off turns it off.")
                }
            }
            .navigationTitle("Light dome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { dome.refresh() }
            .onDisappear { stopTest() }
            .onChange(of: dome.previewOn) { if testRun == nil { dome.showPreview() } }
            .onChange(of: dome.previewLED) { if testRun == nil { dome.showPreview() } }
            .onChange(of: dome.velocity) { if testRun == nil { dome.showPreview() } }
            .onChange(of: dome.ledCount) {
                if dome.previewLED >= dome.ledCount { dome.previewLED = dome.ledCount - 1 }
            }
            .sheet(isPresented: $showBluetooth, onDismiss: { dome.refresh() }) {
                BluetoothMIDIView { showBluetooth = false }.ignoresSafeArea()
            }
        }
    }

    private func runThrough() {
        testRun = Task { @MainActor in
            dome.allOff()
            for n in 0..<dome.ledCount {
                if Task.isCancelled { break }
                testLED = n
                dome.ledOn(n)
                try? await Task.sleep(for: .milliseconds(250))
            }
            dome.allOff()
            testLED = nil
            testRun = nil
            dome.showPreview()
        }
    }

    private func stopTest() {
        testRun?.cancel()
    }
}

/// Apple's Bluetooth MIDI pairing screen.
struct BluetoothMIDIView: UIViewControllerRepresentable {
    var onDone: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = CABTMIDICentralViewController()
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in onDone() })
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
