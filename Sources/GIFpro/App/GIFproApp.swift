import SwiftUI

enum AppIdentity {
    static let name = "GIFpro"
    static let minimumSystemVersion = "14.0"
}

@main
struct GIFproApp: App {
    var body: some Scene {
        MenuBarExtra("GIFpro", systemImage: "record.circle") {
            MenuBarContent()
        }
    }
}
