import CoreGraphics
import XCTest
@testable import GIFpro

final class CaptureRegionTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
    private let initial = CGRect(x: 100, y: 100, width: 200, height: 150)

    func testEveryHandleMovesItsNamedEdgeOrCorner() {
        let cases: [(ResizeHandle, CGPoint, CGRect)] = [
            (.top, CGPoint(x: 0, y: 20), CGRect(x: 100, y: 100, width: 200, height: 170)),
            (.bottom, CGPoint(x: 0, y: 20), CGRect(x: 100, y: 120, width: 200, height: 130)),
            (.left, CGPoint(x: 20, y: 0), CGRect(x: 120, y: 100, width: 180, height: 150)),
            (.right, CGPoint(x: 20, y: 0), CGRect(x: 100, y: 100, width: 220, height: 150)),
            (.topLeft, CGPoint(x: 20, y: 20), CGRect(x: 120, y: 100, width: 180, height: 170)),
            (.topRight, CGPoint(x: 20, y: 20), CGRect(x: 100, y: 100, width: 220, height: 170)),
            (.bottomLeft, CGPoint(x: 20, y: 20), CGRect(x: 120, y: 120, width: 180, height: 130)),
            (.bottomRight, CGPoint(x: 20, y: 20), CGRect(x: 100, y: 120, width: 220, height: 130)),
        ]

        for (handle, translation, expected) in cases {
            XCTAssertEqual(
                SelectionGeometry.resized(initial, handle: handle, translation: translation, within: bounds),
                expected,
                "handle: \(handle)"
            )
        }
    }

    func testResizingClampsEachDisplayEdge() {
        XCTAssertEqual(
            SelectionGeometry.resized(initial, handle: .topRight, translation: CGPoint(x: 400, y: 400), within: bounds),
            CGRect(x: 100, y: 100, width: 400, height: 300)
        )
        XCTAssertEqual(
            SelectionGeometry.resized(initial, handle: .bottomLeft, translation: CGPoint(x: -400, y: -400), within: bounds),
            CGRect(x: 0, y: 0, width: 300, height: 250)
        )
    }

    func testResizingPreservesMinimumSize() {
        XCTAssertEqual(
            SelectionGeometry.resized(initial, handle: .topLeft, translation: CGPoint(x: 500, y: -500), within: bounds),
            CGRect(x: 236, y: 100, width: 64, height: 64)
        )
    }

    func testCaptureRegionStoresAllCaptureMetadata() throws {
        let region = try DisplayCoordinateConverter().convert(
            displayID: 42,
            displayFrame: bounds,
            selection: initial,
            backingScale: 2,
            outputScale: .two
        )

        XCTAssertEqual(region.displayID, 42)
        XCTAssertEqual(region.globalRect, initial)
        XCTAssertEqual(region.sourceRect, CGRect(x: 100, y: 150, width: 200, height: 150))
        XCTAssertEqual(region.logicalPixelSize, CGSize(width: 200, height: 150))
        XCTAssertEqual(region.outputPixelSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(region.backingScale, 2)
    }
}
