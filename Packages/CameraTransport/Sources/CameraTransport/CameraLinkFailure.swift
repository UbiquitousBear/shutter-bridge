/// The four things the engine can do about a failure (proposal, "Import engine design", *Error taxonomy*). The UI
/// shows the outcome, never the code behind it; the code goes to the log.
///
/// Waiting for the Local Network prompt is not a failure and has no outcome: it is `CameraLinkEvent.waitingForLocalNetwork`.
public enum FailureOutcome: String, Sendable, Hashable, CaseIterable {
    /// Transient: try the same call again now.
    case retryNow
    /// The link is gone: pause, and carry on when the camera is back and listed.
    case retryOnReconnect
    /// This file can't be imported; go on with the rest.
    case skipFile
    /// Nothing more can be imported in this job.
    case stopJob
}

/// Every failure a `CameraLink` throws. Each kind maps to exactly one outcome, so no failure reaches the engine
/// unclassified (backlog section 2, *Errors*). A stalled download is not a failure: the link keeps waiting, and
/// pausing is the engine's call (decision 4).
public struct CameraLinkFailure: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The camera or the framework is busy with something else.
        case busy
        /// A request came back with no answer at all (an empty pass-through reply).
        case noAnswer
        /// The camera was removed, or the session ended under the call.
        case disconnected
        /// The file is no longer on the card, or the link doesn't know the item.
        case itemNotFound
        /// The camera couldn't read the file.
        case unreadableItem
        /// The file's format can't be imported (video in 1.0, for one).
        case unsupportedFormat
        /// The phone has no room for the file.
        case phoneStorageFull
        /// The app isn't allowed to use the camera.
        case notAuthorised
        /// The camera's mode lists no files: Remote Shoot (PC Remote) over USB (decision 1).
        case modeListsNoFiles
        /// The camera that answered is not the one the job began with: its serial differs from the one the app
        /// knows (Wi-Fi, on reconnect). Nothing is imported from the wrong camera.
        case identityChanged
        /// The camera refused the connection or the session: a closed port (`ECONNREFUSED`) or PTP/IP's
        /// `Init_Fail`. The bench saw it with access authentication on (`unverified`: that the setting closes the
        /// port is inferred, not tested). Trying again won't help until the camera's settings change.
        case refused
        /// The session is up but the card is not offered: StoreNotAvailable (0x2013), or, from StoreRemoved until
        /// StoreAdded, InvalidObjectHandle too (the camera answered both on 3 Nov, and InvalidObjectHandle must not
        /// become `itemNotFound` then, which skips the file). The camera is still there, so no file counts as
        /// failed; the job pauses until the card comes back. The camera normally drops its Wi-Fi about 6 s after
        /// StoreRemoved, so `CameraLinkEvent.sessionLost` usually follows.
        case cardUnavailable

        public var outcome: FailureOutcome {
            switch self {
            case .busy, .noAnswer: .retryNow
            case .disconnected, .cardUnavailable: .retryOnReconnect
            case .itemNotFound, .unreadableItem, .unsupportedFormat: .skipFile
            case .phoneStorageFull, .notAuthorised, .modeListsNoFiles, .identityChanged, .refused: .stopJob
            }
        }
    }

    public var kind: Kind
    /// What the framework said, for the log only, such as "ImageCaptureCore -9934". Never shown in the UI and never
    /// holding a serial or a device identifier.
    public var detail: String?

    public init(_ kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    public var outcome: FailureOutcome { kind.outcome }

    public var description: String {
        if let detail { "\(kind.rawValue) → \(outcome.rawValue) (\(detail))" } else { "\(kind.rawValue) → \(outcome.rawValue)" }
    }
}
