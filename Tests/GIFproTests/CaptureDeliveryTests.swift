import CoreMedia
import CoreVideo
import XCTest
@testable import GIFpro

private actor SlowFrameConsumer {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var startedTimes: [CMTimeValue] = []

    var startedCount: Int { startedTimes.count }

    func consume(_ frame: CapturedFrame) async throws {
        startedTimes.append(frame.presentationTime.value)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

final class CaptureDeliveryTests: XCTestCase {
    func testSlowConsumerProcessesBoundedFramesInArrivalOrder() async throws {
        let consumer = SlowFrameConsumer()
        let delivery = FrameDelivery(capacity: 2) { frame in
            try await consumer.consume(frame)
        }
        let first = try makeFrame(timeValue: 1)
        let second = try makeFrame(timeValue: 2)
        let third = try makeFrame(timeValue: 3)

        XCTAssertTrue(delivery.offer(first))
        XCTAssertTrue(delivery.offer(second))
        XCTAssertFalse(delivery.offer(third))
        await waitUntil { await consumer.startedCount == 1 }
        for _ in 0 ..< 20 { await Task.yield() }
        let startedBeforeRelease = await consumer.startedTimes
        XCTAssertEqual(startedBeforeRelease, [1])
        XCTAssertEqual(delivery.snapshot.inUse, 2)

        delivery.stopAccepting()
        XCTAssertFalse(delivery.offer(third))
        await consumer.releaseOne()
        await waitUntil { await consumer.startedCount == 2 }
        let startedAfterRelease = await consumer.startedTimes
        XCTAssertEqual(startedAfterRelease, [1, 2])

        await consumer.releaseAll()
        await delivery.waitUntilDrained()
    }

    func testStopRejectsNewFramesAndWaitsForAcceptedFrame() async throws {
        let consumer = SlowFrameConsumer()
        let delivery = FrameDelivery(capacity: 2) { frame in
            try await consumer.consume(frame)
        }
        let frame = try makeFrame()

        XCTAssertTrue(delivery.offer(frame))
        await waitUntil { await consumer.startedCount == 1 }
        delivery.stopAccepting()
        XCTAssertFalse(delivery.offer(frame))

        let drain = Task { await delivery.waitUntilDrained() }
        XCTAssertEqual(delivery.snapshot.inUse, 1)
        await consumer.releaseAll()
        await drain.value
        XCTAssertEqual(delivery.snapshot.inUse, 0)
    }

    private func makeFrame(timeValue: CMTimeValue = 1) throws -> CapturedFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return CapturedFrame(
            pixelBuffer: try XCTUnwrap(pixelBuffer),
            presentationTime: CMTime(value: timeValue, timescale: 12)
        )
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0 ..< 1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition was not satisfied")
    }
}
