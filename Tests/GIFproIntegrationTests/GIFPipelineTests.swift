import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import GIFpro

final class GIFPipelineTests: XCTestCase {
    private var testDirectory: URL!
    private var storeRoot: URL!
    private var store: TemporaryFileStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFPipelineTests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = testDirectory.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        store = TemporaryFileStore(rootURL: storeRoot, availableCapacity: { 2_000_000_000 })
    }

    override func tearDownWithError() throws {
        store = nil
        if testDirectory != nil {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        storeRoot = nil
        try super.tearDownWithError()
    }

    func testRegularRetinaPipelineAtEverySupportedFrameRateAndScale() async throws {
        for fps in [8, 12, 15] {
            for scale in [1, 2] {
                let timestamps = (0 ..< fps).map { Double($0) / Double(fps) }
                try await assertPipeline(
                    fps: fps,
                    scale: scale,
                    timestamps: timestamps,
                    stopTimestamp: 1.0
                )
            }
        }
    }

    func testDroppedFramesPreserveElapsedDurationWithoutPadding() async throws {
        let fps = 12
        let timestamps = (0 ..< fps)
            .filter { $0 != 3 && $0 != 7 }
            .map { Double($0) / Double(fps) }

        let delays = try await assertPipeline(
            fps: fps,
            scale: 1,
            timestamps: timestamps,
            stopTimestamp: 1.0
        )

        XCTAssertEqual(delays.count, 10)
        XCTAssertTrue(
            delays.contains { $0 >= 0.16 },
            "A dropped delivery must extend a preceding frame rather than add padding frames"
        )
    }

    @discardableResult
    private func assertPipeline(
        fps: Int,
        scale: Int,
        timestamps: [TimeInterval],
        stopTimestamp: TimeInterval
    ) async throws -> [TimeInterval] {
        let processor = FrameProcessor()
        let encoder = try GIFStreamEncoder(store: store, maximumFrames: fps)
        let pixelBuffer = try makeRetinaPixelBuffer()
        let expectedSize = CGSize(width: 300 * scale, height: 200 * scale)
        var timing = FrameTiming()

        for timestamp in timestamps {
            XCTAssertNotNil(timing.accept(timestamp: timestamp))
            let image = try processor.process(
                pixelBuffer: pixelBuffer,
                targetPixelSize: expectedSize
            )
            XCTAssertEqual(image.width, Int(expectedSize.width))
            XCTAssertEqual(image.height, Int(expectedSize.height))
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
            let appendResult = await encoder.append(image: image, timestamp: timestamp)
            XCTAssertEqual(appendResult, .accepted)
        }
        XCTAssertNotNil(timing.finish(at: stopTimestamp))

        let file = try await encoder.finish(at: stopTimestamp)
        let accessURL = try store.validatedAccessURL(for: file)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(accessURL as CFURL, nil))

        XCTAssertEqual(CGImageSourceGetCount(source), timestamps.count)
        let firstImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(firstImage.width, Int(expectedSize.width))
        XCTAssertEqual(firstImage.height, Int(expectedSize.height))

        let properties = try XCTUnwrap(
            CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        )
        let gifProperties = try XCTUnwrap(
            properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        )
        XCTAssertEqual(
            (gifProperties[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue,
            1
        )

        let delays = try frameDelays(in: source)
        XCTAssertLessThanOrEqual(abs(delays.reduce(0, +) - stopTimestamp), 0.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: accessURL.path))

        try store.discardTemporaryFile(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: accessURL.path))
        XCTAssertEqual(try storeEntryNames(), [])
        return delays
    }

    private func makeRetinaPixelBuffer() throws -> CVPixelBuffer {
        let width = 600
        let height = 400
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferCGColorSpaceKey,
            CGColorSpace(name: CGColorSpace.sRGB)!,
            .shouldPropagate
        )
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0 ..< height {
            let rowBytes = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< width {
                let offset = column * 4
                rowBytes[offset] = UInt8(column % 256)
                rowBytes[offset + 1] = UInt8(row % 256)
                rowBytes[offset + 2] = UInt8((column + row) % 256)
                rowBytes[offset + 3] = 255
            }
        }
        return buffer
    }

    private func frameDelays(in source: CGImageSource) throws -> [TimeInterval] {
        try (0 ..< CGImageSourceGetCount(source)).map { index in
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            )
            let gif = try XCTUnwrap(
                properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            )
            let value = gif[kCGImagePropertyGIFUnclampedDelayTime]
                ?? gif[kCGImagePropertyGIFDelayTime]
            return try XCTUnwrap(value as? NSNumber).doubleValue
        }
    }

    private func storeEntryNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: storeRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: storeRoot.path).sorted()
    }
}
