import CameraTransport
import Catalogue
import PhotosBridge

/// What the engine did, in its own order: emitted synchronously on the actor (or, for a discarded late file, by the
/// abandoned attempt) to the `EngineTraceSink` the engine was made with, which is `.none` unless the app passes one
/// (its `EngineTraceWording` turns each event into a line for the log; I8). Tests wait on it instead of sleeping.
///
/// No case carries a serial number, identifier, address or network name: file names (as the camera lists them), sizes,
/// counts, times and kinds only.
public enum EngineTrace: Sendable, Hashable {
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
    case skipped(String, ImportSkipReason)
    /// A second copy of a file already in the listing or the pick (same name, capture second and size, another
    /// folder; Shamil's rule of 8 Nov): left out, since it is the same file.
    case sameFileListedTwice(String)
    case failed(String, ImportFailureReason)
    /// One half of a RAW+JPEG pair is downloaded and kept until its partner is too (or won't be), so the pair is
    /// committed as one unit (section 7.1).
    case waitingForPartner(String)
    /// One half of a pair is committed as a lone file: its partner was skipped, or failed after its retries
    /// (section 7.1). The partner's own line says which.
    case committedWithoutPartner(String)
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
    /// A `.sessionLost` stamped with a session a reconnect replaced reached the engine late: ignored, the job carries
    /// on in the new session (I13). The generation is the link's count of sessions, not an identifier.
    case lateSessionLossIgnored(generation: Int)
    /// A `.partial` row's file is gone or shorter than its offset (iOS emptied Caches, the 7-day prune, a dropped
    /// partial): the row was sent back to offset 0 with no temporary file, so the next job copies the file from its
    /// start (`ImportEngine.reconcilePartials()`, I13).
    case partialReset(String)
    /// The job carries on after the camera was lost and listed again (`reconnect`, or `.storeAdded` on the same
    /// session): `sinceLost` is the time from the loss (the first removal, lost session or lost card since the job last
    /// ran) to now, when the card has been listed again and the queue is released; `filesLeft` is the files still to
    /// copy. The replug-to-resume time of decision D1.
    case reconnected(CameraCarrier, sinceLost: Duration?, filesLeft: Int)
    /// The first progress report of any download after `reconnected`: `bytes` is the file's size on disk at that
    /// report (from 0 on a link that copies the file again, from the checkpoint on one that resumes, plus the first
    /// read), `sinceResumed` the time from `reconnected` to the report.
    case firstByteAfterReconnect(String, bytes: UInt64, sinceResumed: Duration)
}

/// Where the engine's trace goes: a closure the app supplies, or nothing (`.none`, the default of
/// `ImportEngine.init`, which then builds no event at all beyond what the engine does itself).
public struct EngineTraceSink: Sendable {
    let sink: (@Sendable (EngineTrace) -> Void)?

    /// Calls `sink` with each event, synchronously on the engine's actor (a discarded late file's, on the abandoned
    /// attempt's task). It must return quickly and never block, nor call back into the engine.
    public init(_ sink: @escaping @Sendable (EngineTrace) -> Void) {
        self.sink = sink
    }

    private init() {
        sink = nil
    }

    /// Records nothing.
    public static let none = EngineTraceSink()

    /// Whether events go anywhere.
    public var isOn: Bool { sink != nil }

    /// Passes an event on, as the engine does.
    public func record(_ event: EngineTrace) { sink?(event) }
}

extension EngineTrace {
    /// The name `retrying` uses for the listing.
    public static let listingName = "(listing)"
}
