import CoreGraphics
import CoreImage
import CoreVideo
import XCTest
@testable import GIFpro

final class FrameProcessorTests: XCTestCase {
    func testProcessesBGRApixelBufferAtExactTargetSizeInSRGB() throws {
        let pixelBuffer = try makePixelBuffer(
            width: 2,
            height: 1,
            pixels: [
                0, 0, 255, 255,
                0, 255, 0, 255,
            ]
        )

        let image = try FrameProcessor().process(
            pixelBuffer: pixelBuffer,
            targetPixelSize: CGSize(width: 4, height: 2)
        )

        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        let pixels = try rgbaBytes(of: image)
        XCTAssertGreaterThan(Int(pixels[0]), 200)
        XCTAssertLessThan(Int(pixels[1]), 30)
        XCTAssertLessThan(Int(pixels[2]), 30)
        let lastPixel = (image.width - 1) * 4
        XCTAssertLessThan(Int(pixels[lastPixel]), 30)
        XCTAssertGreaterThan(Int(pixels[lastPixel + 1]), 200)
        XCTAssertLessThan(Int(pixels[lastPixel + 2]), 30)
    }

    func testRejectsInvalidTargetPixelSizes() throws {
        let pixelBuffer = try makePixelBuffer(width: 1, height: 1, pixels: [0, 0, 0, 255])
        let invalidSizes = [
            CGSize(width: 0, height: 1),
            CGSize(width: 1, height: 0),
            CGSize(width: -1, height: 1),
            CGSize(width: CGFloat.infinity, height: 1),
            CGSize(width: 1.5, height: 1),
        ]

        for size in invalidSizes {
            XCTAssertThrowsError(
                try FrameProcessor().process(pixelBuffer: pixelBuffer, targetPixelSize: size)
            ) { error in
                XCTAssertEqual(error as? FrameProcessor.ProcessingError, .invalidTargetPixelSize)
            }
        }
    }

    func testReportsTypedErrorWhenCoreImageCannotCreateImage() throws {
        let pixelBuffer = try makePixelBuffer(width: 1, height: 1, pixels: [0, 0, 0, 255])
        let processor = FrameProcessor(imageCreator: { _, _, _, _ in nil })

        XCTAssertThrowsError(
            try processor.process(
                pixelBuffer: pixelBuffer,
                targetPixelSize: CGSize(width: 1, height: 1)
            )
        ) { error in
            XCTAssertEqual(error as? FrameProcessor.ProcessingError, .imageCreationFailed)
        }
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        pixels: [UInt8]
    ) throws -> CVPixelBuffer {
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
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0 ..< height {
            _ = pixels.withUnsafeBytes { bytes in
                memcpy(baseAddress.advanced(by: row * rowBytes), bytes.baseAddress!, width * 4)
            }
        }
        return buffer
    }

    private func rgbaBytes(of image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = bytes.withUnsafeMutableBytes { storage in
            CGContext(
                data: storage.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        let drawingContext = try XCTUnwrap(context)
        drawingContext.interpolationQuality = .none
        drawingContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
