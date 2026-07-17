import XCTest
@testable import GIFpro

final class AppSmokeTests: XCTestCase {
    func testApplicationIdentity() {
        XCTAssertEqual(AppIdentity.name, "GIFpro")
        XCTAssertEqual(AppIdentity.minimumSystemVersion, "14.0")
    }
}
