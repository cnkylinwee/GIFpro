import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ImageIODestinationCompatibilityTests: XCTestCase {
    func testFinalizesWithFewerFramesThanDeclaredMaximum() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("fewer-than-count.gif")
            let destination = try XCTUnwrap(
                CGImageDestinationCreateWithURL(
                    url as CFURL,
                    UTType.gif.identifier as CFString,
                    10,
                    nil
                )
            )

            CGImageDestinationAddImage(destination, try solidImage(red: 1, green: 0, blue: 0), nil)
            CGImageDestinationAddImage(destination, try solidImage(red: 0, green: 0, blue: 1), nil)

            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 2)
        }
    }

    func testFinalizesWithExactlyDeclaredFrameCount() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("exact-count.gif")
            let destination = try XCTUnwrap(
                CGImageDestinationCreateWithURL(
                    url as CFURL,
                    UTType.gif.identifier as CFString,
                    2,
                    nil
                )
            )

            CGImageDestinationAddImage(destination, try solidImage(red: 1, green: 0, blue: 0), nil)
            CGImageDestinationAddImage(destination, try solidImage(red: 0, green: 0, blue: 1), nil)

            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 2)
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        try body(directory)
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
