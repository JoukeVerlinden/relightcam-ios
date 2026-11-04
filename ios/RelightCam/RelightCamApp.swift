import SwiftUI

@main
struct RelightCamApp: App {
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
