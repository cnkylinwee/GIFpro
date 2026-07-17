import Darwin
import Foundation
import XCTest
@testable import GIFpro

final class TemporaryFileStoreTests: XCTestCase {
    private enum TestError: Error { case injected }

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

    func testMakeTemporaryFileSecurelyCreatesUUIDGIFInsideRoot() throws {
        let temporaryFile = try makeStore().makeTemporaryFile()

        XCTAssertTrue(fileManager.fileExists(atPath: rootURL.path))
        XCTAssertEqual(URL(fileURLWithPath: temporaryFile.name).pathExtension, "gif")
        XCTAssertNotNil(UUID(uuidString: temporaryFile.name.dropLast(4).description))
        XCTAssertTrue(fileManager.fileExists(atPath: lexicalURL(for: temporaryFile).path))
        let descriptor = rootFD()
        defer { close(descriptor) }
        var status = stat()
        XCTAssertEqual(temporaryFile.name.withCString { fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }, 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
    }

    func testMakeAfterRootSwapCreatesOnlyInPinnedDirectory() throws {
        let store = makeStore()
        _ = try store.makeTemporaryFile()
        let movedRoot = testDirectory.appendingPathComponent("original-root", isDirectory: true)
        try fileManager.moveItem(at: rootURL, to: movedRoot)
        let outsideDirectory = testDirectory.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: rootURL, withDestinationURL: outsideDirectory)

        let temporaryFile = try store.makeTemporaryFile()
        try write(Data("owned".utf8), to: temporaryFile)

        XCTAssertEqual(
            try Data(contentsOf: movedRoot.appendingPathComponent(temporaryFile.name)),
            Data("owned".utf8)
        )
        XCTAssertFalse(fileManager.fileExists(atPath: outsideDirectory.appendingPathComponent(temporaryFile.name).path))
    }

    func testMakeRejectsSymlinkAndNonDirectoryRoots() throws {
        let outsideDirectory = testDirectory.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: rootURL, withDestinationURL: outsideDirectory)
        XCTAssertThrowsError(try makeStore().makeTemporaryFile())
        try fileManager.removeItem(at: rootURL)
        try Data("not-directory".utf8).write(to: rootURL)
        XCTAssertThrowsError(try makeStore().makeTemporaryFile())
    }

    func testValidatedAccessURLReturnsCurrentOwnedPath() throws {
        let store = makeStore()
        let temporaryFile = try store.makeTemporaryFile()

        let accessURL = try store.validatedAccessURL(for: temporaryFile)

        XCTAssertEqual(accessURL, rootURL.appendingPathComponent(temporaryFile.name))
    }

    func testValidatedAccessURLRejectsRootSwap() throws {
        let store = makeStore()
        let temporaryFile = try store.makeTemporaryFile()
        let movedRoot = testDirectory.appendingPathComponent("original-root", isDirectory: true)
        try fileManager.moveItem(at: rootURL, to: movedRoot)
        let outsideDirectory = testDirectory.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: rootURL, withDestinationURL: outsideDirectory)

        XCTAssertThrowsError(try store.validatedAccessURL(for: temporaryFile))
    }

    func testValidatedAccessURLRejectsLeafSwapAndMissingLeaf() throws {
        let store = makeStore()
        let temporaryFile = try store.makeTemporaryFile()
        let lexicalURL = rootURL.appendingPathComponent(temporaryFile.name)
        let movedOriginal = rootURL.appendingPathComponent("moved-original.gif")
        try fileManager.moveItem(at: lexicalURL, to: movedOriginal)
        try Data("replacement".utf8).write(to: lexicalURL)

        XCTAssertThrowsError(try store.validatedAccessURL(for: temporaryFile))

        try fileManager.removeItem(at: lexicalURL)
        XCTAssertThrowsError(try store.validatedAccessURL(for: temporaryFile))
    }

    func testTemporaryFileDescriptorClosesExactlyOnceAndDuplicatesRemainCallerOwned() throws {
        var temporaryFile: TemporaryFile? = try makeStore().makeTemporaryFile()
        let borrowedDescriptor = temporaryFile!.withFileDescriptor { $0 }
        let duplicate = try temporaryFile!.duplicateFileDescriptor()
        XCTAssertNotEqual(fcntl(borrowedDescriptor, F_GETFD), -1)

        temporaryFile = nil

        XCTAssertEqual(fcntl(borrowedDescriptor, F_GETFD), -1)
        XCTAssertNotEqual(fcntl(duplicate, F_GETFD), -1)
        XCTAssertEqual(close(duplicate), 0)
    }

    func testRepeatedTemporaryFileLifetimesDoNotLeakDescriptors() throws {
        let store = makeStore()
        for _ in 0..<100 {
            var borrowedDescriptor: Int32 = -1
            do {
                let temporaryFile = try store.makeTemporaryFile()
                borrowedDescriptor = temporaryFile.withFileDescriptor { $0 }
                XCTAssertNotEqual(fcntl(borrowedDescriptor, F_GETFD), -1)
            }
            XCTAssertEqual(fcntl(borrowedDescriptor, F_GETFD), -1)
        }

        try store.cleanupStaleFiles()
    }

    func testDiscardIsIdempotentForOwnedHandle() throws {
        let store = makeStore()
        let temporaryFile = try store.makeTemporaryFile()
        try write(Data("gif".utf8), to: temporaryFile)

        try store.discardTemporaryFile(temporaryFile)
        try store.discardTemporaryFile(temporaryFile)

        XCTAssertFalse(fileManager.fileExists(atPath: lexicalURL(for: temporaryFile).path))
    }

    func testForeignStoreHandleCannotBeDiscardedOrSaved() throws {
        let otherRoot = testDirectory.appendingPathComponent("Other", isDirectory: true)
        let foreignFile = try TemporaryFileStore(
            fileManager: fileManager,
            rootURL: otherRoot,
            availableCapacity: { 2_000_000_000 }
        ).makeTemporaryFile()
        try write(Data("foreign".utf8), to: foreignFile)
        let store = makeStore()

        XCTAssertThrowsError(try store.discardTemporaryFile(foreignFile))
        XCTAssertThrowsError(
            try store.saveTemporaryFile(foreignFile, to: testDirectory.appendingPathComponent("saved.gif"))
        )
        XCTAssertEqual(try read(from: foreignFile), Data("foreign".utf8))
    }

    func testDiscardRejectsLeafSwapToSymlinkWithoutTouchingTargets() throws {
        let store = makeStore()
        let temporaryFile = try store.makeTemporaryFile()
        try write(Data("owned".utf8), to: temporaryFile)
        let movedOriginal = rootURL.appendingPathComponent("moved-original.gif")
        try fileManager.moveItem(at: lexicalURL(for: temporaryFile), to: movedOriginal)
        let outsideTarget = testDirectory.appendingPathComponent("outside.gif")
        try Data("outside".utf8).write(to: outsideTarget)
        try fileManager.createSymbolicLink(at: lexicalURL(for: temporaryFile), withDestinationURL: outsideTarget)

        XCTAssertThrowsError(try store.discardTemporaryFile(temporaryFile))

        XCTAssertEqual(try Data(contentsOf: movedOriginal), Data("owned".utf8))
        XCTAssertEqual(try Data(contentsOf: outsideTarget), Data("outside".utf8))
    }

    func testCleanupDeletesRootContentsButNeverSiblingOrSymlinkTargets() throws {
        let store = makeStore()
        let stale = try store.makeTemporaryFile()
        try write(Data(), to: stale)
        let nestedDirectory = rootURL.appendingPathComponent("old", isDirectory: true)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data().write(to: nestedDirectory.appendingPathComponent("partial.gif"))
        let sibling = testDirectory.appendingPathComponent("keep.gif")
        try Data("keep".utf8).write(to: sibling)

        try store.cleanupStaleFiles()

        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: rootURL.path), [])
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
    }

    func testCleanupRejectsSymlinkEntryWithoutFollowingIt() throws {
        let store = makeStore()
        _ = try store.makeTemporaryFile()
        let outside = testDirectory.appendingPathComponent("outside.gif")
        try Data("outside".utf8).write(to: outside)
        try fileManager.createSymbolicLink(
            at: rootURL.appendingPathComponent("link.gif"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try store.cleanupStaleFiles())
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testSaveReplacesExistingDestinationAndRemovesMatchingSource() throws {
        let store = makeStore()
        let temporaryFile = try store.makeTemporaryFile()
        let destination = testDirectory.appendingPathComponent("saved.gif")
        try write(Data("new".utf8), to: temporaryFile)
        try Data("old".utf8).write(to: destination)

        let result = try store.saveTemporaryFile(temporaryFile, to: destination)

        XCTAssertEqual(result, .saved(destinationURL: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: lexicalURL(for: temporaryFile).path))
    }

    func testSaveAfterRootSwapUsesPinnedSourceAndLeavesOutsideFileUntouched() throws {
        let store = makeStore()
        let temporaryFile = try store.makeTemporaryFile()
        try write(Data("owned".utf8), to: temporaryFile)
        let movedRoot = testDirectory.appendingPathComponent("original-root", isDirectory: true)
        try fileManager.moveItem(at: rootURL, to: movedRoot)
        let outsideDirectory = testDirectory.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideFile = outsideDirectory.appendingPathComponent(temporaryFile.name)
        try Data("outside".utf8).write(to: outsideFile)
        try fileManager.createSymbolicLink(at: rootURL, withDestinationURL: outsideDirectory)
        let destination = testDirectory.appendingPathComponent("saved.gif")

        let result = try store.saveTemporaryFile(temporaryFile, to: destination)

        XCTAssertEqual(result, .saved(destinationURL: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("owned".utf8))
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: movedRoot.appendingPathComponent(temporaryFile.name).path))
    }

    func testCopyFailureBeforeCommitPreservesDestinationSourceAndCleansStaging() throws {
        var operations = TemporaryFileStore.FileOperations.posix
        operations.copyBytes = { _, _ in throw TestError.injected }
        try assertPrecommitFailurePreservesFiles(operations: operations)
    }

    func testStagingFsyncFailureBeforeCommitPreservesDestinationSourceAndCleansStaging() throws {
        var operations = TemporaryFileStore.FileOperations.posix
        operations.syncStaging = { _ in throw TestError.injected }
        try assertPrecommitFailurePreservesFiles(operations: operations)
    }

    func testRenameFailureBeforeCommitPreservesDestinationSourceAndCleansStaging() throws {
        var operations = TemporaryFileStore.FileOperations.posix
        operations.replaceStaging = { _, _, _ in throw TestError.injected }
        try assertPrecommitFailurePreservesFiles(operations: operations)
    }

    func testDirectoryFsyncFailureAfterCommitReturnsWarningWithoutThrowing() throws {
        var operations = TemporaryFileStore.FileOperations.posix
        operations.syncDestinationDirectory = { _ in throw TestError.injected }
        let store = makeStore(fileOperations: operations)
        let temporaryFile = try store.makeTemporaryFile()
        let destination = testDirectory.appendingPathComponent("saved.gif")
        try write(Data("new".utf8), to: temporaryFile)
        try Data("old".utf8).write(to: destination)

        let result = try store.saveTemporaryFile(temporaryFile, to: destination)

        XCTAssertEqual(
            result,
            .saved(destinationURL: destination, warnings: [.destinationDirectorySyncFailed])
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: lexicalURL(for: temporaryFile).path))
    }

    func testUnlinkFailureAfterCommitReturnsCleanupPendingWithoutThrowing() throws {
        var operations = TemporaryFileStore.FileOperations.posix
        operations.unlinkSource = { _, _ in throw TestError.injected }
        let store = makeStore(fileOperations: operations)
        let temporaryFile = try store.makeTemporaryFile()
        let destination = testDirectory.appendingPathComponent("saved.gif")
        try write(Data("new".utf8), to: temporaryFile)

        let result = try store.saveTemporaryFile(temporaryFile, to: destination)

        XCTAssertEqual(
            result,
            .saved(
                destinationURL: destination,
                cleanupPending: true,
                warnings: [.sourceCleanupFailed]
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertEqual(try read(from: temporaryFile), Data("new".utf8))
        XCTAssertTrue(fileManager.fileExists(atPath: lexicalURL(for: temporaryFile).path))
    }

    func testSourceAlreadyMissingAfterCommitIsNotCleanupPending() throws {
        var sourceURL: URL!
        var operations = TemporaryFileStore.FileOperations.posix
        let replace = operations.replaceStaging
        operations.replaceStaging = { descriptor, stagingName, destinationName in
            try replace(descriptor, stagingName, destinationName)
            try self.fileManager.removeItem(at: sourceURL)
        }
        let store = makeStore(fileOperations: operations)
        let temporaryFile = try store.makeTemporaryFile()
        sourceURL = lexicalURL(for: temporaryFile)
        try write(Data("owned".utf8), to: temporaryFile)
        let destination = testDirectory.appendingPathComponent("saved.gif")

        let result = try store.saveTemporaryFile(temporaryFile, to: destination)

        XCTAssertEqual(result, .saved(destinationURL: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("owned".utf8))
    }

    func testLeafSwapAfterCommitIsNotUnlinkedAndReturnsCleanupPending() throws {
        var sourceURL: URL!
        var movedOriginal: URL!
        var operations = TemporaryFileStore.FileOperations.posix
        let replace = operations.replaceStaging
        operations.replaceStaging = { descriptor, stagingName, destinationName in
            try replace(descriptor, stagingName, destinationName)
            try self.fileManager.moveItem(at: sourceURL, to: movedOriginal)
            try Data("replacement".utf8).write(to: sourceURL)
        }
        let store = makeStore(fileOperations: operations)
        let temporaryFile = try store.makeTemporaryFile()
        sourceURL = lexicalURL(for: temporaryFile)
        movedOriginal = rootURL.appendingPathComponent("moved-original.gif")
        try write(Data("owned".utf8), to: temporaryFile)
        let destination = testDirectory.appendingPathComponent("saved.gif")

        let result = try store.saveTemporaryFile(temporaryFile, to: destination)

        XCTAssertEqual(
            result,
            .saved(destinationURL: destination, cleanupPending: true, warnings: [.sourceChanged])
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("owned".utf8))
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: movedOriginal), Data("owned".utf8))
    }

    func testCapacityPolicyUsesInclusiveStartAndExclusiveStopBoundaries() throws {
        XCTAssertEqual(try makeStore(capacity: 1_000_000_000).capacityPolicy(), .canStart)
        XCTAssertEqual(try makeStore(capacity: 999_999_999).capacityPolicy(), .continue)
        XCTAssertEqual(try makeStore(capacity: 256_000_000).capacityPolicy(), .continue)
        XCTAssertEqual(try makeStore(capacity: 255_999_999).capacityPolicy(), .mustStop)
    }

    func testDefaultCapacityReaderWorksBeforeRootExists() throws {
        let store = TemporaryFileStore(fileManager: fileManager, rootURL: rootURL)
        XCTAssertNoThrow(try store.capacityPolicy())
        XCTAssertFalse(fileManager.fileExists(atPath: rootURL.path))
    }

    private func assertPrecommitFailurePreservesFiles(
        operations: TemporaryFileStore.FileOperations
    ) throws {
        let store = makeStore(fileOperations: operations)
        let temporaryFile = try store.makeTemporaryFile()
        let destination = testDirectory.appendingPathComponent("saved.gif")
        try write(Data("new".utf8), to: temporaryFile)
        try Data("old".utf8).write(to: destination)

        XCTAssertThrowsError(try store.saveTemporaryFile(temporaryFile, to: destination))

        XCTAssertEqual(try read(from: temporaryFile), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: testDirectory.path)
                .filter { $0.hasPrefix(".gifpro-") },
            []
        )
    }

    private func makeStore(
        capacity: Int64 = 2_000_000_000,
        fileOperations: TemporaryFileStore.FileOperations = .posix
    ) -> TemporaryFileStore {
        TemporaryFileStore(
            fileManager: fileManager,
            rootURL: rootURL,
            availableCapacity: { capacity },
            fileOperations: fileOperations
        )
    }

    private func write(_ data: Data, to temporaryFile: TemporaryFile) throws {
        let descriptor = try temporaryFile.duplicateFileDescriptor()
        defer { close(descriptor) }
        guard ftruncate(descriptor, 0) == 0 else { throw TestError.injected }
        let written = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == data.count else { throw TestError.injected }
    }

    private func read(from temporaryFile: TemporaryFile) throws -> Data {
        let descriptor = try temporaryFile.duplicateFileDescriptor()
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw TestError.injected }
        var data = Data(count: Int(status.st_size))
        let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw TestError.injected }
        return data
    }

    private func rootFD() -> Int32 {
        open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    private func lexicalURL(for temporaryFile: TemporaryFile) -> URL {
        rootURL.appendingPathComponent(temporaryFile.name)
    }
}
