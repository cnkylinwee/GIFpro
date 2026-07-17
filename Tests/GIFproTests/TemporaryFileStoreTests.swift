import Foundation
import XCTest
@testable import GIFpro

final class TemporaryFileStoreTests: XCTestCase {
    private let fileManager = FileManager.default
    private var testDirectory: URL!
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("TemporaryFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = testDirectory.appendingPathComponent("GIFpro", isDirectory: true)
        try fileManager.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if testDirectory != nil {
            try? fileManager.removeItem(at: testDirectory)
        }
        rootURL = nil
        testDirectory = nil
        try super.tearDownWithError()
    }

    func testMakeTemporaryFileURLCreatesRootAndReturnsUUIDGIFInsideIt() throws {
        let store = makeStore()

        let url = try store.makeTemporaryFileURL()

        XCTAssertTrue(fileManager.fileExists(atPath: rootURL.path))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, rootURL.standardizedFileURL)
        XCTAssertEqual(url.pathExtension, "gif")
        XCTAssertNotNil(UUID(uuidString: url.deletingPathExtension().lastPathComponent))
    }

    func testMoveTemporaryFileMovesOwnedSourceAndRemovesIt() throws {
        let store = makeStore()
        let source = try store.makeTemporaryFileURL()
        let destination = testDirectory.appendingPathComponent("Saved.gif")
        try Data("gif".utf8).write(to: source)

        try store.moveTemporaryFile(at: source, to: destination)

        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("gif".utf8))
    }

    func testDiscardIsIdempotentForOwnedFile() throws {
        let store = makeStore()
        let source = try store.makeTemporaryFileURL()
        try Data("gif".utf8).write(to: source)

        try store.discardTemporaryFile(at: source)
        try store.discardTemporaryFile(at: source)

        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
    }

    func testCleanupDeletesRootContentsButNeverSiblingFiles() throws {
        let store = makeStore()
        let staleFile = try store.makeTemporaryFileURL()
        let nestedDirectory = rootURL.appendingPathComponent("old", isDirectory: true)
        let nestedFile = nestedDirectory.appendingPathComponent("partial.gif")
        let siblingFile = testDirectory.appendingPathComponent("keep.gif")
        try Data().write(to: staleFile)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data().write(to: nestedFile)
        try Data().write(to: siblingFile)

        try store.cleanupStaleFiles()

        XCTAssertTrue(fileManager.fileExists(atPath: rootURL.path))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: rootURL.path), [])
        XCTAssertTrue(fileManager.fileExists(atPath: siblingFile.path))
    }

    func testDiscardRejectsSourceOutsideOwnedRoot() throws {
        let store = makeStore()
        let outsideFile = testDirectory.appendingPathComponent("outside.gif")
        try Data().write(to: outsideFile)

        XCTAssertThrowsError(try store.discardTemporaryFile(at: outsideFile))
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFile.path))
    }

    func testMoveRejectsSourceOutsideOwnedRoot() throws {
        let store = makeStore()
        let outsideFile = testDirectory.appendingPathComponent("outside.gif")
        let destination = testDirectory.appendingPathComponent("destination.gif")
        try Data().write(to: outsideFile)

        XCTAssertThrowsError(try store.moveTemporaryFile(at: outsideFile, to: destination))
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFile.path))
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
    }

    func testOwnershipRejectsDotDotAndSymlinkEscapes() throws {
        let store = makeStore()
        _ = try store.makeTemporaryFileURL()
        let outsideFile = testDirectory.appendingPathComponent("outside.gif")
        let symlink = rootURL.appendingPathComponent("link.gif")
        try Data().write(to: outsideFile)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: outsideFile)
        let dotDotEscape = rootURL.appendingPathComponent("../outside.gif")

        XCTAssertThrowsError(try store.discardTemporaryFile(at: dotDotEscape))
        XCTAssertThrowsError(try store.discardTemporaryFile(at: symlink))
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFile.path))
    }

    func testCleanupDoesNotFollowSymlinkOutsideOwnedRoot() throws {
        let store = makeStore()
        _ = try store.makeTemporaryFileURL()
        let outsideDirectory = testDirectory.appendingPathComponent("outside", isDirectory: true)
        let outsideFile = outsideDirectory.appendingPathComponent("keep.gif")
        let symlink = rootURL.appendingPathComponent("linked-directory", isDirectory: true)
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data().write(to: outsideFile)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: outsideDirectory)

        XCTAssertThrowsError(try store.cleanupStaleFiles())
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFile.path))
    }

    func testCleanupRejectsRootThatIsItselfASymlink() throws {
        let outsideDirectory = testDirectory.appendingPathComponent("outside-root", isDirectory: true)
        let outsideFile = outsideDirectory.appendingPathComponent("keep.gif")
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data().write(to: outsideFile)
        try fileManager.createSymbolicLink(at: rootURL, withDestinationURL: outsideDirectory)
        let store = makeStore()

        XCTAssertThrowsError(try store.cleanupStaleFiles())
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFile.path))
    }

    func testCapacityPolicyUsesInclusiveStartAndExclusiveStopBoundaries() throws {
        let oneGigabyte: Int64 = 1_000_000_000
        let megabytes256: Int64 = 256_000_000

        XCTAssertEqual(try makeStore(capacity: oneGigabyte).capacityPolicy(), .canStart)
        XCTAssertEqual(try makeStore(capacity: oneGigabyte + 1).capacityPolicy(), .canStart)
        XCTAssertEqual(try makeStore(capacity: oneGigabyte - 1).capacityPolicy(), .continue)
        XCTAssertEqual(try makeStore(capacity: megabytes256).capacityPolicy(), .continue)
        XCTAssertEqual(try makeStore(capacity: megabytes256 - 1).capacityPolicy(), .mustStop)
    }

    func testDefaultCapacityReaderWorksBeforeRootExists() throws {
        let store = TemporaryFileStore(fileManager: fileManager, rootURL: rootURL)

        let policy = try store.capacityPolicy()

        XCTAssertTrue([.canStart, .continue, .mustStop].contains(policy))
        XCTAssertFalse(fileManager.fileExists(atPath: rootURL.path))
    }

    private func makeStore(capacity: Int64 = 2_000_000_000) -> TemporaryFileStore {
        TemporaryFileStore(
            fileManager: fileManager,
            rootURL: rootURL,
            availableCapacity: { capacity }
        )
    }
}
