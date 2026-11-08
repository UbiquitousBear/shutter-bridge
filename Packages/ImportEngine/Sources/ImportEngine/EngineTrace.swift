import CameraTransport
import PhotosBridge

/// What the engine did, in its own order: emitted synchronously on the actor (or, for a discarded late file, by the
/// abandoned attempt) through an internal hook that the public initialiser leaves empty. Tests wait on it instead of
/// sleeping.
enum EngineTrace: Sendable, Hashable {
    case listed(onCard: Int, queued: Int)
    /// A `bytes` call began; `attempt` counts every call for the file.
    case started(String, attempt: Int)
    /// A real error, retried at `until` (computed before this is emitted, so an early clock advance is never lost).
    case retrying(String, retry: Int, until: Duration)
    case stalled(String, count: Int)
    case sizeMismatch(String, expected: UInt64, actual: UInt64)
    case imported(String, DestinationKind)
    case skipped(String, SkipReason)
    /// A second copy of a file already in the listing or the pick (same name, capture second and size, another
    /// folder; Shamil's rule of 8 Nov): left out, since it is the same file.
    case sameFileListedTwice(String)
    case failed(String, FailureReason)
    case destinationChanged(DestinationDecision)
    case linkEvent(CameraLinkEvent)
    case paused(PauseReason)
    case resumed
    /// The download loop parks with a lane free.
    case idle(queued: Int, inFlight: Int)
    case tick(Duration)
    case published(Duration)
    case discardedLateFile
    case finished(JobOutcome)
}

extension EngineTrace {
    /// The name `retrying` uses for the listing.
    static let listingName = "(listing)"
}
