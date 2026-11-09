// Getting a Wi-Fi import back after the camera drops its card or the session: the decided order as a pure table
// (docs/iteration-3-4-backlog.md, section 9, "Recover from the camera dropping its card" and "With the app away";
// decision 3; Shamil's decision of 9 Nov). The app's coordinator (AppUI, W14) feeds it what happened and takes each step.

/// What happened, as the recovery's next step depends on it.
public enum RecoveryInput: Sendable, Equatable, Hashable {
    /// The camera dropped its card with the session still up: the engine paused with `.cardUnavailable` (StoreRemoved, or
    /// StoreNotAvailable on the next call).
    case cardRemoved
    /// The session's connection is gone: the engine paused with `.cameraUnreachable` (`.sessionLost`, or a call that
    /// failed as `disconnected` after it). On 4 Nov 01:08 it followed StoreRemoved by about 6 s, when the camera switched
    /// its Wi-Fi off.
    case sessionLost
    /// StoreAdded came within `WiFiRecoveryTiming.waitForStoreAdded`: the engine has listed the card again on the same
    /// session and carries on.
    case cardBack
    /// `WiFiRecoveryTiming.waitForStoreAdded` passed without StoreAdded.
    case cardWaitEnded
    /// The session is open again (`WirelessSession.prepareImport`).
    case reopened
    /// Getting the session back needs a join, and the app is away (`WirelessFailure.paused(.needsJoin)`).
    case needsJoin
    /// The reopen failed another way: the camera not found, Bluetooth off, a refusal, no answer in the time allowed.
    case reopenFailed
    /// The card has been listed on the new session and the job carries on through it.
    case relisted
    /// Listing the card on the new session failed.
    case relistFailed
    /// The person is back: the app came to the front while the recovery waited for them, or they asked to try again.
    case personReturned
    /// Paused for a join with the app in front, after a reopen that began in front: the session still can't join (its
    /// scene signal says background, or the join was refused while the scene was inactive). Retrying at once would only
    /// get the same answer, so the recovery waits for the person.
    case joinRefusedInFront
}

/// What the coordinator does next.
public enum RecoveryStep: Sendable, Equatable, Hashable {
    /// Wait up to `WiFiRecoveryTiming.waitForStoreAdded` for StoreAdded; the engine lists the card again by itself.
    case waitForCard
    /// `WirelessSession.prepareImport(bluetoothSwitchOnWhenAway:)`, which takes the rest of the decided order itself:
    /// close the session, try the port every second for `WiFiRecoveryTiming.waitBeforeBluetooth` and reopen with no join;
    /// otherwise, in front, connect over Bluetooth, read CC09, write CC08 unless it reads 2, join as soon as it does with no
    /// second fixed wait, and open the session; with the app away, never join: switch the camera's Wi-Fi on over Bluetooth
    /// (when the payload allows it) and wait `WiFiRecoveryTiming.rejoinWhileAway` for iOS to rejoin by itself, else pause
    /// for a join.
    case reopen(bluetoothSwitchOnWhenAway: Bool)
    /// List the card on the new session asking only for handles not seen before (`IPLink.list(reusing:)`, W8), and carry
    /// the job on through it (`ImportEngine.reconnect(_:to:knownItems:route:)`), which resumes the file in flight from its
    /// checkpoint with 0x9211.
    case relist
    /// Pause the job with `.needsJoin` and post the pause notification; join when the person comes back (new in 1.0, B:211).
    case pauseNeedsJoin
    /// The import has recovered.
    case done
    /// Stop recovering by itself: the job stays paused for the camera until the person comes back or tries again.
    case giveUp
    /// The input doesn't change anything now (a late event, or one for a step already under way).
    case noChange
}

/// The order of a Wi-Fi recovery, one input at a time. A value: the coordinator owns one per job.
///
/// 1. With the session still up and the card gone, wait for StoreAdded (`waitForCard`); the engine relists.
/// 2. Otherwise (no StoreAdded in time, or the session lost), reopen (`reopen`): close, probe the port and reopen; else wait
///    out the rest of the 30 s before Bluetooth, then, in front, Bluetooth and the join with no second fixed wait.
/// 3. Once a session is open, list only the new handles and carry the job on (`relist`).
/// 4. With the app away only the steps that need no join are taken; when a join is needed (or anything else fails while the
///    app is away, since the person has to come back for it either way) the job pauses with `.needsJoin` and the pause
///    notification is posted (`pauseNeedsJoin`). In front, a failure gives up.
/// 5. At most `recoveriesPerImport` recoveries by itself per import; the person coming back starts the count again. With
///    the app away, an import that has used them all pauses for a join too, so the person is told.
public struct WiFiRecoveryPlan: Sendable, Equatable, Hashable {
    /// Where the recovery is.
    public enum Phase: Sendable, Equatable, Hashable {
        /// No recovery under way: the import is going, or paused for something else.
        case idle
        case waitingForCard
        case reopening
        case relisting
        /// Paused with `.needsJoin` until the person comes back.
        case pausedForJoin
        /// Waiting for the person after giving up.
        case gaveUp
    }

    public private(set) var phase: Phase = .idle
    /// Recoveries started by themselves since the job began or the person last came back.
    public private(set) var recoveries = 0
    public let recoveriesPerImport: Int

    public init(recoveriesPerImport: Int = WiFiRecoveryTiming.recoveriesPerImport) {
        self.recoveriesPerImport = recoveriesPerImport
    }

    /// Whether a recovery is under way or waiting for the person.
    public var isRecovering: Bool { phase != .idle }

    /// The step after `input`.
    ///
    /// - Parameters:
    ///   - foreground: whether the app is in front now. It decides what a failed reopen does: give up in front, pause for a
    ///     join with the app away.
    ///   - bluetoothAllowed: whether the camera's Wi-Fi may be switched on over Bluetooth while the app is away (B:211, "if
    ///     allowed"); carried by `reopen`.
    public mutating func next(after input: RecoveryInput, foreground: Bool, bluetoothAllowed: Bool) -> RecoveryStep {
        let reopen = RecoveryStep.reopen(bluetoothSwitchOnWhenAway: bluetoothAllowed)
        switch (phase, input) {
        case (.idle, .cardRemoved):
            guard begin() else { return outOfRecoveries(foreground: foreground) }
            phase = .waitingForCard
            return .waitForCard
        case (.idle, .sessionLost):
            guard begin() else { return outOfRecoveries(foreground: foreground) }
            phase = .reopening
            return reopen

        case (.waitingForCard, .cardBack):
            phase = .idle
            return .done
        case (.waitingForCard, .cardWaitEnded), (.waitingForCard, .sessionLost):
            phase = .reopening
            return reopen

        case (.reopening, .reopened):
            phase = .relisting
            return .relist
        case (.reopening, .needsJoin), (.relisting, .needsJoin):
            phase = .pausedForJoin
            return .pauseNeedsJoin
        case (.reopening, .reopenFailed):
            if foreground {
                phase = .gaveUp
                return .giveUp
            }
            phase = .pausedForJoin
            return .pauseNeedsJoin

        case (.relisting, .relisted):
            phase = .idle
            return .done
        case (.relisting, .relistFailed):
            // The new session went too: another recovery, if the import has one left.
            guard begin() else { return outOfRecoveries(foreground: foreground) }
            phase = .reopening
            return reopen

        case (.pausedForJoin, .personReturned), (.gaveUp, .personReturned):
            recoveries = 0
            phase = .reopening
            return reopen
        case (.pausedForJoin, .joinRefusedInFront):
            phase = .gaveUp
            return .giveUp

        default:
            return .noChange
        }
    }

    /// Forgets the recovery and the count: the job ended, or another began.
    public mutating func reset() {
        phase = .idle
        recoveries = 0
    }

    /// Counts a recovery the import starts by itself; false when it has none left.
    private mutating func begin() -> Bool {
        guard recoveries < recoveriesPerImport else { return false }
        recoveries += 1
        return true
    }

    /// No recovery left: in front, wait for the person; with the app away, pause for a join, so the pause notification
    /// tells the person (B:211).
    private mutating func outOfRecoveries(foreground: Bool) -> RecoveryStep {
        if foreground {
            phase = .gaveUp
            return .giveUp
        }
        phase = .pausedForJoin
        return .pauseNeedsJoin
    }
}
