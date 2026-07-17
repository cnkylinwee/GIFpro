import AppKit
import Darwin
import Foundation
import XCTest
@testable import GIFpro

@MainActor
final class SaveAndPreviewControllerTests: XCTestCase {
    func testPreviewUsesExactChineseActionTitles() {
        XCTAssertEqual(GIFPreviewView.saveButtonTitle, "另存为")
        XCTAssertEqual(GIFPreviewView.rerecordButtonTitle, "重新录制")
        XCTAssertEqual(GIFPreviewView.discardButtonTitle, "丢弃")
    }

    func testPreviewMetadataFormatsDimensionsDurationAndFileSize() {
        let metadata = GIFPreviewMetadata(
            pixelWidth: 320,
            pixelHeight: 240,
            duration: 2.5,
            fileSize: 1_536
        )

        XCTAssertEqual(metadata.dimensionsText, "320 × 240 px")
        XCTAssertEqual(metadata.durationText, "2.50 秒")
        XCTAssertFalse(metadata.fileSizeText.isEmpty)
    }

    func testPresentShowsPreviewThenImmediatelyPresentsTimestampedGIFSavePanel() throws {
        let harness = try PreviewHarness()

        try harness.controller.present(
            file: harness.file,
            metadata: .init(pixelWidth: 320, pixelHeight: 240, duration: 2.5, fileSize: 1234),
            notice: nil,
            actions: harness.actions
        )

        XCTAssertEqual(Array(harness.events.values.prefix(3)), ["validate", "preview", "save-began"])
        XCTAssertEqual(harness.savePanel.configurations.count, 1)
        XCTAssertEqual(harness.savePanel.configurations[0].allowedFileExtension, "gif")
        XCTAssertTrue(harness.savePanel.configurations[0].suggestedFilename.hasPrefix("GIFpro-"))
        XCTAssertTrue(harness.savePanel.configurations[0].suggestedFilename.hasSuffix(".gif"))
    }

    func testSuccessfulSaveMovesThroughStoreClosesPreviewAndOpensSavedQuickLook() throws {
        let harness = try PreviewHarness()
        try harness.present()
        let destination = URL(fileURLWithPath: "/Users/example/Desktop/result.gif")

        harness.savePanel.complete(with: destination)

        XCTAssertEqual(harness.store.savedDestinations, [destination])
        XCTAssertEqual(Array(harness.events.values.suffix(4)), ["save", "close-preview", "saved", "system-quick-look"])
        XCTAssertEqual(harness.quickLook.urls, [destination])
        XCTAssertEqual(harness.actionRecorder.savedURLs, [destination])
        XCTAssertNil(harness.controller.currentTemporaryFile)
    }

    func testCommittedSaveRetainsSessionUntilPendingSourceCleanupRetrySucceeds() throws {
        let harness = try PreviewHarness(saveCleanupPending: true, discardFailures: 1)
        try harness.present()
        let destination = URL(fileURLWithPath: "/Users/example/Desktop/result.gif")

        harness.savePanel.complete(with: destination)

        XCTAssertEqual(harness.store.discardCount, 1)
        XCTAssertTrue(harness.controller.currentTemporaryFile === harness.file)
        XCTAssertTrue(harness.preview.isVisible)
        XCTAssertTrue(harness.actionRecorder.savedURLs.isEmpty)
        XCTAssertTrue(harness.quickLook.urls.isEmpty)

        harness.controller.saveAgain()

        XCTAssertEqual(harness.store.savedDestinations, [destination])
        XCTAssertEqual(harness.store.discardCount, 2)
        XCTAssertNil(harness.controller.currentTemporaryFile)
        XCTAssertEqual(harness.actionRecorder.savedURLs, [destination])
        XCTAssertEqual(harness.quickLook.urls, [destination])
        XCTAssertThrowsError(try harness.store.backingStore.validatedAccessURL(for: harness.file))
    }

    func testRealStoreSourceReplacementCompletesSaveWithoutDeletingReplacement() throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = testDirectory.appendingPathComponent("root", isDirectory: true)
        try fileManager.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testDirectory) }

        let sourceURL = PreviewLockedBox<URL?>(nil)
        let movedOriginal = root.appendingPathComponent("moved-original.gif")
        var operations = TemporaryFileStore.FileOperations.posix
        let replace = operations.replaceStaging
        operations.replaceStaging = { descriptor, stagingName, destinationName in
            try replace(descriptor, stagingName, destinationName)
            guard let sourceURL = sourceURL.value else { throw PreviewTestError.expected }
            try FileManager.default.moveItem(at: sourceURL, to: movedOriginal)
            try Data("replacement".utf8).write(to: sourceURL)
        }
        let store = TemporaryFileStore(rootURL: root, fileOperations: operations)
        var file: TemporaryFile? = try store.makeTemporaryFile()
        let weakFile = WeakTemporaryFileReference(file)
        sourceURL.set(root.appendingPathComponent(try XCTUnwrap(file).name))
        try XCTUnwrap(file).withFileDescriptor { descriptor in
            _ = Data("owned".utf8).withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        }
        let events = PreviewEventRecorder()
        let preview = FakePreviewWindow(events: events)
        let savePanel = FakeSavePanel(events: events)
        let quickLook = FakeSystemQuickLook(events: events)
        let actions = FakePreviewActions(events: events)
        let controller = SaveAndPreviewController(
            temporaryFiles: store,
            previewWindow: preview,
            savePanel: savePanel,
            systemQuickLook: quickLook
        )
        try controller.present(
            file: try XCTUnwrap(file),
            metadata: .init(pixelWidth: 1, pixelHeight: 1, duration: 1, fileSize: 5),
            notice: nil,
            actions: actions.actions
        )
        let destination = testDirectory.appendingPathComponent("saved.gif")

        savePanel.complete(with: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("owned".utf8))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(sourceURL.value)), Data("replacement".utf8))
        XCTAssertEqual(actions.warnings, [.sourceChanged])
        XCTAssertEqual(actions.savedURLs, [destination])
        XCTAssertEqual(quickLook.urls, [destination])
        XCTAssertNil(controller.currentTemporaryFile)
        file = nil
        XCTAssertNil(weakFile.value)
    }

    func testSaveCancellationReturnsToPreviewReadyAndRetainsTemporaryFileAndPanel() throws {
        let harness = try PreviewHarness()
        try harness.present()

        harness.savePanel.complete(with: nil)

        XCTAssertEqual(harness.actionRecorder.cancelCount, 1)
        XCTAssertTrue(harness.preview.isVisible)
        XCTAssertTrue(harness.controller.currentTemporaryFile === harness.file)
        XCTAssertEqual(harness.store.discardCount, 0)
    }

    func testMoveFailureReturnsToPreviewAndCanRetry() throws {
        let harness = try PreviewHarness(saveFailures: 1)
        try harness.present()
        let first = URL(fileURLWithPath: "/Users/example/Desktop/first.gif")
        let second = URL(fileURLWithPath: "/Users/example/Desktop/second.gif")

        harness.savePanel.complete(with: first)
        XCTAssertEqual(harness.actionRecorder.failureCount, 1)
        XCTAssertTrue(harness.preview.isVisible)
        XCTAssertTrue(harness.controller.currentTemporaryFile === harness.file)

        harness.controller.saveAgain()
        harness.savePanel.complete(with: second)

        XCTAssertEqual(harness.store.savedDestinations, [first, second])
        XCTAssertEqual(harness.actionRecorder.savedURLs, [second])
        XCTAssertEqual(harness.quickLook.urls, [second])
    }

    func testRerecordDiscardsBeforeRequestingSelectionAndIsExactlyOnce() throws {
        let harness = try PreviewHarness()
        try harness.present()
        harness.savePanel.complete(with: nil)

        harness.controller.rerecord()
        harness.controller.rerecord()

        XCTAssertEqual(Array(harness.events.values.suffix(3)), ["discard", "close-preview", "rerecord"])
        XCTAssertEqual(harness.store.discardCount, 1)
        XCTAssertEqual(harness.actionRecorder.rerecordCount, 1)
    }

    func testDiscardDeletesBeforeReturningIdleAndIsExactlyOnce() throws {
        let harness = try PreviewHarness()
        try harness.present()
        harness.savePanel.complete(with: nil)

        harness.controller.discard()
        harness.controller.discard()

        XCTAssertEqual(Array(harness.events.values.suffix(3)), ["discard", "close-preview", "discarded"])
        XCTAssertEqual(harness.store.discardCount, 1)
        XCTAssertEqual(harness.actionRecorder.discardedCount, 1)
    }

    func testDoubleSaveClickDoesNotPresentConcurrentPanels() throws {
        let harness = try PreviewHarness()
        try harness.present()

        harness.controller.saveAgain()
        harness.controller.saveAgain()

        XCTAssertEqual(harness.savePanel.configurations.count, 1)
    }

    func testDismissDuringSaveInvalidatesLatePanelCompletion() throws {
        let harness = try PreviewHarness()
        try harness.present()

        harness.controller.dismiss()
        harness.savePanel.complete(with: URL(fileURLWithPath: "/tmp/late.gif"))

        XCTAssertNil(harness.controller.currentTemporaryFile)
        XCTAssertTrue(harness.store.savedDestinations.isEmpty)
        XCTAssertTrue(harness.quickLook.urls.isEmpty)
    }

    func testAppKitSavePanelIgnoresLateCompletionFromCancelledPriorPanel() {
        let previewWindow = GIFPreviewWindowController()
        var panels: [NSSavePanel] = []
        var completions: [ObjectIdentifier: (NSApplication.ModalResponse) -> Void] = [:]
        var cancelled: [ObjectIdentifier] = []
        let presenter = AppKitGIFSavePanelPresenter(
            previewWindow: previewWindow,
            panelFactory: {
                let panel = NSSavePanel()
                panels.append(panel)
                return panel
            },
            beginPanel: { panel, _, completion in completions[ObjectIdentifier(panel)] = completion },
            cancelPanel: { panel in cancelled.append(ObjectIdentifier(panel)) }
        )
        let configuration = GIFSavePanelConfiguration(
            suggestedFilename: "test.gif",
            allowedFileExtension: "gif"
        )
        var results: [String] = []

        presenter.present(configuration: configuration) { _ in results.append("A") }
        let firstID = try! XCTUnwrap(completions.keys.first)
        let firstCompletion = try! XCTUnwrap(completions[firstID])
        presenter.cancel()
        presenter.present(configuration: configuration) { _ in results.append("B") }
        let secondID = try! XCTUnwrap(completions.keys.first { $0 != firstID })

        firstCompletion(.cancel)
        presenter.cancel()

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(cancelled, [firstID, secondID])
    }

    func testRootOrLeafValidationFailureDoesNotExposeURLOrPresentSavePanel() throws {
        let harness = try PreviewHarness(validationFailure: true)

        XCTAssertThrowsError(try harness.present())

        XCTAssertTrue(harness.preview.presentedURLs.isEmpty)
        XCTAssertTrue(harness.savePanel.configurations.isEmpty)
        XCTAssertNil(harness.controller.currentTemporaryFile)
    }
}

@MainActor
private final class PreviewHarness {
    let events: PreviewEventRecorder
    let store: FakePreviewTemporaryStore
    let preview: FakePreviewWindow
    let savePanel: FakeSavePanel
    let quickLook: FakeSystemQuickLook
    let actionRecorder: FakePreviewActions
    let controller: SaveAndPreviewController
    let file: TemporaryFile

    init(saveFailures: Int = 0, validationFailure: Bool = false, saveCleanupPending: Bool = false, discardFailures: Int = 0) throws {
        events = PreviewEventRecorder()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backingStore = TemporaryFileStore(rootURL: root)
        file = try backingStore.makeTemporaryFile()
        store = FakePreviewTemporaryStore(
            backingStore: backingStore,
            events: events,
            saveFailures: saveFailures,
            validationFailure: validationFailure,
            saveCleanupPending: saveCleanupPending,
            discardFailures: discardFailures
        )
        preview = FakePreviewWindow(events: events)
        savePanel = FakeSavePanel(events: events)
        quickLook = FakeSystemQuickLook(events: events)
        actionRecorder = FakePreviewActions(events: events)
        controller = SaveAndPreviewController(
            temporaryFiles: store,
            previewWindow: preview,
            savePanel: savePanel,
            systemQuickLook: quickLook,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    var actions: SaveAndPreviewActions { actionRecorder.actions }

    func present() throws {
        try controller.present(
            file: file,
            metadata: .init(pixelWidth: 320, pixelHeight: 240, duration: 2.5, fileSize: 1234),
            notice: nil,
            actions: actions
        )
    }
}

private final class PreviewEventRecorder {
    var values: [String] = []
}

@MainActor
private final class FakePreviewTemporaryStore: PreviewTemporaryFileManaging {
    let backingStore: TemporaryFileStore
    let events: PreviewEventRecorder
    var remainingSaveFailures: Int
    let validationFailure: Bool
    let saveCleanupPending: Bool
    var remainingDiscardFailures: Int
    var savedDestinations: [URL] = []
    var discardCount = 0

    init(backingStore: TemporaryFileStore, events: PreviewEventRecorder, saveFailures: Int, validationFailure: Bool, saveCleanupPending: Bool, discardFailures: Int) {
        self.backingStore = backingStore
        self.events = events
        remainingSaveFailures = saveFailures
        self.validationFailure = validationFailure
        self.saveCleanupPending = saveCleanupPending
        remainingDiscardFailures = discardFailures
    }

    func validatedAccessURL(for file: TemporaryFile) throws -> URL {
        events.values.append("validate")
        if validationFailure { throw PreviewTestError.expected }
        return try backingStore.validatedAccessURL(for: file)
    }

    func save(_ file: TemporaryFile, to destinationURL: URL) throws -> TemporaryFileStore.SaveResult {
        events.values.append("save")
        savedDestinations.append(destinationURL)
        if remainingSaveFailures > 0 {
            remainingSaveFailures -= 1
            throw PreviewTestError.expected
        }
        if !saveCleanupPending {
            try backingStore.discardTemporaryFile(file)
        }
        return .saved(destinationURL: destinationURL, cleanupPending: saveCleanupPending)
    }

    func discard(_ file: TemporaryFile) throws {
        events.values.append("discard")
        discardCount += 1
        if remainingDiscardFailures > 0 {
            remainingDiscardFailures -= 1
            throw PreviewTestError.expected
        }
        try backingStore.discardTemporaryFile(file)
    }
}

@MainActor
private final class FakePreviewWindow: GIFPreviewWindowPresenting {
    let events: PreviewEventRecorder
    var presentedURLs: [URL] = []
    var isVisible = false
    init(events: PreviewEventRecorder) { self.events = events }
    func present(url: URL, metadata: GIFPreviewMetadata, notice: RecordingCompletionNotice?, actions: GIFPreviewViewActions) {
        events.values.append("preview")
        presentedURLs.append(url)
        isVisible = true
    }
    func close() { events.values.append("close-preview"); isVisible = false }
}

@MainActor
private final class FakeSavePanel: GIFSavePanelPresenting {
    let events: PreviewEventRecorder
    var configurations: [GIFSavePanelConfiguration] = []
    private var completion: (@MainActor (URL?) -> Void)?
    init(events: PreviewEventRecorder) { self.events = events }
    func present(configuration: GIFSavePanelConfiguration, completion: @escaping @MainActor (URL?) -> Void) {
        events.values.append("save-began")
        configurations.append(configuration)
        self.completion = completion
    }
    func complete(with url: URL?) { let completion = completion; self.completion = nil; completion?(url) }
    func cancel() { completion = nil }
}

@MainActor
private final class FakeSystemQuickLook: SystemQuickLookPresenting {
    let events: PreviewEventRecorder
    var urls: [URL] = []
    init(events: PreviewEventRecorder) { self.events = events }
    func present(url: URL) { events.values.append("system-quick-look"); urls.append(url) }
}

@MainActor
private final class FakePreviewActions {
    let events: PreviewEventRecorder
    var cancelCount = 0
    var failureCount = 0
    var savedURLs: [URL] = []
    var rerecordCount = 0
    var discardedCount = 0
    var warnings: [TemporaryFileStore.SaveWarning] = []
    init(events: PreviewEventRecorder) { self.events = events }

    var actions: SaveAndPreviewActions {
        SaveAndPreviewActions(
            saveBegan: {},
            saveCancelled: { [weak self] in self?.cancelCount += 1 },
            saveFailed: { [weak self] _ in self?.failureCount += 1 },
            saveWarning: { [weak self] warning in self?.warnings.append(warning) },
            saved: { [weak self] url in self?.events.values.append("saved"); self?.savedURLs.append(url) },
            rerecord: { [weak self] in self?.events.values.append("rerecord"); self?.rerecordCount += 1 },
            discarded: { [weak self] in self?.events.values.append("discarded"); self?.discardedCount += 1 }
        )
    }
}

private enum PreviewTestError: Error { case expected }

private final class PreviewLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func set(_ value: Value) { lock.withLock { storage = value } }
}

private final class WeakTemporaryFileReference {
    weak var value: TemporaryFile?
    init(_ value: TemporaryFile?) { self.value = value }
}
