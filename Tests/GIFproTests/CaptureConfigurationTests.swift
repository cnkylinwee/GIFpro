import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import GIFpro

final class CaptureConfigurationTests: XCTestCase {
    func testMapsRegionAndFixedStreamProperties() {
        let configuration = CaptureConfiguration.makeStreamConfiguration(
            region: makeRegion(),
            settings: makeSettings(fps: .twelve, showsCursor: false)
        )

        XCTAssertEqual(configuration.sourceRect, CGRect(x: 12, y: 34, width: 320, height: 180))
        XCTAssertEqual(configuration.width, 640)
        XCTAssertEqual(configuration.height, 360)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.queueDepth, 3)
        XCTAssertFalse(configuration.showsCursor)
        XCTAssertFalse(configuration.capturesAudio)
    }

    func testMapsEverySupportedFrameRateToMinimumFrameInterval() {
        let cases: [(RecordingSettings.FramesPerSecond, CMTime)] = [
            (.eight, CMTime(value: 1, timescale: 8)),
            (.twelve, CMTime(value: 1, timescale: 12)),
            (.fifteen, CMTime(value: 1, timescale: 15)),
        ]

        for (fps, expectedInterval) in cases {
            let configuration = CaptureConfiguration.makeStreamConfiguration(
                region: makeRegion(),
                settings: makeSettings(fps: fps, showsCursor: true)
            )

            XCTAssertEqual(configuration.minimumFrameInterval, expectedInterval, "fps: \(fps)")
        }
    }

    private func makeRegion() -> CaptureRegion {
        CaptureRegion(
            displayID: 42,
            globalRect: CGRect(x: 100, y: 200, width: 320, height: 180),
            sourceRect: CGRect(x: 12, y: 34, width: 320, height: 180),
            logicalPixelSize: CGSize(width: 320, height: 180),
            outputPixelSize: CGSize(width: 640, height: 360),
            backingScale: 2
        )
    }

    private func makeSettings(
        fps: RecordingSettings.FramesPerSecond,
        showsCursor: Bool
    ) -> RecordingSettings {
        RecordingSettings(
            scale: .two,
            fps: fps,
            duration: .thirty,
            showsCursor: showsCursor
        )
    }
}

final class ShareableContentSelectionTests: XCTestCase {
    func testSelectsRequestedDisplayAndCurrentProcess() throws {
        let snapshot = ShareableContentSnapshot.testing(
            displayIDs: [7, 42],
            processIDs: [100, 200]
        )

        let selection = try ShareableContentSelector.select(
            from: snapshot,
            displayID: 42,
            processID: 200
        )

        XCTAssertEqual(selection.display.displayID, 42)
        XCTAssertEqual(selection.application.processID, 200)
    }

    func testMissingDisplayIsTypedError() {
        let snapshot = ShareableContentSnapshot.testing(displayIDs: [7], processIDs: [200])

        XCTAssertThrowsError(
            try ShareableContentSelector.select(from: snapshot, displayID: 42, processID: 200)
        ) { error in
            XCTAssertEqual(error as? CaptureError, .displayUnavailable(displayID: 42))
        }
    }

    func testMissingSelfApplicationIsTypedError() {
        let snapshot = ShareableContentSnapshot.testing(displayIDs: [42], processIDs: [100])

        XCTAssertThrowsError(
            try ShareableContentSelector.select(from: snapshot, displayID: 42, processID: 200)
        ) { error in
            XCTAssertEqual(error as? CaptureError, .selfApplicationUnavailable(processID: 200))
        }
    }
}

final class CaptureErrorMappingTests: XCTestCase {
    func testSystemStoppedStreamErrorIsNotReportedAsDisplayRemoval() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: -3821,
            userInfo: [NSLocalizedDescriptionKey: "system stopped stream"]
        )

        XCTAssertEqual(CaptureError.wrapping(error), .systemStopped)
    }

    func testNonScreenCaptureErrorPreservesCodeAndDiagnostic() {
        let error = NSError(
            domain: "CaptureTest",
            code: 91,
            userInfo: [NSLocalizedDescriptionKey: "transport failed"]
        )

        XCTAssertEqual(
            CaptureError.wrapping(error),
            .streamFailure(code: 91, message: "transport failed")
        )
    }
}
