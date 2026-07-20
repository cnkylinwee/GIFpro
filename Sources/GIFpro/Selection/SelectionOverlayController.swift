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
        let display: OverlayDisplayDescriptor
        let panel: SelectionOverlayPanel
        let view: SelectionOverlayView
    }

    private let converter: DisplayCoordinateConverter
    private let displayMonitor: any SelectionOverlayDisplayMonitoring
    private let environment: any SelectionOverlayEnvironment
    private let imageLoader: any TemplateControlImageLoading
    private let auxiliaryPanelInstallationGate: (RecordingOverlayAuxiliaryPhase) -> Bool
    private let layoutErrorSink: (String) -> Void
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var ownerDisplayID: CGDirectDisplayID?
    private var controlPanel: NSPanel?
    private var statusPanel: NSPanel?
    private var stopPanel: NSPanel?
    private var settings = RecordingSettings.default
    private var lifecycle = RecordingOverlayLifecycle()
    private(set) var stopActionTarget: OneShotActionTarget?

    var lifecycleSnapshot: RecordingOverlayLifecycleSnapshot { lifecycle.snapshot }

    var auxiliarySnapshot: RecordingOverlayAuxiliarySnapshot {
        RecordingOverlayAuxiliarySnapshot(
            phase: auxiliaryPhase,
            hasStatusPanel: statusPanel != nil,
            hasStopPanel: stopPanel != nil
        )
    }

    var selectionOverlayViews: [CGDirectDisplayID: SelectionOverlayView] {
        overlays.mapValues(\.view)
    }

    init(
        converter: DisplayCoordinateConverter = DisplayCoordinateConverter(),
        imageLoader: (any TemplateControlImageLoading)? = nil,
        environment: (any SelectionOverlayEnvironment)? = nil,
        displayMonitor: (any SelectionOverlayDisplayMonitoring)? = nil,
        auxiliaryPanelInstallationGate: @escaping (RecordingOverlayAuxiliaryPhase) -> Bool = { _ in true },
        layoutErrorSink: @escaping (String) -> Void = { _ in }
    ) {
        self.converter = converter
        self.displayMonitor = displayMonitor ?? DisplayConfigurationMonitor()
        self.environment = environment ?? AppKitSelectionOverlayEnvironment()
        self.imageLoader = imageLoader ?? TemplateControlImageLoader()
        self.auxiliaryPanelInstallationGate = auxiliaryPanelInstallationGate
        self.layoutErrorSink = layoutErrorSink
    }

    init(
        converter: DisplayCoordinateConverter,
        displayMonitor: any SelectionOverlayDisplayMonitoring,
        imageLoader: (any TemplateControlImageLoading)? = nil,
        environment: (any SelectionOverlayEnvironment)? = nil,
        layoutErrorSink: @escaping (String) -> Void = { _ in }
    ) {
        self.converter = converter
        self.displayMonitor = displayMonitor
        self.environment = environment ?? AppKitSelectionOverlayEnvironment()
        self.imageLoader = imageLoader ?? TemplateControlImageLoader()
        self.auxiliaryPanelInstallationGate = { _ in true }
        self.layoutErrorSink = layoutErrorSink
    }

    private var auxiliaryPhase: RecordingOverlayAuxiliaryPhase {
        switch lifecycle.snapshot.phase {
        case .hidden, .selecting: .hidden
        case .countingDown: .countdown
        case .recording: .recording
        case .stopping: .stopping
        }
    }

    func show(settings: RecordingSettings = .default) {
        if !overlays.isEmpty { dismiss() }
        self.settings = settings
        let displays = environment.displays
        lifecycle.beginSelecting(displayIDs: Set(displays.map(\.displayID)))
        for display in displays {
            installOverlay(for: display)
        }
        if let defaultDisplay = displays.first,
           let overlay = overlays[defaultDisplay.displayID],
           claimOwnership(displayID: defaultDisplay.displayID) {
            let defaultRect = SelectionGeometry.defaultRect(within: overlay.view.bounds)
            overlay.view.selectionRect = defaultRect
            presentControls(for: defaultRect, overlay: overlay)
        }
        displayMonitor.start { [weak self] change in
            guard let self else { return }
            self.handleDisplayConfigurationChange(change)
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
        stopActionTarget = nil
        lifecycle.hide()
        for overlay in overlays.values {
            overlay.panel.onEscape = nil
            overlay.panel.close()
        }
        overlays.removeAll()
        ownerDisplayID = nil
    }

    func showCountdown(value: Int, targetDisplayID: CGDirectDisplayID) {
        guard lifecycle.snapshot.phase == .selecting,
              let overlay = validOwnerOverlay(targetDisplayID: targetDisplayID) else { return }
        var proposedLifecycle = lifecycle
        proposedLifecycle.beginCountdown()
        guard installStatusPanels(
            phase: .countdown,
            overlay: overlay,
            text: RecordingOverlayStatusContent.countdown(value),
            onStop: nil
        ) else { return }
        proposedLifecycle.setAuxiliaryPanels(status: statusPanel != nil, stop: false)
        lifecycle = proposedLifecycle
        configureStatusOnlyVisualState()
    }

    func updateCountdown(_ value: Int) {
        guard lifecycle.snapshot.phase == .countingDown,
              statusPanel != nil else { return }
        updateStatusPanel(text: RecordingOverlayStatusContent.countdown(value))
    }

    func startRecordingVisualState(onStop: @escaping () -> Void) {
        guard lifecycle.snapshot.phase == .countingDown,
              stopPanel == nil,
              let overlay = validOwnerOverlay() else { return }
        var proposedLifecycle = lifecycle
        proposedLifecycle.beginRecording()
        guard installStatusPanels(
            phase: .recording,
            overlay: overlay,
            text: RecordingOverlayStatusContent.recording(elapsed: 0, remaining: 0),
            onStop: onStop,
            generation: proposedLifecycle.snapshot.generation
        ) else { return }
        proposedLifecycle.setAuxiliaryPanels(status: statusPanel != nil, stop: stopPanel != nil)
        lifecycle = proposedLifecycle
        configureStatusOnlyVisualState()
    }

    func updateRecordingStatus(
        elapsed: TimeInterval,
        remaining: TimeInterval,
        isWarning: Bool
    ) {
        guard lifecycle.snapshot.phase == .recording,
              statusPanel != nil else { return }
        updateStatusPanel(
            text: RecordingOverlayStatusContent.recording(elapsed: elapsed, remaining: remaining),
            isWarning: isWarning
        )
    }

    func showStoppingVisualState() {
        guard lifecycle.snapshot.phase == .recording else { return }
        lifecycle.beginStopping()
        stopActionTarget = nil
        stopPanel?.close()
        stopPanel = nil
        if statusPanel != nil {
            updateStatusPanel(text: RecordingOverlayStatusContent.stopping)
        }
    }

    private func configureStatusOnlyVisualState() {
        controlPanel?.close()
        controlPanel = nil
        var closedDisplayIDs: [CGDirectDisplayID] = []
        for (displayID, overlay) in overlays {
            if displayID != ownerDisplayID {
                overlay.panel.close()
                closedDisplayIDs.append(displayID)
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
        for displayID in closedDisplayIDs { overlays.removeValue(forKey: displayID) }
    }

    private func handleDisplayConfigurationChange(_ change: DisplayConfigurationChange) {
        let hasAnyChange = !change.added.isEmpty || !change.removed.isEmpty || !change.updated.isEmpty
        let ownerWasInvalidated = ownerDisplayID.map {
            change.removed.contains($0) || change.updated.contains($0)
        } ?? false
        if lifecycle.snapshot.phase == .selecting ? hasAnyChange : ownerWasInvalidated {
            dismiss()
        }
    }

    private func installStatusPanels(
        phase: RecordingOverlayAuxiliaryPhase,
        overlay: Overlay,
        text: String,
        onStop: (() -> Void)?,
        generation: UInt64? = nil
    ) -> Bool {
        guard phase != .hidden,
              auxiliaryPanelInstallationGate(phase),
              let selectionRect = overlay.view.selectionRect else { return false }
        let globalSelection = overlay.panel.convertToScreen(selectionRect)
        let input: RecordingOverlayPresentation.Input = phase == .recording ? .recording : .statusOnly
        let layout = RecordingOverlayPresentation.layout(
            input: input,
            selectionRect: globalSelection,
            visibleFrame: overlay.display.visibleFrame,
            errorSink: layoutErrorSink
        )
        var proposedStatusPanel: NSPanel?
        if let statusFrame = layout.statusFrame {
            let label = NSTextField(labelWithString: text)
            label.alignment = .center
            label.textColor = .white
            label.backgroundColor = NSColor.black.withAlphaComponent(0.78)
            label.drawsBackground = true
            label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
            let status = makeAuxiliaryPanel(frame: statusFrame, contentView: label)
            status.ignoresMouseEvents = RecordingOverlayMousePolicy.statusTextIgnoresMouseEvents
            proposedStatusPanel = status
        }

        var proposedStopPanel: NSPanel?
        var proposedTarget: OneShotActionTarget?
        if let stopFrame = layout.stopFrame {
            guard let onStop, let generation else { return false }
            let button = TemplateControlButton(
                image: imageLoader.load(.stopButton).image,
                semanticTint: .destructive
            )
            button.identifier = NSUserInterfaceItemIdentifier("gifpro.stop")
            button.toolTip = "停止录制"
            button.setAccessibilityIdentifier("gifpro.stop")
            button.setAccessibilityLabel("停止录制")
            button.setAccessibilityRole(.button)
            let target = OneShotActionTarget.install(
                on: button,
                generation: generation,
                currentGeneration: { [weak self] in self?.lifecycle.snapshot.generation ?? .max },
                beforeAction: { [weak self] in self?.consumeStopAction() },
                action: onStop
            )
            let stop = makeAuxiliaryPanel(frame: stopFrame, contentView: button)
            stop.ignoresMouseEvents = RecordingOverlayMousePolicy.stopButtonIgnoresMouseEvents
            proposedStopPanel = stop
            proposedTarget = target
        }

        statusPanel?.close()
        stopPanel?.close()
        stopActionTarget = nil
        statusPanel = proposedStatusPanel
        stopPanel = proposedStopPanel
        stopActionTarget = proposedTarget
        proposedStatusPanel?.orderFrontRegardless()
        proposedStopPanel?.orderFrontRegardless()
        return true
    }

    private func consumeStopAction() {
        guard lifecycle.snapshot.phase == .recording,
              lifecycle.snapshot.hasStopPanel else { return }
        lifecycle.consumeStopControl()
        stopPanel?.close()
        stopPanel = nil
        stopActionTarget = nil
    }

    private func updateStatusPanel(text: String, isWarning: Bool = false) {
        guard let label = statusPanel?.contentView as? NSTextField else { return }
        label.stringValue = text
        label.textColor = isWarning ? .systemYellow : .white
    }

    private func makeAuxiliaryPanel(frame: CGRect, contentView: NSView) -> NSPanel {
        let panel = environment.makeAuxiliaryPanel(frame: frame, contentView: contentView)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrame(frame, display: false)
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

    private func installOverlay(for display: OverlayDisplayDescriptor) {
        let displayID = display.displayID
        let panel = environment.makeSelectionPanel(for: display)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.onEscape = { [weak self] in self?.cancelSelection() }

        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: display.frame.size))
        view.autoresizingMask = [.width, .height]
        view.onDragBegan = { [weak self] in self?.claimOwnership(displayID: displayID) ?? false }
        view.onSelectionCompleted = { [weak self] rect in self?.selectionCompleted(rect, displayID: displayID) }
        panel.contentView = view
        overlays[displayID] = Overlay(display: display, panel: panel, view: view)
        panel.orderFrontRegardless()
    }

    private func claimOwnership(displayID: CGDirectDisplayID) -> Bool {
        if let ownerDisplayID { return ownerDisplayID == displayID }
        ownerDisplayID = displayID
        lifecycle.claimOwner(displayID, hasControlPanel: false)
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
        let supportsTwoX = overlay.display.backingScaleFactor >= 2
        let controls = SelectionControlsView(
            settings: settings,
            supportsTwoX: supportsTwoX,
            imageLoader: imageLoader
        )
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
        let screenFrame = overlay.display.frame
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
        lifecycle.setControlPanel(true)
    }

    private func recordSelection() {
        guard let ownerDisplayID,
              let overlay = overlays[ownerDisplayID],
              let localRect = overlay.view.selectionRect else { return }
        let globalRect = overlay.panel.convertToScreen(localRect)
        do {
            let region = try converter.convert(
                displayID: ownerDisplayID,
                displayFrame: overlay.display.frame,
                selection: globalRect,
                backingScale: overlay.display.backingScaleFactor,
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
