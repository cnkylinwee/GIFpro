import AppKit

@MainActor
final class GIFproPreferencesPanelController {
    static let shared = GIFproPreferencesPanelController()

    private var panel: NSPanel?

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        let content = GIFproPreferencesView(onClose: { [weak self] in self?.close() })
        let size = CGSize(width: 420, height: 210)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let panel = NSPanel(
            contentRect: CGRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "GIFpro 偏好设置"
        panel.level = .floating
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func close() {
        panel?.close()
        panel = nil
    }
}

@MainActor
private final class GIFproPreferencesView: NSView {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: CGRect(x: 0, y: 0, width: 420, height: 210))
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "偏好设置")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let storage = NSTextField(wrappingLabelWithString: "保存位置：录制完成后会弹出保存窗口，选择的位置会由系统保存面板记忆，下一次默认回到上次目录。")
        storage.textColor = .secondaryLabelColor
        storage.font = .systemFont(ofSize: 13)

        let presets = NSTextField(wrappingLabelWithString: "录制参数：缩放倍率、帧率、最长 90 秒录制时长和光标开关会在区域控制条中设置，并自动记忆。")
        presets.textColor = .secondaryLabelColor
        presets.font = .systemFont(ofSize: 13)

        let close = NSButton(title: "完成", target: self, action: #selector(closePressed))
        close.bezelStyle = .rounded

        let textStack = NSStackView(views: [title, storage, presets])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 12

        let root = NSStackView(views: [textStack, close])
        root.orientation = .vertical
        root.alignment = .trailing
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func closePressed() { onClose() }
}
