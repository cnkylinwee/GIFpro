import Foundation
import XCTest
@testable import GIFpro

final class RecordingStateTests: XCTestCase {
    private enum StateCase: String, CaseIterable, Hashable {
        case idle
        case requestingPermission
        case selecting
        case countingDown
        case recording
        case finalizing
        case previewReady
        case awaitingSave
        case savedPreview
        case discarding
        case cancelling
        case failed
    }

    private let previewURL = URL(fileURLWithPath: "/tmp/preview.gif")
    private let savedURL = URL(fileURLWithPath: "/tmp/saved.gif")

    private func state(for stateCase: StateCase) -> RecordingState {
        switch stateCase {
        case .idle: return .idle
        case .requestingPermission: return .requestingPermission
        case .selecting: return .selecting
        case .countingDown: return .countingDown
        case .recording: return .recording
        case .finalizing: return .finalizing
        case .previewReady: return .previewReady(previewURL)
        case .awaitingSave: return .awaitingSave(previewURL)
        case .savedPreview: return .savedPreview(savedURL)
        case .discarding: return .discarding
        case .cancelling: return .cancelling
        case .failed: return .failed(.captureFailed)
        }
    }

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

    func testTransitionPolicyForEveryPairOfStateCases() {
        let allowedDestinations: [StateCase: Set<StateCase>] = [
            .idle: [.requestingPermission],
            .requestingPermission: [.selecting, .failed],
            .selecting: [.countingDown, .cancelling, .failed],
            .countingDown: [.recording, .cancelling, .failed],
            .recording: [.finalizing, .cancelling, .failed],
            .finalizing: [.previewReady, .failed],
            .previewReady: [.selecting, .awaitingSave, .discarding, .failed],
            .awaitingSave: [.previewReady, .savedPreview, .discarding, .failed],
            .savedPreview: [.idle],
            .discarding: [.idle, .failed],
            .cancelling: [.idle, .failed],
            .failed: [.idle, .requestingPermission],
        ]

        for sourceCase in StateCase.allCases {
            for destinationCase in StateCase.allCases {
                let expected = allowedDestinations[sourceCase, default: []].contains(destinationCase)
                let actual = state(for: sourceCase).canTransition(to: state(for: destinationCase))

                XCTAssertEqual(
                    actual,
                    expected,
                    "Unexpected policy for \(sourceCase.rawValue) → \(destinationCase.rawValue)"
                )
            }
        }
    }

    func testPreviewAndAwaitingSaveRejectMismatchedTemporaryFiles() {
        let otherPreviewURL = URL(fileURLWithPath: "/tmp/other-preview.gif")

        XCTAssertFalse(
            RecordingState.previewReady(previewURL)
                .canTransition(to: .awaitingSave(otherPreviewURL))
        )
        XCTAssertFalse(
            RecordingState.awaitingSave(previewURL)
                .canTransition(to: .previewReady(otherPreviewURL))
        )
    }

    func testSavingCanMoveFromTemporaryFileToDifferentDestination() {
        XCTAssertTrue(
            RecordingState.awaitingSave(previewURL)
                .canTransition(to: .savedPreview(savedURL))
        )
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
