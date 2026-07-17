import AppKit
import XCTest
@testable import GIFpro

@MainActor
final class SelectionControlPanelTests: XCTestCase {
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
