import Foundation
import XCTest
@testable import GIFpro

final class RecordingStateTests: XCTestCase {
    private let previewURL = URL(fileURLWithPath: "/tmp/preview.gif")
    private let savedURL = URL(fileURLWithPath: "/tmp/saved.gif")

    func testHappyPathTransitions() {
        let states: [RecordingState] = [
            .idle,
            .requestingPermission,
            .selecting,
            .countingDown,
            .recording,
            .finalizing,
            .previewReady(previewURL),
            .awaitingSave(previewURL),
            .savedPreview(savedURL),
            .idle,
        ]

        for (current, next) in zip(states, states.dropFirst()) {
            XCTAssertTrue(current.canTransition(to: next), "Expected \(current) → \(next) to be allowed")
        }
    }

    func testInvalidTransitionsAreRejected() {
        XCTAssertFalse(RecordingState.idle.canTransition(to: .recording))
        XCTAssertFalse(RecordingState.recording.canTransition(to: .selecting))
        XCTAssertFalse(RecordingState.awaitingSave(previewURL).canTransition(to: .recording))
    }

    func testCancellingSaveReturnsToPreviewAndCanTryAgain() {
        let awaitingSave = RecordingState.awaitingSave(previewURL)
        let previewReady = RecordingState.previewReady(previewURL)

        XCTAssertTrue(awaitingSave.canTransition(to: previewReady))
        XCTAssertTrue(previewReady.canTransition(to: awaitingSave))
    }

    func testPreviewCanStartAReplacementRecording() {
        XCTAssertTrue(RecordingState.previewReady(previewURL).canTransition(to: .selecting))
    }

    func testSavedPreviewCannotStartAReplacementRecording() {
        XCTAssertFalse(RecordingState.savedPreview(savedURL).canTransition(to: .selecting))
    }

    func testSavedPreviewCannotBeDiscarded() {
        XCTAssertFalse(RecordingState.savedPreview(savedURL).canTransition(to: .discarding))
    }

    func testCancellationDiscardAndFailureRecoveryTransitions() {
        XCTAssertTrue(RecordingState.selecting.canTransition(to: .cancelling))
        XCTAssertTrue(RecordingState.countingDown.canTransition(to: .cancelling))
        XCTAssertTrue(RecordingState.recording.canTransition(to: .cancelling))
        XCTAssertTrue(RecordingState.cancelling.canTransition(to: .idle))

        XCTAssertTrue(RecordingState.previewReady(previewURL).canTransition(to: .discarding))
        XCTAssertTrue(RecordingState.discarding.canTransition(to: .idle))

        let failed = RecordingState.failed(.captureFailed)
        XCTAssertTrue(RecordingState.recording.canTransition(to: failed))
        XCTAssertTrue(failed.canTransition(to: .requestingPermission))
        XCTAssertTrue(failed.canTransition(to: .idle))
    }
}
