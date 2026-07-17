import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import GIFpro

final class CapturedFrameExtractionTests: XCTestCase {
    func testExtractsCompleteScreenFrameWithPresentationTime() throws {
        let pixelBuffer = try makePixelBuffer()
        let presentationTime = CMTime(value: 7, timescale: 12)
        let sampleBuffer = try makeSampleBuffer(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            status: .complete
        )

        let frame = try XCTUnwrap(
            CapturedFrameExtractor.extract(from: sampleBuffer, type: .screen)
        )

        XCTAssertTrue(frame.pixelBuffer === pixelBuffer)
        XCTAssertEqual(frame.presentationTime, presentationTime)
    }

    func testRejectsNonScreenAndIncompleteFrames() throws {
        let pixelBuffer = try makePixelBuffer()
        let incomplete = try makeSampleBuffer(
            pixelBuffer: pixelBuffer,
            presentationTime: .zero,
            status: .idle
        )
        let complete = try makeSampleBuffer(
            pixelBuffer: pixelBuffer,
            presentationTime: .zero,
            status: .complete
        )

        XCTAssertNil(CapturedFrameExtractor.extract(from: incomplete, type: .screen))
        XCTAssertNil(CapturedFrameExtractor.extract(from: complete, type: .audio))
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        return try XCTUnwrap(pixelBuffer)
    }

    private func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        status: SCFrameStatus
    ) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        let result = try XCTUnwrap(sampleBuffer)
        CMSetAttachment(
            result,
            key: SCStreamFrameInfo.status.rawValue as CFString,
            value: NSNumber(value: status.rawValue),
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return result
    }
}
