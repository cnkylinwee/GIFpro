import CoreMedia
import CoreVideo

struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}
