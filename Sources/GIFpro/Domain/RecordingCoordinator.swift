import CoreGraphics
import CoreMedia
import Foundation

enum RecordingStopReason: Equatable, Sendable {
    case manual
    case durationLimit
    case diskSpace
    case captureFailure
    case displayRemoved
    case termination
}

enum RecordingCompletionNotice: Equatable, Sendable {
    case displayRemoved
    case captureStopped
}

@MainActor protocol RecordingPermissionAuthorizing: AnyObject {
    func requestAccessIfNeeded() -> Bool
    func recheckAccess() -> Bool
}

@MainActor protocol RecordingSelectionPresenting: AnyObject {
    func show(
        settings: RecordingSettings,
        onSettingsChanged: @escaping (RecordingSettings) -> Void,
        onRecord: @escaping (CaptureRegion, RecordingSettings) -> Void,
        onCancel: @escaping () -> Void,
        onDisplayChange: @escaping (DisplayConfigurationChange) -> Void
    )
    func dismiss()
    func showCountdownVisual(value: Int, targetDisplayID: CGDirectDisplayID)
    func updateCountdown(value: Int)
    func showRecordingVisual(onStop: @escaping () -> Void)
    func updateRecordingStatus(elapsed: TimeInterval, remaining: TimeInterval, isWarning: Bool)
    func showStoppingVisual()
}

protocol RecordingCaptureControlling: Sendable {
    func start(
        region: CaptureRegion,
        settings: RecordingSettings,
        onFrame: @escaping @Sendable (CapturedFrame) async throws -> Void,
        onFailure: @escaping @Sendable (CaptureError) -> Void
    ) async throws
    func stop() async throws
}

protocol RecordingFrameProcessing: Sendable {
    func process(_ frame: CapturedFrame, targetPixelSize: CGSize) throws -> CGImage
}

protocol RecordingEncoding: AnyObject, Sendable {
    var temporaryFile: TemporaryFile { get }
    func append(image: CGImage, timestamp: TimeInterval) async throws
    func finish(at timestamp: TimeInterval) async throws -> TemporaryFile
}

@MainActor protocol RecordingEncoderFactory: AnyObject {
    func make(maximumFrames: Int) throws -> any RecordingEncoding
}

@MainActor protocol RecordingTemporaryFileManaging: AnyObject {
    func capacityPolicy() throws -> TemporaryFileStore.CapacityPolicy
    func validatedAccessURL(for file: TemporaryFile) throws -> URL
    func discard(_ file: TemporaryFile) throws
    func cleanupStaleFiles() throws
}

@MainActor protocol RecordingPreferencesManaging {
    func load() -> RecordingSettings
    func save(_ settings: RecordingSettings)
}

@MainActor protocol RecordingPreviewPresenting: AnyObject {
    func present(url: URL, notice: RecordingCompletionNotice?)
}

protocol RecordingClock: Sendable {
    func now() -> TimeInterval
    func sleep(for duration: TimeInterval) async throws
}

@MainActor
protocol RecordingStopRequestScheduling: AnyObject {
    func schedule(_ operation: @escaping @MainActor () async -> Void)
}

@MainActor
final class ImmediateStopRequestScheduler: RecordingStopRequestScheduling {
    func schedule(_ operation: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await operation() }
    }
}

struct SystemRecordingClock: RecordingClock {
    func now() -> TimeInterval {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(duration))
    }
}

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var countdownValue: Int?
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var isInFinalTenSeconds = false
    private(set) var stopReason: RecordingStopReason?

    var hasActiveOrUnsavedWork: Bool {
        switch state {
        case .idle, .failed, .savedPreview: return false
        default: return true
        }
    }

    var recordingCommandTitle: String {
        switch state {
        case .recording, .countingDown, .finalizing: return "停止录制"
        default: return "开始录制"
        }
    }

    private let permission: any RecordingPermissionAuthorizing
    private let selection: any RecordingSelectionPresenting
    private let capture: any RecordingCaptureControlling
    private let processor: any RecordingFrameProcessing
    private let encoderFactory: any RecordingEncoderFactory
    private let temporaryFiles: any RecordingTemporaryFileManaging
    private let preferences: any RecordingPreferencesManaging
    private let preview: any RecordingPreviewPresenting
    private let clock: any RecordingClock
    private let stopRequestScheduler: any RecordingStopRequestScheduling

    private var token = UUID()
    private var settings = RecordingSettings.default
    private var region: CaptureRegion?
    private var encoder: (any RecordingEncoding)?
    private var activeFile: TemporaryFile?
    private var countdownTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var diskTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var recordingStartTime: TimeInterval?
    private var lastPresentationTime: TimeInterval?
    private var completionNotice: RecordingCompletionNotice?
    private var forcedStopFailure: RecordingFailure?
    private var terminationTask: Task<Void, Never>?

    init(
        permission: any RecordingPermissionAuthorizing,
        selection: any RecordingSelectionPresenting,
        capture: any RecordingCaptureControlling,
        processor: any RecordingFrameProcessing,
        encoderFactory: any RecordingEncoderFactory,
        temporaryFiles: any RecordingTemporaryFileManaging,
        preferences: any RecordingPreferencesManaging,
        preview: any RecordingPreviewPresenting,
        clock: any RecordingClock = SystemRecordingClock(),
        stopRequestScheduler: (any RecordingStopRequestScheduling)? = nil
    ) {
        self.permission = permission
        self.selection = selection
        self.capture = capture
        self.processor = processor
        self.encoderFactory = encoderFactory
        self.temporaryFiles = temporaryFiles
        self.preferences = preferences
        self.preview = preview
        self.clock = clock
        self.stopRequestScheduler = stopRequestScheduler ?? ImmediateStopRequestScheduler()
    }

    func toggleRecording() async {
        switch state {
        case .idle, .failed:
            beginSelection()
        case .selecting, .countingDown, .recording:
            await stop(reason: .manual)
        case .previewReady, .awaitingSave:
            await discardUnsavedOutput()
            beginSelection()
        default:
            break
        }
    }

    func recheckPermission() -> Bool { permission.recheckAccess() }

    func cleanupStaleFiles() throws { try temporaryFiles.cleanupStaleFiles() }

    func stop(reason: RecordingStopReason) async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard state == .selecting || state == .countingDown || state == .recording else { return }
        stopReason = stopReason ?? reason
        let currentToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStop(token: currentToken)
        }
        stopTask = task
        await task.value
        if token == currentToken { stopTask = nil }
    }

    func prepareForTermination() async {
        if let terminationTask {
            await terminationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.state == .recording || self.state == .countingDown || self.state == .selecting {
                await self.stop(reason: .termination)
            }
            await self.discardUnsavedOutput()
        }
        terminationTask = task
        await task.value
    }

    private func beginSelection() {
        resetSession()
        transition(to: .requestingPermission)
        guard permission.requestAccessIfNeeded() else {
            transition(to: .failed(.permissionDenied))
            return
        }
        settings = preferences.load()
        transition(to: .selecting)
        let sessionToken = token
        selection.show(
            settings: settings,
            onSettingsChanged: { [weak self] value in
                guard let self, self.token == sessionToken else { return }
                self.settings = value
                self.preferences.save(value)
            },
            onRecord: { [weak self] region, settings in
                guard let self, self.token == sessionToken else { return }
                Task { @MainActor in await self.selectionConfirmed(region, settings: settings, token: sessionToken) }
            },
            onCancel: { [weak self] in
                guard let self, self.token == sessionToken else { return }
                Task { @MainActor in await self.stop(reason: .manual) }
            },
            onDisplayChange: { [weak self] change in
                guard let self, self.token == sessionToken else { return }
                self.displayChanged(change, token: sessionToken)
            }
        )
    }

    private func selectionConfirmed(
        _ region: CaptureRegion,
        settings: RecordingSettings,
        token sessionToken: UUID
    ) async {
        guard token == sessionToken, state == .selecting else { return }
        self.settings = settings
        preferences.save(settings)
        do {
            guard try temporaryFiles.capacityPolicy() == .canStart else {
                transition(to: .failed(.insufficientDiskSpace))
                selection.dismiss()
                return
            }
        } catch {
            transition(to: .failed(.capacityUnavailable))
            selection.dismiss()
            return
        }
        do {
            encoder = try encoderFactory.make(maximumFrames: settings.fps.rawValue * settings.duration.rawValue)
            activeFile = encoder?.temporaryFile
        } catch {
            transition(to: .failed(.encoderInitializationFailed))
            selection.dismiss()
            return
        }
        self.region = region
        countdownValue = 3
        transition(to: .countingDown)
        selection.showCountdownVisual(value: 3, targetDisplayID: region.displayID)
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for next in [2, 1, 0] {
                do { try await self.clock.sleep(for: 1) } catch { return }
                guard self.token == sessionToken, self.state == .countingDown else { return }
                self.countdownValue = next == 0 ? nil : next
                if next > 0 { self.selection.updateCountdown(value: next) }
            }
            await self.startCapture(token: sessionToken)
        }
    }

    private func startCapture(token sessionToken: UUID) async {
        guard token == sessionToken, state == .countingDown,
              let region, let encoder else { return }
        recordingStartTime = clock.now()
        transition(to: .recording)
        selection.showRecordingVisual { [weak self] in
            Task { @MainActor in
                guard let self, self.token == sessionToken else { return }
                await self.stop(reason: .manual)
            }
        }
        selection.updateRecordingStatus(
            elapsed: 0,
            remaining: TimeInterval(settings.duration.rawValue),
            isWarning: false
        )
        startRuntimeTasks(token: sessionToken)
        let outputSize = region.outputPixelSize
        let processor = processor
        do {
            try await capture.start(
                region: region,
                settings: settings,
                onFrame: { [weak self] frame in
                    do {
                        guard await self?.acceptsFrames(token: sessionToken, encoder: encoder) == true else {
                            return
                        }
                        let image = try processor.process(frame, targetPixelSize: outputSize)
                        let timestamp = CMTimeGetSeconds(frame.presentationTime)
                        guard timestamp.isFinite else { throw RecordingPipelineError.invalidTimestamp }
                        try await encoder.append(image: image, timestamp: timestamp)
                        await self?.acceptedFrame(timestamp: timestamp, token: sessionToken, encoder: encoder)
                    } catch {
                        let shouldRequestStop = await self?.recordForcedStopFailure(
                            .captureFailed,
                            token: sessionToken,
                            encoder: encoder
                        ) == true
                        if shouldRequestStop {
                            await self?.scheduleFailureStopRequest(
                                token: sessionToken,
                                encoder: encoder
                            )
                        }
                        throw error
                    }
                },
                onFailure: { [weak self] error in
                    Task { @MainActor in await self?.captureFailed(error, token: sessionToken) }
                }
            )
        } catch {
            guard token == sessionToken, self.encoder === encoder else { return }
            if state == .finalizing { return }
            cancelRuntimeTasks()
            discardActiveFile()
            transition(to: .failed(.captureFailed))
            selection.dismiss()
            return
        }
        guard token == sessionToken, state == .recording, self.encoder === encoder else { return }
    }

    private func acceptsFrames(token sessionToken: UUID, encoder sessionEncoder: any RecordingEncoding) -> Bool {
        token == sessionToken
            && self.encoder === sessionEncoder
            && (state == .recording || state == .finalizing)
    }

    private func acceptedFrame(
        timestamp: TimeInterval,
        token sessionToken: UUID,
        encoder sessionEncoder: any RecordingEncoding
    ) async {
        guard acceptsFrames(token: sessionToken, encoder: sessionEncoder) else { return }
        lastPresentationTime = timestamp
    }

    private func startRuntimeTasks(token sessionToken: UUID) {
        let duration = TimeInterval(settings.duration.rawValue)
        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.token == sessionToken, self.state == .recording {
                do { try await self.clock.sleep(for: 0.25) } catch { return }
                guard self.token == sessionToken, self.state == .recording else { return }
                guard let start = self.recordingStartTime else { return }
                self.elapsedSeconds = max(0, self.clock.now() - start)
                self.isInFinalTenSeconds = self.elapsedSeconds >= max(0, duration - 10)
                self.selection.updateRecordingStatus(
                    elapsed: self.elapsedSeconds,
                    remaining: max(0, duration - self.elapsedSeconds),
                    isWarning: self.isInFinalTenSeconds
                )
                if self.elapsedSeconds >= duration {
                    await self.stop(reason: .durationLimit)
                    return
                }
            }
        }
        diskTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.token == sessionToken, self.state == .recording {
                do { try await self.clock.sleep(for: 1) } catch { return }
                guard self.token == sessionToken, self.state == .recording else { return }
                do {
                    if try self.temporaryFiles.capacityPolicy() == .mustStop {
                        await self.stop(reason: .diskSpace)
                        return
                    }
                } catch {
                    await self.stopWithFailure(.capacityUnavailable, token: sessionToken)
                    return
                }
            }
        }
    }

    private func captureFailed(_ error: CaptureError, token sessionToken: UUID) async {
        guard token == sessionToken, state == .recording || state == .countingDown else { return }
        completionNotice = error == .displayRemoved ? .displayRemoved : .captureStopped
        await stop(reason: error == .displayRemoved ? .displayRemoved : .captureFailure)
    }

    private func displayChanged(_ change: DisplayConfigurationChange, token sessionToken: UUID) {
        guard token == sessionToken else { return }
        let hasChange = !change.added.isEmpty
            || !change.removed.isEmpty
            || !change.updated.isEmpty
        if state == .selecting, hasChange {
            Task { @MainActor [weak self] in await self?.stop(reason: .manual) }
            return
        }
        guard let displayID = region?.displayID else { return }
        if state == .countingDown,
           change.removed.contains(displayID) || change.updated.contains(displayID) {
            Task { @MainActor [weak self] in await self?.stop(reason: .displayRemoved) }
            return
        }
        guard state == .recording, change.removed.contains(displayID) else { return }
        completionNotice = .displayRemoved
        Task { @MainActor [weak self] in await self?.stop(reason: .displayRemoved) }
    }

    private func stopWithFailure(_ failure: RecordingFailure, token sessionToken: UUID) async {
        guard token == sessionToken else { return }
        forcedStopFailure = forcedStopFailure ?? failure
        stopReason = stopReason ?? .captureFailure
        if state == .finalizing { return }
        await stop(reason: .captureFailure)
    }

    private func recordForcedStopFailure(
        _ failure: RecordingFailure,
        token sessionToken: UUID,
        encoder sessionEncoder: any RecordingEncoding
    ) -> Bool {
        guard token == sessionToken,
              encoder === sessionEncoder,
              state == .recording || state == .finalizing else { return false }
        forcedStopFailure = forcedStopFailure ?? failure
        return state == .recording
    }

    private func scheduleFailureStopRequest(
        token sessionToken: UUID,
        encoder sessionEncoder: any RecordingEncoding
    ) {
        stopRequestScheduler.schedule { [weak self] in
            guard let self,
                  self.token == sessionToken,
                  self.encoder === sessionEncoder,
                  self.forcedStopFailure != nil,
                  self.state == .recording else { return }
            await self.stop(reason: .captureFailure)
        }
    }

    private func performStop(token sessionToken: UUID) async {
        guard token == sessionToken else { return }
        countdownTask?.cancel()
        switch state {
        case .selecting, .countingDown:
            transition(to: .cancelling)
            selection.dismiss()
            discardActiveFile()
            countdownValue = nil
            transition(to: .idle)
        case .recording:
            transition(to: .finalizing)
            selection.showStoppingVisual()
            do { try await capture.stop() } catch { }
            guard token == sessionToken else { return }
            if let forcedStopFailure {
                discardActiveFile()
                cancelRuntimeTasks()
                selection.dismiss()
                transition(to: .failed(forcedStopFailure))
                return
            }
            guard let encoder else {
                transition(to: .failed(.finalizationFailed))
                return
            }
            let finishTime = max(clock.now(), lastPresentationTime ?? -.infinity)
            do {
                let file = try await encoder.finish(at: finishTime)
                cancelRuntimeTasks()
                let url = try temporaryFiles.validatedAccessURL(for: file)
                self.encoder = nil
                transition(to: .previewReady(url))
                preview.present(url: url, notice: completionNotice)
                selection.dismiss()
            } catch {
                discardActiveFile()
                cancelRuntimeTasks()
                selection.dismiss()
                transition(to: .failed(.finalizationFailed))
            }
        default:
            break
        }
    }

    private func discardUnsavedOutput() async {
        switch state {
        case .previewReady, .awaitingSave:
            transition(to: .discarding)
            discardActiveFile()
            transition(to: .idle)
        case .failed:
            transition(to: .idle)
        default:
            break
        }
    }

    private func discardActiveFile() {
        if let file = activeFile { try? temporaryFiles.discard(file) }
        activeFile = nil
        encoder = nil
    }

    private func cancelRuntimeTasks() {
        timerTask?.cancel(); timerTask = nil
        diskTask?.cancel(); diskTask = nil
    }

    private func resetSession() {
        token = UUID()
        stopReason = nil
        countdownValue = nil
        elapsedSeconds = 0
        isInFinalTenSeconds = false
        region = nil
        encoder = nil
        activeFile = nil
        completionNotice = nil
        forcedStopFailure = nil
        recordingStartTime = nil
        lastPresentationTime = nil
        countdownTask?.cancel()
        cancelRuntimeTasks()
        stopTask = nil
        terminationTask = nil
    }

    private func transition(to next: RecordingState) {
        guard state.canTransition(to: next) else {
            assertionFailure("Illegal recording transition: \(state) -> \(next)")
            return
        }
        state = next
    }
}

private enum RecordingPipelineError: Error { case invalidTimestamp }
