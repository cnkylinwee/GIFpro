import AppKit
import OSLog

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    let environment: AppEnvironment
    private var terminationReplyIsPending = false

    override init() {
        environment = AppEnvironment()
        super.init()
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    private lazy var hotKeyController = GlobalHotKeyController { [weak self] in
        guard let self else { return }
        Task { @MainActor in await self.environment.coordinator.startRecording(mode: .region) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try startup { try hotKeyController.start() }
        } catch {
            Logger.lifecycle.error("Startup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startup(registerHotKey: () throws -> Void) throws {
        try environment.coordinator.cleanupStaleFiles()
        try registerHotKey()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = environment.coordinator.recheckPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { [weak sender] in
            sender?.reply(toApplicationShouldTerminate: true)
        }
    }

    func requestTermination(
        reply: @escaping @MainActor () -> Void
    ) -> NSApplication.TerminateReply {
        guard environment.coordinator.hasActiveOrUnsavedWork else { return .terminateNow }
        guard !terminationReplyIsPending else { return .terminateLater }
        terminationReplyIsPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.environment.coordinator.prepareForTermination()
            guard self.terminationReplyIsPending else { return }
            self.terminationReplyIsPending = false
            reply()
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
