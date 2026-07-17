@preconcurrency import CoreGraphics
@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

final class FrameProcessor {
    enum ProcessingError: Error, Equatable {
        case invalidTargetPixelSize
        case imageCreationFailed
    }

    typealias ImageCreator = (
        CIContext,
        CIImage,
        CGRect,
        CGColorSpace
    ) -> CGImage?

    private let context: CIContext
    private let imageCreator: ImageCreator
    private let outputColorSpace: CGColorSpace

    init(
        context: CIContext = CIContext(),
        imageCreator: @escaping ImageCreator = { context, image, bounds, colorSpace in
            context.createCGImage(image, from: bounds, format: .BGRA8, colorSpace: colorSpace)
        }
    ) {
        self.context = context
        self.imageCreator = imageCreator
        outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    }

    func process(
        pixelBuffer: CVPixelBuffer,
        targetPixelSize: CGSize
    ) throws -> CGImage {
        guard targetPixelSize.width.isFinite,
              targetPixelSize.height.isFinite,
              targetPixelSize.width > 0,
              targetPixelSize.height > 0,
              targetPixelSize.width.rounded(.towardZero) == targetPixelSize.width,
              targetPixelSize.height.rounded(.towardZero) == targetPixelSize.height
        else {
            throw ProcessingError.invalidTargetPixelSize
        }

        return try autoreleasepool {
            let source = CIImage(cvPixelBuffer: pixelBuffer)
            guard source.extent.width > 0, source.extent.height > 0 else {
                throw ProcessingError.imageCreationFailed
            }
            let renderedImage: CIImage
            if source.extent.size == targetPixelSize, source.extent.origin == .zero {
                renderedImage = source
            } else {
                let transform = CGAffineTransform(
                    scaleX: targetPixelSize.width / source.extent.width,
                    y: targetPixelSize.height / source.extent.height
                ).translatedBy(x: -source.extent.minX, y: -source.extent.minY)
                renderedImage = source.transformed(by: transform)
            }
            let bounds = CGRect(origin: .zero, size: targetPixelSize)
            guard let image = imageCreator(context, renderedImage, bounds, outputColorSpace) else {
                throw ProcessingError.imageCreationFailed
            }
            return image
        }
    }
}
