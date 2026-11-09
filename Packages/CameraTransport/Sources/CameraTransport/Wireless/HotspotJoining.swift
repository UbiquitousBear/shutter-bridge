// Joining and leaving the camera's network: the protocol `WirelessSession` is written against. The NetworkExtension adapter
// (`NEHotspotJoiner`, W12) implements it; tests use a scripted fake.

import BLEKit

/// Why `HotspotJoining.apply` didn't join, in the terms the session acts on. None of the cases carries the network's name
/// or password.
public enum JoinFailure: Error, Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The person declined iOS's prompt (`NEHotspotConfigurationError.userDenied`). The session pauses; it never asks again
    /// by itself.
    case userDenied
    /// The app wasn't in front (`applicationIsNotInForeground`): a join needs the app in front (backlog section 8). The
    /// session pauses until the person comes back. The app going briefly inactive while iOS's prompt is up is not this:
    /// on 5 Nov 01:21 it was in the background for 8.9 s with the prompt up, and still joined.
    case notInForeground
    /// iOS refused the name, the password or the configuration as a whole (`invalidSSID`, `invalidWPAPassphrase`,
    /// `invalid`): what the camera gave is unusable, and trying again won't change it.
    case invalidCredentials
    /// Another configuration is being applied (`pending`). `unverified`: never seen. Counted as a failed try.
    case pending
    /// iOS couldn't save or apply the configuration (`systemConfiguration`, `internal`). Counted as a failed try.
    case systemConfiguration
    /// The calling task was cancelled.
    case cancelled
    /// Anything else, with the `NEHotspotConfigurationErrorDomain` code, for the log only. Counted as a failed try.
    case other(Int)

    public var description: String {
        switch self {
        case .userDenied: "declined"
        case .notInForeground: "app not in front"
        case .invalidCredentials: "network details refused"
        case .pending: "another join pending"
        case .systemConfiguration: "system configuration"
        case .cancelled: "cancelled"
        case .other(let code): "other (\(code))"
        }
    }
}

/// Asks iOS to join the camera's network and to forget it again.
///
/// Contract the session relies on:
/// - `apply` returns when iOS has taken the configuration (after the person has answered the prompt, the first time). It
///   is *not* a join: the session confirms the join by the camera's gateway on the Wi-Fi path (`WiFiPathWatching`).
///   An adapter treats "already associated" as success, saves the configuration (not join-once), and never logs the name
///   or the password, nor puts them in an error.
/// - `apply` may not end when its task is cancelled: iOS's prompt can't be withdrawn. The session never cancels it on
///   purpose; it waits for the answer.
/// - `leave` removes the configuration, which leaves the network. It has no result (iOS gives none); removing a
///   configuration that isn't there does nothing. Removing it brings the prompt back on the next join (4 Nov 01:08).
public protocol HotspotJoining: Sendable {
    func apply(_ credentials: SonyWiFiCredentials) async throws(JoinFailure)
    func leave(ssid: String) async
}
