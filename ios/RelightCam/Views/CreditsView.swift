import SwiftUI

/// Who made relightCam, what it's built on (with licenses) and the methods it implements.
struct CreditsView: View {
    /// test hook -open-license
    @State private var openLicense = ProcessInfo.processInfo.arguments.contains("-open-license")
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image("UAntwerpenLogo").resizable().scaledToFit().frame(height: 44)
                        .accessibilityLabel("University of Antwerp")
                    Text("relightCam \(version)").font(.headline)
                    Text("Developed by Jouke Verlinden at the University of Antwerp.").font(.footnote)
                }
                .padding(.vertical, 6)
                Link(destination: URL(string: "https://github.com/JoukeVerlinden/relightcam-ios")!) {
                    Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                NavigationLink {
                    LicenseTextView(title: "GPL-3.0", resource: "LICENSE-GPL-3.0")
                } label: {
                    LabeledContent("License", value: "GPL-3.0-or-later")
                }
            } footer: {
                Text("relightCam is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3 or later. It comes with ABSOLUTELY NO WARRANTY.")
            }

            Section("Built on") {
                credit("relight", by: "CNR-ISTI Visual Computing Lab",
                       what: "relightCam ports relight's capture-to-RTI pipeline to Swift: highlight detection on the sphere, PTM and HSH fitting, and the web format.",
                       license: "Core LGPL-3.0, GPL-3.0 components", url: "https://github.com/cnr-isti-vclab/relight")
                credit("OpenLIME 1.2.6", by: "CNR-ISTI Visual Computing Lab and CRS4 Visual and Data-intensive Computing Group",
                       what: "The web viewer included in RTI exports.",
                       license: "GPL-3.0", url: "https://github.com/cnr-isti-vclab/openlime")
                Link(destination: URL(string: "https://www.gnu.org/licenses/lgpl-3.0.html")!) {
                    Label("LGPL-3.0 text (gnu.org)", systemImage: "doc.text")
                }
            }

            Section("Methods") {
                reference("Polynomial texture maps (PTM)",
                          "T. Malzbender, D. Gelb, H. Wolters. Polynomial texture maps. SIGGRAPH 2001.")
                reference("Hemispherical harmonics (HSH)",
                          "P. Gautron, J. Křivánek, S. Pattanaik, K. Bouatouch. A novel hemispherical basis for accurate and efficient rendering. EGSR 2004.")
                reference("Photometric stereo (normal maps)",
                          "R. J. Woodham. Photometric method for determining surface orientation from multiple images. Optical Engineering, 1980.")
                reference("Cloth simulation (XPBD, small steps)",
                          "M. Macklin, M. Müller, N. Chentanez. XPBD: position-based simulation of compliant constrained dynamics. MIG 2016. M. Macklin et al. Small steps in physics simulation. SCA 2019.")
                reference("Long-range attachments",
                          "T. Kim, N. Chentanez, M. Müller-Fischer. Long range attachments: a method to simulate inextensible clothing in computer games. SCA 2012.")
                reference("Fabric bending length",
                          "F. T. Peirce. The \"handle\" of cloth as a measurable quantity. Journal of the Textile Institute, 1930.")
            }

            Section {
                Text("Uses Apple's Metal, ARKit, Vision, AVFoundation and Core Motion frameworks.")
                Text("The University of Antwerp name and logo are trademarks of the University of Antwerp. relightCam is not affiliated with CNR-ISTI.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $openLicense) { LicenseTextView(title: "GPL-3.0", resource: "LICENSE-GPL-3.0") }
    }

    private func credit(_ name: String, by: String, what: String, license: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline)
            Text(by).font(.subheadline).foregroundStyle(.secondary)
            Text(what).font(.footnote)
            HStack {
                Text(license).font(.caption.bold())
                Spacer()
                Link("Website", destination: URL(string: url)!).font(.caption)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }

    private func reference(_ topic: String, _ citation: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(topic).font(.subheadline.weight(.semibold))
            Text(citation).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// A license text bundled with the app (Licenses/<resource>.txt), reflowed to the screen width.
struct LicenseTextView: View {
    let title: String
    let resource: String
    @State private var paragraphs: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(paragraphs.indices, id: \.self) { i in
                    Text(paragraphs[i]).font(.footnote)
                }
            }
            .textSelection(.enabled)
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                paragraphs = ["The license text is missing from this build. See https://www.gnu.org/licenses/gpl-3.0.txt"]
                return
            }
            // the file is wrapped at ~72 characters: join the lines of each paragraph so it fits any width
            paragraphs = text.components(separatedBy: "\n\n").map { p in
                p.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }.filter { !$0.isEmpty }
        }
    }
}
