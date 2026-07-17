import AppKit
import CoreGraphics

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
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var ownerDisplayID: CGDirectDisplayID?
    private var controlPanel: NSPanel?
    private var statusPanel: NSPanel?
    private var stopPanel: NSPanel?
    private var settings = RecordingSettings.default
    private var visualState = VisualState.hidden

    init(converter: DisplayCoordinateConverter = DisplayCoordinateConverter()) {
        self.converter = converter
        self.displayMonitor = DisplayConfigurationMonitor()
    }

    init(
        converter: DisplayCoordinateConverter,
        displayMonitor: DisplayConfigurationMonitor
    ) {
        self.converter = converter
        self.displayMonitor = displayMonitor
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
        for overlay in overlays.values {
            overlay.panel.onEscape = nil
            overlay.panel.close()
        }
        overlays.removeAll()
        ownerDisplayID = nil
        visualState = .hidden
    }

    func showCountdown(value: Int, targetDisplayID: CGDirectDisplayID) {
        guard visualState == .selecting, ownerDisplayID == targetDisplayID else { return }
        visualState = .countingDown
        configureStatusOnlyVisualState()
        overlays[targetDisplayID]?.view.showCountdown(value)
        installStatusPanels(text: "\(value)", onStop: nil)
    }

    func updateCountdown(_ value: Int) {
        guard visualState == .countingDown, let ownerDisplayID else { return }
        overlays[ownerDisplayID]?.view.showCountdown(value)
        updateStatusPanel(text: "\(value)")
    }

    func startRecordingVisualState(onStop: @escaping () -> Void) {
        guard visualState != .hidden else { return }
        visualState = .recording
        configureStatusOnlyVisualState()
        overlays[ownerDisplayID ?? 0]?.view.showRecording(
            elapsed: 0,
            remaining: 0,
            isWarning: false,
            onStop: onStop
        )
        installStatusPanels(text: recordingStatus(elapsed: 0, remaining: 0), onStop: onStop)
    }

    func updateRecordingStatus(
        elapsed: TimeInterval,
        remaining: TimeInterval,
        isWarning: Bool
    ) {
        guard visualState == .recording, let ownerDisplayID else { return }
        overlays[ownerDisplayID]?.view.updateRecordingStatus(
            elapsed: elapsed,
            remaining: remaining,
            isWarning: isWarning
        )
        updateStatusPanel(
            text: recordingStatus(elapsed: elapsed, remaining: remaining),
            isWarning: isWarning
        )
    }

    func showStoppingVisualState() {
        guard visualState == .recording else { return }
        visualState = .stopping
        overlays[ownerDisplayID ?? 0]?.view.showStopping()
        stopPanel?.close()
        stopPanel = nil
        updateStatusPanel(text: "正在完成…")
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

    private func installStatusPanels(text: String, onStop: (() -> Void)?) {
        statusPanel?.close()
        stopPanel?.close()
        statusPanel = nil
        stopPanel = nil
        guard let ownerDisplayID,
              let overlay = overlays[ownerDisplayID],
              let selectionRect = overlay.view.selectionRect else { return }
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
        status.orderFrontRegardless()
        statusPanel = status

        guard let onStop else { return }
        let button = NSButton(title: "停止", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.bezelColor = .systemRed
        button.contentTintColor = .white
        button.target = ClosureActionTarget.install(on: button, action: onStop)
        let stop = makeAuxiliaryPanel(frame: layout.stopFrame, contentView: button)
        stop.ignoresMouseEvents = RecordingOverlayMousePolicy.stopButtonIgnoresMouseEvents
        stop.orderFrontRegardless()
        stopPanel = stop
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

    private func recordingStatus(elapsed: TimeInterval, remaining: TimeInterval) -> String {
        String(
            format: "%02d:%02d  剩余 %02d:%02d",
            Int(elapsed) / 60,
            Int(elapsed) % 60,
            Int(remaining) / 60,
            Int(remaining) % 60
        )
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
