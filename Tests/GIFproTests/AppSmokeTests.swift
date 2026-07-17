import XCTest
@testable import GIFpro

final class AppSmokeTests: XCTestCase {
    func testApplicationIdentity() {
        XCTAssertEqual(AppIdentity.name, "GIFpro")
        XCTAssertEqual(AppIdentity.minimumSystemVersion, "14.0")
    }

    @MainActor
    func testRecordingCommandTitleReflectsRecordingState() {
        let router = RecordingCommandRouter(state: .idle)
        XCTAssertEqual(router.recordingCommandTitle, "开始录制")

        router.state = .recording
        XCTAssertEqual(router.recordingCommandTitle, "停止录制")
    }

    @MainActor
    func testTemporaryRecordingCommandLogsWithoutFakingAStateChange() {
        var loggedStates: [RecordingState] = []
        let router = RecordingCommandRouter(state: .idle) {
            loggedStates.append($0)
        }

        router.performRecordingCommand()

        XCTAssertEqual(loggedStates, [.idle])
        XCTAssertEqual(router.state, .idle)
    }
}
