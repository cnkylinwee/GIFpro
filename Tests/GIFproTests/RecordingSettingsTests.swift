import XCTest
@testable import GIFpro

final class RecordingSettingsTests: XCTestCase {
    func testDefaultsMatchProductDecision() {
        XCTAssertEqual(
            RecordingSettings.default,
            .init(scale: .one, fps: .twelve, duration: .thirty, showsCursor: true)
        )
    }

    func testAllowedValuesMatchProductDecision() {
        XCTAssertEqual(RecordingSettings.Scale.allCases, [.one, .two])
        XCTAssertEqual(RecordingSettings.FramesPerSecond.allCases, [.eight, .twelve, .fifteen])
        XCTAssertEqual(RecordingSettings.Duration.allCases, [.fifteen, .thirty, .sixty, .ninety])
    }

    func testRawValuesMatchPersistedIntegers() {
        XCTAssertEqual(RecordingSettings.Scale.one.rawValue, 1)
        XCTAssertEqual(RecordingSettings.Scale.two.rawValue, 2)
        XCTAssertEqual(RecordingSettings.FramesPerSecond.eight.rawValue, 8)
        XCTAssertEqual(RecordingSettings.FramesPerSecond.twelve.rawValue, 12)
        XCTAssertEqual(RecordingSettings.FramesPerSecond.fifteen.rawValue, 15)
        XCTAssertEqual(RecordingSettings.Duration.fifteen.rawValue, 15)
        XCTAssertEqual(RecordingSettings.Duration.thirty.rawValue, 30)
        XCTAssertEqual(RecordingSettings.Duration.sixty.rawValue, 60)
        XCTAssertEqual(RecordingSettings.Duration.ninety.rawValue, 90)
    }

    func testInvalidPersistedIntegersFallBackToDefaultsIndependently() {
        let settings = RecordingSettings(
            scaleRawValue: 3,
            fpsRawValue: 24,
            durationRawValue: 45,
            showsCursor: false
        )

        XCTAssertEqual(settings.scale, .one)
        XCTAssertEqual(settings.fps, .twelve)
        XCTAssertEqual(settings.duration, .thirty)
        XCTAssertFalse(settings.showsCursor)
    }

    func testOneInvalidPersistedIntegerDoesNotChangeOtherValidFields() {
        let cases: [(RecordingSettings, RecordingSettings)] = [
            (
                RecordingSettings(
                    scaleRawValue: 3,
                    fpsRawValue: 15,
                    durationRawValue: 90,
                    showsCursor: false
                ),
                RecordingSettings(
                    scale: .one,
                    fps: .fifteen,
                    duration: .ninety,
                    showsCursor: false
                )
            ),
            (
                RecordingSettings(
                    scaleRawValue: 2,
                    fpsRawValue: 24,
                    durationRawValue: 90,
                    showsCursor: false
                ),
                RecordingSettings(
                    scale: .two,
                    fps: .twelve,
                    duration: .ninety,
                    showsCursor: false
                )
            ),
            (
                RecordingSettings(
                    scaleRawValue: 2,
                    fpsRawValue: 15,
                    durationRawValue: 45,
                    showsCursor: false
                ),
                RecordingSettings(
                    scale: .two,
                    fps: .fifteen,
                    duration: .thirty,
                    showsCursor: false
                )
            ),
        ]

        for (actual, expected) in cases {
            XCTAssertEqual(actual, expected)
        }
    }

    func testValidPersistedIntegersAreRestored() {
        let settings = RecordingSettings(
            scaleRawValue: 2,
            fpsRawValue: 15,
            durationRawValue: 90,
            showsCursor: false
        )

        XCTAssertEqual(
            settings,
            .init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false)
        )
    }
}
