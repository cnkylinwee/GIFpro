import Foundation

struct TemporaryFileStore {
    enum CapacityPolicy: Equatable {
        case canStart
        case `continue`
        case mustStop
    }

    enum StoreError: Error, Equatable {
        case unsafeURL(URL)
        case capacityUnavailable
    }

    static let minimumStartCapacityBytes: Int64 = 1_000_000_000
    static let minimumContinueCapacityBytes: Int64 = 256_000_000

    private let fileManager: FileManager
    private let rootURL: URL
    private let availableCapacity: () throws -> Int64

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        availableCapacity: (() throws -> Int64)? = nil
    ) {
        self.fileManager = fileManager
        let configuredRoot = rootURL
            ?? fileManager.temporaryDirectory.appendingPathComponent("GIFpro", isDirectory: true)
        self.rootURL = configuredRoot.standardizedFileURL
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

    func makeTemporaryFileURL() throws -> URL {
        try createRootIfNeeded()
        return rootURL.appendingPathComponent("\(UUID().uuidString).gif", isDirectory: false)
    }

    func moveTemporaryFile(at sourceURL: URL, to destinationURL: URL) throws {
        try validateOwnedURL(sourceURL)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func discardTemporaryFile(at url: URL) throws {
        try validateOwnedURL(url)
        do {
            try fileManager.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // An already discarded file is the desired state.
        }
    }

    func cleanupStaleFiles() throws {
        try createRootIfNeeded()
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )

        try contents.forEach(validateOwnedURL)
        for url in contents {
            try fileManager.removeItem(at: url)
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

    private func createRootIfNeeded() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func validateOwnedURL(_ url: URL) throws {
        guard url.isFileURL else {
            throw StoreError.unsafeURL(url)
        }

        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedURL != resolvedRoot,
              resolvedURL.deletingLastPathComponent() == resolvedRoot else {
            throw StoreError.unsafeURL(url)
        }
    }
}
