import AppKit
import XCTest
@testable import GIFpro

@MainActor
final class SelectionControlPanelTests: XCTestCase {
    func testTemplateControlButtonUsesFixedImageOnlyLayout() {
        let image = NSImage(size: CGSize(width: 60, height: 60))
        let button = TemplateControlButton(image: image, semanticTint: .accent)

        XCTAssertEqual(button.title, "")
        XCTAssertFalse(button.isBordered)
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.imageScaling, .scaleProportionallyDown)
        XCTAssertEqual(button.image?.size, CGSize(width: 24, height: 24))
        XCTAssertTrue(button.translatesAutoresizingMaskIntoConstraints == false)
        XCTAssertTrue(button.constraints.contains {
            $0.isActive && $0.firstAttribute == .width && $0.constant == 44
        })
        XCTAssertTrue(button.constraints.contains {
            $0.isActive && $0.firstAttribute == .height && $0.constant == 44
        })
    }

    func testTemplateControlButtonResolvesAccentInteractionStates() {
        assertInteractionStates(semanticTint: .accent, normalColor: .controlAccentColor)
    }

    func testTemplateControlButtonResolvesDestructiveInteractionStates() {
        assertInteractionStates(semanticTint: .destructive, normalColor: .systemRed)
    }

    func testTemplateControlButtonReresolvesTintAndRedrawsForLightAndDarkAppearance() throws {
        let button = TemplateControlButton(
            image: NSImage(size: CGSize(width: 24, height: 24)),
            semanticTint: .accent
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        container.addSubview(button)
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        for appearance in [light, dark] {
            button.appearance = appearance
            button.needsDisplay = false
            let previousGeneration = button.resolvedVisualState.redrawRequestGeneration
            button.viewDidChangeEffectiveAppearance()

            XCTAssertGreaterThan(
                button.resolvedVisualState.redrawRequestGeneration,
                previousGeneration
            )
            XCTAssertEqual(button.resolvedVisualState.appearanceName, appearance.name)
            assertColor(
                button.resolvedVisualState.tintColor,
                equals: resolvedColor(.controlAccentColor, appearance: appearance)
            )
        }
    }

    func testAuxiliaryStatusContentMovesFromCountdownToRecordingAndStopping() {
        XCTAssertEqual(RecordingOverlayStatusContent.countdown(3), "3")
        XCTAssertEqual(
            RecordingOverlayStatusContent.recording(elapsed: 5, remaining: 10),
            "00:05  剩余 00:10"
        )
        XCTAssertEqual(RecordingOverlayStatusContent.stopping, "正在完成…")
    }

    func testAuxiliaryPanelLifecycleTracksStatusAndStopVisibility() {
        var state = RecordingOverlayAuxiliaryState.hidden
        XCTAssertEqual(state.phase, .hidden)
        XCTAssertFalse(state.showsStatusPanel)
        XCTAssertFalse(state.showsStopPanel)

        state.transition(to: .countdown)
        XCTAssertEqual(state.phase, .countdown)
        XCTAssertTrue(state.showsStatusPanel)
        XCTAssertFalse(state.showsStopPanel)

        state.transition(to: .recording)
        XCTAssertEqual(state.phase, .recording)
        XCTAssertTrue(state.showsStatusPanel)
        XCTAssertTrue(state.showsStopPanel)

        state.transition(to: .stopping)
        XCTAssertEqual(state.phase, .stopping)
        XCTAssertTrue(state.showsStatusPanel)
        XCTAssertFalse(state.showsStopPanel)

        state.transition(to: .hidden)
        XCTAssertEqual(state, .hidden)
        XCTAssertFalse(state.showsStatusPanel)
        XCTAssertFalse(state.showsStopPanel)
    }

    func testControllerRejectsRecordingWithoutCountdownOwnerAndSelection() {
        let controller = SelectionOverlayController()
        let hidden = controller.auxiliarySnapshot

        controller.startRecordingVisualState(onStop: {})
        XCTAssertEqual(controller.auxiliarySnapshot, hidden)

        controller.show()
        defer { controller.dismiss() }
        controller.startRecordingVisualState(onStop: {})

        XCTAssertEqual(controller.auxiliarySnapshot, hidden)
        XCTAssertEqual(controller.auxiliarySnapshot.phase, .hidden)
        XCTAssertFalse(controller.auxiliarySnapshot.hasStatusPanel)
        XCTAssertFalse(controller.auxiliarySnapshot.hasStopPanel)
    }

    func testControllerDoesNotCommitRecordingWhenPanelInstallationFails() throws {
        var rejectsRecordingInstallation = true
        let controller = SelectionOverlayController(
            auxiliaryPanelInstallationGate: { phase in
                phase != .recording || !rejectsRecordingInstallation
            }
        )
        controller.show()
        defer { controller.dismiss() }

        let (displayID, view) = try XCTUnwrap(controller.selectionOverlayViews.first)
        XCTAssertTrue(view.onDragBegan?() == true)
        let selection = CGRect(x: 80, y: 80, width: 160, height: 120)
        view.selectionRect = selection
        view.onSelectionCompleted?(selection)

        controller.showCountdown(value: 3, targetDisplayID: displayID)
        let countdown = controller.auxiliarySnapshot
        XCTAssertEqual(countdown.phase, .countdown)
        XCTAssertTrue(countdown.hasStatusPanel)
        XCTAssertFalse(countdown.hasStopPanel)

        controller.startRecordingVisualState(onStop: {})

        XCTAssertEqual(controller.auxiliarySnapshot, countdown)
        XCTAssertEqual(controller.auxiliarySnapshot.phase, .countdown)
        XCTAssertTrue(controller.auxiliarySnapshot.hasStatusPanel)
        XCTAssertFalse(controller.auxiliarySnapshot.hasStopPanel)

        rejectsRecordingInstallation = false
        controller.startRecordingVisualState(onStop: {})
        XCTAssertEqual(controller.auxiliarySnapshot.phase, .recording)
        XCTAssertTrue(controller.auxiliarySnapshot.hasStatusPanel)
        XCTAssertTrue(controller.auxiliarySnapshot.hasStopPanel)

        controller.showStoppingVisualState()
        XCTAssertEqual(controller.auxiliarySnapshot.phase, .stopping)
        XCTAssertTrue(controller.auxiliarySnapshot.hasStatusPanel)
        XCTAssertFalse(controller.auxiliarySnapshot.hasStopPanel)

        controller.dismiss()
        XCTAssertEqual(controller.auxiliarySnapshot.phase, .hidden)
        XCTAssertFalse(controller.auxiliarySnapshot.hasStatusPanel)
        XCTAssertFalse(controller.auxiliarySnapshot.hasStopPanel)
    }

    func testControlPanelCanBecomeKeyWithoutBeingAnActivatingPanel() {
        let panel = makePanel()

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testControlPanelEscapeForwardsCancelWhilePresented() {
        let panel = makePanel()
        var cancelCount = 0
        panel.onCancel = { cancelCount += 1 }

        panel.cancelOperation(nil)

        XCTAssertEqual(cancelCount, 1)
    }

    func testRecordButtonRetainsReturnKeyEquivalent() {
        let loader = StubTemplateControlImageLoader()
        let controls = SelectionControlsView(
            settings: .default,
            supportsTwoX: true,
            imageLoader: loader
        )

        let recordButton = controls.descendants
            .compactMap { $0 as? TemplateControlButton }
            .first { $0.identifier?.rawValue == "gifpro.record" }

        XCTAssertEqual(recordButton?.keyEquivalent, "\r")
        XCTAssertEqual(loader.loadedAssets, [.recordButton])
    }

    func testRecordButtonIsImageOnlyAccessibleAndInvokesCallback() throws {
        let controls = SelectionControlsView(
            settings: .default,
            supportsTwoX: true,
            imageLoader: StubTemplateControlImageLoader()
        )
        let recordButton = try XCTUnwrap(controls.descendants
            .compactMap { $0 as? TemplateControlButton }
            .first { $0.identifier?.rawValue == "gifpro.record" })
        var recordCount = 0
        controls.onRecord = { recordCount += 1 }

        XCTAssertEqual(recordButton.title, "")
        XCTAssertEqual(recordButton.accessibilityIdentifier(), "gifpro.record")
        XCTAssertEqual(recordButton.toolTip, "开始录制")
        XCTAssertEqual(recordButton.accessibilityLabel(), "开始录制")
        XCTAssertEqual(recordButton.accessibilityRole(), .button)

        XCTAssertTrue(recordButton.accessibilityPerformPress())
        XCTAssertEqual(recordCount, 1)

        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        XCTAssertTrue(recordButton.performKeyEquivalent(with: returnEvent))
        XCTAssertEqual(recordCount, 2)

        recordButton.performClick(nil)

        XCTAssertEqual(recordCount, 3)

        recordButton.isEnabled = false
        XCTAssertFalse(recordButton.accessibilityPerformPress())
        recordButton.performClick(nil)
        XCTAssertEqual(recordCount, 3)
    }

    func testControllerPassesItsInjectedLoaderToSelectionControls() throws {
        let loader = StubTemplateControlImageLoader()
        let controller = SelectionOverlayController(imageLoader: loader)
        controller.show()
        defer { controller.dismiss() }

        let (_, view) = try XCTUnwrap(controller.selectionOverlayViews.first)
        XCTAssertTrue(view.onDragBegan?() == true)
        let selection = CGRect(x: 80, y: 80, width: 160, height: 120)
        view.selectionRect = selection
        view.onSelectionCompleted?(selection)

        XCTAssertEqual(loader.loadedAssets, [.recordButton])
    }

    func testRecordingVisualsPassThroughMouseExceptNarrowStopPanel() {
        XCTAssertTrue(RecordingOverlayMousePolicy.selectionVisualsIgnoreMouseEvents)
        XCTAssertTrue(RecordingOverlayMousePolicy.statusTextIgnoresMouseEvents)
        XCTAssertFalse(RecordingOverlayMousePolicy.stopButtonIgnoresMouseEvents)

        let selection = CGRect(x: 100, y: 100, width: 300, height: 200)
        let layout = RecordingOverlayPanelLayout(
            selectionRect: selection,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        XCTAssertEqual(layout.stopFrame.size, CGSize(width: 58, height: 30))
        XCTAssertTrue(selection.contains(layout.stopFrame))
        XCTAssertLessThan(layout.stopFrame.width * layout.stopFrame.height, selection.width * selection.height / 20)
    }

    private func makePanel() -> SelectionControlPanel {
        SelectionControlPanel(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private func assertInteractionStates(
        semanticTint: TemplateControlSemanticTint,
        normalColor: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = TemplateControlButton(
            image: NSImage(size: CGSize(width: 24, height: 24)),
            semanticTint: semanticTint
        )
        let appearance = button.effectiveAppearance

        XCTAssertEqual(button.resolvedVisualState.interaction, .normal, file: file, line: line)
        assertColor(
            button.resolvedVisualState.tintColor,
            equals: resolvedColor(normalColor, appearance: appearance),
            file: file,
            line: line
        )

        button.highlight(true)
        XCTAssertEqual(button.resolvedVisualState.interaction, .highlighted, file: file, line: line)
        assertColor(
            button.resolvedVisualState.tintColor,
            equals: resolvedColor(normalColor.withAlphaComponent(0.75), appearance: appearance),
            file: file,
            line: line
        )

        button.isEnabled = false
        XCTAssertEqual(button.resolvedVisualState.interaction, .disabled, file: file, line: line)
        assertColor(
            button.resolvedVisualState.tintColor,
            equals: resolvedColor(.disabledControlTextColor, appearance: appearance),
            file: file,
            line: line
        )
    }

    private func resolvedColor(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }

    private func assertColor(
        _ actual: NSColor,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actualRGB = actual.usingColorSpace(.deviceRGB),
              let expectedRGB = expected.usingColorSpace(.deviceRGB) else {
            XCTFail("Colors must convert to device RGB", file: file, line: line)
            return
        }
        XCTAssertEqual(actualRGB.redComponent, expectedRGB.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.greenComponent, expectedRGB.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.blueComponent, expectedRGB.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.alphaComponent, expectedRGB.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}

@MainActor
private final class StubTemplateControlImageLoader: TemplateControlImageLoading {
    private(set) var loadedAssets: [TemplateControlImageAsset] = []

    func load(_ asset: TemplateControlImageAsset) -> LoadedTemplateImage {
        loadedAssets.append(asset)
        let image = NSImage(size: CGSize(width: 24, height: 24))
        image.isTemplate = true
        return LoadedTemplateImage(image: image, source: .bundlePNG)
    }
}
