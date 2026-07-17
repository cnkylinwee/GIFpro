import XCTest
@testable import GIFpro

private actor DrainProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

final class FrameBackpressureTests: XCTestCase {
    func testAcquisitionFailsImmediatelyAtCapacity() {
        let backpressure = FrameBackpressure(capacity: 2)

        XCTAssertTrue(backpressure.tryAcquire())
        XCTAssertTrue(backpressure.tryAcquire())
        XCTAssertFalse(backpressure.tryAcquire())
    }

    func testReleaseRestoresCapacityWithoutAllowingExtraPermits() {
        let backpressure = FrameBackpressure(capacity: 2)

        XCTAssertTrue(backpressure.tryAcquire())
        XCTAssertTrue(backpressure.tryAcquire())
        backpressure.release()
        XCTAssertTrue(backpressure.tryAcquire())
        XCTAssertFalse(backpressure.tryAcquire())

        backpressure.release()
        backpressure.release()
        backpressure.release()
        XCTAssertTrue(backpressure.tryAcquire())
        XCTAssertTrue(backpressure.tryAcquire())
        XCTAssertFalse(backpressure.tryAcquire())
    }

    func testWaitUntilDrainedWaitsForEveryAcquiredPermit() async {
        let backpressure = FrameBackpressure(capacity: 2)
        let probe = DrainProbe()
        XCTAssertTrue(backpressure.tryAcquire())
        XCTAssertTrue(backpressure.tryAcquire())

        let waiter = Task {
            await backpressure.waitUntilDrained()
            await probe.complete()
        }

        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let completedBeforeRelease = await probe.isComplete
        XCTAssertFalse(completedBeforeRelease)

        backpressure.release()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let completedAfterOneRelease = await probe.isComplete
        XCTAssertFalse(completedAfterOneRelease)

        backpressure.release()
        await waiter.value
        let completedAfterAllReleases = await probe.isComplete
        XCTAssertTrue(completedAfterAllReleases)
    }

    func testWaitUntilDrainedReturnsImmediatelyWhenAlreadyDrained() async {
        let backpressure = FrameBackpressure(capacity: 2)
        let didDrain = expectation(description: "already drained")

        Task {
            await backpressure.waitUntilDrained()
            didDrain.fulfill()
        }

        await fulfillment(of: [didDrain], timeout: 0.1)
    }
}
