import AppKit
import XCTest
@testable import GIFpro

@MainActor
final class SelectionControlPanelTests: XCTestCase {
    @MainActor
    func testOverlayStatusMovesFromCountdownToRecordingAndStopping() {
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.selectionRect = CGRect(x: 20, y: 20, width: 300, height: 200)

        view.showCountdown(3)
        XCTAssertEqual(view.statusText, "3")
        XCTAssertFalse(view.showsStopControl)

        view.showRecording(elapsed: 5, remaining: 10, isWarning: true, onStop: {})
        XCTAssertTrue(view.statusIsWarning)
        XCTAssertTrue(view.showsStopControl)
        XCTAssertEqual(view.statusText, "00:05  剩余 00:10")

        view.showStopping()
        XCTAssertEqual(view.statusText, "正在完成…")
        XCTAssertFalse(view.showsStopControl)
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
        let controls = SelectionControlsView(settings: .default, supportsTwoX: true)

        let recordButton = controls.descendants
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Record" }

        XCTAssertEqual(recordButton?.keyEquivalent, "\r")
    }

    private func makePanel() -> SelectionControlPanel {
        SelectionControlPanel(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
