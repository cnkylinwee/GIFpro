import CoreGraphics
import CoreMedia
import XCTest
@testable import GIFpro

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func testPreviewSaveCallbacksFollowCancelRetryAndSuccessStateLoop() async {
        let harness = try! Harness()
        await harness.startRecording()
        await harness.coordinator.stop(reason: .manual)

        harness.preview.beginSave()
        guard case .awaitingSave = harness.coordinator.state else {
            return XCTFail("expected awaitingSave")
        }
        harness.preview.cancelSave()
        guard case .previewReady = harness.coordinator.state else {
            return XCTFail("expected previewReady after cancel")
        }

        harness.preview.beginSave()
        harness.preview.failSave()
        guard case .previewReady = harness.coordinator.state else {
            return XCTFail("expected previewReady after move failure")
        }

        harness.preview.beginSave()
        let destination = URL(fileURLWithPath: "/tmp/saved.gif")
        harness.preview.completeSave(destination)
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.tempStore.discardCount, 0)
        XCTAssertNil(harness.coordinator.lastUserFacingFailure)
    }

    func testPreviewRerecordAndDiscardCallbacksClearCoordinatorOwnership() async {
        let rerecord = try! Harness()
        await rerecord.startRecording()
        await rerecord.coordinator.stop(reason: .manual)
        rerecord.preview.requestRerecord()
        XCTAssertEqual(rerecord.coordinator.state, .selecting)
        XCTAssertEqual(rerecord.selection.showCount, 2)

        let discard = try! Harness()
        await discard.startRecording()
        await discard.coordinator.stop(reason: .manual)
        discard.preview.completeDiscard()
        XCTAssertEqual(discard.coordinator.state, .idle)
    }

    func testPreviewPresentationFailureDiscardsTemporaryOutput() async {
        let harness = try! Harness(previewFailure: true)
        await harness.startRecording()

        await harness.coordinator.stop(reason: .manual)

        XCTAssertEqual(harness.coordinator.state, .failed(.finalizationFailed))
        XCTAssertEqual(harness.tempStore.discardCount, 1)
    }

    func testRerecordRechecksPermissionBeforeShowingSelection() async {
        let harness = try! Harness()
        await harness.startRecording()
        await harness.coordinator.stop(reason: .manual)
        harness.permissions.granted = false

        harness.preview.requestRerecord()

        XCTAssertEqual(harness.coordinator.state, .failed(.permissionDenied))
        XCTAssertEqual(harness.selection.showCount, 1)
    }

    func testPreviewDurationFreezesAtFirstStopBoundaryWhileCaptureDrainIsDelayed() async {
        let harness = try! Harness(suspendCaptureStop: true)
        await harness.startRecording()
        harness.clock.advance(by: 4)

        let stopping = Task { await harness.coordinator.stop(reason: .manual) }
        await eventually { harness.capture.isStopSuspended }
        harness.clock.advance(by: 20)
        harness.capture.releaseStop()
        await stopping.value

        XCTAssertEqual(harness.preview.metadatas.last?.duration ?? -1, 4, accuracy: 0.001)
    }

    func testSaveWarningRemainsObservableAfterCommittedSaveCompletes() async {
        let harness = try! Harness()
        await harness.startRecording()
        await harness.coordinator.stop(reason: .manual)
        harness.preview.beginSave()

        harness.preview.reportWarning(.sourceChanged)
        harness.preview.completeSave(URL(fileURLWithPath: "/tmp/saved.gif"))

        XCTAssertEqual(harness.coordinator.saveWarnings, [.sourceChanged])
    }

    func testDeniedPermissionDoesNotShowSelection() async {
        let harness = try! Harness(permission: false)
        await harness.coordinator.toggleRecording()

        XCTAssertEqual(harness.coordinator.state, .failed(.permissionDenied))
        XCTAssertEqual(harness.selection.showCount, 0)
    }

    func testMenuPermissionRecoveryRechecksAndReturnsToSelection() async {
        let harness = try! Harness(permission: false)
        await harness.coordinator.toggleRecording()
        harness.permissions.granted = true

        harness.coordinator.performRecoveryAction(.recheckPermission)

        XCTAssertEqual(harness.permissions.recheckCount, 1)
        XCTAssertEqual(harness.coordinator.state, .selecting)
        XCTAssertEqual(harness.selection.showCount, 1)
    }

    func testMenuSaveRecoveryCallsPreviewRetryAfterSaveFailure() async {
        let harness = try! Harness()
        await harness.startRecording()
        await harness.coordinator.stop(reason: .manual)
        harness.preview.beginSave()
        harness.preview.failSave()
        XCTAssertEqual(harness.coordinator.lastUserFacingFailure, .saveFailed)

        harness.coordinator.performRecoveryAction(.saveAgain)

        XCTAssertEqual(harness.preview.retrySaveCount, 1)
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
        XCTAssertEqual(harness.events, ["visual-stopping", "capture-stop", "encoder-finish", "preview"])
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
            ["visual-stopping", "capture-stop", "encoder-finish", "preview"]
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
        let scheduler = GateStopRequestScheduler()
        let harness = try! Harness(stopRequestScheduler: scheduler)
        await harness.startRecording()
        await harness.capture.waitUntilFailureHandlerInstalled()
        harness.capture.fail(.systemStopped)

        guard scheduler.pendingCount == 1 else {
            XCTFail("Capture failure did not schedule its stop request")
            return
        }
        await scheduler.releaseNext()

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

    func testOverlayStopActivationIsConsumedOnceDownstream() async {
        let harness = try! Harness()
        await harness.startRecording()

        harness.selection.pressStop()
        harness.selection.pressStop()
        harness.selection.pressStop()
        await eventually { harness.capture.stopCount == 1 }

        XCTAssertEqual(harness.selection.stopCallbackCount, 1)
        XCTAssertEqual(harness.capture.stopCount, 1)
    }

    func testUnavailableProductionRecordingLayoutKeepsRealCoordinatorRecordingWithMenuFallback() async {
        let harness = try! Harness(recordingVisibleFrame: CGRect(x: -50, y: -20, width: 100, height: 28))

        await harness.startRecording()

        XCTAssertEqual(harness.selection.recordingLayout?.mode, .unavailable)
        XCTAssertEqual(harness.selection.layoutErrors.count, 1)
        XCTAssertEqual(harness.coordinator.state, .recording)
        XCTAssertEqual(harness.coordinator.recordingCommandTitle, "停止录制")
        XCTAssertEqual(harness.capture.stopCount, 0)
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
        await eventually { harness.capture.isStartSuspended }
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

    func testAppendFailureDuringStopDrainOverridesSuccessfulFinalization() async {
        let harness = try! Harness(
            appendFailure: true,
            frameDuringStopPTS: 10
        )
        await harness.startRecording()

        await harness.coordinator.stop(reason: .manual)

        XCTAssertEqual(harness.coordinator.state, .failed(.captureFailed))
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertEqual(harness.encoder.finishCount, 0)
        XCTAssertTrue(harness.preview.notices.isEmpty)
        XCTAssertEqual(harness.coordinator.stopReason, .manual)
    }

    func testSelectingCancelsForAnyDisplayConfigurationChange() async {
        let harness = try! Harness()
        await harness.coordinator.toggleRecording()
        XCTAssertEqual(harness.coordinator.state, .selecting)

        harness.selection.displayChange(
            .init(added: [7], removed: [8], updated: [9])
        )
        await eventually { harness.coordinator.state == .idle }

        XCTAssertEqual(harness.encoderFactory.makeCount, 0)
        XCTAssertEqual(harness.encoder.finishCount, 0)
        XCTAssertEqual(harness.tempStore.discardCount, 0)
    }

    func testDelayedFailureStopRequestCannotStopReplacementSession() async {
        let scheduler = GateStopRequestScheduler()
        let harness = try! Harness(
            appendFailure: true,
            stopRequestScheduler: scheduler
        )
        await harness.startRecording()
        do { try await harness.capture.deliver(pts: 10) } catch { }
        XCTAssertEqual(scheduler.pendingCount, 1)

        await harness.coordinator.stop(reason: .manual)
        XCTAssertEqual(harness.coordinator.state, .failed(.captureFailed))
        await harness.coordinator.toggleRecording()
        harness.selection.record(harness.region, .default)
        await eventually { harness.coordinator.state == .countingDown }
        let discardCount = harness.tempStore.discardCount

        await scheduler.releaseNext()

        XCTAssertEqual(harness.coordinator.state, .countingDown)
        XCTAssertEqual(harness.tempStore.discardCount, discardCount)
        XCTAssertEqual(harness.encoderFactory.makeCount, 2)
    }

    func testEncoderCapacityIsNormalDurationStopAndPresentsAllAcceptedFrames() async throws {
        let settings = RecordingSettings(
            scale: .one,
            fps: .twelve,
            duration: .fifteen,
            showsCursor: true
        )
        let harness = try Harness(settings: settings)
        harness.encoder.maximumAcceptedFrames = 180
        await harness.startRecording()

        for index in 0 ... 180 {
            try await harness.capture.deliver(pts: 3 + Double(index) / 12)
        }
        await eventually { harness.coordinator.state.isPreviewReady }

        XCTAssertEqual(harness.encoder.appendTimestamps.count, 180)
        XCTAssertEqual(harness.encoder.finishCount, 1)
        XCTAssertEqual(harness.coordinator.stopReason, .durationLimit)
        XCTAssertEqual(harness.preview.metadatas.last?.duration, 15)
        XCTAssertEqual(harness.tempStore.discardCount, 0)
    }

    func testTerminationDuringSuspendedCaptureStopAwaitsFinalizationThenDiscardsPreview() async {
        let harness = try! Harness(suspendCaptureStop: true)
        await harness.startRecording()
        let stopping = Task { await harness.coordinator.stop(reason: .manual) }
        await eventually { harness.capture.isStopSuspended }

        let termination = Task { await harness.coordinator.prepareForTermination() }
        await Task.yield()
        XCTAssertEqual(harness.coordinator.state, .finalizing)
        XCTAssertEqual(harness.encoder.finishCount, 0)

        harness.capture.releaseStop()
        await stopping.value
        await termination.value
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.encoder.finishCount, 1)
        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertNil(harness.preview.actions)
    }

    func testTerminationDuringSuspendedEncoderFinishWaitsAndLeavesNoPreviewOrTemp() async {
        let harness = try! Harness(suspendEncoderFinish: true)
        await harness.startRecording()
        let stopping = Task { await harness.coordinator.stop(reason: .manual) }
        await eventually { harness.encoder.isFinishSuspended }

        let termination = Task { await harness.coordinator.prepareForTermination() }
        await Task.yield()
        XCTAssertEqual(harness.coordinator.state, .finalizing)

        harness.encoder.releaseFinish()
        await stopping.value
        await termination.value
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.encoder.finishCount, 1)
        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertNil(harness.preview.actions)
    }

    func testTerminationDuringSuspendedFailingFinishStillRepliesWithCleanIdleState() async {
        let harness = try! Harness(finishFailure: true, suspendEncoderFinish: true)
        await harness.startRecording()
        let stopping = Task { await harness.coordinator.stop(reason: .manual) }
        await eventually { harness.encoder.isFinishSuspended }
        let termination = Task { await harness.coordinator.prepareForTermination() }

        harness.encoder.releaseFinish()
        await stopping.value
        await termination.value
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.tempStore.discardCount, 1)
        XCTAssertNil(harness.preview.actions)
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
    let selection: FakeSelection
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

    init(permission: Bool = true, settings: RecordingSettings = .default, capacity: TemporaryFileStore.CapacityPolicy = .canStart, capacityError: Bool = false, encoderFailure: Bool = false, finishFailure: Bool = false, suspendEncoderFinish: Bool = false, suspendCaptureStart: Bool = false, suspendCaptureStop: Bool = false, frameBeforeStartReturnPTS: TimeInterval? = nil, releaseCaptureStartOnStop: Bool = true, captureStartError: Error? = nil, appendFailure: Bool = false, frameDuringStopPTS: TimeInterval? = nil, previewFailure: Bool = false, stopRequestScheduler: (any RecordingStopRequestScheduling)? = nil, recordingVisibleFrame: CGRect? = nil) throws {
        selection = FakeSelection(recordingVisibleFrame: recordingVisibleFrame)
        permissions = FakePermissions(granted: permission)
        capture = FakeCapture(events: recorder, suspendStart: suspendCaptureStart, suspendStop: suspendCaptureStop, frameBeforeStartReturnPTS: frameBeforeStartReturnPTS, releaseStartOnStop: releaseCaptureStartOnStop, startError: captureStartError, frameDuringStopPTS: frameDuringStopPTS)
        tempStore = try FakeTempStore(events: recorder, capacity: capacity, capacityError: capacityError)
        preferences = FakePreferences(settings: settings)
        preview = FakePreview(events: recorder, shouldFail: previewFailure)
        encoder = FakeEncoder(file: try tempStore.make(), events: recorder, finishFailure: finishFailure, appendFailure: appendFailure, suspendFinish: suspendEncoderFinish)
        let secondEncoder = FakeEncoder(file: try tempStore.make(), events: recorder, finishFailure: finishFailure, appendFailure: appendFailure)
        encoderFactory = FakeEncoderFactory(encoders: [encoder, secondEncoder], shouldFail: encoderFailure)
        selection.events = recorder
        coordinator = RecordingCoordinator(permission: permissions, selection: selection, capture: capture, processor: processor, encoderFactory: encoderFactory, temporaryFiles: tempStore, preferences: preferences, preview: preview, clock: clock, stopRequestScheduler: stopRequestScheduler ?? ImmediateStopRequestScheduler())
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

@MainActor private func eventually(
    _ predicate: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0 ..< 1_000 {
        if predicate() { return }
        await Task.yield()
    }
    XCTFail("Timed out waiting for asynchronous test condition", file: file, line: line)
}

private final class EventRecorder: @unchecked Sendable { var values: [String] = [] }
private struct FakeError: Error {}

@MainActor private final class FakePermissions: RecordingPermissionAuthorizing {
    var granted: Bool; var recheckCount = 0
    init(granted: Bool) { self.granted = granted }
    func requestAccessIfNeeded() -> Bool { granted }
    func recheckAccess() -> Bool { recheckCount += 1; return granted }
}

@MainActor private final class FakeSelection: RecordingSelectionPresenting {
    var showCount = 0; var shownSettings: [RecordingSettings] = []; var recordCallbacks: [(CaptureRegion, RecordingSettings) -> Void] = []
    var settingsCallback: ((RecordingSettings) -> Void)?; var cancelCallback: (() -> Void)?; var displayCallback: ((DisplayConfigurationChange) -> Void)?; var events: EventRecorder?
    var countdownUpdates: [Int] = []
    var statusUpdates: [(elapsed: TimeInterval, remaining: TimeInterval, warning: Bool)] = []
    var stopCallback: (() -> Void)?
    private(set) var stopCallbackCount = 0
    let recordingVisibleFrame: CGRect?
    private(set) var recordingLayout: RecordingOverlayPresentation.Output?
    private(set) var layoutErrors: [String] = []
    init(recordingVisibleFrame: CGRect? = nil) {
        self.recordingVisibleFrame = recordingVisibleFrame
    }
    func show(settings: RecordingSettings, onSettingsChanged: @escaping (RecordingSettings) -> Void, onRecord: @escaping (CaptureRegion, RecordingSettings) -> Void, onCancel: @escaping () -> Void, onDisplayChange: @escaping (DisplayConfigurationChange) -> Void) { showCount += 1; shownSettings.append(settings); settingsCallback = onSettingsChanged; recordCallbacks.append(onRecord); cancelCallback = onCancel; displayCallback = onDisplayChange }
    func dismiss() {}
    func showCountdownVisual(value: Int, targetDisplayID: CGDirectDisplayID) { countdownUpdates.append(value) }
    func updateCountdown(value: Int) { countdownUpdates.append(value) }
    func showRecordingVisual(onStop: @escaping () -> Void) {
        stopCallback = onStop
        if let recordingVisibleFrame {
            recordingLayout = RecordingOverlayPresentation.layout(
                input: .recording,
                selectionRect: CGRect(x: 0, y: 0, width: 64, height: 64),
                visibleFrame: recordingVisibleFrame,
                errorSink: { [weak self] in self?.layoutErrors.append($0) }
            )
        }
    }
    func updateRecordingStatus(elapsed: TimeInterval, remaining: TimeInterval, isWarning: Bool) { statusUpdates.append((elapsed, remaining, isWarning)) }
    func showStoppingVisual() { events?.values.append("visual-stopping") }
    func changeSettings(_ value: RecordingSettings) { settingsCallback?(value) }
    func record(_ region: CaptureRegion, _ settings: RecordingSettings) { recordCallbacks.last?(region, settings) }
    func cancel() { cancelCallback?() }
    func displayChange(_ change: DisplayConfigurationChange) { displayCallback?(change) }
    func pressStop() {
        guard let callback = stopCallback else { return }
        stopCallback = nil
        stopCallbackCount += 1
        callback()
    }
}

private final class FakeCapture: RecordingCaptureControlling, @unchecked Sendable {
    let events: EventRecorder; private(set) var startCount = 0; private(set) var stopCount = 0
    let suspendStart: Bool; let suspendStop: Bool; let frameBeforeStartReturnPTS: TimeInterval?; let releaseStartOnStop: Bool; let startError: Error?; let frameDuringStopPTS: TimeInterval?; private var continuation: CheckedContinuation<Void, Error>?; private var stopContinuation: CheckedContinuation<Void, Never>?; private var frameConsumer: (@Sendable (CapturedFrame) async throws -> Void)?; private let failureLock = NSLock(); private var failureHandlers: [(@Sendable (CaptureError) -> Void)] = []; private var failureHandlerWaiters: [CheckedContinuation<Void, Never>] = []
    init(events: EventRecorder, suspendStart: Bool = false, suspendStop: Bool = false, frameBeforeStartReturnPTS: TimeInterval? = nil, releaseStartOnStop: Bool = true, startError: Error? = nil, frameDuringStopPTS: TimeInterval? = nil) { self.events = events; self.suspendStart = suspendStart; self.suspendStop = suspendStop; self.frameBeforeStartReturnPTS = frameBeforeStartReturnPTS; self.releaseStartOnStop = releaseStartOnStop; self.startError = startError; self.frameDuringStopPTS = frameDuringStopPTS }
    func start(region: CaptureRegion, settings: RecordingSettings, onFrame: @escaping @Sendable (CapturedFrame) async throws -> Void, onFailure: @escaping @Sendable (CaptureError) -> Void) async throws {
        startCount += 1
        frameConsumer = onFrame
        let waiters = failureLock.withLock {
            failureHandlers.append(onFailure)
            let pending = failureHandlerWaiters
            failureHandlerWaiters.removeAll()
            return pending
        }
        waiters.forEach { $0.resume() }
        if let startError { throw startError }
        if let pts = frameBeforeStartReturnPTS { try await onFrame(makeFrame(pts: pts)) }
        if suspendStart { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    func stop() async throws {
        stopCount += 1
        events.values.append("capture-stop")
        if let frameDuringStopPTS { try? await frameConsumer?(makeFrame(pts: frameDuringStopPTS)) }
        if releaseStartOnStop { releaseStart(error: nil) }
        if suspendStop { await withCheckedContinuation { stopContinuation = $0 } }
    }
    func releaseStop() { stopContinuation?.resume(); stopContinuation = nil }
    var isStartSuspended: Bool { continuation != nil }
    var isStopSuspended: Bool { stopContinuation != nil }
    func releaseStart(error: Error?) { if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }; continuation = nil }
    func deliver(pts: TimeInterval) async throws { try await frameConsumer?(makeFrame(pts: pts)) }
    func waitUntilFailureHandlerInstalled() async {
        await withCheckedContinuation { waiter in
            let isAlreadyInstalled = failureLock.withLock {
                if failureHandlers.isEmpty {
                    failureHandlerWaiters.append(waiter)
                    return false
                }
                return true
            }
            if isAlreadyInstalled { waiter.resume() }
        }
    }
    func fail(_ error: CaptureError) {
        failureLock.withLock { failureHandlers.last }?(error)
    }
    func fail(handlerAt index: Int, error: CaptureError) {
        failureLock.withLock { failureHandlers[index] }(error)
    }
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
    let temporaryFile: TemporaryFile; let events: EventRecorder; let finishFailure: Bool; let appendFailure: Bool; let suspendFinish: Bool; var maximumAcceptedFrames: Int?; private(set) var finishCount = 0; private(set) var appendTimestamps: [TimeInterval] = []; private(set) var finishTimestamp: TimeInterval?; private var finishContinuation: CheckedContinuation<Void, Never>?
    init(file: TemporaryFile, events: EventRecorder, finishFailure: Bool, appendFailure: Bool = false, suspendFinish: Bool = false) { temporaryFile = file; self.events = events; self.finishFailure = finishFailure; self.appendFailure = appendFailure; self.suspendFinish = suspendFinish }
    func append(image: CGImage, timestamp: TimeInterval) async throws -> RecordingAppendDisposition {
        if appendFailure { throw FakeError() }
        if let maximumAcceptedFrames, appendTimestamps.count >= maximumAcceptedFrames { return .capacityReached }
        appendTimestamps.append(timestamp)
        return .accepted
    }
    func finish(at timestamp: TimeInterval) async throws -> TemporaryFile { finishCount += 1; finishTimestamp = timestamp; events.values.append("encoder-finish"); if suspendFinish { await withCheckedContinuation { finishContinuation = $0 } }; if finishFailure { throw FakeError() }; return temporaryFile }
    var isFinishSuspended: Bool { finishContinuation != nil }
    func releaseFinish() { finishContinuation?.resume(); finishContinuation = nil }
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
    let events: EventRecorder; let shouldFail: Bool; var notices: [RecordingCompletionNotice?] = []; var metadatas: [GIFPreviewMetadata] = []
    var actions: SaveAndPreviewActions?; var retrySaveCount = 0
    init(events: EventRecorder, shouldFail: Bool = false) { self.events = events; self.shouldFail = shouldFail }
    func present(file: TemporaryFile, metadata: GIFPreviewMetadata, notice: RecordingCompletionNotice?, actions: SaveAndPreviewActions) throws {
        events.values.append("preview")
        if shouldFail { throw FakeError() }
        notices.append(notice)
        metadatas.append(metadata)
        self.actions = actions
    }
    func dismiss() { actions = nil }
    func retrySave() { retrySaveCount += 1 }
    func beginSave() { actions?.saveBegan() }
    func cancelSave() { actions?.saveCancelled() }
    func failSave() { actions?.saveFailed(FakeError()) }
    func reportWarning(_ warning: TemporaryFileStore.SaveWarning) { actions?.saveWarning(warning) }
    func completeSave(_ url: URL) { actions?.saved(url) }
    func requestRerecord() { actions?.rerecord() }
    func completeDiscard() { actions?.discarded() }
}

private final class ManualRecordingClock: RecordingClock, @unchecked Sendable {
    private let lock = NSLock(); private var instant: TimeInterval = 0; private var waiters: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
    func now() -> TimeInterval { lock.withLock { instant } }
    var pendingSleepCount: Int { lock.withLock { waiters.count } }
    func sleep(for duration: TimeInterval) async { await withCheckedContinuation { continuation in lock.withLock { waiters.append((instant + duration, continuation)) } } }
    func advance(by duration: TimeInterval) { let ready: [CheckedContinuation<Void, Never>] = lock.withLock { instant += duration; let values = waiters.filter { $0.0 <= instant }.map(\.1); waiters.removeAll { $0.0 <= instant }; return values }; ready.forEach { $0.resume() } }
}

private final class GateStopRequestScheduler: RecordingStopRequestScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@MainActor @Sendable () async -> Void] = []
    var pendingCount: Int { lock.withLock { operations.count } }
    func schedule(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        lock.withLock { operations.append(operation) }
    }
    func releaseNext() async {
        let operation = lock.withLock { operations.removeFirst() }
        await operation()
    }
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
