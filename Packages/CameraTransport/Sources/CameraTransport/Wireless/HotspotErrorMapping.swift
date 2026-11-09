// What an `NEHotspotConfigurationManager.apply` error means to the session: the pure half of `NEHotspotJoiner` (W12), so the
// mapping is unit-tested on Linux. The adapter passes in the error's domain and code; nothing else of the error is kept, so
// no text iOS wrote (which could quote the network's name or password) goes anywhere.

/// Maps an `NEHotspotConfigurationErrorDomain` error to a `JoinFailure`, or to success for "already associated".
///
/// The rules:
/// - `alreadyAssociated` is success (W11's contract): the phone is on the camera's network already, and the session confirms
///   the join by the gateway as it does after any `apply`. Seen in the spike whenever the configuration was still saved.
/// - `userDenied` → `.userDenied`; `applicationIsNotInForeground` → `.notInForeground` (the session pauses on both).
/// - `invalid`, `invalidSSID` and `invalidWPAPassphrase` → `.invalidCredentials`: the adapter builds only a WPA configuration
///   from the details the camera gave, so iOS refusing it means those details are unusable, and trying again won't change
///   them. `invalid` (the configuration as a whole) is counted here for that reason; never seen.
/// - `pending` → `.pending`; `systemConfiguration` and `internal` → `.systemConfiguration` (counted as failed tries).
/// - Every other code, in the domain or not, → `.other(code)`, counted as a failed try. That includes `unknown` (the spike's
///   reading: "the network may be out of range"), the codes for settings the adapter never sets (WEP, EAP, Hotspot 2.0,
///   SSID prefix, join-once) and codes added after iOS 27. A code from another domain is passed through as it is; it only
///   reaches the log.
///
/// The raw values below are NetworkExtension's (`NEHotspotConfigurationError`). A test compiled only for iOS checks them
/// against the SDK in CI's simulator run, so a mismatch fails there rather than on the bench.
enum HotspotErrorMapping {
    /// `NEHotspotConfigurationErrorDomain`.
    static let domain = "NEHotspotConfigurationErrorDomain"

    /// `NEHotspotConfigurationError`'s cases, with the SDK's raw values (iOS 11 to 13; unchanged since).
    enum Code: Int, CaseIterable, Sendable {
        case invalid = 0
        case invalidSSID = 1
        case invalidWPAPassphrase = 2
        case invalidWEPPassphrase = 3
        case invalidEAPSettings = 4
        case invalidHS20Settings = 5
        case invalidHS20DomainName = 6
        case userDenied = 7
        /// `NEHotspotConfigurationError.internal` (renamed: `internal` is a Swift keyword).
        case internalError = 8
        case pending = 9
        case systemConfiguration = 10
        case unknown = 11
        case joinOnceNotSupported = 12
        case alreadyAssociated = 13
        case applicationIsNotInForeground = 14
        case invalidSSIDPrefix = 15
    }

    /// What an `apply` error means: nil for success (already associated), else why it didn't join.
    static func failure(domain: String, code: Int) -> JoinFailure? {
        guard domain == Self.domain, let known = Code(rawValue: code) else { return .other(code) }
        switch known {
        case .alreadyAssociated: return nil
        case .userDenied: return .userDenied
        case .applicationIsNotInForeground: return .notInForeground
        case .invalid, .invalidSSID, .invalidWPAPassphrase: return .invalidCredentials
        case .pending: return .pending
        case .systemConfiguration, .internalError: return .systemConfiguration
        case .invalidWEPPassphrase, .invalidEAPSettings, .invalidHS20Settings, .invalidHS20DomainName, .unknown,
             .joinOnceNotSupported, .invalidSSIDPrefix:
            return .other(code)
        }
    }
}
