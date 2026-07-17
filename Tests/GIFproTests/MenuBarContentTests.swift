import XCTest
@testable import GIFpro

@MainActor
final class MenuBarContentTests: XCTestCase {
    func testRecordingCommandUsesCoordinatorOwnedTitle() {
        struct FakeTitleProvider: RecordingCommandTitleProviding {
            let recordingCommandTitle: String
        }
        XCTAssertEqual(
            MenuBarContent.recordingCommandTitle(from: FakeTitleProvider(recordingCommandTitle: "停止录制")),
            "停止录制"
        )
    }

    func testCriticalFailuresHaveChineseMessagesAndRecoveryActions() {
        let permission = MenuBarPresentation.issue(state: .failed(.permissionDenied), lastFailure: nil, saveWarnings: [])
        XCTAssertTrue(permission?.message.contains("屏幕录制权限") == true)
        XCTAssertEqual(permission?.action, .recheckPermission)

        let disk = MenuBarPresentation.issue(state: .failed(.insufficientDiskSpace), lastFailure: nil, saveWarnings: [])
        XCTAssertTrue(disk?.message.contains("磁盘") == true)
        XCTAssertEqual(disk?.action, .rerecord)

        let save = MenuBarPresentation.issue(
            state: .previewReady(URL(fileURLWithPath: "/tmp/a.gif")),
            lastFailure: .saveFailed,
            saveWarnings: []
        )
        XCTAssertTrue(save?.message.contains("保存失败") == true)
        XCTAssertEqual(save?.actionTitle, "再次另存为")
        XCTAssertEqual(save?.action, .saveAgain)
    }

    func testSaveWarningsRemainVisibleWithoutOfferingAnInvalidAction() {
        let issue = MenuBarPresentation.issue(state: .idle, lastFailure: nil, saveWarnings: [.sourceCleanupFailed])
        XCTAssertTrue(issue?.message.contains("临时文件") == true)
        XCTAssertNil(issue?.action)
    }
}
