import ImportEngine

/// The haptic an outcome plays (HIG Playing haptics): success when something the person asked for is done, a warning
/// when it needs them, an error when it failed, and the selection tick. Plain Swift, so the rules are tested on Linux;
/// the screens map it to SwiftUI's `SensoryFeedback`. Nothing plays for progress, for a cancel the person chose, or
/// for a pause they made.
public enum OutcomeFeedback: Sendable, Hashable {
    case success
    case warning
    case error
    case selection

    /// For *Copy as JPEG* and *Share as JPEG…*: success once the JPEG is copied or the share sheet is done, an error
    /// when it failed; nothing while it works or after a cancel (which leaves the action idle).
    public static func forJPEGAction(_ state: JPEGActionState) -> OutcomeFeedback? {
        switch state {
        case .finished: .success
        case .failed: .error
        case .idle, .working: nil
        }
    }

    /// For the import, when its state changes kind: success when it finishes with every file imported or skipped, a
    /// warning when it finishes with failed files or stops to wait for the person or the camera (a removed or
    /// unreachable camera, a card it stopped offering, a network to join, a stall only they can lift), an error when
    /// it stops. Nothing for starting, carrying on, a pause the person or the app's leaving made (including iOS
    /// ending its background time), a stall the engine retries by itself, or a cancel.
    public static func forImport(from old: ImportFeedbackState, to new: ImportFeedbackState) -> OutcomeFeedback? {
        guard old.state != new.state else { return nil }
        switch new.state.state {
        case .idle, .running:
            return nil
        case let .paused(reason):
            switch reason {
            case .cameraRemoved, .cameraUnreachable, .cardUnavailable, .needsJoin: return .warning
            case .stalled: return new.state.isAutomaticRetry ? nil : .warning
            case .byPerson, .appInBackground, .taskExpired: return nil
            }
        case let .finished(outcome):
            switch outcome {
            case .completed: return new.failedFiles > 0 ? .warning : .success
            case .cancelled: return nil
            case .stopped, .catalogueUnavailable, .photosAccessNeeded: return .error
            }
        }
    }
}

/// The import as its haptic sees it (`ImportModel.feedbackState`).
public struct ImportFeedbackState: Sendable, Hashable {
    public var state: ImportWording.AnnouncedState
    public var failedFiles: Int

    public init(state: ImportWording.AnnouncedState, failedFiles: Int = 0) {
        self.state = state
        self.failedFiles = failedFiles
    }
}
