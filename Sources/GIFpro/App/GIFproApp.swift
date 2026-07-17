import AppKit
import OSLog
import SwiftUI

enum AppIdentity {
    static let name = "GIFpro"
    static let minimumSystemVersion = "14.0"
}

@main
struct GIFproApp: App {
    @NSApplicationDelegateAdaptor(GIFproApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("GIFpro", systemImage: "record.circle") {
            MenuBarContent(
                commandRouter: appDelegate.commandRouter,
                permissionService: appDelegate.permissionService
            )
        }
    }
}

@MainActor
final class GIFproApplicationDelegate: NSObject, NSApplicationDelegate {
    let commandRouter = RecordingCommandRouter()
    let permissionService = PermissionService()

    private lazy var hotKeyController = GlobalHotKeyController { [weak self] in
        self?.commandRouter.performRecordingCommand()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try hotKeyController.start()
        } catch {
            Logger.lifecycle.error("Could not register ⌥⌘G: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = permissionService.recheckAccess()
    }

    func applicationWillTerminate(_ notification: Notification) {
        do {
            try hotKeyController.stop()
        } catch {
            Logger.lifecycle.error("Could not unregister ⌥⌘G: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension Logger {
    static let lifecycle = Logger(subsystem: "com.gifpro.app", category: "Lifecycle")
}
