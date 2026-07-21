import AppKit
import SwiftUI

enum AppIdentity {
    static let name = "GIFpro"
    static let minimumSystemVersion = "14.0"
}

@main
struct GIFproApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("GIFpro", systemImage: "record.circle") {
            MenuBarContent(coordinator: appDelegate.environment.coordinator)
        }
    }
}
