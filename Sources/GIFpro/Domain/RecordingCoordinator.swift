import Darwin
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

enum RecordingAppendDisposition: Equatable, Sendable {
    case accepted
    case capacityReached
}

protocol RecordingEncoding: AnyObject, Sendable {
    var temporaryFile: TemporaryFile { get }
    func append(image: CGImage, timestamp: TimeInterval) async throws -> RecordingAppendDisposition
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
    func present(
        file: TemporaryFile,
        metadata: GIFPreviewMetadata,
        notice: RecordingCompletionNotice?,
        actions: SaveAndPreviewActions
    ) throws
    func dismiss()
    func retrySave()
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
    @Published private(set) var saveWarnings: [TemporaryFileStore.SaveWarning] = []
    @Published private(set) var lastUserFacingFailure: RecordingFailure?
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
    private var frozenRecordingDuration: TimeInterval?
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

    func performRecoveryAction(_ action: MenuBarRecoveryAction) {
        switch action {
        case .recheckPermission:
            guard permission.recheckAccess() else { return }
            beginSelection()
        case .rerecord:
            beginSelection()
        case .saveAgain:
            preview.retrySave()
        }
    }

    func cleanupStaleFiles() throws { try temporaryFiles.cleanupStaleFiles() }

    func stop(reason: RecordingStopReason) async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard state == .selecting || state == .countingDown || state == .recording else { return }
        if state == .recording,
           frozenRecordingDuration == nil,
           let recordingStartTime {
            frozenRecordingDuration = max(0, clock.now() - recordingStartTime)
        }
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
            if let stopTask = self.stopTask {
                await stopTask.value
            }
            if self.state == .recording || self.state == .countingDown || self.state == .selecting {
                await self.stop(reason: .termination)
            }
            if let stopTask = self.stopTask {
                await stopTask.value
            }
            await self.discardUnsavedOutput()
        }
        terminationTask = task
        await task.value
    }

    private func beginSelection() {
        resetSession()
        saveWarnings = []
        lastUserFacingFailure = nil
        transition(to: .requestingPermission)
        guard permission.requestAccessIfNeeded() else {
            transition(to: .failed(.permissionDenied))
            return
        }
        settings = preferences.load()
        transition(to: .selecting)
        showSelection(for: token)
    }

    private func showSelection(for sessionToken: UUID) {
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
                        let disposition = try await encoder.append(image: image, timestamp: timestamp)
                        switch disposition {
                        case .accepted:
                            await self?.acceptedFrame(timestamp: timestamp, token: sessionToken, encoder: encoder)
                        case .capacityReached:
                            await self?.capacityReached(token: sessionToken, encoder: encoder)
                        }
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

    private func capacityReached(
        token sessionToken: UUID,
        encoder sessionEncoder: any RecordingEncoding
    ) {
        guard token == sessionToken,
              encoder === sessionEncoder,
              state == .recording,
              stopReason == nil else { return }
        stopReason = .durationLimit
        frozenRecordingDuration = TimeInterval(settings.duration.rawValue)
        stopRequestScheduler.schedule { [weak self] in
            guard let self,
                  self.token == sessionToken,
                  self.encoder === sessionEncoder,
                  self.state == .recording,
                  self.stopReason == .durationLimit else { return }
            await self.stop(reason: .durationLimit)
        }
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
                self.encoder = nil
                let identityURL = previewIdentityURL(for: file)
                let pixelSize = region?.outputPixelSize ?? .zero
                let actualDuration = frozenRecordingDuration ?? elapsedSeconds
                let metadata = GIFPreviewMetadata(
                    pixelWidth: Int(pixelSize.width.rounded()),
                    pixelHeight: Int(pixelSize.height.rounded()),
                    duration: actualDuration,
                    fileSize: temporaryFileSize(file)
                )
                transition(to: .previewReady(identityURL))
                try preview.present(
                    file: file,
                    metadata: metadata,
                    notice: completionNotice,
                    actions: previewActions(
                        token: sessionToken,
                        file: file,
                        identityURL: identityURL
                    )
                )
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
            preview.dismiss()
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
        lastUserFacingFailure = nil
        recordingStartTime = nil
        frozenRecordingDuration = nil
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
        if case .failed(let failure) = next {
            lastUserFacingFailure = failure
        }
    }

    private func previewActions(
        token sessionToken: UUID,
        file sessionFile: TemporaryFile,
        identityURL: URL
    ) -> SaveAndPreviewActions {
        SaveAndPreviewActions(
            saveBegan: { [weak self] in
                guard let self,
                      self.token == sessionToken,
                      self.activeFile === sessionFile,
                      self.state == .previewReady(identityURL) else { return }
                self.transition(to: .awaitingSave(identityURL))
            },
            saveCancelled: { [weak self] in
                self?.returnToPreview(
                    token: sessionToken,
                    file: sessionFile,
                    identityURL: identityURL
                )
            },
            saveFailed: { [weak self] _ in
                guard let self else { return }
                self.returnToPreview(
                    token: sessionToken,
                    file: sessionFile,
                    identityURL: identityURL
                )
                self.lastUserFacingFailure = .saveFailed
            },
            saveWarning: { [weak self] warning in
                guard let self,
                      self.token == sessionToken,
                      self.activeFile === sessionFile else { return }
                self.saveWarnings.append(warning)
            },
            saved: { [weak self] destinationURL in
                guard let self,
                      self.token == sessionToken,
                      self.activeFile === sessionFile,
                      self.state == .awaitingSave(identityURL) else { return }
                self.activeFile = nil
                self.transition(to: .savedPreview(destinationURL))
                self.transition(to: .idle)
                self.resetSession()
            },
            rerecord: { [weak self] in
                guard let self,
                      self.token == sessionToken,
                      self.activeFile === sessionFile,
                      self.state == .previewReady(identityURL) else { return }
                self.activeFile = nil
                self.beginSelectionFromPreview()
            },
            discarded: { [weak self] in
                guard let self,
                      self.token == sessionToken,
                      self.activeFile === sessionFile,
                      self.state == .previewReady(identityURL) else { return }
                self.activeFile = nil
                self.transition(to: .discarding)
                self.transition(to: .idle)
                self.resetSession()
            }
        )
    }

    private func returnToPreview(token sessionToken: UUID, file: TemporaryFile, identityURL: URL) {
        guard token == sessionToken,
              activeFile === file,
              state == .awaitingSave(identityURL) else { return }
        transition(to: .previewReady(identityURL))
    }

    private func beginSelectionFromPreview() {
        guard permission.requestAccessIfNeeded() else {
            transition(to: .failed(.permissionDenied))
            return
        }
        resetSession()
        saveWarnings = []
        settings = preferences.load()
        transition(to: .selecting)
        showSelection(for: token)
    }

    private func previewIdentityURL(for file: TemporaryFile) -> URL {
        URL(string: "gifpro-temp://\(file.name)")!
    }

    private func temporaryFileSize(_ file: TemporaryFile) -> Int64 {
        file.withFileDescriptor { descriptor in
            var status = stat()
            return fstat(descriptor, &status) == 0 ? Int64(status.st_size) : 0
        }
    }
}

private enum RecordingPipelineError: Error { case invalidTimestamp }
