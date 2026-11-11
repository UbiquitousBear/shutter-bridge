import CameraTransport
import Foundation

/// Why a job is paused. A pause is normal, not a failure (decision 4); the Import screen says which. A job can be
/// paused for several reasons at once; `ImportJobState.paused` shows the one the person has to deal with first.
///
/// The reasons that wait for the camera (`cameraRemoved`, `cameraUnreachable`, `cardUnavailable`, `needsJoin`) and
/// the continued task's expiry are lifted by `ImportEngine.reconnect(_:to:knownItems:route:)`; the person's, the
/// app's and a stall's by `resume(_:to:)`. Every reason is transport-neutral (backlog Iteration 3, section 0): the
/// link's events and failures decide which one a job gets, never its carrier.
public enum PauseReason: String, Sendable, Hashable, CaseIterable {
    /// The app left the foreground and the link suspended: "open to continue" (decision 1).
    case appInBackground
    /// The camera was removed (`CameraLinkEvent.removed`, or a `disconnected` failure on a link that never lost
    /// its session): the job carries on when it is back and listed.
    case cameraRemoved
    /// A download stopped making progress; it is retried (decision 4).
    case stalled
    /// The person paused it.
    case byPerson
    /// The continued task that runs the import (`BGContinuedProcessingTask`) expired, or the person stopped it from
    /// the system's UI. The app flushes the checkpoints (`ImportEngine.flushCheckpoints()`) first, then pauses with
    /// this (backlog Iteration 3, section 9, *Expiry is normal*). Continue (`resume()`) lifts it in the same
    /// session; a new session after it is a `reconnect`.
    case taskExpired
    /// The camera dropped its card from the session (`CameraLinkEvent.storeRemoved`, or a `cardUnavailable`
    /// failure). The camera is still there, so no file counts as failed (the spike's 82-files bug, backlog
    /// Iteration 3, section 9); the job lists the card again on `.storeAdded`, or on `reconnect`.
    case cardUnavailable
    /// The session's connection is gone while the camera may still be there (`CameraLinkEvent.sessionLost`): iOS
    /// closed the sockets in the background, the camera dropped an idle session or switched its Wi-Fi off. The job
    /// waits for `reconnect`, which the app's Wi-Fi recovery makes.
    case cameraUnreachable
    /// Getting the camera back needs the phone to join its network, which the app can't do from the background
    /// (decision 3): the app pauses with this, notifies, and joins when the person comes back (backlog Iteration 3,
    /// section 9, new in 1.0). Lifted by `reconnect`.
    case needsJoin

    /// The reasons `reconnect` lifts: everything that waits for the camera or a new session.
    static let liftedByReconnect: Set<PauseReason> = [
        .cameraRemoved, .cameraUnreachable, .cardUnavailable, .taskExpired, .needsJoin,
    ]

    /// The reasons a job gets over without the person: it still counts as a running import
    /// (`ImportEngine.importRunning(carrier:)`), so a USB import keeps the screen on through them (decision 1).
    static let overcomeWithoutThePerson: Set<PauseReason> = [
        .cameraRemoved, .stalled, .cardUnavailable, .cameraUnreachable,
    ]

    /// The order the Import screen shows them in, the first the person has to deal with first: a camera to plug in
    /// again, then anything that needs the app open, then what the app gets over by itself.
    static let precedence: [PauseReason] = [
        .cameraRemoved, .needsJoin, .taskExpired, .appInBackground, .cameraUnreachable, .cardUnavailable, .stalled,
        .byPerson,
    ]
}

/// The engine's job, as `reconnect(_:to:knownItems:route:)` names it, so a reconnect meant for a job that has since
/// ended never lands on the next one.
public struct ImportJobID: Sendable, Hashable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }
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
    /// There is no job to pause, resume, reconnect or append to (or not the one named).
    case noJob
    /// An explicit selection with nothing in it.
    case emptySelection
    /// `reconnect` while the job isn't waiting for the camera or a new session: it is neither waiting for the
    /// camera nor paused for a reason a reconnect lifts (`PauseReason.liftedByReconnect`).
    case cameraNotRemoved
    /// The catalogue couldn't say which of the appended files are already imported.
    case catalogueUnavailable
    /// An `ImportRoute` built from `DestinationDecision.askForPhotosAccess`: the app asks for Photos access before
    /// a job starts (`PhotosAccessGate.decision(for:staging:)` never returns it) and builds the route from the answer.
    case photosAccessNotAsked
}
