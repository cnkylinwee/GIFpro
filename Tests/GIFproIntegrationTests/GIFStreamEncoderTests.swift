import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GIFpro

final class GIFStreamEncoderTests: XCTestCase {
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

    func testEncodesTimestampedFramesWithInfiniteLoopAndExpectedDelays() async throws {
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
        XCTAssertEqual((gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(try delays(in: source), [0.1, 0.2, 0.2])
    }

    func testCarriesCentisecondQuantizationAtCommonFrameRates() async throws {
        for fps in [8.0, 12.0, 15.0] {
            let encoder = try GIFStreamEncoder(store: store, maximumFrames: 4)
            let colors: [Color] = [.red, .green, .blue, .red]
            for index in 0 ..< 4 {
                let result = await encoder.append(
                    image: try solidImage(colors[index]),
                    timestamp: Double(index) / fps
                )
                XCTAssertEqual(result, .accepted)
            }
            let file = try await encoder.finish(at: 4.0 / fps)
            let source = try XCTUnwrap(
                CGImageSourceCreateWithURL(try store.validatedAccessURL(for: file) as CFURL, nil)
            )
            XCTAssertEqual(try delays(in: source).reduce(0, +), 4.0 / fps, accuracy: 0.011)
        }
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
