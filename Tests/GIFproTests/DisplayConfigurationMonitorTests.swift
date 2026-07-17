import AppKit
import CoreGraphics
import XCTest
@testable import GIFpro

@MainActor
final class DisplayConfigurationMonitorTests: XCTestCase {
    func testReportsAddedAndRemovedDisplayIDs() {
        let observer = SpyScreenParameterObserver()
        var snapshots = dictionary(snapshot(id: 1), snapshot(id: 2))
        let monitor = DisplayConfigurationMonitor(observer: observer) { snapshots }
        var changes: [DisplayConfigurationChange] = []
        monitor.start { changes.append($0) }

        snapshots = dictionary(snapshot(id: 2), snapshot(id: 3))
        observer.post()

        XCTAssertEqual(changes, [.init(added: [3], removed: [1], updated: [])])
    }

    func testSameIDOriginChangeIsReportedAsUpdated() {
        assertSameIDUpdate(
            from: snapshot(id: 1),
            to: snapshot(id: 1, frame: CGRect(x: -100, y: 50, width: 500, height: 400))
        )
    }

    func testSameIDSizeChangeIsReportedAsUpdated() {
        assertSameIDUpdate(
            from: snapshot(id: 1),
            to: snapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 600, height: 450))
        )
    }

    func testSameIDBackingScaleChangeIsReportedAsUpdated() {
        assertSameIDUpdate(from: snapshot(id: 1), to: snapshot(id: 1, backingScale: 2))
    }

    func testSameIDRotationChangeIsReportedAsUpdated() {
        assertSameIDUpdate(from: snapshot(id: 1), to: snapshot(id: 1, rotationDegrees: 90))
    }

    func testIdenticalSnapshotsDoNotReportAChange() {
        let observer = SpyScreenParameterObserver()
        let current = dictionary(snapshot(id: 1), snapshot(id: 2))
        let monitor = DisplayConfigurationMonitor(observer: observer) { current }
        var callbackCount = 0
        monitor.start { _ in callbackCount += 1 }

        observer.post()

        XCTAssertEqual(callbackCount, 0)
    }

    func testStopRemovesObservationExactlyOnceAndPreventsCallbacks() {
        let observer = SpyScreenParameterObserver()
        var snapshots = dictionary(snapshot(id: 1))
        let monitor = DisplayConfigurationMonitor(observer: observer) { snapshots }
        var callbackCount = 0
        monitor.start { _ in callbackCount += 1 }
        monitor.stop()
        monitor.stop()

        snapshots = dictionary(snapshot(id: 2))
        observer.post()

        XCTAssertEqual(observer.removalCount, 1)
        XCTAssertEqual(callbackCount, 0)
    }

    func testDeinitRemovesObservationExactlyOnce() {
        let observer = SpyScreenParameterObserver()
        var monitor: DisplayConfigurationMonitor? = DisplayConfigurationMonitor(observer: observer) {
            self.dictionary(self.snapshot(id: 1))
        }
        monitor?.start { _ in }
        XCTAssertEqual(observer.removalCount, 0)

        monitor = nil

        XCTAssertEqual(observer.removalCount, 1)
    }

    private func assertSameIDUpdate(from previous: DisplaySnapshot, to current: DisplaySnapshot) {
        let observer = SpyScreenParameterObserver()
        var snapshots = dictionary(previous)
        let monitor = DisplayConfigurationMonitor(observer: observer) { snapshots }
        var changes: [DisplayConfigurationChange] = []
        monitor.start { changes.append($0) }

        snapshots = dictionary(current)
        observer.post()

        XCTAssertEqual(changes, [.init(added: [], removed: [], updated: [previous.displayID])])
    }

    private func snapshot(
        id: CGDirectDisplayID,
        frame: CGRect = CGRect(x: 0, y: 0, width: 500, height: 400),
        backingScale: CGFloat = 1,
        rotationDegrees: Double = 0
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: id,
            frame: frame,
            backingScale: backingScale,
            rotationDegrees: rotationDegrees
        )
    }

    private func dictionary(_ snapshots: DisplaySnapshot...) -> [CGDirectDisplayID: DisplaySnapshot] {
        Dictionary(uniqueKeysWithValues: snapshots.map { ($0.displayID, $0) })
    }
}

@MainActor
private final class SpyScreenParameterObserver: ScreenParameterObserving {
    private var handler: (@MainActor @Sendable () -> Void)?
    private let counter = LockedCounter()

    var removalCount: Int { counter.value }

    func observe(_ handler: @escaping @MainActor @Sendable () -> Void) -> ScreenParameterObservation {
        self.handler = handler
        return ScreenParameterObservation { [counter] in counter.increment() }
    }

    func post() {
        guard removalCount == 0 else { return }
        handler?()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
