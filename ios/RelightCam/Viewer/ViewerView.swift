import SwiftUI

struct ViewerView: View {
    let project: Project
    @State private var model = ViewerModel()
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .bottom) {
            RTIMetalView(dir: project.rtiDir, model: model, mode: model.mode, gain: model.gain,
                         light: model.light, tilt: model.tilt, recenter: model.recenter)
                .ignoresSafeArea()
            if let e = model.error {
                Text(e).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            }
            if showControls {
                VStack(spacing: 10) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(spacing: 6) {
                            LightIndicator(light: model.light)
                                .frame(width: 64, height: 64)
                                .onTapGesture { if model.tilt { model.recenter += 1 } }
                            Toggle(isOn: $model.tilt) {
                                Label("Tilt", systemImage: "iphone.gen3.radiowaves.left.and.right")
                            }
                            .toggleStyle(.button)
                            .font(.caption.bold())
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Mode", selection: $model.mode) {
                                ForEach(ViewerModel.Mode.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            HStack {
                                Image(systemName: "sun.min")
                                Slider(value: $model.gain, in: 0.5...3)
                                Image(systemName: "sun.max")
                            }
                            .font(.caption)
                            .disabled(model.mode == .normals || model.mode == .shaded)
                        }
                    }
                    HStack {
                        Text(model.tilt
                             ? "Tilt the phone to move the light · tap the dome to re-center · pinch to zoom"
                             : "Drag or tap to move the light · pinch to zoom · two fingers to pan · double-tap to reset")
                            .font(.caption2).foregroundStyle(.secondary)
                        if model.tilt {
                            Spacer()
                            Button("Re-center") { model.recenter += 1 }.font(.caption.bold())
                        }
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .environment(\.colorScheme, .dark)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(project.meta.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black.opacity(0.55), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            // test hooks: -light x,y  -mode n
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-light"), i + 1 < args.count {
                let v = args[i + 1].split(separator: ",").compactMap { Float($0) }
                if v.count == 2 { model.light = SIMD3(v[0], v[1], max(0, 1 - v[0] * v[0] - v[1] * v[1]).squareRoot()) }
            }
            if let i = args.firstIndex(of: "-mode"), i + 1 < args.count, let m = Int(args[i + 1]), let mode = ViewerModel.Mode(rawValue: m) {
                model.mode = mode
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation { showControls.toggle() } } label: {
                    Image(systemName: showControls ? "slider.horizontal.below.rectangle" : "slider.horizontal.3")
                }
            }
        }
    }
}

/// Top view of the light dome with the current direction.
struct LightIndicator: View {
    var light: SIMD3<Float>
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.black.opacity(0.35)))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.6)), lineWidth: 1)
            let p = CGPoint(x: c.x + CGFloat(light.x) * r, y: c.y - CGFloat(light.y) * r)
            var line = Path(); line.move(to: c); line.addLine(to: p)
            ctx.stroke(line, with: .color(.yellow.opacity(0.6)), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.yellow))
        }
    }
}
