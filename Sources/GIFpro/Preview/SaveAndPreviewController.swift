import Foundation

struct GIFPreviewMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let fileSize: Int64

    var dimensionsText: String { "\(pixelWidth) × \(pixelHeight) px" }
    var durationText: String { String(format: "%.2f 秒", duration) }
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }
}

struct GIFPreviewViewActions {
    let saveAgain: @MainActor () -> Void
    let rerecord: @MainActor () -> Void
    let discard: @MainActor () -> Void
}

struct GIFSavePanelConfiguration: Equatable, Sendable {
    let suggestedFilename: String
    let allowedFileExtension: String
}

@MainActor
protocol PreviewTemporaryFileManaging: AnyObject {
    func validatedAccessURL(for file: TemporaryFile) throws -> URL
    func save(_ file: TemporaryFile, to destinationURL: URL) throws -> TemporaryFileStore.SaveResult
    func discard(_ file: TemporaryFile) throws
}

@MainActor
protocol GIFPreviewWindowPresenting: AnyObject {
    func present(
        url: URL,
        metadata: GIFPreviewMetadata,
        notice: RecordingCompletionNotice?,
        actions: GIFPreviewViewActions
    )
    func close()
}

@MainActor
protocol GIFSavePanelPresenting: AnyObject {
    func present(
        configuration: GIFSavePanelConfiguration,
        completion: @escaping @MainActor (URL?) -> Void
    )
    func cancel()
}

@MainActor
protocol SystemQuickLookPresenting: AnyObject {
    func present(url: URL)
}

struct SaveAndPreviewActions {
    let saveBegan: @MainActor () -> Void
    let saveCancelled: @MainActor () -> Void
    let saveFailed: @MainActor (Error) -> Void
    let saved: @MainActor (URL) -> Void
    let rerecord: @MainActor () -> Void
    let discarded: @MainActor () -> Void
}

@MainActor
final class SaveAndPreviewController: RecordingPreviewPresenting {
    enum ControllerError: Error {
        case presentationAlreadyActive
    }

    private struct Session {
        let id: UUID
        let file: TemporaryFile
        let actions: SaveAndPreviewActions
    }

    private let temporaryFiles: any PreviewTemporaryFileManaging
    private let previewWindow: any GIFPreviewWindowPresenting
    private let savePanel: any GIFSavePanelPresenting
    private let systemQuickLook: any SystemQuickLookPresenting
    private let now: () -> Date
    private var session: Session?
    private var saveIsActive = false

    var currentTemporaryFile: TemporaryFile? { session?.file }

    init(
        temporaryFiles: any PreviewTemporaryFileManaging,
        previewWindow: any GIFPreviewWindowPresenting,
        savePanel: any GIFSavePanelPresenting,
        systemQuickLook: any SystemQuickLookPresenting,
        now: @escaping () -> Date = Date.init
    ) {
        self.temporaryFiles = temporaryFiles
        self.previewWindow = previewWindow
        self.savePanel = savePanel
        self.systemQuickLook = systemQuickLook
        self.now = now
    }

    func present(
        file: TemporaryFile,
        metadata: GIFPreviewMetadata,
        notice: RecordingCompletionNotice?,
        actions: SaveAndPreviewActions
    ) throws {
        guard session == nil else { throw ControllerError.presentationAlreadyActive }
        // Quick Look is path-only. Resolve the lexical URL immediately before
        // handing it to the preview adapter and never retain it in this controller.
        let accessURL = try temporaryFiles.validatedAccessURL(for: file)
        session = Session(id: UUID(), file: file, actions: actions)
        previewWindow.present(
            url: accessURL,
            metadata: metadata,
            notice: notice,
            actions: GIFPreviewViewActions(
                saveAgain: { [weak self] in self?.saveAgain() },
                rerecord: { [weak self] in self?.rerecord() },
                discard: { [weak self] in self?.discard() }
            )
        )
        beginSave()
    }

    func dismiss() {
        session = nil
        saveIsActive = false
        savePanel.cancel()
        previewWindow.close()
    }

    func saveAgain() {
        beginSave()
    }

    func rerecord() {
        guard !saveIsActive, let current = takeSession() else { return }
        do {
            try temporaryFiles.discard(current.file)
            previewWindow.close()
            current.actions.rerecord()
        } catch {
            session = current
            current.actions.saveFailed(error)
        }
    }

    func discard() {
        guard !saveIsActive, let current = takeSession() else { return }
        do {
            try temporaryFiles.discard(current.file)
            previewWindow.close()
            current.actions.discarded()
        } catch {
            session = current
            current.actions.saveFailed(error)
        }
    }

    private func beginSave() {
        guard !saveIsActive, let session else { return }
        saveIsActive = true
        session.actions.saveBegan()
        let sessionID = session.id
        savePanel.present(configuration: savePanelConfiguration()) { [weak self] destination in
            self?.completeSave(destination: destination, sessionID: sessionID)
        }
    }

    private func completeSave(destination: URL?, sessionID: UUID) {
        guard saveIsActive, let current = session, current.id == sessionID else { return }
        saveIsActive = false
        guard let destination else {
            current.actions.saveCancelled()
            return
        }
        do {
            let result = try temporaryFiles.save(current.file, to: destination)
            if result.cleanupPending {
                try? temporaryFiles.discard(current.file)
            }
            session = nil
            previewWindow.close()
            current.actions.saved(result.destinationURL)
            systemQuickLook.present(url: result.destinationURL)
        } catch {
            current.actions.saveFailed(error)
        }
    }

    private func takeSession() -> Session? {
        defer { session = nil }
        return session
    }

    private func savePanelConfiguration() -> GIFSavePanelConfiguration {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return GIFSavePanelConfiguration(
            suggestedFilename: "GIFpro-\(formatter.string(from: now())).gif",
            allowedFileExtension: "gif"
        )
    }
}

extension TemporaryFileStore: PreviewTemporaryFileManaging {
    func save(_ file: TemporaryFile, to destinationURL: URL) throws -> SaveResult {
        try saveTemporaryFile(file, to: destinationURL)
    }
}
