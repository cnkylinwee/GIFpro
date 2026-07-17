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

        async let first: Void = harness.coordinator.stop(reason: .manual)
        async let second: Void = harness.coordinator.stop(reason: .diskSpace)
        _ = await (first, second)

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

    init(permission: Bool = true, settings: RecordingSettings = .default, capacity: TemporaryFileStore.CapacityPolicy = .canStart, capacityError: Bool = false, encoderFailure: Bool = false, finishFailure: Bool = false) throws {
        permissions = FakePermissions(granted: permission)
        capture = FakeCapture(events: recorder)
        tempStore = try FakeTempStore(events: recorder, capacity: capacity, capacityError: capacityError)
        preferences = FakePreferences(settings: settings)
        preview = FakePreview(events: recorder)
        encoder = FakeEncoder(file: try tempStore.make(), events: recorder, finishFailure: finishFailure)
        encoderFactory = FakeEncoderFactory(encoder: encoder, shouldFail: encoderFailure)
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
        for _ in 0..<3 {
            await eventually { self.clock.pendingSleepCount == 1 }
            clock.advance(by: 1)
            await Task.yield()
        }
        await eventually { self.capture.startCount == 1 }
    }
}

@MainActor private func eventually(_ predicate: @escaping @MainActor () -> Bool) async {
    for _ in 0..<100 where !predicate() { await Task.yield() }
    XCTAssertTrue(predicate())
}

private final class EventRecorder: @unchecked Sendable { var values: [String] = [] }
private struct FakeError: Error {}

@MainActor private final class FakePermissions: RecordingPermissionAuthorizing {
    let granted: Bool
    init(granted: Bool) { self.granted = granted }
    func requestAccessIfNeeded() -> Bool { granted }
    func recheckAccess() -> Bool { granted }
}

@MainActor private final class FakeSelection: RecordingSelectionPresenting {
    var showCount = 0; var shownSettings: [RecordingSettings] = []; var recordCallbacks: [(CaptureRegion, RecordingSettings) -> Void] = []
    var settingsCallback: ((RecordingSettings) -> Void)?; var cancelCallback: (() -> Void)?; var displayCallback: ((DisplayConfigurationChange) -> Void)?; var events: EventRecorder?
    func show(settings: RecordingSettings, onSettingsChanged: @escaping (RecordingSettings) -> Void, onRecord: @escaping (CaptureRegion, RecordingSettings) -> Void, onCancel: @escaping () -> Void, onDisplayChange: @escaping (DisplayConfigurationChange) -> Void) { showCount += 1; shownSettings.append(settings); settingsCallback = onSettingsChanged; recordCallbacks.append(onRecord); cancelCallback = onCancel; displayCallback = onDisplayChange }
    func dismiss() {}
    func showRecordingVisual() {}
    func showStoppingVisual() { events?.values.append("visual-stopping") }
    func changeSettings(_ value: RecordingSettings) { settingsCallback?(value) }
    func record(_ region: CaptureRegion, _ settings: RecordingSettings) { recordCallbacks.last?(region, settings) }
    func cancel() { cancelCallback?() }
    func displayChange(_ change: DisplayConfigurationChange) { displayCallback?(change) }
}

private final class FakeCapture: RecordingCaptureControlling, @unchecked Sendable {
    let events: EventRecorder; private(set) var startCount = 0; private(set) var stopCount = 0
    init(events: EventRecorder) { self.events = events }
    func start(region: CaptureRegion, settings: RecordingSettings, onFrame: @escaping @Sendable (CapturedFrame) async throws -> Void, onFailure: @escaping @Sendable (CaptureError) -> Void) async throws { startCount += 1 }
    func stop() async throws { stopCount += 1; events.values.append("capture-stop") }
}

private final class FakeProcessor: RecordingFrameProcessing, @unchecked Sendable {
    func process(_ frame: CapturedFrame, targetPixelSize: CGSize) throws -> CGImage { fatalError("not used") }
}

private final class FakeEncoder: RecordingEncoding, @unchecked Sendable {
    let temporaryFile: TemporaryFile; let events: EventRecorder; let finishFailure: Bool; private(set) var finishCount = 0
    init(file: TemporaryFile, events: EventRecorder, finishFailure: Bool) { temporaryFile = file; self.events = events; self.finishFailure = finishFailure }
    func append(image: CGImage, timestamp: TimeInterval) async throws {}
    func finish(at timestamp: TimeInterval) async throws -> TemporaryFile { finishCount += 1; events.values.append("encoder-finish"); if finishFailure { throw FakeError() }; return temporaryFile }
}

@MainActor private final class FakeEncoderFactory: RecordingEncoderFactory {
    let encoder: FakeEncoder; let shouldFail: Bool; var makeCount = 0
    init(encoder: FakeEncoder, shouldFail: Bool) { self.encoder = encoder; self.shouldFail = shouldFail }
    func make(maximumFrames: Int) throws -> any RecordingEncoding { makeCount += 1; if shouldFail { throw FakeError() }; return encoder }
}

@MainActor private final class FakeTempStore: RecordingTemporaryFileManaging {
    let store: TemporaryFileStore; let events: EventRecorder; var capacity: TemporaryFileStore.CapacityPolicy; var capacityError: Bool; var discardCount = 0
    init(events: EventRecorder, capacity: TemporaryFileStore.CapacityPolicy, capacityError: Bool) throws { let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); store = TemporaryFileStore(rootURL: root); self.events = events; self.capacity = capacity; self.capacityError = capacityError }
    func make() throws -> TemporaryFile { try store.makeTemporaryFile() }
    func capacityPolicy() throws -> TemporaryFileStore.CapacityPolicy { if capacityError { throw FakeError() }; return capacity }
    func validatedAccessURL(for file: TemporaryFile) throws -> URL { events.values.append("validate"); return try store.validatedAccessURL(for: file) }
    func discard(_ file: TemporaryFile) throws { discardCount += 1; try store.discardTemporaryFile(file) }
    func cleanupStaleFiles() throws { try store.cleanupStaleFiles() }
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
