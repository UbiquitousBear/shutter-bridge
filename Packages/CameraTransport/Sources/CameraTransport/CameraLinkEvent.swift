/// What a link reports on its side channel (backlog section 2, *Events* and *Lifecycle*). No camera events reach
/// the phone over USB in either mode; Wi-Fi's (Sony's 0xC201 and the rest) arrive with `IPLink` in Iteration 3.
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
}
