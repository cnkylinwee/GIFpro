import AppKit

enum RecordingControlConsoleMetrics {
    static let size = CGSize(width: 560, height: 112)
    static let dragStripHeight: CGFloat = 28
}

@MainActor
final class RecordingControlConsoleController {
    private var panel: RecordingControlConsolePanel?

    func show(
        onFullScreen: @escaping () -> Void,
        onRegion: @escaping () -> Void,
        onPreferences: @escaping () -> Void
    ) {
        if let panel {
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        let frame = Self.defaultFrame()
        let content = RecordingControlConsoleView(
            onFullScreen: { [weak self] in
                self?.hide()
                onFullScreen()
            },
            onRegion: { [weak self] in
                self?.hide()
                onRegion()
            },
            onPreferences: onPreferences
        )
        let panel = RecordingControlConsolePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.onClose = { [weak self] in self?.hide() }
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        let closingPanel = panel
        panel = nil
        closingPanel?.onClose = nil
        closingPanel?.close()
    }

    private static func defaultFrame() -> CGRect {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let size = RecordingControlConsoleMetrics.size
        return CGRect(
            x: screen.midX - size.width / 2,
            y: screen.minY + screen.height * 0.28,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class RecordingControlConsolePanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        super.close()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class RecordingControlConsoleView: NSView {
    private let onFullScreen: () -> Void
    private let onRegion: () -> Void
    private let onPreferences: () -> Void

    init(
        onFullScreen: @escaping () -> Void,
        onRegion: @escaping () -> Void,
        onPreferences: @escaping () -> Void
    ) {
        self.onFullScreen = onFullScreen
        self.onRegion = onRegion
        self.onPreferences = onPreferences
        super.init(frame: CGRect(origin: .zero, size: RecordingControlConsoleMetrics.size))
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let fullScreen = RecordingConsoleTileButton(
            title: "录制全屏画面",
            symbolName: "display",
            accessibilityIdentifier: "gifpro.console.display",
            action: { [weak self] in self?.fullScreenPressed() }
        )
        let region = RecordingConsoleTileButton(
            title: "录制屏幕区域",
            symbolName: "viewfinder",
            accessibilityIdentifier: "gifpro.console.viewfinder",
            action: { [weak self] in self?.regionPressed() }
        )
        let preferences = RecordingConsoleTileButton(
            title: "偏好设置",
            symbolName: "gearshape",
            accessibilityIdentifier: "gifpro.console.preferences",
            action: { [weak self] in self?.preferencesPressed() }
        )

        let dragStrip = RecordingConsoleDragStripView()
        let optionStack = NSStackView(views: [fullScreen, region, preferences])
        optionStack.orientation = .horizontal
        optionStack.spacing = 1
        optionStack.distribution = .fillEqually
        optionStack.wantsLayer = true
        optionStack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let root = NSStackView(views: [dragStrip, optionStack])
        root.orientation = .vertical
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        dragStrip.heightAnchor.constraint(equalToConstant: RecordingControlConsoleMetrics.dragStripHeight).isActive = true
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func fullScreenPressed() { onFullScreen() }
    private func regionPressed() { onRegion() }
    private func preferencesPressed() { onPreferences() }
}

@MainActor
private final class RecordingConsoleTileButton: NSControl {
    private let performAction: () -> Void
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isHovering = false { didSet { updateBackground() } }
    private var isPressing = false { didSet { updateBackground() } }

    init(
        title: String,
        symbolName: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.performAction = action
        super.init(frame: .zero)
        self.toolTip = title
        setAccessibilityIdentifier(accessibilityIdentifier)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        configure(title: title, symbolName: symbolName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { CGSize(width: 160, height: 84) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFire = isPressing && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressing = false
        if shouldFire { performAction() }
    }

    override func accessibilityPerformPress() -> Bool {
        performAction()
        return true
    }

    private func configure(title: String, symbolName: String) {
        wantsLayer = true
        layer?.cornerRadius = 0

        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        symbolView.contentTintColor = .white.withAlphaComponent(0.92)
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white.withAlphaComponent(0.94)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(symbolView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -13),
            symbolView.widthAnchor.constraint(equalToConstant: 30),
            symbolView.heightAnchor.constraint(equalToConstant: 30),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: symbolView.bottomAnchor, constant: 7),
        ])

        updateBackground()
    }

    private func updateBackground() {
        let alpha: CGFloat
        if isPressing {
            alpha = 0.22
        } else if isHovering {
            alpha = 0.14
        } else {
            alpha = 0.06
        }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }
}

@MainActor
private final class RecordingConsoleDragStripView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        toolTip = "拖动控制台"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
