import CoreGraphics
import CoreImage
import CoreVideo
import XCTest
@testable import GIFpro

final class FrameProcessorTests: XCTestCase {
    func testPreservesAsymmetricFourCornerOrientationAtOneAndTwoTimesScale() throws {
        let pixelBuffer = try makePixelBuffer(
            width: 2,
            height: 2,
            pixels: [
                0, 0, 255, 255,       0, 255, 0, 255,
                255, 0, 0, 255,       0, 255, 255, 255,
            ]
        )

        for scale in [1, 2] {
            let image = try FrameProcessor().process(
                pixelBuffer: pixelBuffer,
                targetPixelSize: CGSize(width: 2 * scale, height: 2 * scale)
            )
            let pixels = try rgbaBytes(of: image)

            assertPixel(pixels, imageWidth: image.width, x: 0, y: 0, is: (255, 0, 0))
            assertPixel(pixels, imageWidth: image.width, x: image.width - 1, y: 0, is: (0, 255, 0))
            assertPixel(pixels, imageWidth: image.width, x: 0, y: image.height - 1, is: (0, 0, 255))
            assertPixel(
                pixels,
                imageWidth: image.width,
                x: image.width - 1,
                y: image.height - 1,
                is: (255, 255, 0)
            )
        }
    }

    func testUsesSRGBAttachmentAndProducesSRGBOutput() throws {
        let pixelBuffer = try makePixelBuffer(width: 1, height: 1, pixels: [0, 0, 255, 255])
        var observedInputColorSpace: CFString?
        let processor = FrameProcessor(imageCreator: { context, image, bounds, colorSpace in
            observedInputColorSpace = image.colorSpace?.name
            return context.createCGImage(image, from: bounds, format: .BGRA8, colorSpace: colorSpace)
        })

        let image = try processor.process(
            pixelBuffer: pixelBuffer,
            targetPixelSize: CGSize(width: 1, height: 1)
        )

        XCTAssertEqual(observedInputColorSpace, CGColorSpace.sRGB)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testConvertsDisplayP3AttachmentToSRGBPixelsInsteadOfRelabelingInput() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let pixelBuffer = try makePixelBuffer(
            width: 1,
            height: 1,
            pixels: [24, 112, 224, 255],
            colorSpace: displayP3
        )
        var observedInputColorSpace: CFString?
        let context = CIContext()
        let processor = FrameProcessor(context: context, imageCreator: { context, image, bounds, colorSpace in
            observedInputColorSpace = image.colorSpace?.name
            return context.createCGImage(image, from: bounds, format: .BGRA8, colorSpace: colorSpace)
        })

        let output = try processor.process(
            pixelBuffer: pixelBuffer,
            targetPixelSize: CGSize(width: 1, height: 1)
        )
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let attachmentDrivenReference = try XCTUnwrap(
            context.createCGImage(
                CIImage(cvPixelBuffer: pixelBuffer),
                from: bounds,
                format: .BGRA8,
                colorSpace: sRGB
            )
        )
        let incorrectlyRelabeledReference = try XCTUnwrap(
            context.createCGImage(
                CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: sRGB]),
                from: bounds,
                format: .BGRA8,
                colorSpace: sRGB
            )
        )
        let actualPixel = try rgbaBytes(of: output)
        let expectedPixel = try rgbaBytes(of: attachmentDrivenReference)
        let relabeledPixel = try rgbaBytes(of: incorrectlyRelabeledReference)

        XCTAssertEqual(observedInputColorSpace, CGColorSpace.displayP3)
        XCTAssertEqual(output.colorSpace?.name, CGColorSpace.sRGB)
        for channel in 0 ..< 3 {
            XCTAssertEqual(actualPixel[channel], expectedPixel[channel], accuracy: 2)
        }
        XCTAssertTrue(
            zip(actualPixel.prefix(3), relabeledPixel.prefix(3)).contains {
                abs(Int($0) - Int($1)) >= 4
            },
            "The chosen Display P3 pixel must exercise a real numeric conversion"
        )
    }

    func testProcessesOneToOneBGRApixelBufferWithoutChangingPixels() throws {
        let pixelBuffer = try makePixelBuffer(
            width: 2,
            height: 1,
            pixels: [
                255, 0, 0, 255,
                0, 255, 255, 255,
            ]
        )

        let image = try FrameProcessor().process(
            pixelBuffer: pixelBuffer,
            targetPixelSize: CGSize(width: 2, height: 1)
        )

        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        let pixels = try rgbaBytes(of: image)
        XCTAssertLessThan(Int(pixels[0]), 30)
        XCTAssertLessThan(Int(pixels[1]), 30)
        XCTAssertGreaterThan(Int(pixels[2]), 200)
        XCTAssertGreaterThan(Int(pixels[4]), 200)
        XCTAssertGreaterThan(Int(pixels[5]), 200)
        XCTAssertLessThan(Int(pixels[6]), 30)
    }

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
        pixels: [UInt8],
        colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
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
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferCGColorSpaceKey,
            colorSpace,
            .shouldPropagate
        )
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0 ..< height {
            _ = pixels.withUnsafeBytes { bytes in
                memcpy(
                    baseAddress.advanced(by: row * rowBytes),
                    bytes.baseAddress!.advanced(by: row * width * 4),
                    width * 4
                )
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

    private func assertPixel(
        _ pixels: [UInt8],
        imageWidth: Int,
        x: Int,
        y: Int,
        is expected: (red: UInt8, green: UInt8, blue: UInt8),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let offset = (y * imageWidth + x) * 4
        XCTAssertEqual(pixels[offset], expected.red, accuracy: 2, file: file, line: line)
        XCTAssertEqual(pixels[offset + 1], expected.green, accuracy: 2, file: file, line: line)
        XCTAssertEqual(pixels[offset + 2], expected.blue, accuracy: 2, file: file, line: line)
    }
}
