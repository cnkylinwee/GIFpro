import Foundation

struct FrameTiming: Sendable {
    enum Acceptance: Equatable, Sendable {
        case firstFrame
        case previousFrame(delay: TimeInterval)
    }

    private static let centisecondsPerSecond = 100.0
    private static let minimumDelayCentiseconds = 2.0

    private var previousTimestamp: TimeInterval?
    private var fractionalCentisecondRemainder = 0.0

    mutating func accept(timestamp: TimeInterval) -> Acceptance? {
        guard timestamp.isFinite else {
            return nil
        }

        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return .firstFrame
        }

        guard timestamp > previousTimestamp,
              let delay = quantizedDelay(from: previousTimestamp, to: timestamp)
        else {
            return nil
        }

        self.previousTimestamp = timestamp
        return .previousFrame(delay: delay)
    }

    mutating func finish(at timestamp: TimeInterval) -> TimeInterval? {
        guard timestamp.isFinite,
              let previousTimestamp,
              timestamp > previousTimestamp,
              let delay = quantizedDelay(from: previousTimestamp, to: timestamp)
        else {
            return nil
        }

        self.previousTimestamp = nil
        fractionalCentisecondRemainder = 0
        return delay
    }

    private mutating func quantizedDelay(
        from startTimestamp: TimeInterval,
        to endTimestamp: TimeInterval
    ) -> TimeInterval? {
        let elapsed = endTimestamp - startTimestamp
        let exactCentiseconds = elapsed * Self.centisecondsPerSecond
            + fractionalCentisecondRemainder

        guard elapsed.isFinite, elapsed > 0, exactCentiseconds.isFinite else {
            return nil
        }

        let emittedCentiseconds = max(
            Self.minimumDelayCentiseconds,
            exactCentiseconds.rounded()
        )
        fractionalCentisecondRemainder = exactCentiseconds - emittedCentiseconds
        return emittedCentiseconds / Self.centisecondsPerSecond
    }
}
