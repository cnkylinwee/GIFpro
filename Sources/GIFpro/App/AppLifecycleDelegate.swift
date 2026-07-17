import AppKit
import OSLog

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var terminationReplyIsPending = false

    private lazy var hotKeyController = GlobalHotKeyController { [weak self] in
        guard let self else { return }
        Task { @MainActor in await self.environment.coordinator.toggleRecording() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try environment.coordinator.cleanupStaleFiles()
            try hotKeyController.start()
        } catch {
            Logger.lifecycle.error("Startup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = environment.coordinator.recheckPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard environment.coordinator.hasActiveOrUnsavedWork else { return .terminateNow }
        guard !terminationReplyIsPending else { return .terminateLater }
        terminationReplyIsPending = true
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            await self.environment.coordinator.prepareForTermination()
            guard self.terminationReplyIsPending else { return }
            self.terminationReplyIsPending = false
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        do {
            try hotKeyController.stop()
        } catch {
            Logger.lifecycle.error("Could not unregister ⌥⌘G: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Logger {
    fileprivate static let lifecycle = Logger(subsystem: "com.gifpro.app", category: "Lifecycle")
}
