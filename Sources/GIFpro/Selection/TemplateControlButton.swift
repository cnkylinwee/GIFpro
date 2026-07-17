import AppKit

enum TemplateControlSemanticTint {
    case accent
    case destructive

    fileprivate var color: NSColor {
        switch self {
        case .accent:
            .controlAccentColor
        case .destructive:
            .systemRed
        }
    }
}

struct TemplateControlVisualState {
    enum Interaction: Equatable {
        case normal
        case highlighted
        case disabled
    }

    let interaction: Interaction
    let tintColor: NSColor
    let appearanceName: NSAppearance.Name
    let redrawRequestGeneration: UInt
}

@MainActor
final class TemplateControlButton: NSButton {
    private let semanticTint: TemplateControlSemanticTint
    private var isExplicitlyHighlighted = false
    private(set) var resolvedVisualState = TemplateControlVisualState(
        interaction: .normal,
        tintColor: .clear,
        appearanceName: .aqua,
        redrawRequestGeneration: 0
    )
    private var redrawRequestGeneration: UInt = 0

    init(image: NSImage, semanticTint: TemplateControlSemanticTint) {
        self.semanticTint = semanticTint
        super.init(frame: .zero)

        let templateImage = (image.copy() as? NSImage) ?? NSImage(size: image.size)
        templateImage.size = CGSize(width: 24, height: 24)
        templateImage.isTemplate = true
        self.image = templateImage
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
        ])
        updateVisualState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { updateVisualState() }
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isExplicitlyHighlighted = flag
        updateVisualState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateVisualState()
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    private func updateVisualState() {
        let interaction: TemplateControlVisualState.Interaction
        let dynamicColor: NSColor
        if !isEnabled {
            interaction = .disabled
            dynamicColor = .disabledControlTextColor
        } else if isExplicitlyHighlighted {
            interaction = .highlighted
            dynamicColor = semanticTint.color.withAlphaComponent(0.75)
        } else {
            interaction = .normal
            dynamicColor = semanticTint.color
        }

        let appearance = effectiveAppearance
        var resolvedColor = dynamicColor
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = dynamicColor.usingColorSpace(.deviceRGB) ?? dynamicColor
        }
        redrawRequestGeneration &+= 1
        resolvedVisualState = TemplateControlVisualState(
            interaction: interaction,
            tintColor: resolvedColor,
            appearanceName: appearance.name,
            redrawRequestGeneration: redrawRequestGeneration
        )
        contentTintColor = resolvedColor
        needsDisplay = true
    }
}
