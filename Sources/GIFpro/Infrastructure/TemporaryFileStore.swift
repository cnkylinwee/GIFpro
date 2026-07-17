import Darwin
import Foundation

// The descriptor identity and lifetime state are immutable. Borrowing and
// duplication do not mutate Swift-managed state, so the handle can safely be
// transferred across actor boundaries.
final class TemporaryFile: CustomStringConvertible, @unchecked Sendable {
    let name: String

    var description: String {
        "Temporary GIF \(name)"
    }

    fileprivate let ownerID: UUID
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
    private let descriptor: Int32

    fileprivate init(
        name: String,
        descriptor: Int32,
        ownerID: UUID,
        device: dev_t,
        inode: ino_t
    ) {
        self.name = name
        self.descriptor = descriptor
        self.ownerID = ownerID
        self.device = device
        self.inode = inode
    }

    deinit {
        close(descriptor)
    }

    /// The descriptor is borrowed only for the duration of `body`.
    func withFileDescriptor<T>(_ body: (Int32) throws -> T) rethrows -> T {
        try body(descriptor)
    }

    /// Returns a caller-owned descriptor suitable for a fd-backed data consumer.
    func duplicateFileDescriptor() throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw TemporaryFileStore.StoreError.systemCall("duplicate temporary file", errno)
        }
        return duplicate
    }
}

// Store configuration is immutable after initialization. The only lazily
// mutated state is the pinned root descriptor and identity, protected by
// descriptorLock and never changed after publication.
final class TemporaryFileStore: @unchecked Sendable {
    enum CapacityPolicy: Equatable {
        case canStart
        case `continue`
        case mustStop
    }

    enum SaveWarning: Equatable {
        case destinationDirectorySyncFailed
        case sourceCleanupFailed
        case sourceChanged
    }

    struct SaveResult: Equatable {
        let destinationURL: URL
        let cleanupPending: Bool
        let warnings: [SaveWarning]

        static func saved(
            destinationURL: URL,
            cleanupPending: Bool = false,
            warnings: [SaveWarning] = []
        ) -> SaveResult {
            SaveResult(
                destinationURL: destinationURL,
                cleanupPending: cleanupPending,
                warnings: warnings
            )
        }
    }

    enum StoreError: Error, Equatable {
        case unsafeURL(URL)
        case invalidSource(String)
        case foreignTemporaryFile
        case capacityUnavailable
        case systemCall(String, Int32)
    }

    struct FileOperations {
        var copyBytes: (Int32, Int32) throws -> Void
        var syncStaging: (Int32) throws -> Void
        var replaceStaging: (Int32, String, String) throws -> Void
        var syncDestinationDirectory: (Int32) throws -> Void
        var unlinkSource: (Int32, String) throws -> Void

        static var posix: FileOperations {
            FileOperations(
                copyBytes: copyFileBytes,
                syncStaging: { descriptor in
                    guard fsync(descriptor) == 0 else {
                        throw StoreError.systemCall("fsync staging", errno)
                    }
                },
                replaceStaging: { directoryDescriptor, stagingName, destinationName in
                    let result = stagingName.withCString { stagingPath in
                        destinationName.withCString { destinationPath in
                            renameat(
                                directoryDescriptor,
                                stagingPath,
                                directoryDescriptor,
                                destinationPath
                            )
                        }
                    }
                    guard result == 0 else {
                        throw StoreError.systemCall("renameat staging", errno)
                    }
                },
                syncDestinationDirectory: { descriptor in
                    guard fsync(descriptor) == 0 else {
                        throw StoreError.systemCall("fsync destination directory", errno)
                    }
                },
                unlinkSource: { directoryDescriptor, sourceName in
                    let result = sourceName.withCString {
                        unlinkat(directoryDescriptor, $0, 0)
                    }
                    guard result == 0 || errno == ENOENT else {
                        throw StoreError.systemCall("unlinkat source", errno)
                    }
                }
            )
        }
    }

    static let minimumStartCapacityBytes: Int64 = 1_000_000_000
    static let minimumContinueCapacityBytes: Int64 = 256_000_000

    private enum EntryIdentity {
        case missing
        case matches
        case changed
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let availableCapacity: () throws -> Int64
    private let fileOperations: FileOperations
    private let ownerID = UUID()
    private let descriptorLock = NSLock()
    private var pinnedRootDescriptor: Int32?
    private var pinnedRootDevice: dev_t?
    private var pinnedRootInode: ino_t?

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        availableCapacity: (() throws -> Int64)? = nil,
        fileOperations: FileOperations = .posix
    ) {
        self.fileManager = fileManager
        let configuredRoot = rootURL
            ?? fileManager.temporaryDirectory.appendingPathComponent("GIFpro", isDirectory: true)
        self.rootURL = configuredRoot.standardizedFileURL
        self.fileOperations = fileOperations
        self.availableCapacity = availableCapacity ?? {
            var capacityURL = configuredRoot.standardizedFileURL
            while !fileManager.fileExists(atPath: capacityURL.path) {
                let parentURL = capacityURL.deletingLastPathComponent()
                guard parentURL != capacityURL else {
                    throw StoreError.capacityUnavailable
                }
                capacityURL = parentURL
            }

            let values = try capacityURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
                throw StoreError.capacityUnavailable
            }
            return capacity
        }
    }

    deinit {
        if let descriptor = pinnedRootDescriptor {
            close(descriptor)
        }
    }

    func makeTemporaryFile() throws -> TemporaryFile {
        let rootDescriptor = try rootDescriptor()
        while true {
            let name = "\(UUID().uuidString).gif"
            let descriptor = name.withCString {
                openat(
                    rootDescriptor,
                    $0,
                    O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw StoreError.systemCall("openat temporary file", errno)
            }

            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG else {
                let code = errno
                close(descriptor)
                _ = name.withCString { unlinkat(rootDescriptor, $0, 0) }
                throw StoreError.systemCall("fstat temporary file", code)
            }
            return TemporaryFile(
                name: name,
                descriptor: descriptor,
                ownerID: ownerID,
                device: status.st_dev,
                inode: status.st_ino
            )
        }
    }

    func saveTemporaryFile(
        _ temporaryFile: TemporaryFile,
        to destinationURL: URL
    ) throws -> SaveResult {
        try validateOwner(of: temporaryFile)
        guard destinationURL.isFileURL else {
            throw StoreError.unsafeURL(destinationURL)
        }
        let rootDescriptor = try rootDescriptor()
        guard try entryIdentity(of: temporaryFile, in: rootDescriptor) == .matches else {
            throw StoreError.invalidSource(temporaryFile.description)
        }
        try validateOpenTemporaryFile(temporaryFile)

        let destination = destinationURL.standardizedFileURL
        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty, destinationName != ".", destinationName != ".." else {
            throw StoreError.unsafeURL(destinationURL)
        }
        let destinationDirectoryDescriptor = destination.deletingLastPathComponent().path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard destinationDirectoryDescriptor >= 0 else {
            throw StoreError.systemCall("open destination directory", errno)
        }
        defer { close(destinationDirectoryDescriptor) }

        let stagingName = ".gifpro-\(UUID().uuidString).tmp"
        let stagingDescriptor = stagingName.withCString {
            openat(
                destinationDirectoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard stagingDescriptor >= 0 else {
            throw StoreError.systemCall("openat staging", errno)
        }

        var stagingIsOpen = true
        var stagingNeedsRemoval = true
        defer {
            if stagingIsOpen { close(stagingDescriptor) }
            if stagingNeedsRemoval {
                _ = stagingName.withCString {
                    unlinkat(destinationDirectoryDescriptor, $0, 0)
                }
            }
        }

        try temporaryFile.withFileDescriptor {
            try fileOperations.copyBytes($0, stagingDescriptor)
        }
        try fileOperations.syncStaging(stagingDescriptor)
        let closeResult = close(stagingDescriptor)
        stagingIsOpen = false
        guard closeResult == 0 else {
            throw StoreError.systemCall("close staging", errno)
        }

        try fileOperations.replaceStaging(
            destinationDirectoryDescriptor,
            stagingName,
            destinationName
        )
        stagingNeedsRemoval = false // Commit point: destination now contains the new GIF.

        var warnings: [SaveWarning] = []
        do {
            try fileOperations.syncDestinationDirectory(destinationDirectoryDescriptor)
        } catch {
            warnings.append(.destinationDirectorySyncFailed)
        }

        var cleanupPending = false
        do {
            switch try removeMatchingSource(temporaryFile, from: rootDescriptor) {
            case .matches:
                break
            case .missing:
                break
            case .changed:
                cleanupPending = true
                warnings.append(.sourceChanged)
            }
        } catch {
            cleanupPending = true
            warnings.append(.sourceCleanupFailed)
        }

        return .saved(
            destinationURL: destinationURL,
            cleanupPending: cleanupPending,
            warnings: warnings
        )
    }

    func discardTemporaryFile(_ temporaryFile: TemporaryFile) throws {
        try validateOwner(of: temporaryFile)
        let rootDescriptor = try rootDescriptor()
        switch try removeMatchingSource(temporaryFile, from: rootDescriptor) {
        case .missing:
            return
        case .changed:
            throw StoreError.invalidSource(temporaryFile.description)
        case .matches:
            return
        }
    }

    /// Returns a lexical path only after momentarily proving that it still names
    /// the pinned root and handle inode. This is for path-only readers such as
    /// Quick Look; encoders and other writers must keep using the handle fd.
    func validatedAccessURL(for temporaryFile: TemporaryFile) throws -> URL {
        try validateOwner(of: temporaryFile)
        let rootDescriptor = try rootDescriptor()
        guard let pinnedRootDevice, let pinnedRootInode else {
            throw StoreError.invalidSource(temporaryFile.description)
        }

        var lexicalRootStatus = stat()
        let rootStatusResult = rootURL.path.withCString {
            lstat($0, &lexicalRootStatus)
        }
        guard rootStatusResult == 0,
              lexicalRootStatus.st_mode & S_IFMT == S_IFDIR,
              lexicalRootStatus.st_dev == pinnedRootDevice,
              lexicalRootStatus.st_ino == pinnedRootInode,
              try entryIdentity(of: temporaryFile, in: rootDescriptor) == .matches else {
            throw StoreError.invalidSource(temporaryFile.description)
        }
        return rootURL.appendingPathComponent(temporaryFile.name, isDirectory: false)
    }

    func cleanupStaleFiles() throws {
        let descriptor = try rootDescriptor()
        for name in try entryNames(in: descriptor) {
            try removeEntry(named: name, from: descriptor)
        }
    }

    func capacityPolicy() throws -> CapacityPolicy {
        let capacity = try availableCapacity()
        if capacity >= Self.minimumStartCapacityBytes { return .canStart }
        if capacity < Self.minimumContinueCapacityBytes { return .mustStop }
        return .continue
    }

    private func validateOwner(of temporaryFile: TemporaryFile) throws {
        guard temporaryFile.ownerID == ownerID else {
            throw StoreError.foreignTemporaryFile
        }
    }

    private func validateOpenTemporaryFile(_ temporaryFile: TemporaryFile) throws {
        try temporaryFile.withFileDescriptor { descriptor in
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_dev == temporaryFile.device,
                  status.st_ino == temporaryFile.inode else {
                throw StoreError.invalidSource(temporaryFile.description)
            }
        }
    }

    private func entryIdentity(
        of temporaryFile: TemporaryFile,
        in rootDescriptor: Int32
    ) throws -> EntryIdentity {
        var status = stat()
        let result = temporaryFile.name.withCString {
            fstatat(rootDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return .missing }
            throw StoreError.systemCall("fstatat source", errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_dev == temporaryFile.device,
              status.st_ino == temporaryFile.inode else {
            return .changed
        }
        return .matches
    }

    /// Atomically moves the current logical leaf out of its well-known name before
    /// checking identity, so a replacement leaf is never passed to `unlinkat`.
    private func removeMatchingSource(
        _ temporaryFile: TemporaryFile,
        from rootDescriptor: Int32
    ) throws -> EntryIdentity {
        let guardName = ".gifpro-cleanup-\(UUID().uuidString)"
        let guardDescriptor = guardName.withCString {
            openat(
                rootDescriptor,
                $0,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard guardDescriptor >= 0 else {
            throw StoreError.systemCall("openat cleanup guard", errno)
        }
        var guardStatus = stat()
        guard fstat(guardDescriptor, &guardStatus) == 0 else {
            let code = errno
            close(guardDescriptor)
            _ = guardName.withCString { unlinkat(rootDescriptor, $0, 0) }
            throw StoreError.systemCall("fstat cleanup guard", code)
        }
        close(guardDescriptor)

        var guardNeedsRemoval = true
        defer {
            if guardNeedsRemoval {
                _ = guardName.withCString { unlinkat(rootDescriptor, $0, 0) }
            }
        }

        let swapResult = renameSwap(
            directoryDescriptor: rootDescriptor,
            firstName: temporaryFile.name,
            secondName: guardName
        )
        if swapResult != 0 {
            if errno == ENOENT { return .missing }
            throw StoreError.systemCall("renameatx_np isolate source", errno)
        }

        let isolatedIdentity: EntryIdentity
        do {
            isolatedIdentity = try identity(
                named: guardName,
                device: temporaryFile.device,
                inode: temporaryFile.inode,
                in: rootDescriptor
            )
        } catch {
            if renameSwap(
                directoryDescriptor: rootDescriptor,
                firstName: temporaryFile.name,
                secondName: guardName
            ) != 0 {
                guardNeedsRemoval = false
            }
            throw error
        }
        guard isolatedIdentity == .matches else {
            guard renameSwap(
                directoryDescriptor: rootDescriptor,
                firstName: temporaryFile.name,
                secondName: guardName
            ) == 0 else {
                guardNeedsRemoval = false
                throw StoreError.systemCall("renameatx_np restore changed source", errno)
            }
            return .changed
        }

        do {
            try fileOperations.unlinkSource(rootDescriptor, guardName)
            guardNeedsRemoval = false
        } catch {
            if renameSwap(
                directoryDescriptor: rootDescriptor,
                firstName: temporaryFile.name,
                secondName: guardName
            ) != 0 {
                guardNeedsRemoval = false
            }
            throw error
        }

        let placeholderIdentity = try identity(
            named: temporaryFile.name,
            device: guardStatus.st_dev,
            inode: guardStatus.st_ino,
            in: rootDescriptor
        )
        guard placeholderIdentity == .matches else {
            throw StoreError.invalidSource(temporaryFile.description)
        }
        let placeholderRemoval = temporaryFile.name.withCString {
            unlinkat(rootDescriptor, $0, 0)
        }
        guard placeholderRemoval == 0 else {
            throw StoreError.systemCall("unlinkat cleanup placeholder", errno)
        }
        return .matches
    }

    private func identity(
        named name: String,
        device: dev_t,
        inode: ino_t,
        in directoryDescriptor: Int32
    ) throws -> EntryIdentity {
        var status = stat()
        let result = name.withCString {
            fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return .missing }
            throw StoreError.systemCall("fstatat isolated source", errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_dev == device,
              status.st_ino == inode else {
            return .changed
        }
        return .matches
    }

    private func renameSwap(
        directoryDescriptor: Int32,
        firstName: String,
        secondName: String
    ) -> Int32 {
        firstName.withCString { firstPath in
            secondName.withCString { secondPath in
                renameatx_np(
                    directoryDescriptor,
                    firstPath,
                    directoryDescriptor,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
    }

    private func rootDescriptor() throws -> Int32 {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        if let descriptor = pinnedRootDescriptor { return descriptor }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let descriptor = rootURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw StoreError.systemCall("open root", errno)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            let code = errno
            close(descriptor)
            throw StoreError.systemCall("fstat root", code)
        }
        pinnedRootDescriptor = descriptor
        pinnedRootDevice = status.st_dev
        pinnedRootInode = status.st_ino
        return descriptor
    }

    private func entryNames(in descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw StoreError.systemCall("dup", errno) }
        guard let directory = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            throw StoreError.systemCall("fdopendir", code)
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private func removeEntry(named name: String, from parentDescriptor: Int32) throws {
        var status = stat()
        let statusResult = name.withCString {
            fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0 {
            if errno == ENOENT { return }
            throw StoreError.systemCall("fstatat cleanup", errno)
        }

        switch status.st_mode & S_IFMT {
        case S_IFREG:
            let result = name.withCString { unlinkat(parentDescriptor, $0, 0) }
            if result != 0, errno != ENOENT {
                throw StoreError.systemCall("unlinkat cleanup", errno)
            }
        case S_IFDIR:
            let childDescriptor = name.withCString {
                openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard childDescriptor >= 0 else {
                throw StoreError.systemCall("openat cleanup directory", errno)
            }
            defer { close(childDescriptor) }
            for childName in try entryNames(in: childDescriptor) {
                try removeEntry(named: childName, from: childDescriptor)
            }
            let result = name.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
            if result != 0, errno != ENOENT {
                throw StoreError.systemCall("unlinkat cleanup directory", errno)
            }
        default:
            throw StoreError.invalidSource("Unexpected entry \(name)")
        }
    }

    private static func copyFileBytes(sourceDescriptor: Int32, destinationDescriptor: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var offset: off_t = 0
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes {
                pread(sourceDescriptor, $0.baseAddress, $0.count, offset)
            }
            if bytesRead == 0 { return }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw StoreError.systemCall("pread", errno)
            }

            var bytesWritten = 0
            while bytesWritten < bytesRead {
                let result = buffer.withUnsafeBytes { bytes in
                    write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: bytesWritten),
                        bytesRead - bytesWritten
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.systemCall("write", errno)
                }
                bytesWritten += result
            }
            offset += off_t(bytesRead)
        }
    }
}
