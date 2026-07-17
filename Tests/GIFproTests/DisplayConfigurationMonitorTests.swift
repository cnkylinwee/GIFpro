import AppKit
import CoreGraphics
import XCTest
@testable import GIFpro

@MainActor
final class DisplayConfigurationMonitorTests: XCTestCase {
    func testReportsAddedAndRemovedDisplayIDs() {
        let center = NotificationCenter()
        var IDs: Set<CGDirectDisplayID> = [1, 2]
        let monitor = DisplayConfigurationMonitor(notificationCenter: center) { IDs }
        var changes: [DisplayConfigurationChange] = []
        monitor.start { changes.append($0) }

        IDs = [2, 3]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(changes, [.init(added: [3], removed: [1])])
    }

    func testDoesNotReportWhenIDsAreUnchanged() {
        let center = NotificationCenter()
        let monitor = DisplayConfigurationMonitor(notificationCenter: center) { [1, 2] }
        var callbackCount = 0
        monitor.start { _ in callbackCount += 1 }

        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(callbackCount, 0)
    }

    func testStopPreventsCallbacks() {
        let center = NotificationCenter()
        var IDs: Set<CGDirectDisplayID> = [1]
        let monitor = DisplayConfigurationMonitor(notificationCenter: center) { IDs }
        var callbackCount = 0
        monitor.start { _ in callbackCount += 1 }
        monitor.stop()

        IDs = [2]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(callbackCount, 0)
    }

    func testDeinitRemovesObserver() {
        let center = NotificationCenter()
        var callbackCount = 0
        var monitor: DisplayConfigurationMonitor? = DisplayConfigurationMonitor(notificationCenter: center) { [1] }
        monitor?.start { _ in callbackCount += 1 }
        monitor = nil

        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(callbackCount, 0)
    }
}
