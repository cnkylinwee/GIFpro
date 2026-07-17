import CoreGraphics
import CoreMedia
import XCTest
@testable import GIFpro

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func testDeniedPermissionDoesNotShowSelection() async {
        let harness = try! Harness(permission: false)
        await harness.coordinator.toggleRecording()

        XCTAssertEqual(harness.coordinator.state, .failed(.permissionDenied))
        XCTAssertEqual(harness.selection.showCount, 0)
    }

    func testLoadsPreferencesBeforeShowingSelectionAndSavesChanges() async {
        let saved = RecordingSettings(scale: .two, fps: .fifteen, duration: .sixty, showsCursor: false)
        let harness = try! Harness(settings: saved)
        await harness.coordinator.toggleRecording()

        XCTAssertEqual(harness.selection.shownSettings, [saved])
        let changed = RecordingSettings(scale: .one, fps: .eight, duration: .fifteen, showsCursor: true)
        harness.selection.changeSettings(changed)
        XCTAssertEqual(harness.preferences.saved, [changed])
        harness.selection.cancel()
        await eventually { harness.coordinator.state == .idle }
        await harness.coordinator.toggleRecording()
        XCTAssertEqual(harness.selection.shownSettings.last, changed)
    }

    func testInsufficientStartCapacityDoesNotCreateEncoderOrCountdown() async {
        let harness = try! Harness(capacity: .continue)
        await harness.beginSelectionAndRecord()

        XCTAssertEqual(harness.encoderFactory.makeCount, 0)
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.coordinator.state, .failed(.insufficientDiskSpace))
    }

    func testEncoderInitializationFailureIsRetryableAndCaptureDoesNotStart() async {
        let harness = try! Harness(encoderFailure: true)
        await harness.beginSelectionAndRecord()

        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.coordinator.state, .failed(.encoderInitializationFailed))
    }

    func testCountdownRunsThreeTwoOneBeforeCaptureStarts() async {
        let harness = try! Harness()
        await harness.beginSelectionAndRecord()
        XCTAssertEqual(harness.coordinator.countdownValue, 3)

        await eventually { harness.clock.pendingSleepCount == 1 }
        harness.clock.advance(by: 1)
        await eventually { harness.coordinator.countdownValue == 2 }
        await eventually { harness.clock.pendingSleepCount == 1 }
        harness.clock.advance(by: 1)
        await eventually { harness.coordinator.countdownValue == 1 }
        await eventually { harness.clock.pendingSleepCount == 1 }
        harness.clock.advance(by: 1)
        await eventually { harness.capture.startCount == 1 }
        XCTAssertEqual(harness.coordinator.state, .recording)
    }

    func testStopDuringCountdownNeverStartsCaptureAndDiscardsTemporaryFile() async {
        let harness = try! Harness()
        await harness.beginSelectionAndRecord()
        await harness.coordinator.stop(reason: .manual)
        harness.clock.advance(by: 3)
        await Task.yield()

        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testConcurrentStopsAreIdempotentAndFinalizeInOrder() async {
        let harness = try! Harness()
        await harness.startRecording()

        let first = Task { await harness.coordinator.stop(reason: .manual) }
        await eventually { harness.coordinator.stopReason == .manual }
        let second = Task { await harness.coordinator.stop(reason: .diskSpace) }
        await first.value
        await second.value

        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.encoder.finishCount, 1)
        XCTAssertEqual(harness.coordinator.stopReason, .manual)
        XCTAssertEqual(harness.events, ["visual-stopping", "capture-stop", "encoder-finish", "validate", "preview"])
        guard case .previewReady = harness.coordinator.state else { return XCTFail("expected preview") }
    }

    func testNoFramesDiscardsFileAndRecoversWithTypedFailure() async {
        let harness = try! Harness(finishFailure: true)
        await harness.startRecording()
        await harness.coordinator.stop(reason: .manual)

        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertEqual(harness.coordinator.state, .failed(.finalizationFailed))
    }

    func testDiskPollStopsBelowThresholdAndReportsCapacityReadFailure() async {
        let harness = try! Harness()
        await harness.startRecording()
        harness.tempStore.capacity = .mustStop
        await eventually { harness.clock.pendingSleepCount >= 2 }
        harness.clock.advance(by: 1)
        await eventually { harness.capture.stopCount == 1 }
        XCTAssertEqual(harness.coordinator.stopReason, .diskSpace)

        let failing = try! Harness()
        await failing.startRecording()
        failing.tempStore.capacityError = true
        await eventually { failing.clock.pendingSleepCount >= 2 }
        failing.clock.advance(by: 1)
        await eventually { failing.coordinator.state == .failed(.capacityUnavailable) }
        XCTAssertEqual(failing.coordinator.state, .failed(.capacityUnavailable))
    }

    func testTargetDisplayRemovalFinalizesWithNoticeButUnrelatedChangeDoesNot() async {
        let harness = try! Harness()
        await harness.startRecording()
        harness.selection.displayChange(.init(added: [], removed: [999], updated: []))
        await Task.yield()
        XCTAssertEqual(harness.capture.stopCount, 0)
        harness.selection.displayChange(.init(added: [], removed: [], updated: [42]))
        await Task.yield()
        XCTAssertEqual(harness.capture.stopCount, 0)

        harness.selection.displayChange(.init(added: [], removed: [42], updated: []))
        await eventually { !harness.preview.notices.isEmpty }
        XCTAssertEqual(harness.preview.notices, [.displayRemoved])
    }

    func testStaleSelectionCallbackCannotAffectNewSession() async {
        let harness = try! Harness()
        await harness.coordinator.toggleRecording()
        let staleRecord = harness.selection.recordCallbacks[0]
        harness.selection.cancel()
        await eventually { harness.coordinator.state == .idle }
        await harness.coordinator.toggleRecording()
        staleRecord(harness.region, .default)
        await Task.yield()

        XCTAssertEqual(harness.encoderFactory.makeCount, 0)
        XCTAssertEqual(harness.coordinator.state, .selecting)
    }

    func testTerminationStopsAndDiscardsActiveOrUnsavedPreviewExactlyOnce() async {
        let harness = try! Harness()
        await harness.startRecording()
        async let a: Void = harness.coordinator.prepareForTermination()
        async let b: Void = harness.coordinator.prepareForTermination()
        _ = await (a, b)
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testStartCommandFromUnsavedPreviewDiscardsItBeforeNewSelection() async {
        let harness = try! Harness()
        await harness.startRecording()
        await harness.coordinator.stop(reason: .manual)

        await harness.coordinator.toggleRecording()

        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertEqual(harness.coordinator.state, .selecting)
        XCTAssertEqual(harness.selection.showCount, 2)
    }

    func testFrameDeliveredBeforeCaptureStartReturnsIsFinishedAfterItsPTS() async {
        let harness = try! Harness(suspendCaptureStart: true, frameBeforeStartReturnPTS: 100)
        await harness.beginSelectionAndRecord()
        await harness.finishCountdown()
        await eventually {
            harness.capture.startCount == 1 && harness.encoder.appendTimestamps == [100]
        }

        await harness.coordinator.stop(reason: .manual)

        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertGreaterThanOrEqual(harness.encoder.finishTimestamp ?? -.infinity, 100)
        XCTAssertEqual(
            harness.events,
            ["visual-stopping", "capture-stop", "encoder-finish", "validate", "preview"]
        )
    }

    func testCoordinatorPushesCountdownAndRecordingStatusToOverlay() async {
        let harness = try! Harness(settings: .init(scale: .one, fps: .twelve, duration: .fifteen, showsCursor: true))
        await harness.beginSelectionAndRecord()
        XCTAssertEqual(harness.selection.countdownUpdates, [3])

        await eventually { harness.clock.pendingSleepCount == 1 }
        harness.clock.advance(by: 1)
        await eventually { harness.selection.countdownUpdates == [3, 2] }
        for _ in 0..<2 {
            await eventually { harness.clock.pendingSleepCount == 1 }
            harness.clock.advance(by: 1)
        }
        await eventually { harness.capture.startCount == 1 }
        await eventually { harness.clock.pendingSleepCount >= 2 }
        harness.clock.advance(by: 5)
        await eventually { harness.selection.statusUpdates.last?.warning == true }
        XCTAssertEqual(harness.selection.statusUpdates.last?.remaining ?? -1, 10, accuracy: 0.001)
    }

    func testCountdownCancelsOnlyWhenTargetDisplayIsRemovedOrUpdated() async {
        let harness = try! Harness()
        await harness.beginSelectionAndRecord()
        harness.selection.displayChange(.init(added: [7], removed: [8], updated: [9]))
        await Task.yield()
        XCTAssertEqual(harness.coordinator.state, .countingDown)

        harness.selection.displayChange(.init(added: [], removed: [], updated: [42]))
        await eventually { harness.coordinator.state == .idle }
        XCTAssertEqual(harness.capture.stopCount, 0)
    }

    func testLateSuccessFromStoppedCaptureCannotMutateNewSession() async {
        await assertLateCaptureCompletionDoesNotMutateNewSession(error: nil)
    }

    func testLateFailureFromStoppedCaptureCannotMutateNewSession() async {
        await assertLateCaptureCompletionDoesNotMutateNewSession(error: FakeError())
    }

    func testEveryDurationPresetAutoStopsWithinHalfASecondAndWarnsForLastTen() async {
        for duration in RecordingSettings.Duration.allCases {
            let settings = RecordingSettings(scale: .one, fps: .twelve, duration: duration, showsCursor: true)
            let harness = try! Harness(settings: settings)
            await harness.startRecording()
            await eventually { harness.clock.pendingSleepCount >= 2 }
            harness.clock.advance(by: TimeInterval(duration.rawValue))
            await eventually { harness.coordinator.state.isPreviewReady }

            XCTAssertEqual(harness.coordinator.stopReason, .durationLimit)
            XCTAssertLessThanOrEqual(
                abs(harness.coordinator.elapsedSeconds - TimeInterval(duration.rawValue)),
                0.5
            )
            XCTAssertTrue(harness.coordinator.isInFinalTenSeconds)
        }
    }

    func testStartupCleanupAndPermissionRecheckAreDelegated() {
        let harness = try! Harness()
        XCTAssertNoThrow(try harness.coordinator.cleanupStaleFiles())
        XCTAssertTrue(harness.coordinator.recheckPermission())
        XCTAssertEqual(harness.tempStore.cleanupCount, 1)
        XCTAssertEqual(harness.permissions.recheckCount, 1)
    }

    func testRuntimeSystemCaptureFailureFinalizesWithNotice() async {
        let harness = try! Harness()
        await harness.startRecording()
        harness.capture.fail(.systemStopped)

        await eventually { harness.coordinator.state.isPreviewReady }

        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.preview.notices, [.captureStopped])
        XCTAssertEqual(harness.coordinator.stopReason, .captureFailure)
    }

    func testCaptureStartFailureDiscardsOwnedFileAndIsTyped() async {
        let harness = try! Harness(captureStartError: FakeError())
        await harness.beginSelectionAndRecord()
        await harness.finishCountdown()
        await eventually { harness.coordinator.state == .failed(.captureFailed) }

        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertEqual(harness.encoder.finishCount, 0)
    }

    func testFramesAreProcessedToTargetAndEncodedInOrder() async {
        let harness = try! Harness()
        await harness.startRecording()
        try! await harness.capture.deliver(pts: 10)
        try! await harness.capture.deliver(pts: 11)
        await harness.coordinator.stop(reason: .manual)

        XCTAssertEqual(harness.processor.targetSizes, [harness.region.outputPixelSize, harness.region.outputPixelSize])
        XCTAssertEqual(harness.encoder.appendTimestamps, [10, 11])
        XCTAssertGreaterThanOrEqual(harness.encoder.finishTimestamp ?? -.infinity, 11)
    }

    func testEncoderAppendErrorTriggersOrderedCaptureStopAndDiscard() async {
        let harness = try! Harness(appendFailure: true)
        await harness.startRecording()
        do { try await harness.capture.deliver(pts: 10) } catch { }
        await eventually { harness.coordinator.state == .failed(.captureFailed) }

        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertEqual(harness.encoder.finishCount, 0)
    }

    func testLifecycleTerminatesNowWhenIdle() {
        let harness = try! Harness()
        let delegate = AppLifecycleDelegate(environment: .init(coordinator: harness.coordinator))
        var replyCount = 0

        let decision = delegate.requestTermination { replyCount += 1 }

        XCTAssertEqual(decision, .terminateNow)
        XCTAssertEqual(replyCount, 0)
    }

    func testLifecycleCleansStaleFilesBeforeAcceptingCommands() throws {
        let harness = try Harness()
        let delegate = AppLifecycleDelegate(environment: .init(coordinator: harness.coordinator))
        var cleanupCountWhenRegistered = -1

        try delegate.startup {
            cleanupCountWhenRegistered = harness.tempStore.cleanupCount
        }

        XCTAssertEqual(cleanupCountWhenRegistered, 1)
    }

    func testLifecycleActiveAndUnsavedWorkTerminateLaterAndReplyOnce() async {
        let harness = try! Harness()
        await harness.startRecording()
        let delegate = AppLifecycleDelegate(environment: .init(coordinator: harness.coordinator))
        var replyCount = 0

        XCTAssertEqual(delegate.requestTermination { replyCount += 1 }, .terminateLater)
        XCTAssertEqual(delegate.requestTermination { replyCount += 1 }, .terminateLater)
        await eventually { replyCount == 1 }

        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testLifecycleUnsavedPreviewDiscardsBeforeReply() async {
        let harness = try! Harness()
        await harness.startRecording()
        await harness.coordinator.stop(reason: .manual)
        let delegate = AppLifecycleDelegate(environment: .init(coordinator: harness.coordinator))
        var replyCount = 0

        XCTAssertEqual(delegate.requestTermination { replyCount += 1 }, .terminateLater)
        await eventually { replyCount == 1 }

        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testStaleCountdownCannotAffectReplacementSession() async {
        let harness = try! Harness()
        await harness.beginSelectionAndRecord()
        await harness.coordinator.stop(reason: .manual)
        await harness.coordinator.toggleRecording()
        harness.selection.record(harness.region, .default)
        await eventually { harness.coordinator.state == .countingDown }

        await eventually { harness.clock.pendingSleepCount >= 2 }
        harness.clock.advance(by: 1)
        await eventually { harness.coordinator.countdownValue == 2 }

        XCTAssertEqual(harness.coordinator.state, .countingDown)
        XCTAssertEqual(harness.coordinator.countdownValue, 2)
    }

    func testStaleCaptureFailureCannotAffectReplacementSession() async {
        let harness = try! Harness()
        await harness.startRecording()
        await harness.coordinator.stop(reason: .manual)
        await harness.coordinator.toggleRecording()
        harness.selection.record(harness.region, .default)
        await eventually { harness.coordinator.state == .countingDown }

        harness.capture.fail(handlerAt: 0, error: .systemStopped)
        await Task.yield()

        XCTAssertEqual(harness.coordinator.state, .countingDown)
    }

    func testCommandTitleIsDerivedFromCoordinatorState() async {
        let harness = try! Harness()
        XCTAssertEqual(harness.coordinator.recordingCommandTitle, "开始录制")
        await harness.beginSelectionAndRecord()
        XCTAssertEqual(harness.coordinator.recordingCommandTitle, "停止录制")
    }

    func testDurationLimitCancelsSuspendedCaptureStartWithinHalfSecond() async {
        let settings = RecordingSettings(
            scale: .one,
            fps: .twelve,
            duration: .fifteen,
            showsCursor: true
        )
        let harness = try! Harness(settings: settings, suspendCaptureStart: true)
        await harness.beginSelectionAndRecord()
        await harness.finishCountdown()
        await eventually { harness.capture.startCount == 1 }
        await eventually { harness.clock.pendingSleepCount >= 2 }

        harness.clock.advance(by: 15)
        await eventually { harness.coordinator.state.isPreviewReady }

        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.coordinator.stopReason, .durationLimit)
        XCTAssertLessThanOrEqual(abs(harness.coordinator.elapsedSeconds - 15), 0.5)
    }

    func testDiskLimitCancelsSuspendedCaptureStartAndFinalizes() async {
        let harness = try! Harness(suspendCaptureStart: true)
        await harness.beginSelectionAndRecord()
        await harness.finishCountdown()
        await eventually { harness.capture.startCount == 1 }
        harness.tempStore.capacity = .mustStop
        await eventually { harness.clock.pendingSleepCount >= 2 }

        harness.clock.advance(by: 1)
        await eventually { harness.coordinator.state.isPreviewReady }

        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.coordinator.stopReason, .diskSpace)
    }

    func testCaptureStartFailureCancelsRuntimeTasksWithoutStaleMutation() async {
        let harness = try! Harness(
            suspendCaptureStart: true,
            releaseCaptureStartOnStop: false
        )
        await harness.beginSelectionAndRecord()
        await harness.finishCountdown()
        await eventually { harness.clock.pendingSleepCount >= 2 }
        harness.capture.releaseStart(error: FakeError())
        await eventually { harness.coordinator.state == .failed(.captureFailed) }
        let discardCount = harness.tempStore.discardCount
        let statusCount = harness.selection.statusUpdates.count

        harness.clock.advance(by: 100)
        await Task.yield()

        XCTAssertEqual(harness.coordinator.state, .failed(.captureFailed))
        XCTAssertEqual(harness.tempStore.discardCount, discardCount)
        XCTAssertNil(harness.coordinator.stopReason)
        XCTAssertEqual(harness.coordinator.elapsedSeconds, 0)
        XCTAssertEqual(harness.selection.statusUpdates.count, statusCount)
    }

    private func assertLateCaptureCompletionDoesNotMutateNewSession(error: Error?) async {
        let harness = try! Harness(suspendCaptureStart: true, releaseCaptureStartOnStop: false)
        await harness.startRecording()
        await harness.coordinator.stop(reason: .manual)
        await harness.coordinator.toggleRecording()
        harness.selection.record(harness.region, .default)
        await eventually { harness.coordinator.state == .countingDown }
        let discardCount = harness.tempStore.discardCount

        harness.capture.releaseStart(error: error)
        await Task.yield()

        XCTAssertEqual(harness.coordinator.state, .countingDown)
        XCTAssertEqual(harness.tempStore.discardCount, discardCount)
        XCTAssertEqual(harness.encoderFactory.makeCount, 2)
    }
}

@MainActor
private final class Harness {
    let clock = ManualRecordingClock()
    let permissions: FakePermissions
    let selection = FakeSelection()
    let capture: FakeCapture
    let processor = FakeProcessor()
    let encoder: FakeEncoder
    let encoderFactory: FakeEncoderFactory
    let tempStore: FakeTempStore
    let preferences: FakePreferences
    let preview: FakePreview
    let coordinator: RecordingCoordinator
    var events: [String] { recorder.values }
    let recorder = EventRecorder()
    let region = CaptureRegion(displayID: 42, globalRect: .init(x: 0, y: 0, width: 100, height: 80), sourceRect: .init(x: 0, y: 0, width: 100, height: 80), logicalPixelSize: .init(width: 100, height: 80), outputPixelSize: .init(width: 100, height: 80), backingScale: 1)

    init(permission: Bool = true, settings: RecordingSettings = .default, capacity: TemporaryFileStore.CapacityPolicy = .canStart, capacityError: Bool = false, encoderFailure: Bool = false, finishFailure: Bool = false, suspendCaptureStart: Bool = false, frameBeforeStartReturnPTS: TimeInterval? = nil, releaseCaptureStartOnStop: Bool = true, captureStartError: Error? = nil, appendFailure: Bool = false) throws {
        permissions = FakePermissions(granted: permission)
        capture = FakeCapture(events: recorder, suspendStart: suspendCaptureStart, frameBeforeStartReturnPTS: frameBeforeStartReturnPTS, releaseStartOnStop: releaseCaptureStartOnStop, startError: captureStartError)
        tempStore = try FakeTempStore(events: recorder, capacity: capacity, capacityError: capacityError)
        preferences = FakePreferences(settings: settings)
        preview = FakePreview(events: recorder)
        encoder = FakeEncoder(file: try tempStore.make(), events: recorder, finishFailure: finishFailure, appendFailure: appendFailure)
        let secondEncoder = FakeEncoder(file: try tempStore.make(), events: recorder, finishFailure: finishFailure, appendFailure: appendFailure)
        encoderFactory = FakeEncoderFactory(encoders: [encoder, secondEncoder], shouldFail: encoderFailure)
        selection.events = recorder
        coordinator = RecordingCoordinator(permission: permissions, selection: selection, capture: capture, processor: processor, encoderFactory: encoderFactory, temporaryFiles: tempStore, preferences: preferences, preview: preview, clock: clock)
    }

    func beginSelectionAndRecord() async {
        await coordinator.toggleRecording()
        selection.record(region, preferences.settings)
        await Task.yield()
    }

    func startRecording() async {
        await beginSelectionAndRecord()
        await finishCountdown()
        await eventually { self.capture.startCount == 1 }
    }

    func finishCountdown() async {
        for _ in 0..<3 {
            await eventually { self.clock.pendingSleepCount == 1 }
            clock.advance(by: 1)
            await Task.yield()
        }
    }
}

@MainActor private func eventually(_ predicate: @escaping @MainActor () -> Bool) async {
    for _ in 0..<100 where !predicate() { await Task.yield() }
    XCTAssertTrue(predicate())
}

private final class EventRecorder: @unchecked Sendable { var values: [String] = [] }
private struct FakeError: Error {}

@MainActor private final class FakePermissions: RecordingPermissionAuthorizing {
    let granted: Bool; var recheckCount = 0
    init(granted: Bool) { self.granted = granted }
    func requestAccessIfNeeded() -> Bool { granted }
    func recheckAccess() -> Bool { recheckCount += 1; return granted }
}

@MainActor private final class FakeSelection: RecordingSelectionPresenting {
    var showCount = 0; var shownSettings: [RecordingSettings] = []; var recordCallbacks: [(CaptureRegion, RecordingSettings) -> Void] = []
    var settingsCallback: ((RecordingSettings) -> Void)?; var cancelCallback: (() -> Void)?; var displayCallback: ((DisplayConfigurationChange) -> Void)?; var events: EventRecorder?
    var countdownUpdates: [Int] = []
    var statusUpdates: [(elapsed: TimeInterval, remaining: TimeInterval, warning: Bool)] = []
    func show(settings: RecordingSettings, onSettingsChanged: @escaping (RecordingSettings) -> Void, onRecord: @escaping (CaptureRegion, RecordingSettings) -> Void, onCancel: @escaping () -> Void, onDisplayChange: @escaping (DisplayConfigurationChange) -> Void) { showCount += 1; shownSettings.append(settings); settingsCallback = onSettingsChanged; recordCallbacks.append(onRecord); cancelCallback = onCancel; displayCallback = onDisplayChange }
    func dismiss() {}
    func showCountdownVisual(value: Int, targetDisplayID: CGDirectDisplayID) { countdownUpdates.append(value) }
    func updateCountdown(value: Int) { countdownUpdates.append(value) }
    func showRecordingVisual(onStop: @escaping () -> Void) {}
    func updateRecordingStatus(elapsed: TimeInterval, remaining: TimeInterval, isWarning: Bool) { statusUpdates.append((elapsed, remaining, isWarning)) }
    func showStoppingVisual() { events?.values.append("visual-stopping") }
    func changeSettings(_ value: RecordingSettings) { settingsCallback?(value) }
    func record(_ region: CaptureRegion, _ settings: RecordingSettings) { recordCallbacks.last?(region, settings) }
    func cancel() { cancelCallback?() }
    func displayChange(_ change: DisplayConfigurationChange) { displayCallback?(change) }
}

private final class FakeCapture: RecordingCaptureControlling, @unchecked Sendable {
    let events: EventRecorder; private(set) var startCount = 0; private(set) var stopCount = 0
    let suspendStart: Bool; let frameBeforeStartReturnPTS: TimeInterval?; let releaseStartOnStop: Bool; let startError: Error?; private var continuation: CheckedContinuation<Void, Error>?; private var frameConsumer: (@Sendable (CapturedFrame) async throws -> Void)?; private var failureHandlers: [(@Sendable (CaptureError) -> Void)] = []
    init(events: EventRecorder, suspendStart: Bool = false, frameBeforeStartReturnPTS: TimeInterval? = nil, releaseStartOnStop: Bool = true, startError: Error? = nil) { self.events = events; self.suspendStart = suspendStart; self.frameBeforeStartReturnPTS = frameBeforeStartReturnPTS; self.releaseStartOnStop = releaseStartOnStop; self.startError = startError }
    func start(region: CaptureRegion, settings: RecordingSettings, onFrame: @escaping @Sendable (CapturedFrame) async throws -> Void, onFailure: @escaping @Sendable (CaptureError) -> Void) async throws {
        startCount += 1
        frameConsumer = onFrame
        failureHandlers.append(onFailure)
        if let startError { throw startError }
        if let pts = frameBeforeStartReturnPTS { try await onFrame(makeFrame(pts: pts)) }
        if suspendStart { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    func stop() async throws { stopCount += 1; events.values.append("capture-stop"); if releaseStartOnStop { releaseStart(error: nil) } }
    func releaseStart(error: Error?) { if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }; continuation = nil }
    func deliver(pts: TimeInterval) async throws { try await frameConsumer?(makeFrame(pts: pts)) }
    func fail(_ error: CaptureError) { failureHandlers.last?(error) }
    func fail(handlerAt index: Int, error: CaptureError) { failureHandlers[index](error) }
}

private final class FakeProcessor: RecordingFrameProcessing, @unchecked Sendable {
    private(set) var targetSizes: [CGSize] = []
    func process(_ frame: CapturedFrame, targetPixelSize: CGSize) throws -> CGImage {
        targetSizes.append(targetPixelSize)
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}

private final class FakeEncoder: RecordingEncoding, @unchecked Sendable {
    let temporaryFile: TemporaryFile; let events: EventRecorder; let finishFailure: Bool; let appendFailure: Bool; private(set) var finishCount = 0; private(set) var appendTimestamps: [TimeInterval] = []; private(set) var finishTimestamp: TimeInterval?
    init(file: TemporaryFile, events: EventRecorder, finishFailure: Bool, appendFailure: Bool = false) { temporaryFile = file; self.events = events; self.finishFailure = finishFailure; self.appendFailure = appendFailure }
    func append(image: CGImage, timestamp: TimeInterval) async throws { if appendFailure { throw FakeError() }; appendTimestamps.append(timestamp) }
    func finish(at timestamp: TimeInterval) async throws -> TemporaryFile { finishCount += 1; finishTimestamp = timestamp; events.values.append("encoder-finish"); if finishFailure { throw FakeError() }; return temporaryFile }
}

@MainActor private final class FakeEncoderFactory: RecordingEncoderFactory {
    var encoders: [FakeEncoder]; let shouldFail: Bool; var makeCount = 0
    init(encoders: [FakeEncoder], shouldFail: Bool) { self.encoders = encoders; self.shouldFail = shouldFail }
    func make(maximumFrames: Int) throws -> any RecordingEncoding { makeCount += 1; if shouldFail { throw FakeError() }; return encoders.removeFirst() }
}

@MainActor private final class FakeTempStore: RecordingTemporaryFileManaging {
    let store: TemporaryFileStore; let events: EventRecorder; var capacity: TemporaryFileStore.CapacityPolicy; var capacityError: Bool; var discardCount = 0; var cleanupCount = 0
    init(events: EventRecorder, capacity: TemporaryFileStore.CapacityPolicy, capacityError: Bool) throws { let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = TemporaryFileStore(rootURL: root); self.events = events; self.capacity = capacity; self.capacityError = capacityError }
    func make() throws -> TemporaryFile { try store.makeTemporaryFile() }
    func capacityPolicy() throws -> TemporaryFileStore.CapacityPolicy { if capacityError { throw FakeError() }; return capacity }
    func validatedAccessURL(for file: TemporaryFile) throws -> URL { events.values.append("validate"); return try store.validatedAccessURL(for: file) }
    func discard(_ file: TemporaryFile) throws { discardCount += 1; try store.discardTemporaryFile(file) }
    func cleanupStaleFiles() throws { cleanupCount += 1; try store.cleanupStaleFiles() }
}

@MainActor private final class FakePreferences: RecordingPreferencesManaging {
    var settings: RecordingSettings; var saved: [RecordingSettings] = []
    init(settings: RecordingSettings) { self.settings = settings }
    func load() -> RecordingSettings { settings }
    func save(_ value: RecordingSettings) { settings = value; saved.append(value) }
}

@MainActor private final class FakePreview: RecordingPreviewPresenting {
    let events: EventRecorder; var notices: [RecordingCompletionNotice?] = []
    init(events: EventRecorder) { self.events = events }
    func present(url: URL, notice: RecordingCompletionNotice?) { events.values.append("preview"); notices.append(notice) }
}

private final class ManualRecordingClock: RecordingClock, @unchecked Sendable {
    private let lock = NSLock(); private var instant: TimeInterval = 0; private var waiters: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
    func now() -> TimeInterval { lock.withLock { instant } }
    var pendingSleepCount: Int { lock.withLock { waiters.count } }
    func sleep(for duration: TimeInterval) async { await withCheckedContinuation { continuation in lock.withLock { waiters.append((instant + duration, continuation)) } } }
    func advance(by duration: TimeInterval) { let ready: [CheckedContinuation<Void, Never>] = lock.withLock { instant += duration; let values = waiters.filter { $0.0 <= instant }.map(\.1); waiters.removeAll { $0.0 <= instant }; return values }; ready.forEach { $0.resume() } }
}

private func makeFrame(pts: TimeInterval) -> CapturedFrame {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 1, 1, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    return CapturedFrame(pixelBuffer: pixelBuffer!, presentationTime: CMTime(seconds: pts, preferredTimescale: 1_000))
}

private extension RecordingState {
    var isPreviewReady: Bool {
        if case .previewReady = self { return true }
        return false
    }
}
