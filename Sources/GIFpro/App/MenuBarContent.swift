import AppKit
import OSLog
import SwiftUI

@MainActor
final class RecordingCommandRouter: ObservableObject {
    @Published var state: RecordingState

    private let logAction: (RecordingState) -> Void

    init(
        state: RecordingState = .idle,
        logAction: @escaping (RecordingState) -> Void = { state in
            Logger.recordingCommands.info("Temporary recording command received in state: \(String(describing: state), privacy: .public)")
        }
    ) {
        self.state = state
        self.logAction = logAction
    }

    var recordingCommandTitle: String {
        state == .recording ? "停止录制" : "开始录制"
    }

    func performRecordingCommand() {
        logAction(state)
    }
}

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
    static let recordingCommands = Logger(subsystem: "com.gifpro.app", category: "RecordingCommand")
    static let permissions = Logger(subsystem: "com.gifpro.app", category: "Permissions")
}
