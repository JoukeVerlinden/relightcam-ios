import SwiftUI

@main
struct RelightCamApp: App {
    @State private var store = ProjectStore()

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-dome-virtual") { DomeMIDI.shared.addVirtualTestDome() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
