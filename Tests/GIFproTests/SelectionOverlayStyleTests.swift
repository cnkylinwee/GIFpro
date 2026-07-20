import AppKit
import XCTest
@testable import GIFpro

@MainActor
final class SelectionOverlayStyleTests: XCTestCase {
    private let selection = CGRect(x: 100, y: 80, width: 200, height: 160)

    func testSelectingAndRecordingStylesStoreFixedMetricsAndSemanticRoles() {
        let selecting = SelectionOverlayStyle.selecting
        let recording = SelectionOverlayStyle.recording

        XCTAssertEqual(SelectionOverlayStyle.borderWidth, 2)
        XCTAssertEqual(SelectionOverlayStyle.visibleHandleSize, CGSize(width: 10, height: 10))
        XCTAssertEqual(SelectionOverlayStyle.handleHitSize, CGSize(width: 16, height: 16))
        XCTAssertEqual(SelectionOverlayStyle.handleCornerRadius, 2)
        XCTAssertEqual(selecting.borderRole, .selectionAccent)
        XCTAssertEqual(selecting.handleFillRole, .windowBackground)
        XCTAssertEqual(recording.borderRole, .recordingRed)
        XCTAssertEqual(recording.handleFillRole, .windowBackground)
        XCTAssertNotEqual(selecting, recording)
        XCTAssertEqual(selecting, .selecting)
    }

    func testHandleRenderDescriptorKeepsStrokedOuterBoundsAtTenPoints() {
        let style = SelectionOverlayStyle.selecting
        let descriptor = style.handleRenderDescriptor(for: .topLeft, selection: selection)
        let expectedOuterFrame = CGRect(x: 95, y: 235, width: 10, height: 10)

        XCTAssertEqual(descriptor.visibleOuterFrame, expectedOuterFrame)
        XCTAssertEqual(descriptor.pathFrame, expectedOuterFrame.insetBy(dx: 1, dy: 1))
        XCTAssertEqual(descriptor.strokeWidth, 2)
        XCTAssertEqual(descriptor.outerCornerRadius, 2)
        XCTAssertEqual(descriptor.pathCornerRadius, 1)
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
                CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16),
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

    func testSyntheticMouseEventsResizeFromEveryHandleCenterAndHitEdge() throws {
        let translation = CGPoint(x: 11, y: 13)
        let style = SelectionOverlayStyle.selecting

        for handle in ResizeHandle.allCases {
            let visibleFrame = style.visibleHandleFrame(for: handle, selection: selection)
            try assertResize(handle: handle, mouseDownPoint: visibleFrame.center, translation: translation)

            let hitFrame = style.handleHitFrame(for: handle, selection: selection)
            let hitEdge = CGPoint(x: hitFrame.maxX - 0.5, y: hitFrame.midY)
            try assertResize(handle: handle, mouseDownPoint: hitEdge, translation: translation)
        }
    }

    func testDraggingInsideSelectionAwayFromHandlesCreatesNewSelection() throws {
        let view = makeView()
        view.selectionRect = selection
        let start = CGPoint(x: selection.midX, y: selection.midY)
        let end = CGPoint(x: start.x + 80, y: start.y + 70)

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: start))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: end))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, location: end))

        XCTAssertEqual(view.selectionRect, CGRect(x: start.x, y: start.y, width: 80, height: 70))
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

    func testDefaultSelectionRectIsCenteredAtThreeHundredByTwoHundred() {
        XCTAssertEqual(
            SelectionGeometry.defaultRect(within: CGRect(x: 0, y: 0, width: 500, height: 400)),
            CGRect(x: 100, y: 100, width: 300, height: 200)
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
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
