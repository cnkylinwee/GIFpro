import CoreGraphics
import XCTest
@testable import GIFpro

final class DisplayCoordinateConverterTests: XCTestCase {
    private let converter = DisplayCoordinateConverter()

    func testPrimaryDisplayUsesTopLeftLocalCoordinates() throws {
        let region = try converter.convert(
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            selection: CGRect(x: 100, y: 200, width: 300, height: 200),
            backingScale: 2,
            outputScale: .one
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 100, y: 500, width: 300, height: 200))
    }

    func testDisplayLeftOfPrimaryUsesDisplayLocalCoordinates() throws {
        let region = try converter.convert(
            displayID: 2,
            displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            selection: CGRect(x: -1800, y: 100, width: 300, height: 200),
            backingScale: 1,
            outputScale: .one
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 120, y: 780, width: 300, height: 200))
    }

    func testDisplayAbovePrimaryUsesDisplayLocalCoordinates() throws {
        let region = try converter.convert(
            displayID: 3,
            displayFrame: CGRect(x: 200, y: 900, width: 1280, height: 800),
            selection: CGRect(x: 300, y: 1300, width: 300, height: 200),
            backingScale: 2,
            outputScale: .one
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 100, y: 200, width: 300, height: 200))
    }

    func testRetinaOutputSizesAtOneAndTwoX() throws {
        let one = try makeRegion(backingScale: 2, outputScale: .one)
        let two = try makeRegion(backingScale: 2, outputScale: .two)

        XCTAssertEqual(one.logicalPixelSize, CGSize(width: 300, height: 200))
        XCTAssertEqual(one.outputPixelSize, CGSize(width: 300, height: 200))
        XCTAssertEqual(two.outputPixelSize, CGSize(width: 600, height: 400))
    }

    func testOneXDisplayAllowsTwoXOutput() throws {
        let region = try makeRegion(backingScale: 1, outputScale: .two)

        XCTAssertEqual(region.logicalPixelSize, CGSize(width: 300, height: 200))
        XCTAssertEqual(region.outputPixelSize, CGSize(width: 600, height: 400))
        XCTAssertEqual(region.backingScale, 1)
    }

    func testSelectionSmallerThanMinimumIsRejected() {
        XCTAssertThrowsError(try converter.convert(
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            selection: CGRect(x: 20, y: 20, width: 63, height: 64),
            backingScale: 2,
            outputScale: .one
        )) { error in
            XCTAssertEqual(error as? DisplayCoordinateConverter.Error, .selectionTooSmall)
        }
    }

    func testSelectionCrossingDisplayBoundsIsRejected() {
        XCTAssertThrowsError(try converter.convert(
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            selection: CGRect(x: 450, y: 100, width: 100, height: 100),
            backingScale: 2,
            outputScale: .one
        )) { error in
            XCTAssertEqual(error as? DisplayCoordinateConverter.Error, .selectionOutsideDisplay)
        }
    }

    private func makeRegion(
        backingScale: CGFloat,
        outputScale: RecordingSettings.Scale
    ) throws -> CaptureRegion {
        try converter.convert(
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            selection: CGRect(x: 100, y: 200, width: 300, height: 200),
            backingScale: backingScale,
            outputScale: outputScale
        )
    }
}
