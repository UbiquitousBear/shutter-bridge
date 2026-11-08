import CameraTransport

/// Why a job is paused. A pause is normal, not a failure (decision 4); the Import screen says which.
public enum PauseReason: String, Sendable, Hashable, CaseIterable {
    /// The app left the foreground and the link suspended: "open to continue" (decision 1).
    case appInBackground
    /// The camera was removed; the job carries on when it is back and listed.
    case cameraRemoved
    /// A download stopped making progress; it is retried (decision 4).
    case stalled
    /// The person paused it.
    case byPerson
}

/// How a job ended.
public enum JobOutcome: Sendable, Hashable {
    case completed
    case cancelled
    /// A failure with the outcome `.stopJob`, such as the phone's storage being full.
    case stopped(CameraLinkFailure.Kind)
    /// The catalogue couldn't be read or written: going on would import files again later, so the job stopped.
    case catalogueUnavailable
}

/// The engine's single job, as the UI sees it.
public enum ImportJobState: Sendable, Hashable {
    case idle
    case running
    case paused(PauseReason)
    case finished(JobOutcome)

    /// Whether a job exists that hasn't finished.
    public var isActive: Bool {
        switch self {
        case .running, .paused: true
        case .idle, .finished: false
        }
    }
}

/// Why the engine refused a request.
public enum ImportEngineError: Error, Sendable, Hashable {
    /// A job is already running or paused; add to it with `append(_:)` instead.
    case jobInProgress
    /// There is no job to pause, resume, reconnect or append to.
    case noJob
    /// An explicit selection with nothing in it.
    case emptySelection
    /// `reconnect(_:to:)` while the job isn't waiting for the camera to come back.
    case cameraNotRemoved
    /// The catalogue couldn't say which of the appended files are already imported.
    case catalogueUnavailable
}
