import Foundation

enum RecordingFailure: Equatable, Sendable {
    case permissionDenied
    case captureFailed
    case finalizationFailed
    case saveFailed
}

enum RecordingState: Equatable, Sendable {
    case idle
    case requestingPermission
    case selecting
    case countingDown
    case recording
    case finalizing
    case previewReady(URL)
    case awaitingSave(URL)
    case savedPreview(URL)
    case discarding
    case cancelling
    case failed(RecordingFailure)

    func canTransition(to next: RecordingState) -> Bool {
        switch self {
        case .idle:
            switch next {
            case .requestingPermission: return true
            case .idle, .selecting, .countingDown, .recording, .finalizing,
                 .previewReady, .awaitingSave, .savedPreview, .discarding,
                 .cancelling, .failed: return false
            }

        case .requestingPermission:
            switch next {
            case .selecting, .failed: return true
            case .idle, .requestingPermission, .countingDown, .recording,
                 .finalizing, .previewReady, .awaitingSave, .savedPreview,
                 .discarding, .cancelling: return false
            }

        case .selecting:
            switch next {
            case .countingDown, .cancelling, .failed: return true
            case .idle, .requestingPermission, .selecting, .recording,
                 .finalizing, .previewReady, .awaitingSave, .savedPreview,
                 .discarding: return false
            }

        case .countingDown:
            switch next {
            case .recording, .cancelling, .failed: return true
            case .idle, .requestingPermission, .selecting, .countingDown,
                 .finalizing, .previewReady, .awaitingSave, .savedPreview,
                 .discarding: return false
            }

        case .recording:
            switch next {
            case .finalizing, .cancelling, .failed: return true
            case .idle, .requestingPermission, .selecting, .countingDown,
                 .recording, .previewReady, .awaitingSave, .savedPreview,
                 .discarding: return false
            }

        case .finalizing:
            switch next {
            case .previewReady, .failed: return true
            case .idle, .requestingPermission, .selecting, .countingDown,
                 .recording, .finalizing, .awaitingSave, .savedPreview,
                 .discarding, .cancelling: return false
            }

        case .previewReady:
            switch next {
            case .selecting, .awaitingSave, .discarding: return true
            case .idle, .requestingPermission, .countingDown, .recording,
                 .finalizing, .previewReady, .savedPreview, .cancelling,
                 .failed: return false
            }

        case .awaitingSave:
            switch next {
            case .previewReady, .savedPreview, .failed: return true
            case .idle, .requestingPermission, .selecting, .countingDown,
                 .recording, .finalizing, .awaitingSave, .discarding,
                 .cancelling: return false
            }

        case .savedPreview:
            switch next {
            case .idle: return true
            case .requestingPermission, .selecting, .countingDown, .recording,
                 .finalizing, .previewReady, .awaitingSave, .savedPreview,
                 .discarding, .cancelling, .failed: return false
            }

        case .discarding:
            switch next {
            case .idle, .failed: return true
            case .requestingPermission, .selecting, .countingDown, .recording,
                 .finalizing, .previewReady, .awaitingSave, .savedPreview,
                 .discarding, .cancelling: return false
            }

        case .cancelling:
            switch next {
            case .idle, .failed: return true
            case .requestingPermission, .selecting, .countingDown, .recording,
                 .finalizing, .previewReady, .awaitingSave, .savedPreview,
                 .discarding, .cancelling: return false
            }

        case .failed:
            switch next {
            case .idle, .requestingPermission: return true
            case .selecting, .countingDown, .recording, .finalizing,
                 .previewReady, .awaitingSave, .savedPreview, .discarding,
                 .cancelling, .failed: return false
            }
        }
    }
}
