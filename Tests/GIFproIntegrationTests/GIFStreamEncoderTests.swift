import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GIFpro

final class GIFStreamEncoderTests: XCTestCase {
    private enum InjectedError: Error { case failure }
    private var directory: URL!
    private var store: TemporaryFileStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFStreamEncoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TemporaryFileStore(
            rootURL: directory.appendingPathComponent("store", isDirectory: true),
            availableCapacity: { 2_000_000_000 }
        )
    }

    override func tearDownWithError() throws {
        store = nil
        if directory != nil { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    func testEncodesTimestampedFramesWithSinglePlaybackAndExpectedDelays() async throws {
        let encoder = try GIFStreamEncoder(store: store, maximumFrames: 10)
        let first = await encoder.append(image: try solidImage(.red), timestamp: 0)
        let second = await encoder.append(image: try solidImage(.green), timestamp: 0.1)
        let third = await encoder.append(image: try solidImage(.blue), timestamp: 0.3)
        XCTAssertEqual(first, .accepted)
        XCTAssertEqual(second, .accepted)
        XCTAssertEqual(third, .accepted)

        let file = try await encoder.finish(at: 0.5)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(try store.validatedAccessURL(for: file) as CFURL, nil)
        )

        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let container = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gif = try XCTUnwrap(container[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual((gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(try delays(in: source), [0.1, 0.2, 0.2])
    }

    func testDuplicateFailureDiscardsEntryAndClosesOwnerDescriptor() throws {
        let ownerDescriptor = LockedValue<Int32>(-1)

        XCTAssertThrowsError(
            try GIFStreamEncoder(
                store: store,
                maximumFrames: 1,
                duplicateDescriptor: { file in
                    ownerDescriptor.withValue { value in
                        value = file.withFileDescriptor { $0 }
                    }
                    throw InjectedError.failure
                }
            )
        ) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .duplicateDescriptorFailed)
        }

        XCTAssertEqual(try storeEntries(), [])
        XCTAssertEqual(fcntl(ownerDescriptor.value, F_GETFD), -1)
    }

    func testConsumerCreationFailureDiscardsEntryAndBalancesContextLifetime() throws {
        let duplicateDescriptor = LockedValue<Int32>(-1)
        let closeCalls = LockedValue(0)
        let destroyedContexts = LockedValue(0)

        XCTAssertThrowsError(
            try GIFStreamEncoder(
                store: store,
                maximumFrames: 1,
                didDuplicateDescriptor: { descriptor in
                    duplicateDescriptor.withValue { $0 = descriptor }
                },
                closeDescriptor: { descriptor in
                    closeCalls.withValue { $0 += 1 }
                    return Darwin.close(descriptor)
                },
                consumerFactory: { _, _ in nil },
                didDestroyConsumerContext: { destroyedContexts.withValue { $0 += 1 } }
            )
        ) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .consumerCreationFailed)
        }

        XCTAssertEqual(try storeEntries(), [])
        XCTAssertEqual(fcntl(duplicateDescriptor.value, F_GETFD), -1)
        XCTAssertEqual(closeCalls.value, 1)
        XCTAssertEqual(destroyedContexts.value, 1)
    }

    func testDestinationCreationFailureDiscardsEntryAndReleasesConsumerContextOnce() throws {
        let duplicateDescriptor = LockedValue<Int32>(-1)
        let closeCalls = LockedValue(0)
        let destroyedContexts = LockedValue(0)

        XCTAssertThrowsError(
            try GIFStreamEncoder(
                store: store,
                maximumFrames: 1,
                didDuplicateDescriptor: { descriptor in
                    duplicateDescriptor.withValue { $0 = descriptor }
                },
                closeDescriptor: { descriptor in
                    closeCalls.withValue { $0 += 1 }
                    return Darwin.close(descriptor)
                },
                destinationFactory: { _, _ in nil },
                didDestroyConsumerContext: { destroyedContexts.withValue { $0 += 1 } }
            )
        ) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .destinationCreationFailed)
        }

        XCTAssertEqual(try storeEntries(), [])
        XCTAssertEqual(fcntl(duplicateDescriptor.value, F_GETFD), -1)
        XCTAssertEqual(closeCalls.value, 1)
        XCTAssertEqual(destroyedContexts.value, 1)
    }

    func testCarriesCentisecondQuantizationAtCommonFrameRates() async throws {
        let cases: [(fps: Double, expected: [Double])] = [
            (8, [0.13, 0.12, 0.13, 0.12]),
            (12, [0.08, 0.09, 0.08, 0.08]),
            (15, [0.07, 0.06, 0.07, 0.07]),
        ]
        for testCase in cases {
            let encoder = try GIFStreamEncoder(store: store, maximumFrames: 4)
            let colors: [Color] = [.red, .green, .blue, .red]
            for index in 0 ..< 4 {
                let result = await encoder.append(
                    image: try solidImage(colors[index]),
                    timestamp: Double(index) / testCase.fps
                )
                XCTAssertEqual(result, .accepted)
            }
            let file = try await encoder.finish(at: 4.0 / testCase.fps)
            let source = try XCTUnwrap(
                CGImageSourceCreateWithURL(try store.validatedAccessURL(for: file) as CFURL, nil)
            )
            let actual = try delays(in: source)
            XCTAssertEqual(actual.count, testCase.expected.count)
            for (actualDelay, expectedDelay) in zip(actual, testCase.expected) {
                XCTAssertEqual(actualDelay, expectedDelay, accuracy: 0.001)
            }
            XCTAssertEqual(actual.reduce(0, +), 4.0 / testCase.fps, accuracy: 0.011)
        }
    }

    func testDroppedTimestampExtendsThePreviousFrameDelayAndPreservesTotalDuration() async throws {
        let encoder = try GIFStreamEncoder(store: store, maximumFrames: 4)
        _ = await encoder.append(image: try solidImage(.red), timestamp: 0)
        _ = await encoder.append(image: try solidImage(.green), timestamp: 0.1)
        // A nominal 0.2 frame was dropped before the next delivered frame.
        _ = await encoder.append(image: try solidImage(.blue), timestamp: 0.3)
        let file = try await encoder.finish(at: 0.5)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(try store.validatedAccessURL(for: file) as CFURL, nil)
        )

        let actual = try delays(in: source)
        XCTAssertEqual(actual, [0.1, 0.2, 0.2])
        XCTAssertEqual(actual.reduce(0, +), 0.5, accuracy: 0.001)
    }

    func testRejectsInvalidTimestampsCapacityAndAppendAfterFinish() async throws {
        let encoder = try GIFStreamEncoder(store: store, maximumFrames: 2)
        let invalid = await encoder.append(image: try solidImage(.red), timestamp: .nan)
        let first = await encoder.append(image: try solidImage(.red), timestamp: 0)
        let duplicate = await encoder.append(image: try solidImage(.green), timestamp: 0)
        let second = await encoder.append(image: try solidImage(.green), timestamp: 0.1)
        let overCapacity = await encoder.append(image: try solidImage(.blue), timestamp: 0.2)
        XCTAssertEqual(invalid, .rejected(.invalidTimestamp))
        XCTAssertEqual(first, .accepted)
        XCTAssertEqual(duplicate, .rejected(.invalidTimestamp))
        XCTAssertEqual(second, .accepted)
        XCTAssertEqual(overCapacity, .rejected(.maximumFrameCountReached))
        _ = try await encoder.finish(at: 0.3)
        let afterFinish = await encoder.append(image: try solidImage(.blue), timestamp: 0.4)
        XCTAssertEqual(afterFinish, .rejected(.finished))
    }

    func testTheoreticalMaximumRejectsFrame181AndFinalizesExactly180Frames() async throws {
        let encoder = try GIFStreamEncoder(store: store, maximumFrames: 180)
        let images = try [Color.red, .green, .blue].map(solidImage)
        for index in 0 ..< 180 {
            let result = await encoder.append(
                image: images[index % images.count],
                timestamp: Double(index) / 12
            )
            XCTAssertEqual(result, .accepted)
        }
        let overflow = await encoder.append(image: images[0], timestamp: 15)
        XCTAssertEqual(overflow, .rejected(.maximumFrameCountReached))

        let file = try await encoder.finish(at: 15)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(try store.validatedAccessURL(for: file) as CFURL, nil)
        )
        XCTAssertEqual(CGImageSourceGetCount(source), 180)
        XCTAssertEqual(try delays(in: source).reduce(0, +), 15, accuracy: 0.2)
    }

    func testNoFramesInvalidStopAndSecondFinishHaveTypedErrors() async throws {
        XCTAssertThrowsError(try GIFStreamEncoder(store: store, maximumFrames: 0)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .invalidMaximumFrameCount)
        }

        let empty = try GIFStreamEncoder(store: store, maximumFrames: 1)
        await XCTAssertThrowsErrorAsync(try await empty.finish(at: 1)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .noFrames)
        }

        let encoder = try GIFStreamEncoder(store: store, maximumFrames: 1)
        _ = await encoder.append(image: try solidImage(.red), timestamp: 1)
        await XCTAssertThrowsErrorAsync(try await encoder.finish(at: 1)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .invalidStopTimestamp)
        }
        _ = try await encoder.finish(at: 1.1)
        await XCTAssertThrowsErrorAsync(try await encoder.finish(at: 1.2)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .alreadyFinished)
        }
    }

    func testInjectedFinalizeFailureRunsFinalizeExactlyOnce() async throws {
        let calls = LockedValue(0)
        let encoder = try GIFStreamEncoder(
            store: store,
            maximumFrames: 1,
            finalize: { _ in
                calls.withValue { $0 += 1 }
                return false
            }
        )
        _ = await encoder.append(image: try solidImage(.red), timestamp: 0)

        await XCTAssertThrowsErrorAsync(try await encoder.finish(at: 0.1)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .finalizationFailed)
        }
        await XCTAssertThrowsErrorAsync(try await encoder.finish(at: 0.2)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .alreadyFinished)
        }
        XCTAssertEqual(calls.value, 1)
    }

    func testConcurrentFinishFinalizesOnceAndRejectsTheOtherCaller() async throws {
        let calls = LockedValue(0)
        let encoder = try GIFStreamEncoder(
            store: store,
            maximumFrames: 1,
            finalize: { destination in
                calls.withValue { $0 += 1 }
                return CGImageDestinationFinalize(destination)
            }
        )
        _ = await encoder.append(image: try solidImage(.red), timestamp: 0)

        async let first = concurrentFinishOutcome(encoder, at: 0.1)
        async let second = concurrentFinishOutcome(encoder, at: 0.1)
        let outcomes = await [first, second]

        XCTAssertEqual(outcomes.filter { $0 == .success }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .alreadyFinished }.count, 1)
        XCTAssertEqual(calls.value, 1)
    }

    func testConsumerWriteFailureClosesDuplicateButLeavesTemporaryFileDescriptorValid() async throws {
        let duplicateDescriptor = LockedValue<Int32>(-1)
        let encoder = try GIFStreamEncoder(
            store: store,
            maximumFrames: 1,
            didDuplicateDescriptor: { descriptor in
                duplicateDescriptor.withValue { $0 = descriptor }
            },
            writeBytes: { _, _, _ in 0 }
        )
        let file = encoder.temporaryFileForDiscardAfterFailure
        let ownerDescriptor = file.withFileDescriptor { $0 }
        _ = await encoder.append(image: try solidImage(.red), timestamp: 0)

        await XCTAssertThrowsErrorAsync(try await encoder.finish(at: 0.1)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .consumerWriteFailed)
        }

        XCTAssertEqual(fcntl(duplicateDescriptor.value, F_GETFD), -1)
        XCTAssertNotEqual(fcntl(ownerDescriptor, F_GETFD), -1)
    }

    func testRepeatedEncodeReadbackClosesEveryConsumerDescriptor() async throws {
        for index in 0 ..< 25 {
            let duplicateDescriptor = LockedValue<Int32>(-1)
            let encoder = try GIFStreamEncoder(
                store: store,
                maximumFrames: 2,
                didDuplicateDescriptor: { descriptor in
                    duplicateDescriptor.withValue { $0 = descriptor }
                }
            )
            _ = await encoder.append(image: try solidImage(.red), timestamp: 0)
            _ = await encoder.append(image: try solidImage(.blue), timestamp: 0.1)
            let file = try await encoder.finish(at: 0.2)
            let source = try XCTUnwrap(
                CGImageSourceCreateWithURL(try store.validatedAccessURL(for: file) as CFURL, nil)
            )

            XCTAssertEqual(CGImageSourceGetCount(source), 2, "iteration \(index)")
            XCTAssertEqual(fcntl(duplicateDescriptor.value, F_GETFD), -1, "iteration \(index)")
        }
    }

    func testConsumerRetriesEINTRAndCompletesPartialWritesBeforeReturning() async throws {
        struct WriteProbe: Sendable {
            var calls = 0
            var successfulBytes = 0
            var sawEINTR = false
            var sawPartialWrite = false
        }
        let probe = LockedValue(WriteProbe())
        let closeCalls = LockedValue(0)
        let duplicateDescriptor = LockedValue<Int32>(-1)
        let encoder = try GIFStreamEncoder(
            store: store,
            maximumFrames: 2,
            didDuplicateDescriptor: { descriptor in
                duplicateDescriptor.withValue { $0 = descriptor }
            },
            writeBytes: { descriptor, buffer, count in
                let shouldInterrupt = probe.withValueReturning { value in
                    value.calls += 1
                    if !value.sawEINTR {
                        value.sawEINTR = true
                        return true
                    }
                    return false
                }
                if shouldInterrupt {
                    errno = EINTR
                    return -1
                }
                let requested = min(count, 7)
                let written = Darwin.write(descriptor, buffer, requested)
                probe.withValue { value in
                    if requested < count { value.sawPartialWrite = true }
                    if written > 0 { value.successfulBytes += written }
                }
                return written
            },
            closeDescriptor: { descriptor in
                closeCalls.withValue { $0 += 1 }
                return Darwin.close(descriptor)
            }
        )
        _ = await encoder.append(image: try solidImage(.red), timestamp: 0)
        _ = await encoder.append(image: try solidImage(.blue), timestamp: 0.1)
        let file = try await encoder.finish(at: 0.2)
        let url = try store.validatedAccessURL(for: file)
        let data = try Data(contentsOf: url)

        XCTAssertTrue(probe.value.sawEINTR)
        XCTAssertTrue(probe.value.sawPartialWrite)
        XCTAssertGreaterThan(probe.value.calls, 2)
        XCTAssertEqual(probe.value.successfulBytes, data.count)
        XCTAssertEqual(closeCalls.value, 1)
        XCTAssertEqual(fcntl(duplicateDescriptor.value, F_GETFD), -1)
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil))
    }

    func testWriteFailureCanBeExplicitlyDiscardedAndReleasesAllDescriptors() async throws {
        let duplicateDescriptor = LockedValue<Int32>(-1)
        let closeCalls = LockedValue(0)
        var encoder: GIFStreamEncoder? = try GIFStreamEncoder(
            store: store,
            maximumFrames: 1,
            didDuplicateDescriptor: { descriptor in
                duplicateDescriptor.withValue { $0 = descriptor }
            },
            writeBytes: { _, _, _ in 0 },
            closeDescriptor: { descriptor in
                closeCalls.withValue { $0 += 1 }
                return Darwin.close(descriptor)
            }
        )
        var file: TemporaryFile? = encoder!.temporaryFileForDiscardAfterFailure
        let ownerDescriptor = file!.withFileDescriptor { $0 }
        _ = await encoder!.append(image: try solidImage(.red), timestamp: 0)
        await XCTAssertThrowsErrorAsync(try await encoder!.finish(at: 0.1)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .consumerWriteFailed)
        }

        try store.discardTemporaryFile(file!)
        try store.discardTemporaryFile(file!)
        XCTAssertThrowsError(try store.validatedAccessURL(for: file!))
        XCTAssertEqual(fcntl(duplicateDescriptor.value, F_GETFD), -1)
        XCTAssertEqual(closeCalls.value, 1)

        encoder = nil
        file = nil
        XCTAssertEqual(fcntl(ownerDescriptor, F_GETFD), -1)
    }

    func testFinalizeFailureCanBeExplicitlyDiscardedWithoutLeavingAPathEntry() async throws {
        let closeCalls = LockedValue(0)
        var encoder: GIFStreamEncoder? = try GIFStreamEncoder(
            store: store,
            maximumFrames: 1,
            closeDescriptor: { descriptor in
                closeCalls.withValue { $0 += 1 }
                return Darwin.close(descriptor)
            },
            finalize: { _ in false }
        )
        var file: TemporaryFile? = encoder!.temporaryFileForDiscardAfterFailure
        let ownerDescriptor = file!.withFileDescriptor { $0 }
        _ = await encoder!.append(image: try solidImage(.red), timestamp: 0)
        await XCTAssertThrowsErrorAsync(try await encoder!.finish(at: 0.1)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .finalizationFailed)
        }

        try store.discardTemporaryFile(file!)
        try store.discardTemporaryFile(file!)
        XCTAssertThrowsError(try store.validatedAccessURL(for: file!))
        XCTAssertEqual(closeCalls.value, 1)
        encoder = nil
        file = nil
        XCTAssertEqual(fcntl(ownerDescriptor, F_GETFD), -1)
    }

    func testEncodingValidationFailureCanBeDiscardedAndClosesOnEncoderRelease() async throws {
        let closeCalls = LockedValue(0)
        let duplicateDescriptor = LockedValue<Int32>(-1)
        var encoder: GIFStreamEncoder? = try GIFStreamEncoder(
            store: store,
            maximumFrames: 1,
            didDuplicateDescriptor: { descriptor in
                duplicateDescriptor.withValue { $0 = descriptor }
            },
            closeDescriptor: { descriptor in
                closeCalls.withValue { $0 += 1 }
                return Darwin.close(descriptor)
            }
        )
        var file: TemporaryFile? = encoder!.temporaryFileForDiscardAfterFailure
        let ownerDescriptor = file!.withFileDescriptor { $0 }
        _ = await encoder!.append(image: try solidImage(.red), timestamp: 1)
        await XCTAssertThrowsErrorAsync(try await encoder!.finish(at: 1)) { error in
            XCTAssertEqual(error as? GIFStreamEncoder.EncodingError, .invalidStopTimestamp)
        }

        try store.discardTemporaryFile(file!)
        XCTAssertThrowsError(try store.validatedAccessURL(for: file!))
        encoder = nil
        XCTAssertEqual(closeCalls.value, 1)
        XCTAssertEqual(fcntl(duplicateDescriptor.value, F_GETFD), -1)
        file = nil
        XCTAssertEqual(fcntl(ownerDescriptor, F_GETFD), -1)
    }

    private enum Color { case red, green, blue }

    private func solidImage(_ color: Color) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        switch color {
        case .red: context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        case .green: context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        case .blue: context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        }
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func delays(in source: CGImageSource) throws -> [Double] {
        try (0 ..< CGImageSourceGetCount(source)).map { index in
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            )
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
            let clamped = gif[kCGImagePropertyGIFDelayTime] as? NSNumber
            XCTAssertNotNil(unclamped)
            XCTAssertNotNil(clamped)
            return try XCTUnwrap(unclamped ?? clamped).doubleValue
        }
    }

    private func storeEntries() throws -> [String] {
        let root = directory.appendingPathComponent("store", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
    }

}

private enum FinishOutcome: Equatable, Sendable {
    case success
    case alreadyFinished
    case unexpectedFailure
}

private func concurrentFinishOutcome(
    _ encoder: GIFStreamEncoder,
    at timestamp: TimeInterval
) async -> FinishOutcome {
    do {
        _ = try await encoder.finish(at: timestamp)
        return .success
    } catch GIFStreamEncoder.EncodingError.alreadyFinished {
        return .alreadyFinished
    } catch {
        return .unexpectedFailure
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }

    func withValueReturning<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        handler(error)
    }
}
