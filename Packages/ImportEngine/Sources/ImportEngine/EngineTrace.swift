import CameraTransport
import Catalogue
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
    /// Committed to the staging folder and recorded with `markStaged`.
    case staged(String, StagedLocation?)
    /// A stage job left this file out: the catalogue has a staged copy of it (by content).
    case alreadyStaged(String)
    case skipped(String, SkipReason)
    /// A second copy of a file already in the listing or the pick (same name, capture second and size, another
    /// folder; Shamil's rule of 8 Nov): left out, since it is the same file.
    case sameFileListedTwice(String)
    case failed(String, FailureReason)
    case destinationChanged(DestinationDecision)
    /// A continue or a reconnect offered a route the job may not take (`ImportRoute.mayChange(to:)`): it kept its own.
    case routeRefused(DestinationDecision)
    case linkEvent(CameraLinkEvent)
    case paused(PauseReason)
    case resumed
    /// The download loop parks with a lane free.
    case idle(queued: Int, inFlight: Int)
    case tick(Duration)
    case published(Duration)
    case discardedLateFile
    /// A resumable download's checkpoint was written to the catalogue (`markPartial`) at this offset.
    case checkpointSaved(String, offset: UInt64)
    /// A file's commit is waiting for a checkpoint write that was in flight when it began, before it writes its row.
    case waitingForCheckpointWrites(String)
    /// That wait ran out (`ImportPolicy.checkpointWriteWait`): the row is written without it.
    case checkpointWritesUnsettled(String)
    /// The camera's file under this item's ID has another name or size than the partial file was begun from: the
    /// partial was dropped and the card is listed again.
    case identityChanged(String)
    case finished(JobOutcome)
}

extension EngineTrace {
    /// The name `retrying` uses for the listing.
    static let listingName = "(listing)"
}
