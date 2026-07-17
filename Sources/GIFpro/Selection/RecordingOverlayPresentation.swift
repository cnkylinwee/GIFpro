import AppKit
import CoreGraphics

struct OverlayDisplayDescriptor: Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScaleFactor: CGFloat
}

@MainActor
protocol SelectionOverlayEnvironment {
    var displays: [OverlayDisplayDescriptor] { get }
    func makeSelectionPanel(for display: OverlayDisplayDescriptor) -> SelectionOverlayPanel
    func makeAuxiliaryPanel(frame: CGRect, contentView: NSView) -> NSPanel
}

@MainActor
struct AppKitSelectionOverlayEnvironment: SelectionOverlayEnvironment {
    var displays: [OverlayDisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.directDisplayID else { return nil }
            return OverlayDisplayDescriptor(
                displayID: displayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                backingScaleFactor: screen.backingScaleFactor
            )
        }
    }

    func makeSelectionPanel(for display: OverlayDisplayDescriptor) -> SelectionOverlayPanel {
        let screen = NSScreen.screens.first { $0.directDisplayID == display.displayID }
        return SelectionOverlayPanel(
            contentRect: display.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
    }

    func makeAuxiliaryPanel(frame: CGRect, contentView: NSView) -> NSPanel {
        NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }
}

enum RecordingOverlayPresentation {
    enum Input: Equatable {
        case statusOnly
        case recording
    }

    enum Mode: Equatable {
        case statusOnly
        case horizontal
        case vertical
        case stopOnly
        case unavailable
    }

    struct Output: Equatable {
        let statusFrame: CGRect?
        let stopFrame: CGRect?
        let mode: Mode
    }

    static let statusHeight: CGFloat = 28
    static let minimumStatusWidth: CGFloat = 100
    static let maximumStatusWidth: CGFloat = 220
    static let stopSize = CGSize(width: 44, height: 44)
    static let gap: CGFloat = 8

    static func layout(
        input: Input,
        selectionRect: CGRect,
        visibleFrame: CGRect,
        errorSink: (String) -> Void = { _ in }
    ) -> Output {
        switch input {
        case .statusOnly:
            let width = min(maximumStatusWidth, max(minimumStatusWidth, selectionRect.width))
            let size = CGSize(width: min(width, visibleFrame.width), height: min(statusHeight, visibleFrame.height))
            guard size.width > 0, size.height > 0 else {
                return Output(statusFrame: nil, stopFrame: nil, mode: .unavailable)
            }
            let origin = positionedOrigin(
                size: size,
                centeredOn: selectionRect,
                visibleFrame: visibleFrame
            )
            return Output(statusFrame: CGRect(origin: origin, size: size), stopFrame: nil, mode: .statusOnly)

        case .recording:
            guard visibleFrame.width >= stopSize.width, visibleFrame.height >= stopSize.height else {
                errorSink("Recording overlay cannot fit the 44x44 stop control in the visible frame")
                return Output(statusFrame: nil, stopFrame: nil, mode: .unavailable)
            }
            let desiredStatusWidth = min(
                maximumStatusWidth,
                max(minimumStatusWidth, selectionRect.width - stopSize.width - gap)
            )
            let horizontalStatusWidth = min(
                desiredStatusWidth,
                visibleFrame.width - gap - stopSize.width
            )
            let horizontalWidth = horizontalStatusWidth + gap + stopSize.width
            if horizontalStatusWidth >= minimumStatusWidth, visibleFrame.height >= stopSize.height {
                let comboSize = CGSize(width: horizontalWidth, height: stopSize.height)
                let origin = positionedOrigin(size: comboSize, centeredOn: selectionRect, visibleFrame: visibleFrame)
                return Output(
                    statusFrame: CGRect(
                        x: origin.x,
                        y: origin.y + (stopSize.height - statusHeight) / 2,
                        width: horizontalStatusWidth,
                        height: statusHeight
                    ),
                    stopFrame: CGRect(
                        origin: CGPoint(x: origin.x + horizontalStatusWidth + gap, y: origin.y),
                        size: stopSize
                    ),
                    mode: .horizontal
                )
            }

            let verticalStatusWidth = min(desiredStatusWidth, visibleFrame.width)
            let verticalHeight = statusHeight + gap + stopSize.height
            if visibleFrame.width >= stopSize.width, visibleFrame.height >= verticalHeight {
                let comboSize = CGSize(width: verticalStatusWidth, height: verticalHeight)
                let origin = positionedOrigin(size: comboSize, centeredOn: selectionRect, visibleFrame: visibleFrame)
                return Output(
                    statusFrame: CGRect(origin: CGPoint(x: origin.x, y: origin.y + stopSize.height + gap), size: CGSize(width: verticalStatusWidth, height: statusHeight)),
                    stopFrame: CGRect(origin: CGPoint(x: origin.x + (verticalStatusWidth - stopSize.width) / 2, y: origin.y), size: stopSize),
                    mode: .vertical
                )
            }

            let origin = clampedOrigin(
                CGPoint(x: selectionRect.midX - stopSize.width / 2, y: selectionRect.maxY - stopSize.height),
                size: stopSize,
                visibleFrame: visibleFrame
            )
            return Output(statusFrame: nil, stopFrame: CGRect(origin: origin, size: stopSize), mode: .stopOnly)
        }
    }

    private static func positionedOrigin(
        size: CGSize,
        centeredOn selectionRect: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let x = min(
            max(selectionRect.midX - size.width / 2, visibleFrame.minX),
            visibleFrame.maxX - size.width
        )
        let belowY = selectionRect.minY - gap - size.height
        if belowY >= visibleFrame.minY {
            return CGPoint(x: x, y: belowY)
        }
        let aboveY = selectionRect.maxY + gap
        if aboveY + size.height <= visibleFrame.maxY {
            return CGPoint(x: x, y: aboveY)
        }
        return clampedOrigin(
            CGPoint(x: x, y: selectionRect.maxY - size.height),
            size: size,
            visibleFrame: visibleFrame
        )
    }

    private static func clampedOrigin(_ origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
    }
}

enum RecordingOverlayLifecyclePhase: Equatable {
    case hidden
    case selecting
    case countingDown
    case recording
    case stopping
}

struct RecordingOverlayLifecycleSnapshot: Equatable {
    let phase: RecordingOverlayLifecyclePhase
    let ownerDisplayID: CGDirectDisplayID?
    let overlayDisplayIDs: Set<CGDirectDisplayID>
    let nonOwnerDisplayIDs: Set<CGDirectDisplayID>
    let hasControlPanel: Bool
    let hasStatusPanel: Bool
    let hasStopPanel: Bool
    let overlayIgnoresMouseEvents: Bool
    let statusIgnoresMouseEvents: Bool
    let stopIgnoresMouseEvents: Bool
    let generation: UInt64
}

struct RecordingOverlayLifecycle {
    private(set) var snapshot = RecordingOverlayLifecycleSnapshot(
        phase: .hidden,
        ownerDisplayID: nil,
        overlayDisplayIDs: [],
        nonOwnerDisplayIDs: [],
        hasControlPanel: false,
        hasStatusPanel: false,
        hasStopPanel: false,
        overlayIgnoresMouseEvents: true,
        statusIgnoresMouseEvents: true,
        stopIgnoresMouseEvents: false,
        generation: 0
    )

    mutating func beginSelecting(displayIDs: Set<CGDirectDisplayID>) {
        advanceGeneration()
        snapshot = RecordingOverlayLifecycleSnapshot(
            phase: .selecting,
            ownerDisplayID: nil,
            overlayDisplayIDs: displayIDs,
            nonOwnerDisplayIDs: displayIDs,
            hasControlPanel: false,
            hasStatusPanel: false,
            hasStopPanel: false,
            overlayIgnoresMouseEvents: false,
            statusIgnoresMouseEvents: true,
            stopIgnoresMouseEvents: false,
            generation: snapshot.generation
        )
    }

    mutating func claimOwner(_ displayID: CGDirectDisplayID, hasControlPanel: Bool) {
        guard snapshot.phase == .selecting, snapshot.overlayDisplayIDs.contains(displayID) else { return }
        replace(ownerDisplayID: displayID, nonOwnerDisplayIDs: snapshot.overlayDisplayIDs.subtracting([displayID]), hasControlPanel: hasControlPanel)
    }

    mutating func setControlPanel(_ exists: Bool) {
        guard snapshot.phase == .selecting else { return }
        replace(hasControlPanel: exists)
    }

    mutating func setAuxiliaryPanels(status: Bool, stop: Bool) {
        replace(hasStatusPanel: status, hasStopPanel: stop)
    }

    mutating func beginCountdown() {
        guard snapshot.phase == .selecting, let owner = snapshot.ownerDisplayID else { return }
        replace(
            phase: .countingDown,
            overlayDisplayIDs: [owner],
            nonOwnerDisplayIDs: [],
            hasControlPanel: false,
            hasStatusPanel: true,
            hasStopPanel: false,
            overlayIgnoresMouseEvents: true
        )
    }

    mutating func beginRecording() {
        guard snapshot.phase == .countingDown else { return }
        advanceGeneration()
        replace(phase: .recording, hasStatusPanel: true, hasStopPanel: true)
    }

    mutating func beginStopping() {
        guard snapshot.phase == .recording else { return }
        advanceGeneration()
        replace(phase: .stopping, hasStatusPanel: true, hasStopPanel: false)
    }

    mutating func consumeStopControl() {
        guard snapshot.phase == .recording, snapshot.hasStopPanel else { return }
        advanceGeneration()
        replace(hasStopPanel: false)
    }

    mutating func hide() {
        advanceGeneration()
        let generation = snapshot.generation
        snapshot = RecordingOverlayLifecycle().snapshot
        replace(generation: generation)
    }

    mutating func displayInvalidated() { hide() }

    private mutating func advanceGeneration() {
        replace(generation: snapshot.generation &+ 1)
    }

    private mutating func replace(
        phase: RecordingOverlayLifecyclePhase? = nil,
        ownerDisplayID: CGDirectDisplayID?? = nil,
        overlayDisplayIDs: Set<CGDirectDisplayID>? = nil,
        nonOwnerDisplayIDs: Set<CGDirectDisplayID>? = nil,
        hasControlPanel: Bool? = nil,
        hasStatusPanel: Bool? = nil,
        hasStopPanel: Bool? = nil,
        overlayIgnoresMouseEvents: Bool? = nil,
        generation: UInt64? = nil
    ) {
        snapshot = RecordingOverlayLifecycleSnapshot(
            phase: phase ?? snapshot.phase,
            ownerDisplayID: ownerDisplayID ?? snapshot.ownerDisplayID,
            overlayDisplayIDs: overlayDisplayIDs ?? snapshot.overlayDisplayIDs,
            nonOwnerDisplayIDs: nonOwnerDisplayIDs ?? snapshot.nonOwnerDisplayIDs,
            hasControlPanel: hasControlPanel ?? snapshot.hasControlPanel,
            hasStatusPanel: hasStatusPanel ?? snapshot.hasStatusPanel,
            hasStopPanel: hasStopPanel ?? snapshot.hasStopPanel,
            overlayIgnoresMouseEvents: overlayIgnoresMouseEvents ?? snapshot.overlayIgnoresMouseEvents,
            statusIgnoresMouseEvents: true,
            stopIgnoresMouseEvents: false,
            generation: generation ?? snapshot.generation
        )
    }
}

@MainActor
final class OneShotActionTarget: NSObject {
    let generation: UInt64
    private(set) var fired = false
    private weak var control: NSControl?
    private let currentGeneration: () -> UInt64
    private let beforeAction: () -> Void
    private let action: () -> Void

    private init(
        control: NSControl,
        generation: UInt64,
        currentGeneration: @escaping () -> UInt64,
        beforeAction: @escaping () -> Void,
        action: @escaping () -> Void
    ) {
        self.control = control
        self.generation = generation
        self.currentGeneration = currentGeneration
        self.beforeAction = beforeAction
        self.action = action
    }

    @objc private func invoke() {
        guard !fired else { return }
        guard generation == currentGeneration() else {
            control?.isEnabled = false
            return
        }
        fired = true
        control?.isEnabled = false
        beforeAction()
        action()
    }

    static func install(
        on control: NSControl,
        generation: UInt64,
        currentGeneration: @escaping () -> UInt64,
        beforeAction: @escaping () -> Void,
        action: @escaping () -> Void
    ) -> OneShotActionTarget {
        let target = OneShotActionTarget(
            control: control,
            generation: generation,
            currentGeneration: currentGeneration,
            beforeAction: beforeAction,
            action: action
        )
        control.target = target
        control.action = #selector(invoke)
        objc_setAssociatedObject(control, &oneShotAssociationKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return target
    }
}

private nonisolated(unsafe) var oneShotAssociationKey: UInt8 = 0
