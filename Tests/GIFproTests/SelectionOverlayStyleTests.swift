import AppKit
import XCTest
@testable import GIFpro

@MainActor
final class SelectionOverlayStyleTests: XCTestCase {
    private let selection = CGRect(x: 100, y: 80, width: 200, height: 160)

    func testSelectingAndRecordingStylesStoreFixedMetricsAndSemanticRoles() {
        let selecting = SelectionOverlayStyle.selecting
        let recording = SelectionOverlayStyle.recording
        let countdown = SelectionOverlayStyle.countdown

        XCTAssertEqual(SelectionOverlayStyle.borderWidth, 2)
        XCTAssertEqual(SelectionOverlayStyle.visibleHandleSize, CGSize(width: 10, height: 10))
        XCTAssertEqual(SelectionOverlayStyle.handleHitSize, CGSize(width: 22, height: 22))
        XCTAssertEqual(SelectionOverlayStyle.handleCornerRadius, 5)
        XCTAssertEqual(SelectionOverlayStyle.selectionDashPattern, [NSNumber(value: 8), NSNumber(value: 6)])
        XCTAssertEqual(SelectionOverlayStyle.borderResizeHitSlop, 5)
        XCTAssertEqual(SelectionOverlayStyle.countdownCornerLength, 16)
        XCTAssertEqual(SelectionOverlayStyle.countdownCornerWidth, 3)
        XCTAssertEqual(SelectionOverlayStyle.countdownDiskSize, CGSize(width: 96, height: 96))
        XCTAssertEqual(SelectionOverlayStyle.countdownFontSize, 72)
        XCTAssertEqual(selecting.borderRole, .selectionAccent)
        XCTAssertEqual(selecting.handleFillRole, .windowBackground)
        XCTAssertEqual(recording.borderRole, .recordingRed)
        XCTAssertEqual(recording.handleFillRole, .windowBackground)
        XCTAssertEqual(countdown.borderRole, .countdownOrangeRed)
        XCTAssertEqual(countdown.handleFillRole, .windowBackground)
        XCTAssertNotEqual(selecting, recording)
        XCTAssertNotEqual(countdown, recording)
        XCTAssertEqual(selecting, .selecting)
    }

    func testHandleRenderDescriptorKeepsStrokedOuterBoundsAtTenPoints() {
        let style = SelectionOverlayStyle.selecting
        let descriptor = style.handleRenderDescriptor(for: .topLeft, selection: selection)
        let expectedOuterFrame = CGRect(x: 95, y: 235, width: 10, height: 10)

        XCTAssertEqual(descriptor.visibleOuterFrame, expectedOuterFrame)
        XCTAssertEqual(descriptor.pathFrame, expectedOuterFrame.insetBy(dx: 1, dy: 1))
        XCTAssertEqual(descriptor.strokeWidth, 2)
        XCTAssertEqual(descriptor.outerCornerRadius, 5)
        XCTAssertEqual(descriptor.pathCornerRadius, 4)
        XCTAssertEqual(descriptor.strokedOuterBounds, expectedOuterFrame)
    }

    func testVisibleAndHitFramesAreCenteredOnAllEightHandleLocations() throws {
        let style = SelectionOverlayStyle.selecting
        let centers: [ResizeHandle: CGPoint] = [
            .top: CGPoint(x: 200, y: 240),
            .bottom: CGPoint(x: 200, y: 80),
            .left: CGPoint(x: 100, y: 160),
            .right: CGPoint(x: 300, y: 160),
            .topLeft: CGPoint(x: 100, y: 240),
            .topRight: CGPoint(x: 300, y: 240),
            .bottomLeft: CGPoint(x: 100, y: 80),
            .bottomRight: CGPoint(x: 300, y: 80),
        ]

        for handle in ResizeHandle.allCases {
            let center = try XCTUnwrap(centers[handle])
            XCTAssertEqual(
                style.visibleHandleFrame(for: handle, selection: selection),
                CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10),
                "visible frame for \(handle)"
            )
            XCTAssertEqual(
                style.handleHitFrame(for: handle, selection: selection),
                CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22),
                "hit frame for \(handle)"
            )
        }
    }

    func testCornerHandleWinsWhenCornerAndEdgeHitFramesOverlap() {
        let style = SelectionOverlayStyle.selecting
        let narrowSelection = CGRect(x: 100, y: 80, width: 12, height: 12)

        XCTAssertEqual(
            style.hitHandle(at: CGPoint(x: 101, y: 91), selection: narrowSelection),
            .topLeft
        )
        XCTAssertEqual(
            style.hitHandle(at: CGPoint(x: 111, y: 91), selection: narrowSelection),
            .topRight
        )
    }

    func testOnlyVisibleControlPointLocationsAreResizeTargets() {
        let style = SelectionOverlayStyle.selecting

        XCTAssertEqual(style.hitHandle(at: style.visibleHandleFrame(for: .top, selection: selection).center, selection: selection), .top)
        XCTAssertEqual(style.hitHandle(at: style.visibleHandleFrame(for: .bottom, selection: selection).center, selection: selection), .bottom)
        XCTAssertEqual(style.hitHandle(at: style.visibleHandleFrame(for: .left, selection: selection).center, selection: selection), .left)
        XCTAssertEqual(style.hitHandle(at: style.visibleHandleFrame(for: .right, selection: selection).center, selection: selection), .right)
        XCTAssertNil(style.hitHandle(at: CGPoint(x: 140, y: selection.maxY - 1), selection: selection))
        XCTAssertNil(style.hitHandle(at: CGPoint(x: selection.maxX - 1, y: 130), selection: selection))
    }

    func testSemanticRolesResolveAgainstLightAndDarkAppearances() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))

        for appearance in [aqua, darkAqua] {
            XCTAssertEqual(
                SelectionOverlayColorRole.selectionAccent.color(with: appearance),
                color(.controlAccentColor, with: appearance)
            )
            XCTAssertEqual(
                SelectionOverlayColorRole.recordingRed.color(with: appearance),
                color(.systemRed, with: appearance)
            )
            XCTAssertEqual(
                SelectionOverlayColorRole.windowBackground.color(with: appearance),
                color(.windowBackgroundColor, with: appearance)
            )
            assertColor(
                SelectionOverlayColorRole.countdownOrangeRed.color(with: appearance),
                equals: NSColor(calibratedRed: 1, green: 0.28, blue: 0.16, alpha: 1)
            )
        }
    }

    func testAppearanceAndSystemColorChangesRequestRedraw() {
        let notifications = NotificationCenter()
        var redrawCount = 0
        let view = SelectionOverlayView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            notificationCenter: notifications,
            onRedrawRequested: { redrawCount += 1 }
        )

        view.viewDidChangeEffectiveAppearance()
        notifications.post(name: NSColor.systemColorsDidChangeNotification, object: nil)

        XCTAssertEqual(redrawCount, 2)
    }

    func testSyntheticMouseEventsResizeFromEveryControlPoint() throws {
        let translation = CGPoint(x: 11, y: 13)
        let style = SelectionOverlayStyle.selecting

        for handle in ResizeHandle.allCases {
            let visibleFrame = style.visibleHandleFrame(for: handle, selection: selection)
            try assertResize(handle: handle, mouseDownPoint: visibleFrame.center, translation: translation)
        }
    }

    func testDraggingBorderAwayFromControlPointsMovesExistingSelection() throws {
        let view = makeView()
        view.selectionRect = selection
        let start = CGPoint(x: 140, y: selection.maxY - 1)
        let end = CGPoint(x: start.x + 30, y: start.y + 20)

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: start))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: end))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: end))

        XCTAssertEqual(view.selectionRect, CGRect(x: 130, y: 100, width: 200, height: 160))
    }

    func testDraggingInsideSelectionAwayFromBorderMovesExistingSelection() throws {
        let view = makeView()
        view.selectionRect = selection
        let start = CGPoint(x: selection.midX, y: selection.midY)
        let end = CGPoint(x: start.x + 80, y: start.y + 70)

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: start))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: end))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: end))

        XCTAssertEqual(view.selectionRect, CGRect(x: 180, y: 150, width: 200, height: 160))
    }

    func testInteractiveOverlayConsumesMouseEventsInsideSelection() {
        let view = makeView()
        view.selectionRect = selection

        XCTAssertTrue(view.hitTest(CGPoint(x: selection.midX, y: selection.midY)) === view)
        XCTAssertTrue(view.hitTest(CGPoint(x: selection.minX + 1, y: selection.maxY - 1)) === view)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testNonInteractiveOverlayDoesNotConsumeMouseEvents() {
        let view = makeView()
        view.selectionRect = selection
        view.isInteractive = false

        XCTAssertNil(view.hitTest(CGPoint(x: selection.midX, y: selection.midY)))
        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    func testRecordingOverlayConsumesOnlySelectionRectWhenBlockingMouseEvents() {
        let view = makeView()
        view.selectionRect = selection
        view.isInteractive = false
        view.blocksSelectionMouseEvents = true

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertTrue(view.hitTest(CGPoint(x: selection.midX, y: selection.midY)) === view)
        XCTAssertNil(view.hitTest(CGPoint(x: selection.minX - 20, y: selection.midY)))
    }

    func testDraggingOutsideSelectionStillCreatesNewSelection() throws {
        let view = makeView()
        view.selectionRect = selection
        let start = CGPoint(x: 20, y: 20)
        let end = CGPoint(x: 100, y: 90)

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: start))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: end))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: end))

        XCTAssertEqual(view.selectionRect, CGRect(x: start.x, y: start.y, width: 80, height: 70))
    }

    func testDefaultSelectionRectIsCenteredAtFiveHundredByThreeHundred() {
        XCTAssertEqual(
            SelectionGeometry.defaultRect(within: CGRect(x: 0, y: 0, width: 800, height: 600)),
            CGRect(x: 150, y: 150, width: 500, height: 300)
        )
        XCTAssertEqual(
            SelectionGeometry.defaultRect(within: CGRect(x: 0, y: 0, width: 240, height: 160)),
            CGRect(x: 0, y: 0, width: 240, height: 160)
        )
    }

    private func assertResize(
        handle: ResizeHandle,
        mouseDownPoint: CGPoint,
        translation: CGPoint
    ) throws {
        let view = makeView()
        view.selectionRect = selection
        let end = CGPoint(
            x: mouseDownPoint.x + translation.x,
            y: mouseDownPoint.y + translation.y
        )

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: mouseDownPoint))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: end))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: end))

        XCTAssertEqual(
            view.selectionRect,
            SelectionGeometry.resized(
                selection,
                handle: handle,
                translation: translation,
                within: view.bounds
            ),
            "resize from \(handle) at \(mouseDownPoint)"
        )
    }

    private func makeView() -> SelectionOverlayView {
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        view.onDragBegan = { true }
        return view
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

    private func color(_ semanticColor: @autoclosure () -> NSColor, with appearance: NSAppearance) -> NSColor {
        var color: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            color = semanticColor()
        }
        return color ?? semanticColor()
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

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
