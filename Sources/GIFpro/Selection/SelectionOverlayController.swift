import AppKit
import CoreGraphics

enum RecordingOverlayStatusContent {
    static func countdown(_ value: Int) -> String { "\(value)" }

    static func recording(elapsed: TimeInterval, remaining: TimeInterval) -> String {
        String(
            format: "%02d:%02d  剩余 %02d:%02d",
            Int(elapsed) / 60,
            Int(elapsed) % 60,
            Int(remaining) / 60,
            Int(remaining) % 60
        )
    }

    static let stopping = "正在完成…"
}

enum RecordingOverlayAuxiliaryPhase: Equatable {
    case hidden
    case countdown
    case recording
    case stopping
}

struct RecordingOverlayAuxiliaryState: Equatable {
    private(set) var phase: RecordingOverlayAuxiliaryPhase

    static let hidden = RecordingOverlayAuxiliaryState(phase: .hidden)

    var showsStatusPanel: Bool { phase != .hidden }
    var showsStopPanel: Bool { phase == .recording }

    mutating func transition(to phase: RecordingOverlayAuxiliaryPhase) {
        self.phase = phase
    }
}

struct RecordingOverlayAuxiliarySnapshot: Equatable {
    let phase: RecordingOverlayAuxiliaryPhase
    let hasStatusPanel: Bool
    let hasStopPanel: Bool
}

@MainActor
final class SelectionOverlayController {
    var onSettingsChanged: ((RecordingSettings) -> Void)?
    var onRecord: ((CaptureRegion, RecordingSettings) -> Void)?
    var onCancel: (() -> Void)?
    var onDisplayConfigurationChanged: ((DisplayConfigurationChange) -> Void)?

    private struct Overlay {
        let screen: NSScreen
        let panel: SelectionOverlayPanel
        let view: SelectionOverlayView
    }

    private enum VisualState {
        case hidden
        case selecting
        case countingDown
        case recording
        case stopping
    }

    private let converter: DisplayCoordinateConverter
    private let displayMonitor: DisplayConfigurationMonitor
    private let auxiliaryPanelInstallationGate: (RecordingOverlayAuxiliaryPhase) -> Bool
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var ownerDisplayID: CGDirectDisplayID?
    private var controlPanel: NSPanel?
    private var statusPanel: NSPanel?
    private var stopPanel: NSPanel?
    private var settings = RecordingSettings.default
    private var visualState = VisualState.hidden
    private(set) var auxiliaryState = RecordingOverlayAuxiliaryState.hidden

    var auxiliarySnapshot: RecordingOverlayAuxiliarySnapshot {
        RecordingOverlayAuxiliarySnapshot(
            phase: auxiliaryState.phase,
            hasStatusPanel: statusPanel != nil,
            hasStopPanel: stopPanel != nil
        )
    }

    var selectionOverlayViews: [CGDirectDisplayID: SelectionOverlayView] {
        overlays.mapValues(\.view)
    }

    init(
        converter: DisplayCoordinateConverter = DisplayCoordinateConverter(),
        auxiliaryPanelInstallationGate: @escaping (RecordingOverlayAuxiliaryPhase) -> Bool = { _ in true }
    ) {
        self.converter = converter
        self.displayMonitor = DisplayConfigurationMonitor()
        self.auxiliaryPanelInstallationGate = auxiliaryPanelInstallationGate
    }

    init(
        converter: DisplayCoordinateConverter,
        displayMonitor: DisplayConfigurationMonitor
    ) {
        self.converter = converter
        self.displayMonitor = displayMonitor
        self.auxiliaryPanelInstallationGate = { _ in true }
    }

    func show(settings: RecordingSettings = .default) {
        guard overlays.isEmpty else { return }
        self.settings = settings
        visualState = .selecting
        for screen in NSScreen.screens {
            guard let displayID = screen.directDisplayID else { continue }
            installOverlay(for: screen, displayID: displayID)
        }
        displayMonitor.start { [weak self] change in
            guard let self else { return }
            self.onDisplayConfigurationChanged?(change)
        }
    }

    func dismiss() {
        displayMonitor.stop()
        controlPanel?.close()
        controlPanel = nil
        statusPanel?.close()
        statusPanel = nil
        stopPanel?.close()
        stopPanel = nil
        auxiliaryState.transition(to: .hidden)
        for overlay in overlays.values {
            overlay.panel.onEscape = nil
            overlay.panel.close()
        }
        overlays.removeAll()
        ownerDisplayID = nil
        visualState = .hidden
    }

    func showCountdown(value: Int, targetDisplayID: CGDirectDisplayID) {
        guard visualState == .selecting,
              auxiliaryState.phase == .hidden,
              let overlay = validOwnerOverlay(targetDisplayID: targetDisplayID) else { return }
        var proposedState = auxiliaryState
        proposedState.transition(to: .countdown)
        guard installStatusPanels(
            for: proposedState,
            overlay: overlay,
            text: RecordingOverlayStatusContent.countdown(value),
            onStop: nil
        ) else { return }
        visualState = .countingDown
        auxiliaryState = proposedState
        configureStatusOnlyVisualState()
    }

    func updateCountdown(_ value: Int) {
        guard visualState == .countingDown,
              auxiliaryState.phase == .countdown,
              statusPanel != nil else { return }
        updateStatusPanel(text: RecordingOverlayStatusContent.countdown(value))
    }

    func startRecordingVisualState(onStop: @escaping () -> Void) {
        guard visualState == .countingDown,
              auxiliaryState.phase == .countdown,
              statusPanel != nil,
              stopPanel == nil,
              let overlay = validOwnerOverlay() else { return }
        var proposedState = auxiliaryState
        proposedState.transition(to: .recording)
        guard installStatusPanels(
            for: proposedState,
            overlay: overlay,
            text: RecordingOverlayStatusContent.recording(elapsed: 0, remaining: 0),
            onStop: onStop
        ) else { return }
        visualState = .recording
        auxiliaryState = proposedState
        configureStatusOnlyVisualState()
    }

    func updateRecordingStatus(
        elapsed: TimeInterval,
        remaining: TimeInterval,
        isWarning: Bool
    ) {
        guard visualState == .recording,
              auxiliaryState.phase == .recording,
              statusPanel != nil,
              stopPanel != nil else { return }
        updateStatusPanel(
            text: RecordingOverlayStatusContent.recording(elapsed: elapsed, remaining: remaining),
            isWarning: isWarning
        )
    }

    func showStoppingVisualState() {
        guard visualState == .recording,
              auxiliaryState.phase == .recording,
              statusPanel != nil,
              stopPanel != nil else { return }
        stopPanel?.close()
        stopPanel = nil
        visualState = .stopping
        auxiliaryState.transition(to: .stopping)
        updateStatusPanel(text: RecordingOverlayStatusContent.stopping)
    }

    private func configureStatusOnlyVisualState() {
        controlPanel?.close()
        controlPanel = nil
        for (displayID, overlay) in overlays {
            if displayID != ownerDisplayID {
                overlay.panel.close()
                continue
            }
            overlay.view.showsDimming = false
            overlay.view.showsHandles = false
            overlay.view.isInteractive = false
            overlay.panel.handlesEscape = false
            overlay.panel.onEscape = nil
            overlay.panel.ignoresMouseEvents = RecordingOverlayMousePolicy.selectionVisualsIgnoreMouseEvents
            overlay.panel.resignKey()
        }
    }

    private func installStatusPanels(
        for proposedState: RecordingOverlayAuxiliaryState,
        overlay: Overlay,
        text: String,
        onStop: (() -> Void)?
    ) -> Bool {
        guard proposedState.showsStatusPanel,
              auxiliaryPanelInstallationGate(proposedState.phase),
              let selectionRect = overlay.view.selectionRect else { return false }
        let globalSelection = overlay.panel.convertToScreen(selectionRect)
        let layout = RecordingOverlayPanelLayout(
            selectionRect: globalSelection,
            visibleFrame: overlay.screen.visibleFrame
        )
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        label.drawsBackground = true
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        let status = makeAuxiliaryPanel(frame: layout.statusFrame, contentView: label)
        status.ignoresMouseEvents = RecordingOverlayMousePolicy.statusTextIgnoresMouseEvents

        var proposedStopPanel: NSPanel?
        if proposedState.showsStopPanel {
            guard let onStop else { return false }
            let button = NSButton(title: "停止", target: nil, action: nil)
            button.bezelStyle = .rounded
            button.bezelColor = .systemRed
            button.contentTintColor = .white
            button.target = ClosureActionTarget.install(on: button, action: onStop)
            let stop = makeAuxiliaryPanel(frame: layout.stopFrame, contentView: button)
            stop.ignoresMouseEvents = RecordingOverlayMousePolicy.stopButtonIgnoresMouseEvents
            proposedStopPanel = stop
        }

        statusPanel?.close()
        stopPanel?.close()
        statusPanel = status
        stopPanel = proposedStopPanel
        status.orderFrontRegardless()
        proposedStopPanel?.orderFrontRegardless()
        return true
    }

    private func updateStatusPanel(text: String, isWarning: Bool = false) {
        guard let label = statusPanel?.contentView as? NSTextField else { return }
        label.stringValue = text
        label.textColor = isWarning ? .systemYellow : .white
    }

    private func makeAuxiliaryPanel(frame: CGRect, contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView.frame = CGRect(origin: .zero, size: frame.size)
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView
        return panel
    }

    private func validOwnerOverlay(targetDisplayID: CGDirectDisplayID? = nil) -> Overlay? {
        guard let ownerDisplayID,
              targetDisplayID == nil || targetDisplayID == ownerDisplayID,
              let overlay = overlays[ownerDisplayID],
              let selectionRect = overlay.view.selectionRect,
              selectionRect.width >= SelectionGeometry.minimumSize.width,
              selectionRect.height >= SelectionGeometry.minimumSize.height,
              overlay.view.bounds.contains(selectionRect) else { return nil }
        return overlay
    }

    private func installOverlay(for screen: NSScreen, displayID: CGDirectDisplayID) {
        let panel = SelectionOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.onEscape = { [weak self] in self?.cancelSelection() }

        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        view.onDragBegan = { [weak self] in self?.claimOwnership(displayID: displayID) ?? false }
        view.onSelectionCompleted = { [weak self] rect in self?.selectionCompleted(rect, displayID: displayID) }
        panel.contentView = view
        overlays[displayID] = Overlay(screen: screen, panel: panel, view: view)
        panel.orderFrontRegardless()
    }

    private func claimOwnership(displayID: CGDirectDisplayID) -> Bool {
        if let ownerDisplayID { return ownerDisplayID == displayID }
        ownerDisplayID = displayID
        for (otherID, overlay) in overlays where otherID != displayID {
            overlay.view.isInteractive = false
        }
        overlays[displayID]?.panel.makeKey()
        return true
    }

    private func selectionCompleted(_ localRect: CGRect, displayID: CGDirectDisplayID) {
        guard ownerDisplayID == displayID,
              let overlay = overlays[displayID],
              localRect.width >= SelectionGeometry.minimumSize.width,
              localRect.height >= SelectionGeometry.minimumSize.height else { return }
        presentControls(for: localRect, overlay: overlay)
    }

    private func presentControls(for localRect: CGRect, overlay: Overlay) {
        controlPanel?.close()
        let supportsTwoX = overlay.screen.backingScaleFactor >= 2
        let controls = SelectionControlsView(settings: settings, supportsTwoX: supportsTwoX)
        let previousSettings = settings
        settings = controls.settings
        if settings != previousSettings { onSettingsChanged?(settings) }
        controls.onSettingsChanged = { [weak self] settings in
            self?.settings = settings
            self?.onSettingsChanged?(settings)
        }
        controls.onRecord = { [weak self] in self?.recordSelection() }
        controls.onCancel = { [weak self] in self?.cancelSelection() }

        let size = controls.fittingSize
        let panelSize = CGSize(width: max(size.width, 500), height: max(size.height, 52))
        let globalRect = overlay.panel.convertToScreen(localRect)
        let screenFrame = overlay.screen.frame
        let proposedY = globalRect.minY - panelSize.height - 12
        let y = proposedY >= screenFrame.minY
            ? proposedY
            : min(globalRect.maxY + 12, screenFrame.maxY - panelSize.height)
        let x = min(
            max(globalRect.midX - panelSize.width / 2, screenFrame.minX),
            screenFrame.maxX - panelSize.width
        )
        let panel = SelectionControlPanel(
            contentRect: CGRect(origin: CGPoint(x: x, y: y), size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = controls
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.cancelSelection() }
        panel.orderFrontRegardless()
        panel.makeKey()
        controlPanel = panel
    }

    private func recordSelection() {
        guard let ownerDisplayID,
              let overlay = overlays[ownerDisplayID],
              let localRect = overlay.view.selectionRect else { return }
        let globalRect = overlay.panel.convertToScreen(localRect)
        do {
            let region = try converter.convert(
                displayID: ownerDisplayID,
                displayFrame: overlay.screen.frame,
                selection: globalRect,
                backingScale: overlay.screen.backingScaleFactor,
                outputScale: settings.scale
            )
            onRecord?(region, settings)
        } catch {
            NSSound.beep()
        }
    }

    private func cancelSelection() {
        let callback = onCancel
        dismiss()
        callback?()
    }
}
