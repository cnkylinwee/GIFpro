import AppKit
import CoreGraphics

struct DisplaySnapshot: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let backingScale: CGFloat
    let rotationDegrees: Double
}

struct DisplayConfigurationChange: Equatable, Sendable {
    let added: Set<CGDirectDisplayID>
    let removed: Set<CGDirectDisplayID>
    let updated: Set<CGDirectDisplayID>
}

final class ScreenParameterObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let action = lock.withLock {
            let action = cancellation
            cancellation = nil
            return action
        }
        action?()
    }

    deinit {
        cancel()
    }
}

@MainActor
protocol ScreenParameterObserving: AnyObject {
    func observe(_ handler: @escaping @MainActor @Sendable () -> Void) -> ScreenParameterObservation
}

@MainActor
private final class NotificationScreenParameterObserver: ScreenParameterObserving {
    private final class TokenBox: @unchecked Sendable {
        let notificationCenter: NotificationCenter
        let token: NSObjectProtocol

        init(notificationCenter: NotificationCenter, token: NSObjectProtocol) {
            self.notificationCenter = notificationCenter
            self.token = token
        }

        func remove() {
            notificationCenter.removeObserver(token)
        }
    }

    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func observe(_ handler: @escaping @MainActor @Sendable () -> Void) -> ScreenParameterObservation {
        let token = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        let box = TokenBox(notificationCenter: notificationCenter, token: token)
        return ScreenParameterObservation { [box] in box.remove() }
    }
}

@MainActor
final class DisplayConfigurationMonitor {
    typealias SnapshotProvider = @MainActor () -> [CGDirectDisplayID: DisplaySnapshot]
    typealias ChangeHandler = @MainActor @Sendable (DisplayConfigurationChange) -> Void

    private let observer: any ScreenParameterObserving
    private let snapshotProvider: SnapshotProvider
    private var observation: ScreenParameterObservation?
    private var previousSnapshots: [CGDirectDisplayID: DisplaySnapshot] = [:]

    init() {
        self.observer = NotificationScreenParameterObserver()
        self.snapshotProvider = DisplayConfigurationMonitor.currentSnapshots
    }

    init(
        observer: any ScreenParameterObserving,
        snapshotProvider: @escaping SnapshotProvider
    ) {
        self.observer = observer
        self.snapshotProvider = snapshotProvider
    }

    func start(onChange: @escaping ChangeHandler) {
        stop()
        previousSnapshots = snapshotProvider()
        observation = observer.observe { [weak self] in
            self?.screenParametersChanged(onChange: onChange)
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    deinit {
        observation?.cancel()
    }

    private func screenParametersChanged(onChange: ChangeHandler) {
        let currentSnapshots = snapshotProvider()
        let previousIDs = Set(previousSnapshots.keys)
        let currentIDs = Set(currentSnapshots.keys)
        let commonIDs = previousIDs.intersection(currentIDs)
        let change = DisplayConfigurationChange(
            added: currentIDs.subtracting(previousIDs),
            removed: previousIDs.subtracting(currentIDs),
            updated: Set(commonIDs.filter { previousSnapshots[$0] != currentSnapshots[$0] })
        )
        previousSnapshots = currentSnapshots
        guard !change.added.isEmpty || !change.removed.isEmpty || !change.updated.isEmpty else { return }
        onChange(change)
    }

    private static func currentSnapshots() -> [CGDirectDisplayID: DisplaySnapshot] {
        Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let displayID = screen.directDisplayID else { return nil }
            return (
                displayID,
                DisplaySnapshot(
                    displayID: displayID,
                    frame: screen.frame,
                    backingScale: screen.backingScaleFactor,
                    rotationDegrees: CGDisplayRotation(displayID)
                )
            )
        })
    }
}

extension DisplayConfigurationMonitor: SelectionOverlayDisplayMonitoring {}

extension NSScreen {
    var directDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
