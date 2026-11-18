import SwiftUI
import CoreMIDI
import CoreAudioKit
import UniformTypeIdentifiers

/// Settings for capturing with a MIDI light dome (see DomeMIDI).
struct DomeSettingsView: View {
    @Bindable var dome: DomeMIDI
    @Environment(\.dismiss) private var dismiss
    @State private var showBluetooth = false
    @State private var importingLights = false
    @State private var lightsError: String?

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
                    if let l = dome.lights {
                        HStack(spacing: 14) {
                            DirectionsPlot(directions: l.directions).frame(width: 84, height: 84)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(l.name).font(.headline).lineLimit(2)
                                Text("\(l.count) LEDs\(dome.lightsAreCustom ? "" : " (default)")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Give photos these directions", isOn: $dome.useLights)
                        if dome.ledCount != l.count {
                            Button {
                                dome.ledCount = min(l.count, DomeMIDI.maxLEDs)
                            } label: {
                                Label("The file has \(l.count) LEDs, the dome is set to \(dome.ledCount). Use \(l.count)", systemImage: "exclamationmark.triangle")
                            }
                        }
                    } else {
                        Text("No light positions").foregroundStyle(.secondary)
                    }
                    Button { importingLights = true } label: { Label("Import an .lp file", systemImage: "doc.badge.plus") }
                    if dome.lightsAreCustom {
                        Button { dome.useDefaultLights() } label: {
                            Label("Use the default (\(DomeMIDI.defaultLightsName))", systemImage: "arrow.uturn.backward")
                        }
                    }
                } header: {
                    Text("Light positions")
                } footer: {
                    Text("A relight .lp file: line 1 of the list is LED 1, line 2 is LED 2, and so on. With it, each dome photo gets its LED's light direction, so the sphere isn't needed. The x and y axes must match how the phone sits on the dome (x to the right of the photo, y to its top).")
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
                    Text("Each LED is lit this long before its photo, then the app saves the first camera frame exposed entirely under it and turns the LED off. Longer is steadier; shorter is faster. LED 1 is MIDI note 0 on channel 1, LED 2 is note 1, and so on.")
                }

                Section {
                    Toggle("Light an LED while framing", isOn: $dome.previewOn)
                    Stepper("Framing LED: \(dome.previewLED + 1)", value: $dome.previewLED, in: 0...max(0, dome.ledCount - 1))
                        .disabled(!dome.previewOn)
                } footer: {
                    Text("Set focus and exposure with this LED on, then tap Lock.")
                }

            }
            .navigationTitle("Light dome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { dome.refresh() }
            .onChange(of: dome.previewOn) { dome.showPreview() }
            .onChange(of: dome.previewLED) { dome.showPreview() }
            .onChange(of: dome.velocity) { dome.showPreview() }
            .onChange(of: dome.ledCount) {
                if dome.previewLED >= dome.ledCount { dome.previewLED = dome.ledCount - 1 }
            }
            .fileImporter(isPresented: $importingLights, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    do { try dome.importLights(from: url) } catch { lightsError = error.localizedDescription }
                case .failure(let e):
                    lightsError = e.localizedDescription
                }
            }
            .alert("Can't use this file", isPresented: Binding(get: { lightsError != nil }, set: { if !$0 { lightsError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(lightsError ?? "") }
            .sheet(isPresented: $showBluetooth, onDismiss: { dome.refresh() }) {
                BluetoothMIDIView { showBluetooth = false }.ignoresSafeArea()
            }
        }
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

/// Light directions seen from above (x right, y up), like the project's light plot. `highlight` marks one LED.
struct DirectionsPlot: View {
    let directions: [[Double]]
    var highlight: Int?

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 4
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for f in [1.0, cos(Double.pi / 6), cos(Double.pi / 3)] {
                let rr = r * f
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                           with: .color(.secondary.opacity(f == 1 ? 0.8 : 0.35)), lineWidth: 1)
            }
            for (i, d) in directions.enumerated() where d.count == 3 {
                let p = CGPoint(x: c.x + d[0] * r, y: c.y - d[1] * r)
                let big = i == highlight
                let s: CGFloat = big ? 9 : 5
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                         with: .color(big ? .yellow : .orange))
            }
        }
        .accessibilityLabel("\(directions.count) light positions seen from above")
    }
}
