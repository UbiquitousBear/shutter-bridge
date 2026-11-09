// Every wait in the Bluetooth hand-off and the pairing check, each with the measurement it rests on (plan section 0, item 8).

/// The timings of the Wi-Fi hand-off. A value that is the spike's own limit rather than a measurement says so, and a value
/// nobody measured says `unverified`, so a change of behaviour is a change to one constant.
///
/// Sources: spike-findings.md, *BLE advertisement*, and `Spike/Sources/Bluetooth/SonyWiFiHandover.swift` (3 to 5 Nov 2026,
/// α7C II firmware 2.01).
public enum HandoffTiming {
    /// How long one notification switch gets to be confirmed. The spike's limit (`doSubscribe`); measured: all five took in
    /// 1.4 to 1.7 s together.
    public static let subscribeEach: Duration = .seconds(10)

    /// How long one notification switch gets to be turned off again. The spike's limit (`unsubscribeAll`). A bonded camera
    /// may keep a client's switches across links, so the release does this on purpose.
    public static let unsubscribeEach: Duration = .seconds(5)

    /// The pause after the five switches are confirmed, before CC09 is read and CC08 written: "collecting the first
    /// notifications" in the spike (`doSubscribe`), which had it in every run that worked. Whether the camera needs it is
    /// `unverified`: no run went without. It is spent on the event queue, so notifications that come meanwhile are merged.
    public static let afterSubscribe: Duration = .seconds(1)

    /// How long the baseline read of CC09 gets. The spike's default read limit; measured: 0.07 s on a paired phone.
    public static let statusRead: Duration = .seconds(15)

    /// How long the acknowledgement of the CC08 write gets. The spike's limit; measured: 55 to 88 ms.
    public static let wifiOnAck: Duration = .seconds(15)

    /// How long the camera gets to reach status 2 ("launched") after the write is acknowledged, or after the wait starts
    /// when the camera was already launching or terminating. The spike's limit (`switchWiFiOn(timeout: 30)`); measured:
    /// status 1 at +0.09 to +0.11 s and status 2 at +0.8 to +2.7 s after the write.
    public static let statusTwo: Duration = .seconds(30)

    /// When no CC09 notification has come this long after the write was acknowledged, the sequencer also reads CC09.
    /// The spike's rule (`doSwitchWiFiOn`); in every measured run the notifications came, so the reads never ran.
    public static let pollIfSilentAfter: Duration = .seconds(3)

    /// The gap between those reads. The spike's rule: once a second.
    public static let pollEvery: Duration = .seconds(1)

    /// How long one of those reads gets. The spike's limit.
    public static let pollRead: Duration = .seconds(5)

    /// After the status has left its value from before the write and fallen back to it (the camera gave up: 0 → 1 → 0, as
    /// without the five notifications), the wait ends this long afterwards, still short of status 2. The spike's rule.
    public static let fallbackGrace: Duration = .seconds(3)

    /// The gap between tries to read CC06 and CC07. The guided run's rule (`GuidedScripts`, 3 Nov onwards).
    public static let credentialRetry: Duration = .seconds(2)

    /// How long, from the first try, CC06 and CC07 are retried while the status stays 2. The guided run's rule; measured:
    /// the first try worked every time, 0.27 to 0.47 s after status 2.
    public static let credentialWindow: Duration = .seconds(20)

    /// The fewest tries at CC06 and CC07 before the window may end the retries (`readDetailsWhileOn(tries: 3, ...)` in the
    /// guided run): reads that time out take 15 s each, so the window alone would allow one or two.
    public static let credentialMinimumTries = 3

    /// How long one read of CC06 or CC07 gets. The spike's default read limit.
    public static let credentialRead: Duration = .seconds(15)

    /// How long a camera whose Wi-Fi nobody joins keeps it on, counted from status 2: status 3 comes at +50.0 s (49.98 to
    /// 50.01 s, seven runs of seven, with Creators' App quit and open) and status 0 about 1.5 s later. The count runs from
    /// status 2, not from the write; a Bluetooth link with notifications on doesn't stop it (backlog section 8).
    public static let cameraWiFiWindow: Duration = .seconds(50)

    /// A protected read that returns sooner than this was answered without a prompt: the phone was already paired. Measured:
    /// 0.07 s on a paired phone; 12.3 s with both prompts accepted. Nothing was measured in between, so the threshold is
    /// `unverified`; a wrong guess only changes whether onboarding skips its explanation.
    public static let pairingPromptThreshold: Duration = .seconds(3)
}
