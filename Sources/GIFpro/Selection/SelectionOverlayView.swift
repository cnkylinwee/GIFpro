import AppKit

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

        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()

        for handle in ResizeHandle.allCases where showsHandles {
            NSColor.white.setFill()
            NSColor.systemRed.setStroke()
            let path = NSBezierPath(ovalIn: handleRect(for: handle, selection: selectionRect))
            path.lineWidth = 2
            path.fill()
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        let point = convert(event.locationInWindow, from: nil)
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
        ResizeHandle.allCases.first { handleRect(for: $0, selection: selection).insetBy(dx: -3, dy: -3).contains(point) }
    }

    private func handleRect(for handle: ResizeHandle, selection: CGRect) -> CGRect {
        let center: CGPoint
        switch handle {
        case .top: center = CGPoint(x: selection.midX, y: selection.maxY)
        case .bottom: center = CGPoint(x: selection.midX, y: selection.minY)
        case .left: center = CGPoint(x: selection.minX, y: selection.midY)
        case .right: center = CGPoint(x: selection.maxX, y: selection.midY)
        case .topLeft: center = CGPoint(x: selection.minX, y: selection.maxY)
        case .topRight: center = CGPoint(x: selection.maxX, y: selection.maxY)
        case .bottomLeft: center = CGPoint(x: selection.minX, y: selection.minY)
        case .bottomRight: center = CGPoint(x: selection.maxX, y: selection.minY)
        }
        return CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
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
