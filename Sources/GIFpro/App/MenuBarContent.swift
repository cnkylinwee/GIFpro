import AppKit
import OSLog
import SwiftUI

enum MenuBarRecoveryAction: Equatable, Sendable {
    case recheckPermission
    case rerecord
    case saveAgain
}

struct MenuBarIssue: Equatable, Sendable {
    let message: String
    let actionTitle: String?
    let action: MenuBarRecoveryAction?
}

enum MenuBarPresentation {
    static func issue(state: RecordingState, lastFailure: RecordingFailure?, saveWarnings: [TemporaryFileStore.SaveWarning]) -> MenuBarIssue? {
        let failure: RecordingFailure?
        if case .failed(let value) = state { failure = value } else { failure = lastFailure }
        if let failure {
            switch failure {
            case .permissionDenied:
                return .init(message: "需要屏幕录制权限。请打开系统设置授权后重新检查。", actionTitle: "重新检查权限", action: .recheckPermission)
            case .insufficientDiskSpace:
                return .init(message: "磁盘可用空间不足，无法开始录制。", actionTitle: "重新录制", action: .rerecord)
            case .capacityUnavailable:
                return .init(message: "无法读取磁盘可用空间，请检查磁盘后重试。", actionTitle: "重新录制", action: .rerecord)
            case .encoderInitializationFailed:
                return .init(message: "无法创建 GIF 编码器。", actionTitle: "重新录制", action: .rerecord)
            case .captureFailed:
                return .init(message: "屏幕录制意外停止，请重新录制。", actionTitle: "重新录制", action: .rerecord)
            case .finalizationFailed:
                return .init(message: "GIF 生成失败，请重新录制。", actionTitle: "重新录制", action: .rerecord)
            case .saveFailed:
                return .init(message: "保存失败，临时预览仍保留。", actionTitle: "再次另存为", action: .saveAgain)
            }
        }
        guard let warning = saveWarnings.last else { return nil }
        switch warning {
        case .destinationDirectorySyncFailed:
            return .init(message: "GIF 已保存，但目录同步未确认。", actionTitle: nil, action: nil)
        case .sourceCleanupFailed:
            return .init(message: "GIF 已保存，但临时文件稍后清理。", actionTitle: nil, action: nil)
        case .sourceChanged:
            return .init(message: "GIF 已保存；检测到临时文件已变化，未删除替代文件。", actionTitle: nil, action: nil)
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var coordinator: RecordingCoordinator
    let permissionService: PermissionService

    var body: some View {
        if let issue = MenuBarPresentation.issue(
            state: coordinator.state,
            lastFailure: coordinator.lastUserFacingFailure,
            saveWarnings: coordinator.saveWarnings
        ) {
            Text(issue.message)
            if let title = issue.actionTitle, let action = issue.action {
                Button(title) { coordinator.performRecoveryAction(action) }
            }
            Divider()
        }

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
