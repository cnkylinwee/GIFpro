@preconcurrency import CoreGraphics
@preconcurrency import ImageIO
import Darwin
import Foundation
import UniformTypeIdentifiers

private final class FileDataConsumerContext: @unchecked Sendable {
    typealias WriteBytes = @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    typealias CloseDescriptor = @Sendable (Int32) -> Int32

    private let lock = NSLock()
    private var descriptor: Int32
    private var writeFailed = false
    private let writeBytes: WriteBytes
    private let closeDescriptor: CloseDescriptor
    private let didDestroy: @Sendable () -> Void

    init(
        descriptor: Int32,
        writeBytes: @escaping WriteBytes,
        closeDescriptor: @escaping CloseDescriptor,
        didDestroy: @escaping @Sendable () -> Void
    ) {
        self.descriptor = descriptor
        self.writeBytes = writeBytes
        self.closeDescriptor = closeDescriptor
        self.didDestroy = didDestroy
    }

    deinit {
        didDestroy()
    }

    var didFail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeFailed
    }

    func putBytes(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !writeFailed else { return 0 }

        var total = 0
        while total < count {
            let written = writeBytes(descriptor, buffer.advanced(by: total), count - total)
            if written > 0 {
                total += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                writeFailed = true
                return 0
            }
        }
        return total
    }

    func closeOnce() {
        lock.lock()
        let descriptorToClose = descriptor
        descriptor = -1
        lock.unlock()
        if descriptorToClose >= 0 {
            _ = closeDescriptor(descriptorToClose)
        }
    }
}

private let dataConsumerPutBytes: CGDataConsumerPutBytesCallback = { info, buffer, count in
    guard let info else { return 0 }
    return Unmanaged<FileDataConsumerContext>
        .fromOpaque(info)
        .takeUnretainedValue()
        .putBytes(buffer, count: count)
}

private let dataConsumerRelease: CGDataConsumerReleaseInfoCallback = { info in
    guard let info else { return }
    let context = Unmanaged<FileDataConsumerContext>.fromOpaque(info).takeRetainedValue()
    context.closeOnce()
}

actor GIFStreamEncoder {
    enum RejectionReason: Equatable, Sendable {
        case invalidTimestamp
        case maximumFrameCountReached
        case finished
        case consumerWriteFailed
    }

    enum AppendResult: Equatable, Sendable {
        case accepted
        case rejected(RejectionReason)
    }

    enum EncodingError: Error, Equatable {
        case invalidMaximumFrameCount
        case duplicateDescriptorFailed
        case consumerCreationFailed
        case destinationCreationFailed
        case noFrames
        case invalidStopTimestamp
        case consumerWriteFailed
        case finalizationFailed
        case alreadyFinished
    }

    typealias WriteBytes = @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    typealias CloseDescriptor = @Sendable (Int32) -> Int32
    typealias Finalize = @Sendable (CGImageDestination) -> Bool
    typealias DuplicateDescriptor = @Sendable (TemporaryFile) throws -> Int32
    typealias ConsumerFactory = @Sendable (
        UnsafeMutableRawPointer,
        UnsafePointer<CGDataConsumerCallbacks>
    ) -> CGDataConsumer?
    typealias DestinationFactory = @Sendable (CGDataConsumer, Int) -> CGImageDestination?

    // CGImage is immutable. This wrapper documents that the actor is its sole
    // owner after append enters actor isolation.
    private struct PendingImage: @unchecked Sendable {
        let value: CGImage
    }

    private enum State { case active, finished }

    nonisolated let temporaryFileForDiscardAfterFailure: TemporaryFile
    private let maximumFrames: Int
    private let finalizeDestination: Finalize
    private let consumerContext: FileDataConsumerContext
    private var consumer: CGDataConsumer?
    private var destination: CGImageDestination?
    private var timing = FrameTiming()
    private var pendingImage: PendingImage?
    private var acceptedFrameCount = 0
    private var state = State.active

    init(
        store: TemporaryFileStore,
        maximumFrames: Int,
        duplicateDescriptor: @escaping DuplicateDescriptor = {
            try $0.duplicateFileDescriptor()
        },
        didDuplicateDescriptor: @Sendable (Int32) -> Void = { _ in },
        writeBytes: @escaping WriteBytes = { descriptor, buffer, count in
            Darwin.write(descriptor, buffer, count)
        },
        closeDescriptor: @escaping CloseDescriptor = { Darwin.close($0) },
        consumerFactory: @escaping ConsumerFactory = { info, callbacks in
            CGDataConsumer(info: info, cbks: callbacks)
        },
        destinationFactory: @escaping DestinationFactory = { consumer, maximumFrames in
            CGImageDestinationCreateWithDataConsumer(
                consumer,
                UTType.gif.identifier as CFString,
                maximumFrames,
                nil
            )
        },
        didDestroyConsumerContext: @escaping @Sendable () -> Void = {},
        finalize: @escaping Finalize = { CGImageDestinationFinalize($0) }
    ) throws {
        guard maximumFrames > 0 else {
            throw EncodingError.invalidMaximumFrameCount
        }

        let temporaryFile = try store.makeTemporaryFile()
        var initializationSucceeded = false
        defer {
            if !initializationSucceeded {
                try? store.discardTemporaryFile(temporaryFile)
            }
        }

        let duplicate: Int32
        do {
            duplicate = try duplicateDescriptor(temporaryFile)
        } catch {
            throw EncodingError.duplicateDescriptorFailed
        }
        didDuplicateDescriptor(duplicate)
        let context = FileDataConsumerContext(
            descriptor: duplicate,
            writeBytes: writeBytes,
            closeDescriptor: closeDescriptor,
            didDestroy: didDestroyConsumerContext
        )
        let retainedContext = Unmanaged.passRetained(context)
        var callbacks = CGDataConsumerCallbacks(
            putBytes: dataConsumerPutBytes,
            releaseConsumer: dataConsumerRelease
        )
        let consumer = withUnsafePointer(to: &callbacks) { callbacks in
            consumerFactory(retainedContext.toOpaque(), callbacks)
        }
        guard let consumer else {
            retainedContext.release()
            context.closeOnce()
            throw EncodingError.consumerCreationFailed
        }
        guard let destination = destinationFactory(consumer, maximumFrames) else {
            throw EncodingError.destinationCreationFailed
        }

        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 1,
                ],
            ] as CFDictionary
        )

        temporaryFileForDiscardAfterFailure = temporaryFile
        self.maximumFrames = maximumFrames
        finalizeDestination = finalize
        consumerContext = context
        self.consumer = consumer
        self.destination = destination
        initializationSucceeded = true
    }

    deinit {
        destination = nil
        consumer = nil
        consumerContext.closeOnce()
    }

    func append(image: CGImage, timestamp: TimeInterval) -> AppendResult {
        guard state == .active else { return .rejected(.finished) }
        guard !consumerContext.didFail else { return .rejected(.consumerWriteFailed) }
        guard acceptedFrameCount < maximumFrames else {
            return .rejected(.maximumFrameCountReached)
        }

        guard let acceptance = timing.accept(timestamp: timestamp) else {
            return .rejected(.invalidTimestamp)
        }

        switch acceptance {
        case .firstFrame:
            break
        case .previousFrame(let delay):
            guard let pendingImage, let destination else {
                return .rejected(.consumerWriteFailed)
            }
            add(pendingImage.value, delay: delay, to: destination)
        }
        pendingImage = PendingImage(value: image)
        acceptedFrameCount += 1
        return consumerContext.didFail ? .rejected(.consumerWriteFailed) : .accepted
    }

    func finish(at timestamp: TimeInterval) throws -> TemporaryFile {
        guard state == .active else { throw EncodingError.alreadyFinished }
        guard let pendingImage else { throw EncodingError.noFrames }
        guard let finalDelay = timing.finish(at: timestamp) else {
            throw EncodingError.invalidStopTimestamp
        }
        guard let destination else { throw EncodingError.finalizationFailed }

        state = .finished
        add(pendingImage.value, delay: finalDelay, to: destination)
        self.pendingImage = nil
        let didFinalize = finalizeDestination(destination)
        self.destination = nil
        consumer = nil
        consumerContext.closeOnce()

        if consumerContext.didFail {
            throw EncodingError.consumerWriteFailed
        }
        guard didFinalize else {
            throw EncodingError.finalizationFailed
        }
        return temporaryFileForDiscardAfterFailure
    }

    private func add(_ image: CGImage, delay: TimeInterval, to destination: CGImageDestination) {
        let properties: CFDictionary = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: delay,
                kCGImagePropertyGIFDelayTime: delay,
            ],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
    }
}
