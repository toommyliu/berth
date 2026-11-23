import SwiftUI

@main
struct BerthApp: App {
    @State private var library = Library()

    var body: some Scene {
        Window("Berth", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 980, minHeight: 380)
        }
        .defaultSize(width: 1180, height: 560)
    }
}
