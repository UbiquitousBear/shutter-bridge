/// What a link reports on its side channel (backlog section 2, *Events* and *Lifecycle*). No camera events reach
/// the phone over USB in either mode, and a USB link never sends the four Wi-Fi events at the end; `IPLink`
/// (Iteration 3) sends them. Events are facts about the session, not failures: the engine decides what each one
/// means for a job. The engine pauses on `.storeRemoved` (`cardUnavailable`) and `.sessionLost`
/// (`cameraUnreachable`), lists the card again on `.storeAdded`, and only informs on `.waitingForLocalNetwork`
/// (`ImportEngine`, W7).
public enum CameraLinkEvent: Sendable, Hashable {
    /// The camera went away: cable pulled, camera switched off or the session lost. Pending calls end with a
    /// failure whose outcome is `.retryOnReconnect`.
    case removed
    /// ImageCaptureCore will suspend the session (the app left the foreground); *did suspend* follows about 30 s
    /// later unless the app returns first.
    case willSuspend
    /// The session is suspended. The engine pauses the job (decision 1).
    case didSuspend
    /// The app came back within the 30 s, so the suspension was called off.
    case cancelledSuspending
    /// ImageCaptureCore resumed operations. It also fires with no suspension before it, so the engine continues on
    /// the app's return, not on this alone (backlog section 2).
    case resumedOperations

    // MARK: Wi-Fi (PTP/IP). Sent by `IPLink` only.

    /// The connection is waiting for the person to answer the Local Network prompt: iOS holds it with "Network is
    /// down" (POSIX 50) until they do (the probe succeeded 1.53 s after it began, prompt allowed in that time). This
    /// is never a failure (backlog Iteration 3, section 1, *Local Network permission*): the link keeps waiting, the
    /// app explains the prompt, and `.resumedOperations` is not sent for it.
    case waitingForLocalNetwork
    /// The camera dropped its card from the session (PTP StoreRemoved). The session is still up, for now. From this
    /// event until `.storeAdded` the link reports every StoreNotAvailable and every InvalidObjectHandle as
    /// `cardUnavailable`, never as `itemNotFound`: on 3 Nov the camera answered the next GetObject with both, and
    /// InvalidObjectHandle read as a missing file skips every file still queued (the spike's 82-files bug). The
    /// camera normally switches its Wi-Fi off about 6 s later (3 and 4 Nov), so `.sessionLost` usually follows
    /// `.storeRemoved`.
    case storeRemoved
    /// The card is back (PTP StoreAdded). The listing is asked for again; handles may have changed.
    case storeAdded
    /// The session's sockets are gone while the camera may still be there: iOS closed them in the background (POSIX
    /// 53 on both channels after 4.8 s on 5 Nov), the camera dropped an idle session, or the access point went. Not
    /// `.removed`: the link is not finished, and reopening it (or a new link to the same camera) can carry on, so
    /// pending calls end as `disconnected` (retry on reconnect) and `events` stays open.
    ///
    /// `generation` is the lost session's: the link's `sessionGeneration` while that session was open. A loss can
    /// reach a reader after the link has opened the next session (the reader's stream lags behind, or a socket of the
    /// old session reports itself late), so a reader that has carried on in a newer session ignores a loss stamped with
    /// an older generation (backlog section 2; the engine does, I13). 0 means not stamped: the current session.
    case sessionLost(generation: Int)

    /// Whether this is `.sessionLost`, of whichever generation.
    public var isSessionLost: Bool {
        if case .sessionLost = self { true } else { false }
    }
}
