import Darwin
import Foundation

final class TemporaryFileStore {
    enum CapacityPolicy: Equatable {
        case canStart
        case `continue`
        case mustStop
    }

    enum StoreError: Error, Equatable {
        case unsafeURL(URL)
        case invalidSource(URL)
        case capacityUnavailable
        case systemCall(String, Int32)
    }

    enum RenameResult {
        case moved
        case crossVolume
    }

    struct FileOperations {
        var renameOwnedFile: (Int32, String, URL) throws -> RenameResult
        var copyBytes: (Int32, Int32) throws -> Void

        static var posix: FileOperations {
            FileOperations(
                renameOwnedFile: { rootDescriptor, sourceName, destinationURL in
                    let result = sourceName.withCString { sourcePath in
                        destinationURL.path.withCString { destinationPath in
                            renameat(rootDescriptor, sourcePath, AT_FDCWD, destinationPath)
                        }
                    }
                    if result == 0 {
                        return .moved
                    }
                    let code = errno
                    if code == EXDEV {
                        return .crossVolume
                    }
                    throw StoreError.systemCall("renameat", code)
                },
                copyBytes: copyFileBytes
            )
        }
    }

    static let minimumStartCapacityBytes: Int64 = 1_000_000_000
    static let minimumContinueCapacityBytes: Int64 = 256_000_000

    private let fileManager: FileManager
    private let rootURL: URL
    private let availableCapacity: () throws -> Int64
    private let fileOperations: FileOperations
    private let descriptorLock = NSLock()
    private var pinnedRootDescriptor: Int32?

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

    func makeTemporaryFileURL() throws -> URL {
        _ = try rootDescriptor()
        return rootURL.appendingPathComponent("\(UUID().uuidString).gif", isDirectory: false)
    }

    func moveTemporaryFile(at sourceURL: URL, to destinationURL: URL) throws {
        guard destinationURL.isFileURL else {
            throw StoreError.unsafeURL(destinationURL)
        }
        let sourceName = try ownedLeafName(for: sourceURL)
        let descriptor = try rootDescriptor()
        try requireRegularFile(named: sourceName, sourceURL: sourceURL, in: descriptor)

        switch try fileOperations.renameOwnedFile(descriptor, sourceName, destinationURL) {
        case .moved:
            return
        case .crossVolume:
            try replaceAcrossVolumes(
                sourceName: sourceName,
                sourceURL: sourceURL,
                rootDescriptor: descriptor,
                destinationURL: destinationURL
            )
        }
    }

    func discardTemporaryFile(at url: URL) throws {
        let name = try ownedLeafName(for: url)
        let descriptor = try rootDescriptor()
        guard try isRegularFileIfPresent(named: name, sourceURL: url, in: descriptor) else {
            return
        }

        let result = name.withCString { unlinkat(descriptor, $0, 0) }
        if result != 0, errno != ENOENT {
            throw StoreError.systemCall("unlinkat", errno)
        }
    }

    func cleanupStaleFiles() throws {
        let descriptor = try rootDescriptor()
        for name in try entryNames(in: descriptor) {
            try removeEntry(named: name, from: descriptor)
        }
    }

    func capacityPolicy() throws -> CapacityPolicy {
        let capacity = try availableCapacity()
        if capacity >= Self.minimumStartCapacityBytes {
            return .canStart
        }
        if capacity < Self.minimumContinueCapacityBytes {
            return .mustStop
        }
        return .continue
    }

    private func rootDescriptor() throws -> Int32 {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        if let descriptor = pinnedRootDescriptor {
            return descriptor
        }

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let descriptor = rootURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw StoreError.systemCall("open root", errno)
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            throw StoreError.systemCall("fstat root", code)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw StoreError.unsafeURL(rootURL)
        }

        pinnedRootDescriptor = descriptor
        return descriptor
    }

    private func ownedLeafName(for url: URL) throws -> String {
        guard url.isFileURL else {
            throw StoreError.unsafeURL(url)
        }
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.deletingLastPathComponent() == rootURL,
              standardizedURL != rootURL else {
            throw StoreError.unsafeURL(url)
        }
        let name = standardizedURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw StoreError.unsafeURL(url)
        }
        return name
    }

    private func requireRegularFile(
        named name: String,
        sourceURL: URL,
        in descriptor: Int32
    ) throws {
        guard try isRegularFileIfPresent(named: name, sourceURL: sourceURL, in: descriptor) else {
            throw StoreError.systemCall("fstatat", ENOENT)
        }
    }

    private func isRegularFileIfPresent(
        named name: String,
        sourceURL: URL,
        in descriptor: Int32
    ) throws -> Bool {
        var status = stat()
        let result = name.withCString {
            fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT {
                return false
            }
            throw StoreError.systemCall("fstatat", errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw StoreError.invalidSource(sourceURL)
        }
        return true
    }

    private func replaceAcrossVolumes(
        sourceName: String,
        sourceURL: URL,
        rootDescriptor: Int32,
        destinationURL: URL
    ) throws {
        try requireRegularFile(named: sourceName, sourceURL: sourceURL, in: rootDescriptor)
        let sourceDescriptor = sourceName.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0 else {
            throw StoreError.systemCall("openat source", errno)
        }
        defer { close(sourceDescriptor) }

        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              sourceStatus.st_mode & S_IFMT == S_IFREG else {
            throw StoreError.invalidSource(sourceURL)
        }

        let destinationDirectoryURL = destinationURL.deletingLastPathComponent().standardizedFileURL
        let destinationName = destinationURL.lastPathComponent
        guard !destinationName.isEmpty, destinationName != ".", destinationName != ".." else {
            throw StoreError.unsafeURL(destinationURL)
        }
        let destinationDirectoryDescriptor = destinationDirectoryURL.path.withCString {
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
            if stagingIsOpen {
                close(stagingDescriptor)
            }
            if stagingNeedsRemoval {
                _ = stagingName.withCString {
                    unlinkat(destinationDirectoryDescriptor, $0, 0)
                }
            }
        }

        try fileOperations.copyBytes(sourceDescriptor, stagingDescriptor)
        guard fsync(stagingDescriptor) == 0 else {
            throw StoreError.systemCall("fsync staging", errno)
        }
        let closeResult = close(stagingDescriptor)
        stagingIsOpen = false
        guard closeResult == 0 else {
            throw StoreError.systemCall("close staging", errno)
        }

        let replaceResult = stagingName.withCString { stagingPath in
            destinationName.withCString { destinationPath in
                renameat(
                    destinationDirectoryDescriptor,
                    stagingPath,
                    destinationDirectoryDescriptor,
                    destinationPath
                )
            }
        }
        guard replaceResult == 0 else {
            throw StoreError.systemCall("renameat staging", errno)
        }
        stagingNeedsRemoval = false
        _ = fsync(destinationDirectoryDescriptor)

        let unlinkResult = sourceName.withCString {
            unlinkat(rootDescriptor, $0, 0)
        }
        guard unlinkResult == 0 else {
            throw StoreError.systemCall("unlinkat source", errno)
        }
    }

    private func entryNames(in descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else {
            throw StoreError.systemCall("dup", errno)
        }
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
            if name != ".", name != ".." {
                names.append(name)
            }
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
            throw StoreError.invalidSource(rootURL.appendingPathComponent(name))
        }
    }

    private static func copyFileBytes(sourceDescriptor: Int32, destinationDescriptor: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes {
                read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if bytesRead == 0 {
                return
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw StoreError.systemCall("read", errno)
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
        }
    }
}
