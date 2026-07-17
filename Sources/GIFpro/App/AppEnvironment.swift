import Foundation
import CoreGraphics

@MainActor
final class AppEnvironment {
    let permissionService: PermissionService
    let coordinator: RecordingCoordinator

    init() {
        let permissionService = PermissionService()
        let selection = SelectionOverlayController()
        let capture = ProductionCaptureController()
        let processor = ProductionFrameProcessor()
        let temporaryFiles = TemporaryFileStore()
        let preferences = PreferencesStore()
        let previewWindow = GIFPreviewWindowController()
        let savePanel = AppKitGIFSavePanelPresenter(previewWindow: previewWindow)
        let systemQuickLook = SystemQuickLookController()
        let preview = SaveAndPreviewController(
            temporaryFiles: temporaryFiles,
            previewWindow: previewWindow,
            savePanel: savePanel,
            systemQuickLook: systemQuickLook
        )
        let encoderFactory = GIFEncoderFactory(store: temporaryFiles)

        self.permissionService = permissionService
        coordinator = RecordingCoordinator(
            permission: permissionService,
            selection: selection,
            capture: capture,
            processor: processor,
            encoderFactory: encoderFactory,
            temporaryFiles: temporaryFiles,
            preferences: preferences,
            preview: preview
        )
    }

    init(
        coordinator: RecordingCoordinator,
        permissionService: PermissionService = PermissionService()
    ) {
        self.coordinator = coordinator
        self.permissionService = permissionService
    }
}

@MainActor
private final class ProductionCaptureController: RecordingCaptureControlling, @unchecked Sendable {
    private var engine: CaptureEngine?

    func start(
        region: CaptureRegion,
        settings: RecordingSettings,
        onFrame: @escaping @Sendable (CapturedFrame) async throws -> Void,
        onFailure: @escaping @Sendable (CaptureError) -> Void
    ) async throws {
        let engine = CaptureEngine(onFailure: onFailure)
        self.engine = engine
        do {
            try await engine.start(region: region, settings: settings, onFrame: onFrame)
        } catch {
            if self.engine === engine { self.engine = nil }
            throw error
        }
    }

    func stop() async throws {
        guard let engine else { return }
        await engine.stop()
        if self.engine === engine { self.engine = nil }
    }
}

@MainActor
private final class GIFEncoderFactory: RecordingEncoderFactory {
    private let store: TemporaryFileStore

    init(store: TemporaryFileStore) { self.store = store }

    func make(maximumFrames: Int) throws -> any RecordingEncoding {
        GIFRecordingEncoder(
            encoder: try GIFStreamEncoder(store: store, maximumFrames: maximumFrames)
        )
    }
}

private final class ProductionFrameProcessor: RecordingFrameProcessing, @unchecked Sendable {
    private let processor = FrameProcessor()

    func process(_ frame: CapturedFrame, targetPixelSize: CGSize) throws -> CGImage {
        try processor.process(pixelBuffer: frame.pixelBuffer, targetPixelSize: targetPixelSize)
    }
}

private actor GIFRecordingEncoder: RecordingEncoding {
    nonisolated let temporaryFile: TemporaryFile
    private let encoder: GIFStreamEncoder

    init(encoder: GIFStreamEncoder) {
        self.encoder = encoder
        temporaryFile = encoder.temporaryFileForDiscardAfterFailure
    }

    func append(image: CGImage, timestamp: TimeInterval) async throws -> RecordingAppendDisposition {
        switch await encoder.append(image: image, timestamp: timestamp) {
        case .accepted:
            return .accepted
        case .rejected(.maximumFrameCountReached):
            return .capacityReached
        case .rejected(let reason):
            throw GIFEncodingAdapterError.rejected(reason)
        }
    }

    func finish(at timestamp: TimeInterval) async throws -> TemporaryFile {
        try await encoder.finish(at: timestamp)
    }
}

extension PermissionService: RecordingPermissionAuthorizing {}
extension PreferencesStore: RecordingPreferencesManaging {}
extension TemporaryFileStore: RecordingTemporaryFileManaging {
    func discard(_ file: TemporaryFile) throws { try discardTemporaryFile(file) }
}

private enum GIFEncodingAdapterError: Error {
    case rejected(GIFStreamEncoder.RejectionReason)
}

extension SelectionOverlayController: RecordingSelectionPresenting {
    func show(
        settings: RecordingSettings,
        onSettingsChanged: @escaping (RecordingSettings) -> Void,
        onRecord: @escaping (CaptureRegion, RecordingSettings) -> Void,
        onCancel: @escaping () -> Void,
        onDisplayChange: @escaping (DisplayConfigurationChange) -> Void
    ) {
        self.onSettingsChanged = onSettingsChanged
        self.onRecord = onRecord
        self.onCancel = onCancel
        onDisplayConfigurationChanged = onDisplayChange
        show(settings: settings)
    }

    func showCountdownVisual(value: Int, targetDisplayID: CGDirectDisplayID) {
        showCountdown(value: value, targetDisplayID: targetDisplayID)
    }

    func updateCountdown(value: Int) { updateCountdown(value) }

    func showRecordingVisual(onStop: @escaping () -> Void) {
        startRecordingVisualState(onStop: onStop)
    }

    func showStoppingVisual() { showStoppingVisualState() }
}
