import AppKit

enum RecordingOverlayMousePolicy {
    static let selectionVisualsIgnoreMouseEvents = true
    static let statusTextIgnoresMouseEvents = true
    static let stopButtonIgnoresMouseEvents = false
}

struct RecordingOverlayPanelLayout: Equatable {
    let statusFrame: CGRect
    let stopFrame: CGRect

    init(selectionRect: CGRect, visibleFrame: CGRect) {
        let statusSize = CGSize(width: min(220, max(100, selectionRect.width - 70)), height: 28)
        let stopSize = CGSize(width: 58, height: 30)
        let preferredY = selectionRect.maxY - 36
        let y = min(max(preferredY, visibleFrame.minY), visibleFrame.maxY - statusSize.height)
        let statusX = min(
            max(selectionRect.minX + 8, visibleFrame.minX),
            visibleFrame.maxX - statusSize.width
        )
        let stopX = min(
            max(selectionRect.maxX - stopSize.width - 8, visibleFrame.minX),
            visibleFrame.maxX - stopSize.width
        )
        statusFrame = CGRect(origin: CGPoint(x: statusX, y: y), size: statusSize)
        stopFrame = CGRect(origin: CGPoint(x: stopX, y: y), size: stopSize)
    }
}

@MainActor
final class ClosureActionTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    @objc func invoke() { action() }

    static func install(on control: NSControl, action: @escaping () -> Void) -> ClosureActionTarget {
        let target = ClosureActionTarget(action: action)
        control.action = #selector(invoke)
        objc_setAssociatedObject(control, &associationKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return target
    }
}

private nonisolated(unsafe) var associationKey: UInt8 = 0

enum SelectionOverlayColorRole: Equatable {
    case selectionAccent
    case recordingRed
    case windowBackground

    func color(with appearance: NSAppearance? = nil) -> NSColor {
        let resolve = {
            switch self {
            case .selectionAccent: NSColor.controlAccentColor
            case .recordingRed: NSColor.systemRed
            case .windowBackground: NSColor.windowBackgroundColor
            }
        }
        guard let appearance else { return resolve() }
        var color: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            color = resolve()
        }
        return color ?? resolve()
    }
}

struct SelectionOverlayStyle {
    let borderWidth: CGFloat = 2
    let visibleHandleSize = CGSize(width: 10, height: 10)
    let handleHitSize = CGSize(width: 16, height: 16)
    let handleCornerRadius: CGFloat = 2
    let handleFillRole = SelectionOverlayColorRole.windowBackground

    func borderRole(showsHandles: Bool) -> SelectionOverlayColorRole {
        showsHandles ? .selectionAccent : .recordingRed
    }

    func visibleHandleFrame(for handle: ResizeHandle, selection: CGRect) -> CGRect {
        frame(size: visibleHandleSize, centeredAt: center(for: handle, selection: selection))
    }

    func handleHitFrame(for handle: ResizeHandle, selection: CGRect) -> CGRect {
        frame(size: handleHitSize, centeredAt: center(for: handle, selection: selection))
    }

    func hitHandle(at point: CGPoint, selection: CGRect) -> ResizeHandle? {
        let hitTestOrder: [ResizeHandle] = [
            .topLeft, .topRight, .bottomLeft, .bottomRight,
            .top, .bottom, .left, .right,
        ]
        return hitTestOrder.first { handleHitFrame(for: $0, selection: selection).contains(point) }
    }

    private func center(for handle: ResizeHandle, selection: CGRect) -> CGPoint {
        switch handle {
        case .top: CGPoint(x: selection.midX, y: selection.maxY)
        case .bottom: CGPoint(x: selection.midX, y: selection.minY)
        case .left: CGPoint(x: selection.minX, y: selection.midY)
        case .right: CGPoint(x: selection.maxX, y: selection.midY)
        case .topLeft: CGPoint(x: selection.minX, y: selection.maxY)
        case .topRight: CGPoint(x: selection.maxX, y: selection.maxY)
        case .bottomLeft: CGPoint(x: selection.minX, y: selection.minY)
        case .bottomRight: CGPoint(x: selection.maxX, y: selection.minY)
        }
    }

    private func frame(size: CGSize, centeredAt center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class SelectionOverlayPanel: NSPanel {
    var handlesEscape = true
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { handlesEscape }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        guard handlesEscape else { return }
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, handlesEscape {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class SelectionControlPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class SelectionOverlayView: NSView {
    var onDragBegan: (() -> Bool)?
    var onSelectionChanged: ((CGRect) -> Void)?
    var onSelectionCompleted: ((CGRect) -> Void)?

    var selectionRect: CGRect? {
        didSet { needsDisplay = true }
    }
    var showsDimming = true {
        didSet { needsDisplay = true }
    }
    var showsHandles = true {
        didSet { needsDisplay = true }
    }
    var isInteractive = true

    private var dragAnchor: CGPoint?
    private var resizeHandle: ResizeHandle?
    private var resizeStartRect: CGRect?
    private var resizeStartPoint: CGPoint?
    private let style = SelectionOverlayStyle()
    private let notificationCenter: NotificationCenter
    private let onRedrawRequested: (() -> Void)?

    override init(frame frameRect: NSRect) {
        notificationCenter = .default
        onRedrawRequested = nil
        super.init(frame: frameRect)
        observeSystemColorChanges()
    }

    init(
        frame frameRect: NSRect,
        notificationCenter: NotificationCenter,
        onRedrawRequested: (() -> Void)?
    ) {
        self.notificationCenter = notificationCenter
        self.onRedrawRequested = onRedrawRequested
        super.init(frame: frameRect)
        observeSystemColorChanges()
    }

    required init?(coder: NSCoder) {
        notificationCenter = .default
        onRedrawRequested = nil
        super.init(coder: coder)
        observeSystemColorChanges()
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { isInteractive }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsDimming {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
        }

        guard let selectionRect else { return }
        if showsDimming {
            NSGraphicsContext.saveGraphicsState()
            NSColor.clear.setFill()
            selectionRect.fill(using: .copy)
            NSGraphicsContext.restoreGraphicsState()
        }

        style.borderRole(showsHandles: showsHandles).color().setStroke()
        let borderInset = style.borderWidth / 2
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: borderInset, dy: borderInset))
        border.lineWidth = style.borderWidth
        border.stroke()

        for handle in ResizeHandle.allCases where showsHandles {
            style.handleFillRole.color().setFill()
            SelectionOverlayColorRole.selectionAccent.color().setStroke()
            let handleFrame = style.visibleHandleFrame(for: handle, selection: selectionRect)
            let path = NSBezierPath(
                roundedRect: handleFrame,
                xRadius: style.handleCornerRadius,
                yRadius: style.handleCornerRadius
            )
            path.lineWidth = style.borderWidth
            path.fill()
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        requestRedraw()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isInteractive else { return }
        if let selectionRect, let handle = hitHandle(at: point, selection: selectionRect) {
            resizeHandle = handle
            resizeStartRect = selectionRect
            resizeStartPoint = point
            return
        }
        guard onDragBegan?() == true else { return }
        dragAnchor = point
        selectionRect = CGRect(origin: point, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = resizeHandle,
           let startRect = resizeStartRect,
           let startPoint = resizeStartPoint {
            let translation = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            selectionRect = SelectionGeometry.resized(
                startRect,
                handle: handle,
                translation: translation,
                within: bounds
            )
        } else if let dragAnchor {
            selectionRect = normalizedRect(from: dragAnchor, to: point)
        }
        if let selectionRect { onSelectionChanged?(selectionRect) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive, var selectionRect else { return }
        if resizeHandle == nil {
            selectionRect = enforceMinimumSize(selectionRect)
            self.selectionRect = selectionRect
        }
        dragAnchor = nil
        resizeHandle = nil
        resizeStartRect = nil
        resizeStartPoint = nil
        onSelectionCompleted?(selectionRect)
    }

    private func normalizedRect(from start: CGPoint, to unclampedEnd: CGPoint) -> CGRect {
        let end = CGPoint(
            x: min(max(unclampedEnd.x, bounds.minX), bounds.maxX),
            y: min(max(unclampedEnd.y, bounds.minY), bounds.maxY)
        )
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func enforceMinimumSize(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, SelectionGeometry.minimumSize.width), bounds.width)
        let height = min(max(rect.height, SelectionGeometry.minimumSize.height), bounds.height)
        return CGRect(
            x: min(rect.minX, bounds.maxX - width),
            y: min(rect.minY, bounds.maxY - height),
            width: width,
            height: height
        )
    }

    private func hitHandle(at point: CGPoint, selection: CGRect) -> ResizeHandle? {
        style.hitHandle(at: point, selection: selection)
    }

    private func observeSystemColorChanges() {
        notificationCenter.addObserver(
            self,
            selector: #selector(systemColorsDidChange),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
    }

    @objc private func systemColorsDidChange() {
        requestRedraw()
    }

    private func requestRedraw() {
        needsDisplay = true
        onRedrawRequested?()
    }
}

@MainActor
final class SelectionControlsView: NSView {
    var onSettingsChanged: ((RecordingSettings) -> Void)?
    var onRecord: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var settings: RecordingSettings
    private let scaleControl = NSSegmentedControl(labels: ["1×", "2×"], trackingMode: .selectOne, target: nil, action: nil)
    private let fpsControl = NSSegmentedControl(labels: ["8", "12", "15"], trackingMode: .selectOne, target: nil, action: nil)
    private let durationControl = NSSegmentedControl(labels: ["15s", "30s", "60s", "90s"], trackingMode: .selectOne, target: nil, action: nil)
    private let cursorControl = NSButton(checkboxWithTitle: "Cursor", target: nil, action: nil)

    init(settings: RecordingSettings, supportsTwoX: Bool) {
        if !supportsTwoX, settings.scale == .two {
            self.settings = RecordingSettings(
                scale: .one,
                fps: settings.fps,
                duration: settings.duration,
                showsCursor: settings.showsCursor
            )
        } else {
            self.settings = settings
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 10
        scaleControl.setEnabled(supportsTwoX, forSegment: 1)
        configureControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureControls() {
        scaleControl.selectedSegment = settings.scale == .one ? 0 : 1
        fpsControl.selectedSegment = RecordingSettings.FramesPerSecond.allCases.firstIndex(of: settings.fps) ?? 1
        durationControl.selectedSegment = RecordingSettings.Duration.allCases.firstIndex(of: settings.duration) ?? 1
        cursorControl.state = settings.showsCursor ? .on : .off

        for control in [scaleControl, fpsControl, durationControl] {
            control.target = self
            control.action = #selector(controlChanged)
        }
        cursorControl.target = self
        cursorControl.action = #selector(controlChanged)

        let record = NSButton(title: "Record", target: self, action: #selector(recordPressed))
        record.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        let stack = NSStackView(views: [scaleControl, fpsControl, durationControl, cursorControl, record, cancel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func controlChanged() {
        let scales = RecordingSettings.Scale.allCases
        let frameRates = RecordingSettings.FramesPerSecond.allCases
        let durations = RecordingSettings.Duration.allCases
        settings = RecordingSettings(
            scale: scales[max(0, scaleControl.selectedSegment)],
            fps: frameRates[max(0, fpsControl.selectedSegment)],
            duration: durations[max(0, durationControl.selectedSegment)],
            showsCursor: cursorControl.state == .on
        )
        onSettingsChanged?(settings)
    }

    @objc private func recordPressed() { onRecord?() }
    @objc private func cancelPressed() { onCancel?() }
}
