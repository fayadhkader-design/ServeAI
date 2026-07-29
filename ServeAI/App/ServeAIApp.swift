import SwiftData
import SwiftUI

@main
struct ServeAIApp: App {
    init() {
        FontRegistrar.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: ServeAnalysis.self)
    }
}
