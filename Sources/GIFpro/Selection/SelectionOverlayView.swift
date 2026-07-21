import AppKit
import QuartzCore

enum RecordingOverlayMousePolicy {
    static let selectionVisualsIgnoreMouseEvents = false
    static let statusTextIgnoresMouseEvents = true
    static let stopButtonIgnoresMouseEvents = false
}

enum SelectionOverlayColorRole: Equatable {
    case selectionAccent
    case recordingRed
    case countdownOrangeRed
    case windowBackground

    func color(with appearance: NSAppearance? = nil) -> NSColor {
        let resolve = {
            switch self {
            case .selectionAccent: NSColor.controlAccentColor
            case .recordingRed: NSColor.systemRed
            case .countdownOrangeRed: NSColor(calibratedRed: 1, green: 0.28, blue: 0.16, alpha: 1)
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

struct SelectionHandleRenderDescriptor: Equatable {
    let visibleOuterFrame: CGRect
    let pathFrame: CGRect
    let strokeWidth: CGFloat
    let outerCornerRadius: CGFloat
    let pathCornerRadius: CGFloat

    var strokedOuterBounds: CGRect {
        pathFrame.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
    }
}

struct SelectionOverlayStyle: Equatable {
    static let borderWidth: CGFloat = 2
    static let visibleHandleSize = CGSize(width: 10, height: 10)
    static let handleHitSize = CGSize(width: 22, height: 22)
    static let handleCornerRadius: CGFloat = visibleHandleSize.width / 2
    static let selectionDashPattern: [NSNumber] = [8, 6]
    static let borderResizeHitSlop: CGFloat = 5
    static let countdownCornerLength: CGFloat = 16
    static let countdownCornerWidth: CGFloat = 3
    static let countdownDiskSize = CGSize(width: 96, height: 96)
    static let countdownFontSize: CGFloat = 72

    static let selecting = SelectionOverlayStyle(
        borderRole: .selectionAccent,
        handleFillRole: .windowBackground
    )
    static let recording = SelectionOverlayStyle(
        borderRole: .recordingRed,
        handleFillRole: .windowBackground
    )
    static let countdown = SelectionOverlayStyle(
        borderRole: .countdownOrangeRed,
        handleFillRole: .windowBackground
    )

    let borderRole: SelectionOverlayColorRole
    let handleFillRole: SelectionOverlayColorRole

    func visibleHandleFrame(for handle: ResizeHandle, selection: CGRect) -> CGRect {
        frame(size: Self.visibleHandleSize, centeredAt: center(for: handle, selection: selection))
    }

    func handleHitFrame(for handle: ResizeHandle, selection: CGRect) -> CGRect {
        frame(size: Self.handleHitSize, centeredAt: center(for: handle, selection: selection))
    }

    func handleRenderDescriptor(
        for handle: ResizeHandle,
        selection: CGRect
    ) -> SelectionHandleRenderDescriptor {
        let visibleOuterFrame = visibleHandleFrame(for: handle, selection: selection)
        let strokeInset = Self.borderWidth / 2
        return SelectionHandleRenderDescriptor(
            visibleOuterFrame: visibleOuterFrame,
            pathFrame: visibleOuterFrame.insetBy(dx: strokeInset, dy: strokeInset),
            strokeWidth: Self.borderWidth,
            outerCornerRadius: Self.handleCornerRadius,
            pathCornerRadius: max(0, Self.handleCornerRadius - strokeInset)
        )
    }

    func hitHandle(at point: CGPoint, selection: CGRect) -> ResizeHandle? {
        let cornerHitTestOrder: [ResizeHandle] = [
            .topLeft, .topRight, .bottomLeft, .bottomRight,
        ]
        if let corner = cornerHitTestOrder.first(where: { handleHitFrame(for: $0, selection: selection).contains(point) }) {
            return corner
        }

        let edgeHitTestOrder: [ResizeHandle] = [.top, .bottom, .left, .right]
        return edgeHitTestOrder.first { handleHitFrame(for: $0, selection: selection).contains(point) }
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
        didSet {
            guard oldValue != selectionRect else { return }
            updateSelectionLayers()
        }
    }
    var showsDimming = true {
        didSet { updateSelectionLayers() }
    }
    var showsHandles = true {
        didSet { updateSelectionLayers() }
    }
    var hidesSelectionChrome = false {
        didSet { updateSelectionLayers() }
    }
    var isInteractive = true
    var blocksSelectionMouseEvents = false {
        didSet { updateSelectionLayers() }
    }
    var countdownValue: Int? {
        didSet { updateSelectionLayers() }
    }

    private let dimmingLayer = CAShapeLayer()
    private let eventCaptureLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let countdownCornerLayer = CAShapeLayer()
    private let countdownDiskLayer = CAShapeLayer()
    private let countdownTextLayer = CATextLayer()
    private var handleLayers: [ResizeHandle: CAShapeLayer] = [:]
    private var dragAnchor: CGPoint?
    private var resizeHandle: ResizeHandle?
    private var resizeStartRect: CGRect?
    private var resizeStartPoint: CGPoint?
    private var moveStartRect: CGRect?
    private var moveStartPoint: CGPoint?
    private let notificationCenter: NotificationCenter
    private let onRedrawRequested: (() -> Void)?

    override init(frame frameRect: NSRect) {
        notificationCenter = .default
        onRedrawRequested = nil
        super.init(frame: frameRect)
        configureLayerRendering()
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
        configureLayerRendering()
        observeSystemColorChanges()
    }

    required init?(coder: NSCoder) {
        notificationCenter = .default
        onRedrawRequested = nil
        super.init(coder: coder)
        configureLayerRendering()
        observeSystemColorChanges()
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { isInteractive }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isInteractive || blocksSelectionMouseEvents
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if isInteractive { return self }
        if blocksSelectionMouseEvents,
           let selectionRect,
           selectionRect.contains(point) {
            return self
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        updateSelectionLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        requestRedraw()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isInteractive,
              showsHandles,
              !hidesSelectionChrome,
              let selectionRect else { return }
        addCursorRect(selectionRect, cursor: .openHand)
        let style = SelectionOverlayStyle.selecting
        for handle in ResizeHandle.allCases {
            addCursorRect(style.handleHitFrame(for: handle, selection: selectionRect), cursor: cursor(for: handle))
        }
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
        if let selectionRect, selectionRect.contains(point) {
            moveStartRect = selectionRect
            moveStartPoint = point
            NSCursor.closedHand.set()
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
        } else if let startRect = moveStartRect,
                  let startPoint = moveStartPoint {
            let translation = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            selectionRect = SelectionGeometry.moved(
                startRect,
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
        let didMoveExistingSelection = moveStartRect != nil
        if resizeHandle == nil, !didMoveExistingSelection {
            selectionRect = enforceMinimumSize(selectionRect)
            self.selectionRect = selectionRect
        }
        dragAnchor = nil
        resizeHandle = nil
        resizeStartRect = nil
        resizeStartPoint = nil
        moveStartRect = nil
        moveStartPoint = nil
        if didMoveExistingSelection { NSCursor.openHand.set() }
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
        SelectionOverlayStyle.selecting.hitHandle(at: point, selection: selection)
    }

    private func cursor(for handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .crosshair
        }
    }

    private func configureLayerRendering() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        dimmingLayer.fillRule = .evenOdd
        dimmingLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.addSublayer(dimmingLayer)

        eventCaptureLayer.fillColor = NSColor.black.withAlphaComponent(0.01).cgColor
        layer?.addSublayer(eventCaptureLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = SelectionOverlayStyle.borderWidth
        layer?.addSublayer(borderLayer)

        countdownCornerLayer.fillColor = NSColor.clear.cgColor
        countdownCornerLayer.lineWidth = SelectionOverlayStyle.countdownCornerWidth
        countdownCornerLayer.lineCap = .square
        countdownCornerLayer.lineJoin = .miter
        layer?.addSublayer(countdownCornerLayer)

        countdownDiskLayer.fillColor = NSColor.black.withAlphaComponent(0.46).cgColor
        countdownDiskLayer.strokeColor = NSColor.white.withAlphaComponent(0.32).cgColor
        countdownDiskLayer.lineWidth = 1
        layer?.addSublayer(countdownDiskLayer)

        countdownTextLayer.alignmentMode = .center
        countdownTextLayer.foregroundColor = NSColor.white.cgColor
        countdownTextLayer.shadowColor = NSColor.black.cgColor
        countdownTextLayer.shadowOpacity = 0.28
        countdownTextLayer.shadowRadius = 8
        countdownTextLayer.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(countdownTextLayer)

        for handle in ResizeHandle.allCases {
            let handleLayer = CAShapeLayer()
            handleLayer.lineWidth = SelectionOverlayStyle.borderWidth
            handleLayer.fillColor = NSColor.clear.cgColor
            handleLayers[handle] = handleLayer
            layer?.addSublayer(handleLayer)
        }
        updateSelectionLayers()
    }

    private func updateSelectionLayers() {
        discardCursorRects()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let rootBounds = bounds
        [dimmingLayer, eventCaptureLayer, borderLayer, countdownCornerLayer, countdownDiskLayer, countdownTextLayer].forEach {
            $0.frame = rootBounds
            $0.contentsScale = contentsScale
        }
        handleLayers.values.forEach {
            $0.frame = rootBounds
            $0.contentsScale = contentsScale
        }

        if showsDimming {
            let dimmingPath = CGMutablePath()
            dimmingPath.addRect(rootBounds)
            if let selectionRect {
                dimmingPath.addRect(selectionRect)
            }
            dimmingLayer.path = dimmingPath
            dimmingLayer.isHidden = false
        } else {
            dimmingLayer.isHidden = true
        }

        guard let selectionRect else {
            borderLayer.isHidden = true
            eventCaptureLayer.isHidden = true
            hideCountdownLayers()
            handleLayers.values.forEach { $0.isHidden = true }
            return
        }

        let isCountingDown = countdownValue != nil
        let style: SelectionOverlayStyle = isCountingDown ? .countdown : (showsHandles ? .selecting : .recording)
        eventCaptureLayer.isHidden = hidesSelectionChrome || (!showsHandles && !blocksSelectionMouseEvents)
        eventCaptureLayer.path = CGPath(rect: selectionRect, transform: nil)
        borderLayer.isHidden = hidesSelectionChrome
        borderLayer.strokeColor = style.borderRole.color(with: effectiveAppearance).cgColor
        borderLayer.lineDashPattern = (showsHandles || isCountingDown) ? SelectionOverlayStyle.selectionDashPattern : nil
        borderLayer.path = CGPath(
            rect: selectionRect.insetBy(
                dx: SelectionOverlayStyle.borderWidth / 2,
                dy: SelectionOverlayStyle.borderWidth / 2
            ),
            transform: nil
        )
        updateCountdownLayers(selectionRect: selectionRect, style: style)

        for handle in ResizeHandle.allCases {
            guard let handleLayer = handleLayers[handle] else { continue }
            handleLayer.isHidden = hidesSelectionChrome || !showsHandles
            guard !handleLayer.isHidden else { continue }
            let descriptor = style.handleRenderDescriptor(for: handle, selection: selectionRect)
            handleLayer.strokeColor = style.borderRole.color(with: effectiveAppearance).cgColor
            handleLayer.fillColor = style.handleFillRole.color(with: effectiveAppearance).cgColor
            handleLayer.lineDashPattern = nil
            handleLayer.path = CGPath(ellipseIn: descriptor.pathFrame, transform: nil)
        }
    }

    private func updateCountdownLayers(selectionRect: CGRect, style: SelectionOverlayStyle) {
        guard let countdownValue, !hidesSelectionChrome else {
            hideCountdownLayers()
            borderLayer.removeAnimation(forKey: "gifpro.countdown.border.pulse")
            countdownCornerLayer.removeAnimation(forKey: "gifpro.countdown.corner.pulse")
            return
        }

        let accent = style.borderRole.color(with: effectiveAppearance)
        countdownCornerLayer.isHidden = false
        countdownCornerLayer.strokeColor = accent.cgColor
        countdownCornerLayer.path = countdownCornerPath(for: selectionRect)

        let diskSize = min(
            SelectionOverlayStyle.countdownDiskSize.width,
            max(56, min(selectionRect.width, selectionRect.height) * 0.45)
        )
        let diskFrame = CGRect(
            x: selectionRect.midX - diskSize / 2,
            y: selectionRect.midY - diskSize / 2,
            width: diskSize,
            height: diskSize
        )
        countdownDiskLayer.isHidden = false
        countdownDiskLayer.path = CGPath(ellipseIn: diskFrame, transform: nil)

        let fontSize = min(SelectionOverlayStyle.countdownFontSize, diskSize * 0.75)
        countdownTextLayer.isHidden = false
        countdownTextLayer.string = "\(countdownValue)"
        countdownTextLayer.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy)
        countdownTextLayer.fontSize = fontSize
        countdownTextLayer.frame = CGRect(
            x: diskFrame.minX,
            y: diskFrame.midY - fontSize * 0.58,
            width: diskFrame.width,
            height: fontSize * 1.2
        )

        installCountdownPulseIfNeeded(on: borderLayer, key: "gifpro.countdown.border.pulse")
        installCountdownPulseIfNeeded(on: countdownCornerLayer, key: "gifpro.countdown.corner.pulse")
    }

    private func hideCountdownLayers() {
        countdownCornerLayer.isHidden = true
        countdownDiskLayer.isHidden = true
        countdownTextLayer.isHidden = true
    }

    private func countdownCornerPath(for selectionRect: CGRect) -> CGPath {
        let inset = SelectionOverlayStyle.countdownCornerWidth / 2
        let rect = selectionRect.insetBy(dx: inset, dy: inset)
        let length = min(
            SelectionOverlayStyle.countdownCornerLength,
            max(8, min(rect.width, rect.height) / 4)
        )
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - length))

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        return path
    }

    private func installCountdownPulseIfNeeded(on layer: CALayer, key: String) {
        guard layer.animation(forKey: key) == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.62
        animation.toValue = 1.0
        animation.duration = 0.72
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
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
        updateSelectionLayers()
        onRedrawRequested?()
    }
}

@MainActor
final class RecordingStatusPillView: NSView {
    private let dotLayer = CAShapeLayer()
    private let textField = NSTextField(labelWithString: "")
    private var isWarning = false

    init(text: String, isWarning: Bool) {
        self.isWarning = isWarning
        super.init(frame: .zero)
        configure(text: text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        dotLayer.frame = CGRect(x: 13, y: bounds.midY - 4, width: 8, height: 8)
        dotLayer.path = CGPath(ellipseIn: dotLayer.bounds, transform: nil)
    }

    func update(text: String, isWarning: Bool) {
        self.isWarning = isWarning
        textField.stringValue = text
        textField.textColor = isWarning ? .systemYellow : .white
        dotLayer.fillColor = (isWarning ? NSColor.systemYellow : NSColor.systemRed).cgColor
    }

    private func configure(text: String) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        dotLayer.fillColor = NSColor.systemRed.cgColor
        layer?.addSublayer(dotLayer)

        textField.alignment = .center
        textField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        textField.textColor = .white
        textField.lineBreakMode = .byClipping
        textField.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(text: text, isWarning: isWarning)
    }
}

@MainActor
final class RecordingStopButton: NSButton {
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { RecordingOverlayPresentation.stopSize }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isPressed ? 3 : 2
        let circleRect = bounds.insetBy(dx: inset, dy: inset)
        let background = isEnabled
            ? NSColor.systemRed.withAlphaComponent(isPressed ? 0.82 : 0.96)
            : NSColor.disabledControlTextColor.withAlphaComponent(0.44)
        background.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        NSColor.white.withAlphaComponent(isEnabled ? 0.96 : 0.62).setFill()
        let squareSize: CGFloat = 13
        let squareRect = CGRect(
            x: bounds.midX - squareSize / 2,
            y: bounds.midY - squareSize / 2,
            width: squareSize,
            height: squareSize
        )
        NSBezierPath(roundedRect: squareRect, xRadius: 3, yRadius: 3).fill()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func configure() {
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        bezelStyle = .regularSquare
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: RecordingOverlayPresentation.stopSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: RecordingOverlayPresentation.stopSize.height).isActive = true
    }
}

@MainActor
final class SelectionControlsView: NSView {
    var onSettingsChanged: ((RecordingSettings) -> Void)?
    var onRecord: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMoveBegan: (() -> Bool)? {
        didSet { dragHandle.onMoveBegan = onMoveBegan }
    }
    var onMoveChanged: ((CGPoint) -> Void)? {
        didSet { dragHandle.onMoveChanged = onMoveChanged }
    }
    var onMoveEnded: (() -> Void)? {
        didSet { dragHandle.onMoveEnded = onMoveEnded }
    }

    private(set) var settings: RecordingSettings
    private let dragHandle = SelectionDragHandleView()
    private let scaleControl = NSSegmentedControl(labels: ["1×", "2×"], trackingMode: .selectOne, target: nil, action: nil)
    private let fpsControl = NSSegmentedControl(labels: ["8", "12", "15"], trackingMode: .selectOne, target: nil, action: nil)
    private let durationControl = NSSegmentedControl(labels: ["15s", "30s", "60s", "90s"], trackingMode: .selectOne, target: nil, action: nil)
    private let cursorControl = NSButton(checkboxWithTitle: "Cursor", target: nil, action: nil)

    init(
        settings: RecordingSettings,
        supportsTwoX: Bool,
        imageLoader: any TemplateControlImageLoading
    ) {
        _ = supportsTwoX
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 10
        scaleControl.setEnabled(true, forSegment: 1)
        configureControls(imageLoader: imageLoader)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureControls(imageLoader: any TemplateControlImageLoading) {
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

        let record = TemplateControlButton(
            image: imageLoader.load(.recordButton).image,
            semanticTint: .accent
        )
        record.identifier = NSUserInterfaceItemIdentifier("gifpro.record")
        record.setAccessibilityIdentifier("gifpro.record")
        record.toolTip = "开始录制"
        record.setAccessibilityElement(true)
        record.setAccessibilityRole(.button)
        record.setAccessibilityLabel("开始录制")
        record.target = self
        record.action = #selector(recordPressed)
        record.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        let stack = NSStackView(views: [dragHandle, scaleControl, fpsControl, durationControl, cursorControl, record, cancel])
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

@MainActor
final class SelectionDragHandleView: NSView {
    var onMoveBegan: (() -> Bool)?
    var onMoveChanged: ((CGPoint) -> Void)?
    var onMoveEnded: (() -> Void)?

    private var dragStartPoint: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { CGSize(width: 22, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.tertiaryLabelColor.setFill()
        let dotSize = CGSize(width: 3, height: 3)
        let spacing: CGFloat = 5
        let startX = bounds.midX - spacing / 2 - dotSize.width
        let startY = bounds.midY - spacing / 2 - dotSize.height
        for column in 0..<2 {
            for row in 0..<2 {
                let rect = CGRect(
                    x: startX + CGFloat(column) * (dotSize.width + spacing),
                    y: startY + CGFloat(row) * (dotSize.height + spacing),
                    width: dotSize.width,
                    height: dotSize.height
                )
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard onMoveBegan?() == true else { return }
        if let window, event.windowNumber == window.windowNumber {
            NSCursor.closedHand.set()
            window.performDrag(with: event)
            NSCursor.openHand.set()
            onMoveEnded?()
            return
        }
        dragStartPoint = event.locationInWindow
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint else { return }
        onMoveChanged?(
            CGPoint(
                x: event.locationInWindow.x - dragStartPoint.x,
                y: event.locationInWindow.y - dragStartPoint.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartPoint != nil else { return }
        dragStartPoint = nil
        NSCursor.openHand.set()
        onMoveEnded?()
    }

    private func commonInit() {
        identifier = NSUserInterfaceItemIdentifier("gifpro.selection-drag-handle")
        toolTip = "拖动以移动控制条"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("移动控制条")
    }
}
