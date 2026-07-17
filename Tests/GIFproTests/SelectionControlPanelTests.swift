import AppKit
import XCTest
@testable import GIFpro

@MainActor
final class SelectionControlPanelTests: XCTestCase {
    func testAuxiliaryStatusContentMovesFromCountdownToRecordingAndStopping() {
        XCTAssertEqual(RecordingOverlayStatusContent.countdown(3), "3")
        XCTAssertEqual(
            RecordingOverlayStatusContent.recording(elapsed: 5, remaining: 10),
            "00:05  剩余 00:10"
        )
        XCTAssertEqual(RecordingOverlayStatusContent.stopping, "正在完成…")
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
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
