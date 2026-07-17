import AppKit
import CoreGraphics

struct DisplayConfigurationChange: Equatable, Sendable {
    let added: Set<CGDirectDisplayID>
    let removed: Set<CGDirectDisplayID>
}

@MainActor
final class DisplayConfigurationMonitor {
    typealias ScreenIDProvider = @MainActor () -> Set<CGDirectDisplayID>
    typealias ChangeHandler = @MainActor @Sendable (DisplayConfigurationChange) -> Void

    private let notificationCenter: NotificationCenter
    private let screenIDProvider: ScreenIDProvider
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private var previousIDs: Set<CGDirectDisplayID> = []

    init(
        notificationCenter: NotificationCenter = .default,
        screenIDProvider: @escaping ScreenIDProvider = DisplayConfigurationMonitor.currentScreenIDs
    ) {
        self.notificationCenter = notificationCenter
        self.screenIDProvider = screenIDProvider
    }

    func start(onChange: @escaping ChangeHandler) {
        stop()
        previousIDs = screenIDProvider()
        observer = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenParametersChanged(onChange: onChange)
            }
        }
    }

    func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    private func screenParametersChanged(onChange: ChangeHandler) {
        let currentIDs = screenIDProvider()
        let change = DisplayConfigurationChange(
            added: currentIDs.subtracting(previousIDs),
            removed: previousIDs.subtracting(currentIDs)
        )
        previousIDs = currentIDs
        guard !change.added.isEmpty || !change.removed.isEmpty else { return }
        onChange(change)
    }

    private static func currentScreenIDs() -> Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap(\.directDisplayID))
    }
}

extension NSScreen {
    var directDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
