// Every wait in joining the camera's network, staying on it and leaving it, each with the measurement or the decision it
// rests on (wireless plan, section 0, item 8). A value nobody measured says `unverified`, so a change of behaviour is a change
// to one constant.

/// The timings of the join, the stay and the leave (`WirelessSession`).
///
/// Sources: docs/iteration-3-4-backlog.md, section 8 (join, stay and leave) and section 9 (recovery); the spike's
/// `HotspotJoiner` and guided join (`Spike/Sources/Network/HotspotJoiner.swift`, 3 to 5 Nov 2026, α7C II firmware 2.01);
/// Shamil's decisions of 4, 8 and 9 Nov (docs/decision-pack.md).
public enum WirelessTiming {
    /// How long the phone stays on the camera's network after an import, counted from the end of the import, while the app
    /// is in the foreground. Decided by Shamil on 8 Nov (decision 2, option (d); recommendation 1, option (a)): one timer, 3 minutes,
    /// in this single constant. A starting default, not a measurement: the camera held its Wi-Fi for 785 s after
    /// CloseSession with a phone joined and the Bluetooth link up (4 Nov), and its battery cost is unmeasured.
    public static let stay: Duration = .seconds(180)

    /// How long the gateway 192.168.122.1 gets to appear on the Wi-Fi path after `apply` returns. `apply` returning is not
    /// a join: on 4 Nov 12:34 it returned without an error and iOS then reported the join failed. The spike's limit
    /// (`HotspotJoiner.swift:75`); measured: the gateway appeared 9.5 to 10.6 s after the call, about 1 to 2 s after
    /// `apply` returned.
    public static let gatewayWait: Duration = .seconds(20)

    /// How many times `apply` is tried for one hand-off while the camera's Wi-Fi stays on; a rewrite after a lapse starts
    /// the count again. Two: the 12:34 attempt failed with nothing wrong, and the 12:39 one, with nothing changed, joined
    /// (backlog section 8). The cause is unknown.
    public static let joinAttempts = 2

    /// The gap before `apply` is tried again after it threw (`pending`: another configuration was being applied; a system
    /// configuration error; an unknown one). `unverified`: the spike never saw `apply` throw these; an immediate retry would
    /// most likely meet the same configuration still being applied.
    public static let applyRetryAfter: Duration = .seconds(2)

    /// How many times, in one join, the camera's Wi-Fi may lapse (CC09 at 3 or 0, or the camera's 50 s gone with the
    /// Bluetooth link down) and be switched on again before the join gives up (decision 3: write CC08 again and retry).
    /// `unverified`: no run lapsed during a join; two allows a person slow at iOS's prompt twice.
    public static let rewritesPerJoin = 2

    /// How many times a hand-off whose Bluetooth link dropped is started again from a new connection, in one join. Once,
    /// as the pairing check does: the link dropped by itself 11.2 s after a join on 5 Nov (CBInternalErrorDomain 13).
    public static let handoffReconnects = 1

    /// How long the camera's PTP/IP port gets to open the session after the join is confirmed. The spike's guided join
    /// (`joinAndImport`); measured: the port answered 0.1 s after `apply` returned.
    public static let portWait: Duration = .seconds(60)

    /// The gap between tries to open the session while the port is awaited, and while Wi-Fi is retried before Bluetooth.
    /// The spike's port probe in the copy recovery (2 s per connect, 1 s apart).
    public static let portRetryEvery: Duration = .seconds(1)

    /// How long a session that won't reopen on the camera's network is retried on Wi-Fi before going back to Bluetooth to
    /// switch the camera's Wi-Fi on again. Decided by Shamil on 9 Nov (the spike's first wait); also the wait before
    /// Bluetooth that decision 3 keeps, since the camera's Bluetooth answers while it is switched off. One value with the
    /// recovery's (`WiFiRecoveryTiming.waitBeforeBluetooth`, W14).
    public static let wifiRetryBeforeBluetooth: Duration = WiFiRecoveryTiming.waitBeforeBluetooth

    /// How long the stay keeps going with the Bluetooth link down and not restored. A stay with the link closed is tested
    /// only to 63 to 64 s (3 Nov 14:56 and 15:21, 4 Nov 13:06), so the stay ends here (backlog section 8). A reconnect in
    /// progress at the limit is not cut off: it finishes within the connector's own limits first.
    public static let linkDownStayLimit: Duration = .seconds(60)

    /// How long a join is held while the app is away (`WirelessPhase.awaitingFront`), with the Bluetooth link kept, before
    /// the session lets go of everything and pauses with `.needsJoin`. A join is never applied from the background (bench
    /// 19.1, 9 Nov: `apply` made while away showed no prompt, and the camera's 50 s ran out). Decided by Shamil on 9 Nov as
    /// a starting value: `unverified`, nobody measured how long the camera keeps its Bluetooth link with the app away.
    public static let joinHoldWhileAway: Duration = .seconds(300)

    /// After iOS refused `apply` because the app wasn't in front while the scene already read active (an inactive to active
    /// race), the gap before the one more try. `unverified`: the race was never seen; a second refusal pauses.
    public static let applyAgainInFrontAfter: Duration = .seconds(1)

    /// The gap between tries to reconnect the Bluetooth link during the stay. `unverified`: the spike never reconnected
    /// during a stay; each try already spends the connector's own limits (W10: 8 s, or 20 s, then a 10 s scan).
    public static let bluetoothReconnectEvery: Duration = .seconds(5)
}
