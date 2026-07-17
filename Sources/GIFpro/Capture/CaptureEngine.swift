import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

enum CaptureError: Error, Equatable, Sendable {
    case displayUnavailable(displayID: CGDirectDisplayID)
    case selfApplicationUnavailable(processID: pid_t)
    case alreadyRunning
    case startCancelled
    case displayRemoved
    case shareableContentFailure(message: String)
    case streamFailure(code: Int, message: String)

    static func wrapping(_ error: Error) -> CaptureError {
        if let captureError = error as? CaptureError {
            return captureError
        }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == -3821 {
            return .displayRemoved
        }
        return .streamFailure(code: nsError.code, message: nsError.localizedDescription)
    }
}

struct ShareableDisplay: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    fileprivate let screenCaptureDisplay: SCDisplay?
}

struct ShareableApplication: @unchecked Sendable {
    let processID: pid_t
    fileprivate let screenCaptureApplication: SCRunningApplication?
}

struct ShareableContentSnapshot: Sendable {
    let displays: [ShareableDisplay]
    let applications: [ShareableApplication]

    static func testing(
        displayIDs: [CGDirectDisplayID],
        processIDs: [pid_t]
    ) -> ShareableContentSnapshot {
        ShareableContentSnapshot(
            displays: displayIDs.map {
                ShareableDisplay(displayID: $0, screenCaptureDisplay: nil)
            },
            applications: processIDs.map {
                ShareableApplication(processID: $0, screenCaptureApplication: nil)
            }
        )
    }
}

struct SelectedShareableContent: Sendable {
    let display: ShareableDisplay
    let application: ShareableApplication
}

enum ShareableContentSelector {
    static func select(
        from snapshot: ShareableContentSnapshot,
        displayID: CGDirectDisplayID,
        processID: pid_t
    ) throws -> SelectedShareableContent {
        guard let display = snapshot.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable(displayID: displayID)
        }
        guard let application = snapshot.applications.first(where: { $0.processID == processID }) else {
            throw CaptureError.selfApplicationUnavailable(processID: processID)
        }
        return SelectedShareableContent(display: display, application: application)
    }
}

protocol ShareableContentProviding: Sendable {
    func latestSnapshot() async throws -> ShareableContentSnapshot
}

struct ScreenCaptureShareableContentProvider: ShareableContentProviding {
    func latestSnapshot() async throws -> ShareableContentSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return ShareableContentSnapshot(
            displays: content.displays.map {
                ShareableDisplay(displayID: $0.displayID, screenCaptureDisplay: $0)
            },
            applications: content.applications.map {
                ShareableApplication(processID: $0.processID, screenCaptureApplication: $0)
            }
        )
    }
}

final class FrameDelivery: @unchecked Sendable {
    typealias Consumer = @Sendable (CapturedFrame) async throws -> Void

    private let backpressure: FrameBackpressure
    private let consumer: Consumer
    private let lock = NSLock()
    private var isAccepting = true

    init(capacity: Int = 2, consumer: @escaping Consumer) {
        backpressure = FrameBackpressure(capacity: capacity)
        self.consumer = consumer
    }

    var snapshot: FrameBackpressure.Snapshot {
        backpressure.snapshot
    }

    @discardableResult
    func offer(_ frame: CapturedFrame) -> Bool {
        lock.lock()
        guard isAccepting, backpressure.tryAcquire() else {
            lock.unlock()
            return false
        }
        lock.unlock()

        Task {
            defer { backpressure.release() }
            _ = try? await consumer(frame)
        }
        return true
    }

    func stopAccepting() {
        lock.lock()
        isAccepting = false
        lock.unlock()
    }

    func waitUntilDrained() async {
        await backpressure.waitUntilDrained()
    }
}

enum CapturedFrameExtractor {
    static func extract(
        from sampleBuffer: CMSampleBuffer,
        type: SCStreamOutputType
    ) -> CapturedFrame? {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              frameStatus(of: sampleBuffer) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return nil
        }

        return CapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        let key = SCStreamFrameInfo.status.rawValue as CFString
        if let value = CMGetAttachment(sampleBuffer, key: key, attachmentModeOut: nil) {
            return status(from: value)
        }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawValue = attachments.first?[.status]
        else {
            return nil
        }
        return status(from: rawValue)
    }

    private static func status(from value: Any) -> SCFrameStatus? {
        if let number = value as? NSNumber {
            return SCFrameStatus(rawValue: number.intValue)
        }
        if let integer = value as? Int {
            return SCFrameStatus(rawValue: integer)
        }
        return nil
    }
}

protocol CaptureSession: Sendable {
    func start() async throws
    func stop() async throws
}

protocol CaptureSessionBuilding: Sendable {
    func build(
        selection: SelectedShareableContent,
        configuration: SCStreamConfiguration,
        delivery: FrameDelivery,
        onFailure: @escaping @Sendable (CaptureError) -> Void
    ) throws -> any CaptureSession
}

actor CaptureEngine {
    typealias FrameConsumer = @Sendable (CapturedFrame) async throws -> Void
    typealias FailureHandler = @Sendable (CaptureError) -> Void

    private final class StartingContext: @unchecked Sendable {
        let id = UUID()
        var isCancelled = false
        var session: (any CaptureSession)?
        var delivery: FrameDelivery?
        var cleanupTask: Task<Void, Never>?
        var completionWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private final class RunningContext: @unchecked Sendable {
        let id: UUID
        let session: any CaptureSession
        let delivery: FrameDelivery

        init(id: UUID, session: any CaptureSession, delivery: FrameDelivery) {
            self.id = id
            self.session = session
            self.delivery = delivery
        }
    }

    private final class StoppingContext: @unchecked Sendable {
        let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }
    }

    private enum Lifecycle {
        case idle
        case starting(StartingContext)
        case running(RunningContext)
        case stopping(StoppingContext)
    }

    private let contentProvider: any ShareableContentProviding
    private let sessionBuilder: any CaptureSessionBuilding
    private let processID: pid_t
    private let onFailure: FailureHandler
    private var lifecycle = Lifecycle.idle

    init(
        contentProvider: any ShareableContentProviding = ScreenCaptureShareableContentProvider(),
        sessionBuilder: any CaptureSessionBuilding = ScreenCaptureSessionBuilder(),
        processID: pid_t = ProcessInfo.processInfo.processIdentifier,
        onFailure: @escaping FailureHandler = { _ in }
    ) {
        self.contentProvider = contentProvider
        self.sessionBuilder = sessionBuilder
        self.processID = processID
        self.onFailure = onFailure
    }

    func start(
        region: CaptureRegion,
        settings: RecordingSettings,
        onFrame: @escaping FrameConsumer
    ) async throws {
        guard case .idle = lifecycle else {
            throw CaptureError.alreadyRunning
        }
        let context = StartingContext()
        lifecycle = .starting(context)

        do {
            let snapshot: ShareableContentSnapshot
            do {
                snapshot = try await contentProvider.latestSnapshot()
            } catch {
                throw CaptureError.shareableContentFailure(message: error.localizedDescription)
            }
            try ensureStartIsActive(context)
            let selection = try ShareableContentSelector.select(
                from: snapshot,
                displayID: region.displayID,
                processID: processID
            )
            try ensureStartIsActive(context)

            let nextDelivery = FrameDelivery(capacity: 2, consumer: onFrame)
            context.delivery = nextDelivery
            let token = context.id
            let nextSession: any CaptureSession
            do {
                nextSession = try sessionBuilder.build(
                    selection: selection,
                    configuration: CaptureConfiguration.makeStreamConfiguration(
                        region: region,
                        settings: settings
                    ),
                    delivery: nextDelivery,
                    onFailure: { [weak self] error in
                        Task {
                            await self?.handleUnexpectedTermination(error, token: token)
                        }
                    }
                )
            } catch {
                throw CaptureError.wrapping(error)
            }
            context.session = nextSession
            try ensureStartIsActive(context)
            try await nextSession.start()
            try ensureStartIsActive(context)

            lifecycle = .running(
                RunningContext(id: context.id, session: nextSession, delivery: nextDelivery)
            )
            finishStarting(context)
        } catch {
            let captureError: CaptureError
            if context.isCancelled {
                captureError = .startCancelled
            } else {
                captureError = CaptureError.wrapping(error)
            }
            context.delivery?.stopAccepting()
            let cleanupTask = startCleanupTask(for: context)
            await cleanupTask.value
            if case .starting(let current) = lifecycle, current === context {
                lifecycle = .idle
            }
            finishStarting(context)
            throw captureError
        }
    }

    func stop() async {
        switch lifecycle {
        case .idle:
            return

        case .starting(let context):
            context.isCancelled = true
            context.delivery?.stopAccepting()
            _ = startCleanupTask(for: context)
            await withCheckedContinuation { continuation in
                context.completionWaiters.append(continuation)
            }

        case .running(let context):
            context.delivery.stopAccepting()
            let task = Task {
                try? await context.session.stop()
                await context.delivery.waitUntilDrained()
            }
            let stopping = StoppingContext(task: task)
            lifecycle = .stopping(stopping)
            await task.value
            if case .stopping(let current) = lifecycle, current === stopping {
                lifecycle = .idle
            }

        case .stopping(let context):
            await context.task.value
        }
    }

    private func ensureStartIsActive(_ context: StartingContext) throws {
        guard !context.isCancelled,
              case .starting(let current) = lifecycle,
              current === context
        else {
            throw CaptureError.startCancelled
        }
    }

    private func startCleanupTask(for context: StartingContext) -> Task<Void, Never> {
        if let cleanupTask = context.cleanupTask {
            return cleanupTask
        }
        let session = context.session
        let delivery = context.delivery
        let task = Task {
            if let session {
                try? await session.stop()
            }
            await delivery?.waitUntilDrained()
        }
        context.cleanupTask = task
        return task
    }

    private func finishStarting(_ context: StartingContext) {
        let waiters = context.completionWaiters
        context.completionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func handleUnexpectedTermination(_ error: CaptureError, token: UUID) async {
        guard case .running(let context) = lifecycle, context.id == token else {
            return
        }
        context.delivery.stopAccepting()
        let task = Task {
            try? await context.session.stop()
            await context.delivery.waitUntilDrained()
        }
        let stopping = StoppingContext(task: task)
        lifecycle = .stopping(stopping)
        await task.value
        guard case .stopping(let current) = lifecycle, current === stopping else {
            return
        }
        lifecycle = .idle
        onFailure(error)
    }
}

struct ScreenCaptureSessionBuilder: CaptureSessionBuilding {
    func build(
        selection: SelectedShareableContent,
        configuration: SCStreamConfiguration,
        delivery: FrameDelivery,
        onFailure: @escaping @Sendable (CaptureError) -> Void
    ) throws -> any CaptureSession {
        guard let display = selection.display.screenCaptureDisplay else {
            throw CaptureError.displayUnavailable(displayID: selection.display.displayID)
        }
        guard let application = selection.application.screenCaptureApplication else {
            throw CaptureError.selfApplicationUnavailable(processID: selection.application.processID)
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [application],
            exceptingWindows: []
        )
        return try ScreenCaptureSession(
            filter: filter,
            configuration: configuration,
            delivery: delivery,
            onFailure: onFailure
        )
    }
}

private final class ScreenCaptureSession: CaptureSession, @unchecked Sendable {
    private let stream: SCStream
    private let output: ScreenStreamOutput
    private let delegate: ScreenStreamDelegate

    init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        delivery: FrameDelivery,
        onFailure: @escaping @Sendable (CaptureError) -> Void
    ) throws {
        let delegate = ScreenStreamDelegate(onFailure: onFailure)
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: delegate
        )
        let output = ScreenStreamOutput(delivery: delivery)
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(
                label: "com.gifpro.capture.frames",
                qos: .userInitiated
            )
        )
        self.stream = stream
        self.output = output
        self.delegate = delegate
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async throws {
        delegate.markIntentionalStop()
        var stopError: Error?
        do {
            try await stream.stopCapture()
        } catch {
            stopError = error
        }
        try? stream.removeStreamOutput(output, type: .screen)
        if let stopError {
            throw stopError
        }
    }
}

private final class ScreenStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let delivery: FrameDelivery

    init(delivery: FrameDelivery) {
        self.delivery = delivery
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        _ = stream
        guard let frame = CapturedFrameExtractor.extract(from: sampleBuffer, type: outputType) else {
            return
        }
        delivery.offer(frame)
    }
}

private final class ScreenStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var isIntentionalStop = false
    private let onFailure: @Sendable (CaptureError) -> Void

    init(onFailure: @escaping @Sendable (CaptureError) -> Void) {
        self.onFailure = onFailure
    }

    func markIntentionalStop() {
        lock.lock()
        isIntentionalStop = true
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        _ = stream
        lock.lock()
        let shouldReport = !isIntentionalStop
        lock.unlock()
        if shouldReport {
            onFailure(CaptureError.wrapping(error))
        }
    }
}

enum CaptureConfiguration {
    static func makeStreamConfiguration(
        region: CaptureRegion,
        settings: RecordingSettings
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.sourceRect
        configuration.width = Int(region.outputPixelSize.width)
        configuration.height = Int(region.outputPixelSize.height)
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(settings.fps.rawValue)
        )
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = settings.showsCursor
        configuration.capturesAudio = false
        return configuration
    }
}
