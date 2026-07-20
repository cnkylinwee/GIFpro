import AppKit

enum RecordingControlConsoleMetrics {
    static let size = CGSize(width: 500, height: 100)
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
            y: screen.maxY - size.height - 48,
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

        let fullScreen = makeModeButton(
            title: "录制全屏画面",
            symbolName: "display",
            action: #selector(fullScreenPressed)
        )
        let region = makeModeButton(
            title: "录制屏幕区域",
            symbolName: "viewfinder",
            action: #selector(regionPressed)
        )
        let preferences = makePlainButton(title: "偏好设置", action: #selector(preferencesPressed))

        let optionStack = NSStackView(views: [fullScreen, divider(), region])
        optionStack.orientation = .horizontal
        optionStack.spacing = 0
        optionStack.distribution = .fill
        fullScreen.widthAnchor.constraint(equalTo: region.widthAnchor).isActive = true

        let root = NSStackView(views: [optionStack, preferences])
        root.orientation = .horizontal
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        preferences.widthAnchor.constraint(equalToConstant: 76).isActive = true
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeModeButton(title: String, symbolName: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageAbove
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .white.withAlphaComponent(0.9)
        button.toolTip = title
        button.setAccessibilityIdentifier("gifpro.console.\(symbolName)")
        return button
    }

    private func makePlainButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = true
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .white
        button.setAccessibilityIdentifier("gifpro.console.preferences")
        return button
    }

    private func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    @objc private func fullScreenPressed() { onFullScreen() }
    @objc private func regionPressed() { onRegion() }
    @objc private func preferencesPressed() { onPreferences() }
}
