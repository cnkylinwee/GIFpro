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

    func testTemplateControlButtonReresolvesTintAndRedrawsForSystemColorChanges() {
        let notifications = NotificationCenter()
        let button = TemplateControlButton(
            image: NSImage(size: CGSize(width: 24, height: 24)),
            semanticTint: .accent,
            notificationCenter: notifications
        )
        button.needsDisplay = false
        let previousGeneration = button.resolvedVisualState.redrawRequestGeneration

        notifications.post(name: NSColor.systemColorsDidChangeNotification, object: nil)

        XCTAssertGreaterThan(
            button.resolvedVisualState.redrawRequestGeneration,
            previousGeneration
        )
        XCTAssertEqual(button.resolvedVisualState.interaction, .normal)
        assertColor(
            button.resolvedVisualState.tintColor,
            equals: resolvedColor(.controlAccentColor, appearance: button.effectiveAppearance)
        )
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
        let controller = SelectionOverlayController(
            environment: makeEnvironment(),
            displayMonitor: StubSelectionOverlayDisplayMonitor()
        )
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
            environment: makeEnvironment(),
            displayMonitor: StubSelectionOverlayDisplayMonitor(),
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

    func testTwoXScaleRemainsSelectableWhenDisplayIsOneX() throws {
        let controls = SelectionControlsView(
            settings: .init(scale: .two, fps: .twelve, duration: .thirty, showsCursor: true),
            supportsTwoX: false,
            imageLoader: StubTemplateControlImageLoader()
        )
        let scaleControl = try XCTUnwrap(controls.descendants
            .compactMap { $0 as? NSSegmentedControl }
            .first)

        XCTAssertEqual(controls.settings.scale, .two)
        XCTAssertTrue(scaleControl.isEnabled(forSegment: 1))
        XCTAssertEqual(scaleControl.selectedSegment, 1)
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

    func testSelectionDragHandleIsAccessibleAndReportsWindowTranslation() throws {
        let controls = SelectionControlsView(
            settings: .default,
            supportsTwoX: true,
            imageLoader: StubTemplateControlImageLoader()
        )
        let handle = try XCTUnwrap(controls.descendants
            .compactMap { $0 as? SelectionDragHandleView }
            .first)
        var beganCount = 0
        var translations: [CGPoint] = []
        var endedCount = 0
        controls.onMoveBegan = {
            beganCount += 1
            return true
        }
        controls.onMoveChanged = { translations.append($0) }
        controls.onMoveEnded = { endedCount += 1 }

        handle.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: CGPoint(x: 10, y: 12)))
        handle.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 34, y: 4)))
        handle.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: CGPoint(x: 34, y: 4)))

        XCTAssertEqual(handle.identifier?.rawValue, "gifpro.selection-drag-handle")
        XCTAssertEqual(handle.toolTip, "拖动以移动录制范围")
        XCTAssertEqual(beganCount, 1)
        XCTAssertEqual(translations, [CGPoint(x: 24, y: -8)])
        XCTAssertEqual(endedCount, 1)
    }

    func testDraggingSelectionControlHandleMovesSelectionAndPanelWithinBounds() throws {
        let controller = SelectionOverlayController(
            imageLoader: StubTemplateControlImageLoader(),
            environment: makeEnvironment(),
            displayMonitor: StubSelectionOverlayDisplayMonitor()
        )
        controller.show()
        defer { controller.dismiss() }

        let panel = try XCTUnwrap(controller.selectionControlPanel)
        let controls = try XCTUnwrap(panel.contentView as? SelectionControlsView)
        let handle = try XCTUnwrap(controls.descendants
            .compactMap { $0 as? SelectionDragHandleView }
            .first)
        let view = try XCTUnwrap(controller.selectionOverlayViews[42])
        _ = try XCTUnwrap(view.selectionRect)
        let startPanelFrame = panel.frame
        let startPoint = CGPoint(x: 12, y: 12)

        handle.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: startPoint))
        handle.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 72, y: 52)))

        XCTAssertNil(controller.selectionMovePanel)
        XCTAssertEqual(view.selectionRect, CGRect(x: 310, y: 290, width: 500, height: 300))
        XCTAssertFalse(view.hidesSelectionChrome)
        XCTAssertEqual(panel.frame.origin, startPanelFrame.origin)

        handle.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: CGPoint(x: -10_000, y: -10_000)))
        XCTAssertEqual(view.selectionRect, CGRect(x: 0, y: 0, width: 500, height: 300))
        handle.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: CGPoint(x: -10_000, y: -10_000)))

        XCTAssertEqual(view.selectionRect, CGRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertFalse(view.hidesSelectionChrome)
        XCTAssertNil(controller.selectionMovePanel)
        XCTAssertEqual(
            panel.frame.origin,
            CGPoint(x: 0, y: 312)
        )
    }

    func testControllerPassesItsInjectedLoaderToSelectionControls() throws {
        let loader = StubTemplateControlImageLoader()
        let controller = SelectionOverlayController(
            imageLoader: loader,
            environment: makeEnvironment(),
            displayMonitor: StubSelectionOverlayDisplayMonitor()
        )
        controller.show()
        defer { controller.dismiss() }

        let view = try XCTUnwrap(controller.selectionOverlayViews[42])

        XCTAssertEqual(view.selectionRect, CGRect(x: 250, y: 250, width: 500, height: 300))
        XCTAssertTrue(controller.lifecycleSnapshot.hasControlPanel)
        XCTAssertEqual(loader.loadedAssets, [.recordButton])
    }

    func testFullScreenModeShowsParameterControlsBeforeRecording() throws {
        let controller = SelectionOverlayController(
            imageLoader: StubTemplateControlImageLoader(),
            environment: makeEnvironment(),
            displayMonitor: StubSelectionOverlayDisplayMonitor()
        )
        var recordedRegions: [CaptureRegion] = []
        controller.onRecord = { region, _ in recordedRegions.append(region) }

        controller.show(mode: .fullScreen)
        defer { controller.dismiss() }

        let view = try XCTUnwrap(controller.selectionOverlayViews[42])
        XCTAssertEqual(view.selectionRect, view.bounds)
        XCTAssertFalse(view.isInteractive)
        XCTAssertTrue(controller.lifecycleSnapshot.hasControlPanel)
        XCTAssertTrue(recordedRegions.isEmpty)
    }

    func testRecordingVisualsPassThroughMouseExceptNarrowStopPanel() {
        XCTAssertTrue(RecordingOverlayMousePolicy.selectionVisualsIgnoreMouseEvents)
        XCTAssertTrue(RecordingOverlayMousePolicy.statusTextIgnoresMouseEvents)
        XCTAssertFalse(RecordingOverlayMousePolicy.stopButtonIgnoresMouseEvents)

        let selection = CGRect(x: 100, y: 100, width: 300, height: 200)
        let layout = RecordingOverlayPresentation.layout(
            input: .recording,
            selectionRect: selection,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        XCTAssertEqual(layout.stopFrame?.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(layout.mode, .horizontal)
    }

    func testRecordingLayoutUsesHorizontalBelowAboveThenClamp() {
        let visible = CGRect(x: -500, y: -300, width: 400, height: 300)
        let below = RecordingOverlayPresentation.layout(
            input: .recording,
            selectionRect: CGRect(x: -400, y: -150, width: 200, height: 100),
            visibleFrame: visible
        )
        XCTAssertEqual(below.mode, .horizontal)
        XCTAssertEqual(below.statusFrame, CGRect(x: -400, y: -194, width: 148, height: 28))
        XCTAssertEqual(below.stopFrame, CGRect(x: -244, y: -202, width: 44, height: 44))

        let above = RecordingOverlayPresentation.layout(
            input: .recording,
            selectionRect: CGRect(x: -400, y: -280, width: 200, height: 100),
            visibleFrame: visible
        )
        XCTAssertEqual(above.statusFrame, CGRect(x: -400, y: -164, width: 148, height: 28))
        XCTAssertEqual(above.stopFrame, CGRect(x: -244, y: -172, width: 44, height: 44))

        let clamped = RecordingOverlayPresentation.layout(
            input: .recording,
            selectionRect: CGRect(x: -400, y: -260, width: 200, height: 220),
            visibleFrame: visible
        )
        XCTAssertEqual(clamped.statusFrame, CGRect(x: -400, y: -76, width: 148, height: 28))
        XCTAssertEqual(clamped.stopFrame, CGRect(x: -244, y: -84, width: 44, height: 44))
    }

    func testRecordingLayoutThresholdsChooseHorizontalVerticalStopOnlyAndUnavailable() {
        let selection = CGRect(x: 0, y: 0, width: 64, height: 64)
        XCTAssertEqual(
            RecordingOverlayPresentation.layout(input: .recording, selectionRect: selection, visibleFrame: CGRect(x: 0, y: 0, width: 152, height: 44)).mode,
            .horizontal
        )
        XCTAssertEqual(
            RecordingOverlayPresentation.layout(input: .recording, selectionRect: selection, visibleFrame: CGRect(x: 0, y: 0, width: 44, height: 80)).mode,
            .vertical
        )
        XCTAssertEqual(
            RecordingOverlayPresentation.layout(input: .recording, selectionRect: selection, visibleFrame: CGRect(x: 0, y: 0, width: 140, height: 60)).mode,
            .stopOnly
        )
        var errors: [String] = []
        let unavailable = RecordingOverlayPresentation.layout(
            input: .recording,
            selectionRect: selection,
            visibleFrame: CGRect(x: -20, y: -20, width: 40, height: 40),
            errorSink: { errors.append($0) }
        )
        XCTAssertEqual(unavailable.mode, .unavailable)
        XCTAssertNil(unavailable.statusFrame)
        XCTAssertNil(unavailable.stopFrame)
        XCTAssertEqual(errors.count, 1)

        let shrinkToFit = RecordingOverlayPresentation.layout(
            input: .recording,
            selectionRect: CGRect(x: 0, y: 0, width: 300, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        XCTAssertEqual(shrinkToFit.mode, .horizontal)
        XCTAssertEqual(shrinkToFit.statusFrame?.width, 148)
    }

    func testMinimumSelectionAtCenterEdgesAndCornersHasExactContainedNonintersectingFrames() {
        let visible = CGRect(x: -500, y: -300, width: 400, height: 300)
        let cases: [(CGRect, CGRect, CGRect)] = [
            (CGRect(x: -332, y: -182, width: 64, height: 64), CGRect(x: -376, y: -226, width: 100, height: 28), CGRect(x: -268, y: -234, width: 44, height: 44)),
            (CGRect(x: -500, y: -182, width: 64, height: 64), CGRect(x: -500, y: -226, width: 100, height: 28), CGRect(x: -392, y: -234, width: 44, height: 44)),
            (CGRect(x: -164, y: -182, width: 64, height: 64), CGRect(x: -252, y: -226, width: 100, height: 28), CGRect(x: -144, y: -234, width: 44, height: 44)),
            (CGRect(x: -332, y: -300, width: 64, height: 64), CGRect(x: -376, y: -220, width: 100, height: 28), CGRect(x: -268, y: -228, width: 44, height: 44)),
            (CGRect(x: -332, y: -64, width: 64, height: 64), CGRect(x: -376, y: -108, width: 100, height: 28), CGRect(x: -268, y: -116, width: 44, height: 44)),
            (CGRect(x: -500, y: -300, width: 64, height: 64), CGRect(x: -500, y: -220, width: 100, height: 28), CGRect(x: -392, y: -228, width: 44, height: 44)),
            (CGRect(x: -164, y: -300, width: 64, height: 64), CGRect(x: -252, y: -220, width: 100, height: 28), CGRect(x: -144, y: -228, width: 44, height: 44)),
            (CGRect(x: -500, y: -64, width: 64, height: 64), CGRect(x: -500, y: -108, width: 100, height: 28), CGRect(x: -392, y: -116, width: 44, height: 44)),
            (CGRect(x: -164, y: -64, width: 64, height: 64), CGRect(x: -252, y: -108, width: 100, height: 28), CGRect(x: -144, y: -116, width: 44, height: 44)),
        ]
        for (selection, expectedStatus, expectedStop) in cases {
            let output = RecordingOverlayPresentation.layout(input: .recording, selectionRect: selection, visibleFrame: visible)
            let status = try! XCTUnwrap(output.statusFrame)
            let stop = try! XCTUnwrap(output.stopFrame)
            XCTAssertEqual(status, expectedStatus)
            XCTAssertEqual(stop, expectedStop)
            XCTAssertTrue(visible.contains(status))
            XCTAssertTrue(visible.contains(stop))
            XCTAssertFalse(status.intersects(stop))
        }
    }

    func testStatusOnlyLayoutCentersAndUsesBelowAboveThenClamp() {
        let visible = CGRect(x: -500, y: -300, width: 400, height: 300)
        let below = RecordingOverlayPresentation.layout(input: .statusOnly, selectionRect: CGRect(x: -400, y: -150, width: 200, height: 100), visibleFrame: visible)
        XCTAssertEqual(below.mode, .statusOnly)
        XCTAssertEqual(below.statusFrame, CGRect(x: -400, y: -186, width: 200, height: 28))
        XCTAssertNil(below.stopFrame)
        let above = RecordingOverlayPresentation.layout(input: .statusOnly, selectionRect: CGRect(x: -400, y: -280, width: 200, height: 100), visibleFrame: visible)
        XCTAssertEqual(above.statusFrame, CGRect(x: -400, y: -172, width: 200, height: 28))
        let clamped = RecordingOverlayPresentation.layout(input: .statusOnly, selectionRect: CGRect(x: -400, y: -290, width: 200, height: 280), visibleFrame: visible)
        XCTAssertEqual(clamped.statusFrame, CGRect(x: -400, y: -38, width: 200, height: 28))
    }

    func testStatusOnlyRequiresItsExactMinimumSizeAndReportsUnavailableOnce() {
        let selection = CGRect(x: -50, y: -20, width: 100, height: 28)
        let exact = RecordingOverlayPresentation.layout(
            input: .statusOnly,
            selectionRect: selection,
            visibleFrame: CGRect(x: -50, y: -20, width: 100, height: 28)
        )
        XCTAssertEqual(exact.mode, .statusOnly)
        XCTAssertEqual(exact.statusFrame, CGRect(x: -50, y: -20, width: 100, height: 28))

        for visible in [
            CGRect(x: -50, y: -20, width: 99, height: 28),
            CGRect(x: -50, y: -20, width: 100, height: 27),
            CGRect(x: -50, y: -20, width: 40, height: 20),
        ] {
            var errors: [String] = []
            let unavailable = RecordingOverlayPresentation.layout(
                input: .statusOnly,
                selectionRect: selection,
                visibleFrame: visible,
                errorSink: { errors.append($0) }
            )
            XCTAssertEqual(unavailable.mode, .unavailable)
            XCTAssertNil(unavailable.statusFrame)
            XCTAssertNil(unavailable.stopFrame)
            XCTAssertEqual(errors.count, 1)
        }
    }

    func testLifecycleTransitionsAndInvalidatesGeneration() {
        var lifecycle = RecordingOverlayLifecycle()
        XCTAssertEqual(lifecycle.snapshot.phase, .hidden)
        let initialGeneration = lifecycle.snapshot.generation
        lifecycle.beginSelecting(displayIDs: [1, 2])
        XCTAssertEqual(lifecycle.snapshot.phase, .selecting)
        XCTAssertEqual(lifecycle.snapshot.overlayDisplayIDs, [1, 2])
        lifecycle.claimOwner(1, hasControlPanel: true)
        lifecycle.beginCountdown()
        XCTAssertEqual(lifecycle.snapshot.nonOwnerDisplayIDs, [])
        XCTAssertTrue(lifecycle.snapshot.hasStatusPanel)
        XCTAssertTrue(lifecycle.snapshot.overlayIgnoresMouseEvents)
        lifecycle.beginRecording()
        XCTAssertTrue(lifecycle.snapshot.hasStopPanel)
        XCTAssertFalse(lifecycle.snapshot.stopIgnoresMouseEvents)
        lifecycle.beginStopping()
        XCTAssertFalse(lifecycle.snapshot.hasStopPanel)
        lifecycle.hide()
        XCTAssertEqual(lifecycle.snapshot.phase, .hidden)
        XCTAssertGreaterThan(lifecycle.snapshot.generation, initialGeneration)

        lifecycle.beginSelecting(displayIDs: [3])
        let replacementGeneration = lifecycle.snapshot.generation
        lifecycle.displayInvalidated()
        XCTAssertEqual(lifecycle.snapshot.phase, .hidden)
        XCTAssertTrue(lifecycle.snapshot.overlayDisplayIDs.isEmpty)
        XCTAssertGreaterThan(lifecycle.snapshot.generation, replacementGeneration)
    }

    func testOneShotActionTargetUsesRealMouseAndAccessibilityPathsAndRejectsStaleTarget() throws {
        var currentGeneration: UInt64 = 1
        var fireCount = 0
        let button = TemplateControlButton(image: NSImage(size: CGSize(width: 24, height: 24)), semanticTint: .destructive)
        let target = OneShotActionTarget.install(
            on: button,
            generation: 1,
            currentGeneration: { currentGeneration },
            beforeAction: {},
            action: { fireCount += 1 }
        )
        button.performClick(nil)
        button.performClick(nil)
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertEqual(fireCount, 1)
        XCTAssertTrue(target.fired)

        currentGeneration = 2
        let accessibilityButton = TemplateControlButton(image: NSImage(size: CGSize(width: 24, height: 24)), semanticTint: .destructive)
        _ = OneShotActionTarget.install(on: accessibilityButton, generation: 2, currentGeneration: { currentGeneration }, beforeAction: {}, action: { fireCount += 1 })
        XCTAssertTrue(accessibilityButton.accessibilityPerformPress())
        XCTAssertFalse(accessibilityButton.accessibilityPerformPress())
        XCTAssertEqual(fireCount, 2)

        let staleButton = TemplateControlButton(image: NSImage(size: CGSize(width: 24, height: 24)), semanticTint: .destructive)
        let stale = OneShotActionTarget.install(on: staleButton, generation: 2, currentGeneration: { currentGeneration }, beforeAction: {}, action: { fireCount += 1 })
        currentGeneration = 3
        staleButton.performClick(nil)
        XCTAssertFalse(staleButton.accessibilityPerformPress())
        XCTAssertFalse(stale.fired)
        XCTAssertEqual(fireCount, 2)
    }

    func testControllerUsesInjectedEnvironmentAndKeepsSnapshotSynchronized() throws {
        let environment = StubSelectionOverlayEnvironment(displays: [
            .init(displayID: 7, frame: CGRect(x: -500, y: -300, width: 400, height: 300), visibleFrame: CGRect(x: -500, y: -300, width: 400, height: 300), backingScaleFactor: 2),
            .init(displayID: 8, frame: CGRect(x: -100, y: -300, width: 300, height: 300), visibleFrame: CGRect(x: -100, y: -300, width: 300, height: 300), backingScaleFactor: 1),
        ])
        let loader = StubTemplateControlImageLoader()
        let monitor = StubSelectionOverlayDisplayMonitor()
        let controller = SelectionOverlayController(
            imageLoader: loader,
            environment: environment,
            displayMonitor: monitor
        )
        controller.show()
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(controller.lifecycleSnapshot.phase, .selecting)
        XCTAssertEqual(controller.lifecycleSnapshot.overlayDisplayIDs, [7, 8])
        XCTAssertEqual(controller.lifecycleSnapshot.ownerDisplayID, 7)
        XCTAssertTrue(controller.lifecycleSnapshot.hasControlPanel)

        let ownerView = try XCTUnwrap(controller.selectionOverlayViews[7])
        XCTAssertEqual(ownerView.selectionRect, CGRect(x: 0, y: 0, width: 400, height: 300))

        controller.showCountdown(value: 3, targetDisplayID: 7)
        XCTAssertEqual(controller.lifecycleSnapshot.phase, .countingDown)
        XCTAssertEqual(controller.lifecycleSnapshot.overlayDisplayIDs, [7])
        XCTAssertEqual(controller.selectionOverlayViews.keys.sorted(), [7])
        XCTAssertTrue(controller.lifecycleSnapshot.hasStatusPanel)
        XCTAssertFalse(controller.lifecycleSnapshot.hasStopPanel)

        var stopCount = 0
        var callbackObservedClosedStop = false
        controller.startRecordingVisualState {
            stopCount += 1
            callbackObservedClosedStop = !controller.lifecycleSnapshot.hasStopPanel
                && !controller.auxiliarySnapshot.hasStopPanel
        }
        let stopPanel = try XCTUnwrap(environment.auxiliaryPanels.last)
        let stopButton = try XCTUnwrap(stopPanel.contentView as? TemplateControlButton)
        XCTAssertEqual(loader.loadedAssets, [.recordButton, .stopButton])
        XCTAssertEqual(stopButton.title, "")
        XCTAssertEqual(stopButton.identifier?.rawValue, "gifpro.stop")
        XCTAssertEqual(stopButton.toolTip, "停止录制")
        XCTAssertEqual(stopButton.accessibilityLabel(), "停止录制")
        XCTAssertEqual(stopButton.accessibilityRole(), .button)
        XCTAssertTrue(stopPanel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(stopPanel.ignoresMouseEvents)
        XCTAssertFalse(stopPanel.isKeyWindow)

        stopButton.performClick(nil)
        stopButton.performClick(nil)
        XCTAssertFalse(stopButton.accessibilityPerformPress())
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(callbackObservedClosedStop)
        XCTAssertFalse(controller.lifecycleSnapshot.hasStopPanel)
        XCTAssertNil(controller.auxiliarySnapshot.hasStopPanel ? stopPanel : nil)
        controller.showStoppingVisualState()
        XCTAssertEqual(controller.lifecycleSnapshot.phase, .stopping)
        controller.dismiss()
        XCTAssertGreaterThanOrEqual(monitor.stopCount, 1)
        XCTAssertEqual(controller.lifecycleSnapshot.phase, .hidden)
        XCTAssertTrue(controller.lifecycleSnapshot.overlayDisplayIDs.isEmpty)
    }

    func testUnavailableRecordingLayoutReportsOnceAndCommitsRecordingWithoutPanels() throws {
        let environment = StubSelectionOverlayEnvironment(displays: [
            .init(displayID: 9, frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 28), backingScaleFactor: 1),
        ])
        var errors: [String] = []
        let controller = SelectionOverlayController(
            environment: environment,
            displayMonitor: StubSelectionOverlayDisplayMonitor(),
            layoutErrorSink: { errors.append($0) }
        )
        controller.show()
        let view = try XCTUnwrap(controller.selectionOverlayViews[9])
        XCTAssertTrue(view.onDragBegan?() == true)
        let selection = CGRect(x: 0, y: 0, width: 64, height: 64)
        view.selectionRect = selection
        view.onSelectionCompleted?(selection)
        controller.showCountdown(value: 3, targetDisplayID: 9)
        controller.startRecordingVisualState(onStop: {})

        XCTAssertEqual(controller.lifecycleSnapshot.phase, .recording)
        XCTAssertFalse(controller.lifecycleSnapshot.hasStatusPanel)
        XCTAssertFalse(controller.lifecycleSnapshot.hasStopPanel)
        XCTAssertFalse(controller.auxiliarySnapshot.hasStatusPanel)
        XCTAssertFalse(controller.auxiliarySnapshot.hasStopPanel)
        XCTAssertEqual(errors.count, 1)
        controller.showStoppingVisualState()
        XCTAssertEqual(controller.lifecycleSnapshot.phase, .stopping)
        controller.dismiss()
    }

    func testControllerInvalidatesRetainedStopAfterStoppingDisplayLossAndDismiss() throws {
        for invalidation: StopInvalidation in [.stopping, .displayLoss, .dismiss] {
            var stopCount = 0
            let session = try makeRecordingSession { stopCount += 1 }
            let retainedTarget = try XCTUnwrap(session.controller.stopActionTarget)
            let oldGeneration = session.controller.lifecycleSnapshot.generation

            switch invalidation {
            case .stopping:
                session.controller.showStoppingVisualState()
            case .displayLoss:
                session.monitor.send(.init(added: [], removed: [42], updated: []))
            case .dismiss:
                session.controller.dismiss()
            }

            XCTAssertGreaterThan(session.controller.lifecycleSnapshot.generation, oldGeneration)
            session.stopButton.performClick(nil)
            XCTAssertFalse(session.stopButton.accessibilityPerformPress())
            XCTAssertFalse(retainedTarget.fired)
            XCTAssertEqual(stopCount, 0)
            XCTAssertFalse(session.controller.auxiliarySnapshot.hasStopPanel)
            session.controller.dismiss()
        }
    }

    func testReplacementSessionInvalidatesOldStopWithoutAffectingNewStop() throws {
        var oldStopCount = 0
        let first = try makeRecordingSession { oldStopCount += 1 }
        let oldTarget = try XCTUnwrap(first.controller.stopActionTarget)
        let oldGeneration = first.controller.lifecycleSnapshot.generation

        first.controller.show()
        XCTAssertEqual(first.controller.lifecycleSnapshot.phase, .selecting)
        XCTAssertGreaterThan(first.controller.lifecycleSnapshot.generation, oldGeneration)
        first.stopButton.performClick(nil)
        XCTAssertFalse(first.stopButton.accessibilityPerformPress())
        XCTAssertFalse(oldTarget.fired)
        XCTAssertEqual(oldStopCount, 0)

        let view = try XCTUnwrap(first.controller.selectionOverlayViews[42])
        XCTAssertTrue(view.onDragBegan?() == true)
        let selection = CGRect(x: 100, y: 100, width: 200, height: 120)
        view.selectionRect = selection
        view.onSelectionCompleted?(selection)
        first.controller.showCountdown(value: 3, targetDisplayID: 42)
        var newStopCount = 0
        first.controller.startRecordingVisualState { newStopCount += 1 }
        let newButton = try XCTUnwrap(first.environment.auxiliaryPanels.last?.contentView as? TemplateControlButton)
        newButton.performClick(nil)

        XCTAssertEqual(oldStopCount, 0)
        XCTAssertEqual(newStopCount, 1)
        first.controller.dismiss()
    }

    func testCancelUsesControllerLifecycleAndAdvancesGeneration() throws {
        let environment = makeEnvironment()
        let monitor = StubSelectionOverlayDisplayMonitor()
        let controller = SelectionOverlayController(environment: environment, displayMonitor: monitor)
        var cancelCount = 0
        controller.onCancel = { cancelCount += 1 }
        controller.show()
        let generation = controller.lifecycleSnapshot.generation

        try XCTUnwrap(environment.selectionPanels.first).cancelOperation(nil)

        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(controller.lifecycleSnapshot.phase, .hidden)
        XCTAssertGreaterThan(controller.lifecycleSnapshot.generation, generation)
        XCTAssertTrue(controller.selectionOverlayViews.isEmpty)
        XCTAssertGreaterThanOrEqual(monitor.stopCount, 1)
    }

    private func makePanel() -> SelectionControlPanel {
        SelectionControlPanel(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private func makeEnvironment() -> StubSelectionOverlayEnvironment {
        StubSelectionOverlayEnvironment(displays: [
            .init(
                displayID: 42,
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                backingScaleFactor: 2
            ),
        ])
    }

    private func mouseEvent(type: NSEvent.EventType, location: CGPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    private enum StopInvalidation {
        case stopping
        case displayLoss
        case dismiss
    }

    private func makeRecordingSession(
        onStop: @escaping () -> Void
    ) throws -> (
        controller: SelectionOverlayController,
        environment: StubSelectionOverlayEnvironment,
        monitor: StubSelectionOverlayDisplayMonitor,
        stopButton: TemplateControlButton
    ) {
        let environment = StubSelectionOverlayEnvironment(displays: [
            .init(displayID: 42, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), backingScaleFactor: 2),
            .init(displayID: 43, frame: CGRect(x: 1_000, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 1_000, y: 0, width: 800, height: 600), backingScaleFactor: 1),
        ])
        let monitor = StubSelectionOverlayDisplayMonitor()
        let controller = SelectionOverlayController(
            imageLoader: StubTemplateControlImageLoader(),
            environment: environment,
            displayMonitor: monitor
        )
        controller.show()
        let view = try XCTUnwrap(controller.selectionOverlayViews[42])
        XCTAssertTrue(view.onDragBegan?() == true)
        let selection = CGRect(x: 100, y: 100, width: 200, height: 120)
        view.selectionRect = selection
        view.onSelectionCompleted?(selection)
        controller.showCountdown(value: 3, targetDisplayID: 42)
        controller.startRecordingVisualState(onStop: onStop)
        let statusPanel = try XCTUnwrap(environment.auxiliaryPanels.dropLast().last)
        let stopPanel = try XCTUnwrap(environment.auxiliaryPanels.last)
        let stopButton = try XCTUnwrap(stopPanel.contentView as? TemplateControlButton)

        XCTAssertEqual(controller.lifecycleSnapshot.phase, .recording)
        XCTAssertEqual(controller.lifecycleSnapshot.overlayDisplayIDs, [42])
        XCTAssertEqual(controller.selectionOverlayViews.keys.sorted(), [42])
        XCTAssertTrue(environment.selectionPanels[0].ignoresMouseEvents)
        XCTAssertTrue(statusPanel.ignoresMouseEvents)
        XCTAssertFalse(stopPanel.ignoresMouseEvents)
        XCTAssertTrue(controller.lifecycleSnapshot.hasStatusPanel)
        XCTAssertTrue(controller.lifecycleSnapshot.hasStopPanel)
        XCTAssertEqual(controller.auxiliarySnapshot.hasStatusPanel, controller.lifecycleSnapshot.hasStatusPanel)
        XCTAssertEqual(controller.auxiliarySnapshot.hasStopPanel, controller.lifecycleSnapshot.hasStopPanel)
        return (controller, environment, monitor, stopButton)
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

@MainActor
private final class StubSelectionOverlayEnvironment: SelectionOverlayEnvironment {
    let displays: [OverlayDisplayDescriptor]
    private(set) var selectionPanels: [SelectionOverlayPanel] = []
    private(set) var auxiliaryPanels: [NSPanel] = []

    init(displays: [OverlayDisplayDescriptor]) { self.displays = displays }

    func makeSelectionPanel(for display: OverlayDisplayDescriptor) -> SelectionOverlayPanel {
        let panel = SelectionOverlayPanel(
            contentRect: display.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        selectionPanels.append(panel)
        return panel
    }

    func makeAuxiliaryPanel(frame: CGRect, contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        auxiliaryPanels.append(panel)
        return panel
    }
}

@MainActor
private final class StubSelectionOverlayDisplayMonitor: SelectionOverlayDisplayMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor @Sendable (DisplayConfigurationChange) -> Void)?

    func start(onChange: @escaping @MainActor @Sendable (DisplayConfigurationChange) -> Void) {
        startCount += 1
        handler = onChange
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func send(_ change: DisplayConfigurationChange) {
        handler?(change)
    }
}
