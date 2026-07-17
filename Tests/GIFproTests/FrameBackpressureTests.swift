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

        var didRegisterWaiter = false
        for _ in 0 ..< 1_000 {
            if backpressure.snapshot.drainWaiterCount == 1 {
                didRegisterWaiter = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(didRegisterWaiter)

        let waitingSnapshot = backpressure.snapshot
        XCTAssertEqual(waitingSnapshot.inUse, 2)
        XCTAssertEqual(waitingSnapshot.drainWaiterCount, 1)
        let completedBeforeRelease = await probe.isComplete
        XCTAssertFalse(completedBeforeRelease)

        backpressure.release()
        let partlyDrainedSnapshot = backpressure.snapshot
        XCTAssertEqual(partlyDrainedSnapshot.inUse, 1)
        XCTAssertEqual(partlyDrainedSnapshot.drainWaiterCount, 1)
        let completedAfterOneRelease = await probe.isComplete
        XCTAssertFalse(completedAfterOneRelease)

        backpressure.release()
        await waiter.value
        let drainedSnapshot = backpressure.snapshot
        XCTAssertEqual(drainedSnapshot.inUse, 0)
        XCTAssertEqual(drainedSnapshot.drainWaiterCount, 0)
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
