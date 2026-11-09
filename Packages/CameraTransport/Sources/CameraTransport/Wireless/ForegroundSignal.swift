// Whether the app is in the foreground, as the join and the stay need to know.

/// Whether the app is in the foreground now. The app's scene phase (W16) implements it.
///
/// The session reads it where a rule depends on it: before a join (iOS refuses a join from the background with
/// `applicationIsNotInForeground`) and when an import ends (the stay runs only in the foreground; the app leaves on going
/// to the background, decided 8 Nov). Changes of scene reach the session through `WirelessSession.appMovedToBackground()`
/// and `appBecameActive()`, and a change during the read wins over the read.
public protocol ForegroundSignal: Sendable {
    /// True unless the app is in the background. An inactive app is in the foreground: with Notification Centre or Control
    /// Centre pulled down, a call banner up, or just after a system alert such as the notification permission prompt
    /// (`scenePhase != .background`, not `== .active`).
    var isInForeground: Bool { get async }
}
