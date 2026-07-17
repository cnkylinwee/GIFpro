import CoreMedia
import CoreVideo
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

private actor SuspendedContentProvider: ShareableContentProviding {
    private var continuation: CheckedContinuation<ShareableContentSnapshot, Error>?
    private(set) var firstRequestIsPending = false
    private var callCount = 0

    func latestSnapshot() async throws -> ShareableContentSnapshot {
        callCount += 1
        if callCount > 1 {
            return .testing(displayIDs: [42], processIDs: [200])
        }
        firstRequestIsPending = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func releaseFirstRequest() {
        continuation?.resume(returning: .testing(displayIDs: [42], processIDs: [200]))
        continuation = nil
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

private final class ThrowingSessionBuilder: CaptureSessionBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDelivery: FrameDelivery?

    var delivery: FrameDelivery? {
        lock.lock()
        defer { lock.unlock() }
        return storedDelivery
    }

    func build(
        selection: SelectedShareableContent,
        configuration: SCStreamConfiguration,
        delivery: FrameDelivery,
        onFailure: @escaping @Sendable (CaptureError) -> Void
    ) throws -> any CaptureSession {
        _ = selection
        _ = configuration
        _ = onFailure
        lock.lock()
        storedDelivery = delivery
        lock.unlock()
        throw NSError(
            domain: "CaptureSetup",
            code: 73,
            userInfo: [NSLocalizedDescriptionKey: "add output failed"]
        )
    }
}

private final class TerminatingSessionBuilder: CaptureSessionBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [any CaptureSession]
    private var latestDelivery: FrameDelivery?
    private var latestFailure: (@Sendable (CaptureError) -> Void)?

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
        lock.lock()
        defer { lock.unlock() }
        latestDelivery = delivery
        latestFailure = onFailure
        return sessions.removeFirst()
    }

    func offer(_ frame: CapturedFrame) -> Bool {
        lock.lock()
        let delivery = latestDelivery
        lock.unlock()
        return delivery?.offer(frame) ?? false
    }

    func terminate(with error: CaptureError) {
        lock.lock()
        let failure = latestFailure
        lock.unlock()
        failure?(error)
    }
}

private actor AutoTerminatingSession: CaptureSession {
    private let onFailure: @Sendable (CaptureError) -> Void
    private(set) var stopCount = 0

    init(onFailure: @escaping @Sendable (CaptureError) -> Void) {
        self.onFailure = onFailure
    }

    func start() async throws {
        onFailure(.displayRemoved)
        onFailure(.displayRemoved)
    }

    func stop() async throws {
        stopCount += 1
    }
}

private final class AutoTerminatingSessionBuilder: CaptureSessionBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private let retrySession: any CaptureSession
    private var buildCount = 0
    private var storedDelivery: FrameDelivery?
    private var storedSession: AutoTerminatingSession?

    init(retrySession: any CaptureSession) {
        self.retrySession = retrySession
    }

    var firstDelivery: FrameDelivery? {
        lock.lock()
        defer { lock.unlock() }
        return storedDelivery
    }

    var firstSession: AutoTerminatingSession? {
        lock.lock()
        defer { lock.unlock() }
        return storedSession
    }

    func build(
        selection: SelectedShareableContent,
        configuration: SCStreamConfiguration,
        delivery: FrameDelivery,
        onFailure: @escaping @Sendable (CaptureError) -> Void
    ) throws -> any CaptureSession {
        _ = selection
        _ = configuration
        lock.lock()
        defer { lock.unlock() }
        buildCount += 1
        guard buildCount == 1 else { return retrySession }
        let session = AutoTerminatingSession(onFailure: onFailure)
        storedDelivery = delivery
        storedSession = session
        return session
    }
}

private actor SuspendedStartSession: CaptureSession {
    enum PrematureStop: Error { case startIsPending }

    private let onFailure: @Sendable (CaptureError) -> Void
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var startIsPending = false
    private(set) var prematureStopCount = 0
    private(set) var stopCount = 0
    private(set) var events: [String] = []

    init(onFailure: @escaping @Sendable (CaptureError) -> Void) {
        self.onFailure = onFailure
    }

    func start() async throws {
        startIsPending = true
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        startIsPending = false
        events.append("start settled")
    }

    func stop() async throws {
        guard !startIsPending else {
            prematureStopCount += 1
            throw PrematureStop.startIsPending
        }
        stopCount += 1
        events.append("stop capture")
        events.append("remove output")
    }

    func terminateTwice() {
        onFailure(.displayRemoved)
        onFailure(.displayRemoved)
    }

    func finishStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
}

private final class SuspendedStartSessionBuilder: CaptureSessionBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private let retrySession: any CaptureSession
    private var buildCount = 0
    private var storedSession: SuspendedStartSession?

    init(retrySession: any CaptureSession) {
        self.retrySession = retrySession
    }

    var firstSession: SuspendedStartSession? {
        lock.lock()
        defer { lock.unlock() }
        return storedSession
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
        lock.lock()
        defer { lock.unlock() }
        buildCount += 1
        guard buildCount == 1 else { return retrySession }
        let session = SuspendedStartSession(onFailure: onFailure)
        storedSession = session
        return session
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

private actor TerminationProbe {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var startedCount = 0

    func consume(_ frame: CapturedFrame) async throws {
        _ = frame
        startedCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FailureProbe {
    private(set) var errors: [CaptureError] = []
    func record(_ error: CaptureError) { errors.append(error) }
}

final class CaptureEngineLifecycleTests: XCTestCase {
    func testDelegateTerminationBeforeStartReturnsPreventsRunningAndSurfacesThroughStart() async throws {
        let retrySession = StubCaptureSession()
        let builder = AutoTerminatingSessionBuilder(retrySession: retrySession)
        let failures = FailureProbe()
        let engine = CaptureEngine(
            contentProvider: StubContentProvider(),
            sessionBuilder: builder,
            processID: 200,
            onFailure: { error in Task { await failures.record(error) } }
        )

        var surfacedError: CaptureError?
        do {
            try await engine.start(region: makeRegion(), settings: .default) { _ in }
        } catch {
            surfacedError = error as? CaptureError
        }
        if surfacedError == nil { await engine.stop() }

        XCTAssertEqual(surfacedError, .displayRemoved)
        let firstSession = try XCTUnwrap(builder.firstSession)
        let firstStopCount = await firstSession.stopCount
        XCTAssertEqual(firstStopCount, 1)
        XCTAssertFalse(try XCTUnwrap(builder.firstDelivery).offer(try makeFrame()))
        for _ in 0 ..< 20 { await Task.yield() }
        let externalFailures = await failures.errors
        XCTAssertTrue(externalFailures.isEmpty)

        try await engine.start(region: makeRegion(), settings: .default) { _ in }
        await engine.stop()
    }

    func testStopWinsWhenDelegateTerminationArrivesAfterStartCancellation() async throws {
        let retrySession = StubCaptureSession()
        let builder = SuspendedStartSessionBuilder(retrySession: retrySession)
        let failures = FailureProbe()
        let engine = CaptureEngine(
            contentProvider: StubContentProvider(),
            sessionBuilder: builder,
            processID: 200,
            onFailure: { error in Task { await failures.record(error) } }
        )
        let region = makeRegion()
        let start = Task { () -> CaptureError? in
            do {
                try await engine.start(region: region, settings: .default) { _ in }
                return nil
            } catch {
                return error as? CaptureError
            }
        }
        await waitUntil { await builder.firstSession?.startIsPending == true }
        let session = try XCTUnwrap(builder.firstSession)
        let stop = Task { await engine.stop() }
        for _ in 0 ..< 20 { await Task.yield() }
        let prematureStops = await session.prematureStopCount
        XCTAssertEqual(prematureStops, 0)

        await session.terminateTwice()
        await session.finishStart()
        let surfacedError = await start.value
        await stop.value

        XCTAssertEqual(surfacedError, .startCancelled)
        for _ in 0 ..< 20 { await Task.yield() }
        let externalFailures = await failures.errors
        XCTAssertTrue(externalFailures.isEmpty)
        let stopCount = await session.stopCount
        XCTAssertEqual(stopCount, 1)
        let events = await session.events
        XCTAssertEqual(events, ["start settled", "stop capture", "remove output"])

        try await engine.start(region: region, settings: .default) { _ in }
        await engine.stop()
    }

    func testStopDuringShareableContentLookupCancelsStartAndAllowsRetry() async throws {
        let provider = SuspendedContentProvider()
        let firstSession = StubCaptureSession()
        let retrySession = StubCaptureSession()
        let engine = CaptureEngine(
            contentProvider: provider,
            sessionBuilder: StubSessionBuilder(sessions: [firstSession, retrySession]),
            processID: 200
        )
        let region = makeRegion()

        let start = Task { () -> CaptureError? in
            do {
                try await engine.start(region: region, settings: .default) { _ in }
                return nil
            } catch {
                return error as? CaptureError
            }
        }
        await waitUntil { await provider.firstRequestIsPending }
        let stopCompletion = CompletionProbe()
        let stop = Task {
            await engine.stop()
            await stopCompletion.complete()
        }
        for _ in 0 ..< 20 { await Task.yield() }
        let stopCompletedWhileStartWasPending = await stopCompletion.isComplete
        XCTAssertFalse(stopCompletedWhileStartWasPending)

        await provider.releaseFirstRequest()
        let startError = await start.value
        await stop.value
        XCTAssertEqual(startError, .startCancelled)
        let firstStartCount = await firstSession.startCount
        XCTAssertEqual(firstStartCount, 0)

        try await engine.start(region: region, settings: .default) { _ in }
        await engine.stop()
    }

    func testBuilderFailureIsWrappedAndDeliveryIsClosed() async throws {
        let builder = ThrowingSessionBuilder()
        let engine = CaptureEngine(
            contentProvider: StubContentProvider(),
            sessionBuilder: builder,
            processID: 200
        )

        do {
            try await engine.start(region: makeRegion(), settings: .default) { _ in }
            XCTFail("expected setup failure")
        } catch let error as CaptureError {
            XCTAssertEqual(
                error,
                .streamFailure(code: 73, message: "add output failed")
            )
        }

        let delivery = try XCTUnwrap(builder.delivery)
        XCTAssertFalse(delivery.offer(try makeFrame()))
    }

    func testUnexpectedTerminationStopsDeliveryDrainsAndReturnsToIdle() async throws {
        let firstSession = StubCaptureSession()
        let retrySession = StubCaptureSession()
        let builder = TerminatingSessionBuilder(sessions: [firstSession, retrySession])
        let consumer = TerminationProbe()
        let failures = FailureProbe()
        let engine = CaptureEngine(
            contentProvider: StubContentProvider(),
            sessionBuilder: builder,
            processID: 200,
            onFailure: { error in
                Task { await failures.record(error) }
            }
        )
        try await engine.start(region: makeRegion(), settings: .default) { frame in
            try await consumer.consume(frame)
        }
        let frame = try makeFrame()
        XCTAssertTrue(builder.offer(frame))
        await waitUntil { await consumer.startedCount == 1 }

        builder.terminate(with: .displayRemoved)
        builder.terminate(with: .displayRemoved)
        await waitUntil { await firstSession.stopCount == 1 }
        XCTAssertFalse(builder.offer(frame))
        let failuresBeforeDrain = await failures.errors
        XCTAssertTrue(failuresBeforeDrain.isEmpty)

        await consumer.release()
        await waitUntil { await failures.errors.count == 1 }
        let reportedFailures = await failures.errors
        XCTAssertEqual(reportedFailures, [.displayRemoved])
        let firstStopCount = await firstSession.stopCount
        XCTAssertEqual(firstStopCount, 1)

        try await engine.start(region: makeRegion(), settings: .default) { _ in }
        await engine.stop()
    }

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

    private func makeFrame() throws -> CapturedFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        return CapturedFrame(
            pixelBuffer: try XCTUnwrap(pixelBuffer),
            presentationTime: .zero
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
