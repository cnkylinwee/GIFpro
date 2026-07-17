import ScreenCaptureKit
import XCTest
@testable import GIFpro

private actor StubContentProvider: ShareableContentProviding {
    private(set) var callCount = 0

    func latestSnapshot() async throws -> ShareableContentSnapshot {
        callCount += 1
        return .testing(displayIDs: [42], processIDs: [200])
    }
}

private actor StubCaptureSession: CaptureSession {
    enum StubError: Error { case startFailed }

    private let shouldFailStart: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(shouldFailStart: Bool = false) {
        self.shouldFailStart = shouldFailStart
    }

    func start() async throws {
        startCount += 1
        if shouldFailStart { throw StubError.startFailed }
    }

    func stop() async throws {
        stopCount += 1
    }
}

private final class StubSessionBuilder: CaptureSessionBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [any CaptureSession]

    init(sessions: [any CaptureSession]) {
        self.sessions = sessions
    }

    func build(
        selection: SelectedShareableContent,
        configuration: SCStreamConfiguration,
        delivery: FrameDelivery,
        onFailure: @escaping @Sendable (CaptureError) -> Void
    ) throws -> any CaptureSession {
        _ = selection
        _ = configuration
        _ = delivery
        _ = onFailure
        lock.lock()
        defer { lock.unlock() }
        return sessions.removeFirst()
    }
}

private actor BlockingStopSession: CaptureSession {
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopStarted = false

    func start() async throws {}

    func stop() async throws {
        stopStarted = true
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private actor CompletionProbe {
    private(set) var isComplete = false
    func complete() { isComplete = true }
}

final class CaptureEngineLifecycleTests: XCTestCase {
    func testConcurrentStopsAwaitTheSameStopOperation() async throws {
        let session = BlockingStopSession()
        let engine = CaptureEngine(
            contentProvider: StubContentProvider(),
            sessionBuilder: StubSessionBuilder(sessions: [session]),
            processID: 200
        )
        try await engine.start(region: makeRegion(), settings: .default) { _ in }

        let firstStop = Task { await engine.stop() }
        await waitUntil { await session.stopStarted }
        let secondCompletion = CompletionProbe()
        let secondStop = Task {
            await engine.stop()
            await secondCompletion.complete()
        }
        for _ in 0 ..< 20 { await Task.yield() }
        let completedBeforeUnderlyingStop = await secondCompletion.isComplete
        XCTAssertFalse(completedBeforeUnderlyingStop)

        await session.finishStop()
        await firstStop.value
        await secondStop.value
        let completedAfterUnderlyingStop = await secondCompletion.isComplete
        XCTAssertTrue(completedAfterUnderlyingStop)
    }

    func testEveryStartRefreshesContentAndDoubleStopIsIdempotent() async throws {
        let provider = StubContentProvider()
        let firstSession = StubCaptureSession()
        let secondSession = StubCaptureSession()
        let engine = CaptureEngine(
            contentProvider: provider,
            sessionBuilder: StubSessionBuilder(sessions: [firstSession, secondSession]),
            processID: 200
        )

        try await engine.start(region: makeRegion(), settings: .default) { _ in }
        await engine.stop()
        await engine.stop()
        try await engine.start(region: makeRegion(), settings: .default) { _ in }
        await engine.stop()

        let providerCalls = await provider.callCount
        let firstCounts = await (firstSession.startCount, firstSession.stopCount)
        let secondCounts = await (secondSession.startCount, secondSession.stopCount)
        XCTAssertEqual(providerCalls, 2)
        XCTAssertEqual(firstCounts.0, 1)
        XCTAssertEqual(firstCounts.1, 1)
        XCTAssertEqual(secondCounts.0, 1)
        XCTAssertEqual(secondCounts.1, 1)
    }

    func testStartFailureStopsSessionAndAllowsRetry() async throws {
        let provider = StubContentProvider()
        let failedSession = StubCaptureSession(shouldFailStart: true)
        let retrySession = StubCaptureSession()
        let engine = CaptureEngine(
            contentProvider: provider,
            sessionBuilder: StubSessionBuilder(sessions: [failedSession, retrySession]),
            processID: 200
        )

        do {
            try await engine.start(region: makeRegion(), settings: .default) { _ in }
            XCTFail("expected start to fail")
        } catch let error as CaptureError {
            guard case .streamFailure = error else {
                return XCTFail("unexpected capture error: \(error)")
            }
        }
        let failedStopCount = await failedSession.stopCount
        XCTAssertEqual(failedStopCount, 1)

        try await engine.start(region: makeRegion(), settings: .default) { _ in }
        await engine.stop()
        let retryStartCount = await retrySession.startCount
        XCTAssertEqual(retryStartCount, 1)
    }

    private func makeRegion() -> CaptureRegion {
        CaptureRegion(
            displayID: 42,
            globalRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            logicalPixelSize: CGSize(width: 100, height: 100),
            outputPixelSize: CGSize(width: 100, height: 100),
            backingScale: 1
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
