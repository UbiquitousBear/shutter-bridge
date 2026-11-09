// The waits and limits of getting a Wi-Fi import back after the camera drops its card or the session (backlog Iteration 3,
// section 9, "Recover from the camera dropping its card"; decision 3; Shamil's decision of 9 Nov). A value nobody measured
// says `unverified`, so a change of behaviour is a change to one constant (wireless plan, section 0, item 8).

/// The timings of the Wi-Fi recovery (`WiFiRecoveryPlan`, and `WirelessSession.prepareImport(bluetoothSwitchOnWhenAway:)`
/// for the steps it takes).
///
/// Sources: the spike's copy recovery (`Spike/Sources/Network/WiFiViewModel.swift`, 3 and 4 Nov 2026, α7C II firmware 2.01)
/// and its 4 Nov 01:08 run, which got the copy back by itself 97 s after the failure, 62 s of it in two fixed 30 s waits.
/// 1.0 keeps the first (the wait before Bluetooth) and drops the second (waiting for iOS to rejoin after the camera's Wi-Fi
/// is on again): the join is made as soon as CC09 reports status 2 (decision 3).
public enum WiFiRecoveryTiming {
    /// With the session still up and the card gone (StoreRemoved, or StoreNotAvailable on the next call), how long to wait
    /// for StoreAdded before closing the session and reopening it. The engine lists the card again by itself on StoreAdded
    /// (W7). The spike's limit (copy recovery step a); measured: the card came back about 2 s after the session was ready,
    /// 0.1 s on a reopen. On 4 Nov 01:08 it never came back on the old session: the camera switched its Wi-Fi off about 6 s
    /// after StoreRemoved.
    public static let waitForStoreAdded: Duration = .seconds(15)

    /// How long a session that won't reopen is retried on the camera's network before going back to Bluetooth to switch
    /// the camera's Wi-Fi on again. Decided by Shamil on 9 Nov: 30 s, the spike's port probe (TCP 15740 every second, step b).
    /// It is also the wait before Bluetooth that decision 3 keeps: the camera's Bluetooth answers while the camera is
    /// switched off, and 1.0 shouldn't switch on a camera the person has just switched off (how to tell the two apart is
    /// open). The port is tried every `WirelessTiming.portRetryEvery` throughout, so the probe and the wait are one 30 s,
    /// not two. `WirelessTiming.wifiRetryBeforeBluetooth` is this value.
    public static let waitBeforeBluetooth: Duration = .seconds(30)

    /// With the app away, after the camera's Wi-Fi has been switched on over Bluetooth, how long to wait for iOS to rejoin
    /// the camera's network by itself (its configuration is still saved) before pausing for a join. Never longer than what
    /// is left of the camera's 50 s from status 2. `unverified`: the spike waited 30 s for the port, and at 01:08, with the
    /// home network in range and the app in front, iOS didn't rejoin in those 30 s; a rejoin with the phone locked, and a
    /// Bluetooth switch-on from the background, were never measured (B:211).
    public static let rejoinWhileAway: Duration = .seconds(30)

    /// How many recoveries one import makes by itself before it waits for the person. The spike's limit
    /// (`copyRecoveryLimit`). A recovery the person starts (coming back to the app after a pause for a join, or trying
    /// again) starts the count again.
    public static let recoveriesPerImport = 3
}
