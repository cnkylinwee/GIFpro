import AppKit
import OSLog
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var coordinator: RecordingCoordinator
    let permissionService: PermissionService

    var body: some View {
        Button(coordinator.recordingCommandTitle) {
            Task { await coordinator.toggleRecording() }
        }

        Button("打开屏幕录制设置") {
            do {
                try permissionService.openSettings()
            } catch {
                Logger.permissions.error("Could not open Screen Recording settings: \(error.localizedDescription, privacy: .public)")
            }
        }

        Divider()

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}

private extension Logger {
    static let permissions = Logger(subsystem: "com.gifpro.app", category: "Permissions")
}
