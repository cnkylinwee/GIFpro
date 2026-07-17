import Foundation
import XCTest
@testable import GIFpro

final class FrameTimingTests: XCTestCase {
    func testRegularTimestampsAtSupportedFrameRatesCarryCentisecondRounding() {
        let cases: [(fps: Double, expected: [TimeInterval])] = [
            (8, [0.13, 0.12, 0.13]),
            (12, [0.08, 0.09, 0.08]),
            (15, [0.07, 0.06, 0.07]),
        ]

        for testCase in cases {
            var timing = FrameTiming()
            XCTAssertEqual(timing.accept(timestamp: 0), .firstFrame)

            let delays = (1 ... 3).compactMap { index -> TimeInterval? in
                guard case .previousFrame(let delay) = timing.accept(
                    timestamp: Double(index) / testCase.fps
                ) else {
                    return nil
                }
                return delay
            }

            XCTAssertEqual(delays, testCase.expected, "Unexpected delays at \(testCase.fps) FPS")
        }
    }

    func testDroppedFrameGapExtendsPreviousFrameDelay() {
        var timing = FrameTiming()

        XCTAssertEqual(timing.accept(timestamp: 0), .firstFrame)
        XCTAssertEqual(timing.accept(timestamp: 0.10), .previousFrame(delay: 0.10))
        XCTAssertEqual(timing.accept(timestamp: 0.30), .previousFrame(delay: 0.20))
    }

    func testFinishEmitsPendingFinalFrameDelayOnlyOnce() {
        var timing = FrameTiming()

        XCTAssertEqual(timing.accept(timestamp: 0), .firstFrame)
        XCTAssertEqual(timing.accept(timestamp: 0.10), .previousFrame(delay: 0.10))
        XCTAssertEqual(timing.finish(at: 0.30), 0.20)
        XCTAssertNil(timing.finish(at: 0.50))
    }

    func testOneSecondRecordingStaysWithinOneCentisecondAfterRounding() throws {
        var timing = FrameTiming()
        var delays: [TimeInterval] = []

        XCTAssertEqual(timing.accept(timestamp: 0), .firstFrame)
        for frameIndex in 1 ..< 12 {
            guard case .previousFrame(let delay) = timing.accept(
                timestamp: Double(frameIndex) / 12
            ) else {
                return XCTFail("Expected timestamp to emit its preceding frame")
            }
            delays.append(delay)
        }
        delays.append(try XCTUnwrap(timing.finish(at: 1.00)))

        XCTAssertEqual(delays.reduce(0, +), 1.00, accuracy: 0.01)
    }

    func testEveryEmittedDelayIsAtLeastTwoCentiseconds() throws {
        var timing = FrameTiming()

        XCTAssertEqual(timing.accept(timestamp: 1.000), .firstFrame)
        guard case .previousFrame(let shortDelay) = timing.accept(timestamp: 1.005) else {
            return XCTFail("Expected a delay for the previous frame")
        }
        let finalDelay = try XCTUnwrap(timing.finish(at: 1.010))

        XCTAssertGreaterThanOrEqual(shortDelay, 0.02)
        XCTAssertGreaterThanOrEqual(finalDelay, 0.02)
    }

    func testInvalidAndNonIncreasingTimestampsAreRejectedWithoutChangingPendingFrame() {
        var timing = FrameTiming()

        XCTAssertNil(timing.accept(timestamp: .nan))
        XCTAssertNil(timing.accept(timestamp: .infinity))
        XCTAssertEqual(timing.accept(timestamp: 2), .firstFrame)
        XCTAssertNil(timing.accept(timestamp: 2))
        XCTAssertNil(timing.accept(timestamp: 1))
        XCTAssertNil(timing.accept(timestamp: -.infinity))
        XCTAssertEqual(timing.accept(timestamp: 2.10), .previousFrame(delay: 0.10))
    }
}
