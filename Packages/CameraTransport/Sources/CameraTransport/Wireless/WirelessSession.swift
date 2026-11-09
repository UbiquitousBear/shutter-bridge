// Join, stay and leave: the decided timing rules for the camera's own network as one clock-driven actor
// (docs/iteration-3-4-backlog.md, section 8; decisions 2 and 3; Shamil's decisions of 8 and 9 Nov).

import BLEKit
import Foundation

/// What the session needs to know about the camera. The app fills it from the catalogue's camera row
/// (`CameraRecord.bluetoothPeripheralID`); CameraTransport doesn't depend on Catalogue.
public struct WirelessCamera: Sendable, Hashable {
    /// The camera's own network gives the phone this gateway, which is also the camera's address (measured on every run).
    public static let cameraNetworkGateway = "192.168.122.1"

    /// The peripheral iOS gave the camera when it was paired, if the app has it. Nil connects by a scan (W10).
    public var peripheral: PeripheralID?

    public init(peripheral: PeripheralID?) {
        self.peripheral = peripheral
    }
}

/// Why the session is waiting for the person. In each, nothing is held: no Bluetooth link, no network, no session.
public enum WirelessPause: Sendable, Equatable, Hashable {
    /// A join is needed and the app isn't in front (a join needs the app in front), or it stayed away longer than
    /// `WirelessTiming.joinHoldWhileAway` during a join, or a switch-on after a lapse that came while it was away failed.
    /// Prepare again from the front.
    case needsJoin
    /// The camera refused because the phone isn't paired with it: the person opens the camera's Pairing screen.
    case notPaired
    /// The phone's Bluetooth is switched off.
    case bluetoothOff
    /// The app isn't allowed to use Bluetooth: the person changes it in Settings.
    case bluetoothNotAllowed
    /// The person declined iOS's prompt to join the camera's network. The session doesn't ask again by itself.
    case joinDeclined
}

/// Where the session is, for the Import screen and the log. `phases` reports every change.
public enum WirelessPhase: Sendable, Equatable, Hashable {
    /// Not on the camera's network and holding nothing.
    case idle
    /// Bluetooth: connecting, switching the camera's Wi-Fi on and reading its network's details.
    case handingOff
    /// Asking iOS to join and waiting for the camera's gateway.
    case joining
    /// A join held because the app is away: iOS shows no join prompt to an app in the background, so nothing is applied
    /// and no rewrite starts until the app is back in front, for at most `WirelessTiming.joinHoldWhileAway`. The Bluetooth
    /// link is kept. The person's return goes on with the join; after the limit the session pauses with `.needsJoin`.
    case awaitingFront
    /// On the camera's network, opening the camera's session.
    case openingSession
    /// The session is open; an import is running or about to.
    case ready
    /// After an import, on the camera's network with no session open, so that a second import needs no join.
    /// `WirelessSession.stayRemaining` says how long the stay has left, worked out when it is asked.
    case staying
    /// Closing the session, leaving the network and closing the Bluetooth link.
    case leaving
    case paused(WirelessPause)
}

/// Why `prepareImport()` gave no link. When it throws, the session holds nothing.
public enum WirelessFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// Waiting for the person; `phase` is `.paused` with the same reason.
    case paused(WirelessPause)
    /// The camera wasn't found over Bluetooth in the connector's time (off, or out of range).
    case cameraNotFound
    /// Bluetooth failed for another reason (`serviceMissing` sends the person to the manual route, backlog section 7).
    case bluetooth(GATTFailure)
    /// The first hand-off of the join didn't give the network's details (`HandoffFailure` says why).
    case handoff(HandoffFailure)
    /// The camera's Wi-Fi went off during the join (a slow answer to iOS's prompt) and switching it on again failed
    /// (`HandoffFailure` says why). Told apart from `handoff`, a first hand-off that failed, so the app can word it apart.
    /// When the lapse came while the app was away, the session pauses with `.needsJoin` instead.
    case rewriteFailed(HandoffFailure)
    /// `apply` failed: the details were refused, or every try failed this way.
    case join(JoinFailure)
    /// `apply` returned, but the camera's gateway never appeared, `WirelessTiming.joinAttempts` times.
    case noGateway
    /// The camera's Wi-Fi went off during the join more often than `WirelessTiming.rewritesPerJoin`.
    case cameraWiFiLapsed
    /// The camera's session didn't open: a refusal, the wrong camera, or no answer within `WirelessTiming.portWait`.
    case link(CameraLinkFailure)
    /// `leave()` was called during the preparation.
    case cancelled

    public var description: String {
        switch self {
        case .paused(let pause): "paused (\(pause))"
        case .cameraNotFound: "camera not found over Bluetooth"
        case .bluetooth(let failure): "Bluetooth: \(failure)"
        case .handoff(let failure): "hand-off: \(failure)"
        case .rewriteFailed(let failure): "rewrite hand-off: \(failure)"
        case .join(let failure): "join: \(failure)"
        case .noGateway: "joined, but the camera's gateway never appeared"
        case .cameraWiFiLapsed: "the camera's Wi-Fi kept going off during the join"
        case .link(let failure): "session: \(failure)"
        case .cancelled: "cancelled"
        }
    }
}

/// The Bluetooth hand-off as the session uses it. `WiFiHandoff` is the real one; tests script it.
protocol WiFiHandingOff: Sendable {
    func run(on link: any GATTLink) async throws(HandoffFailure) -> HandoffResult
    func rewriteIfLapsed(on link: any GATTLink) async throws(HandoffFailure) -> HandoffResult
    func release(_ link: any GATTLink) async -> ReleaseReport
}

extension WiFiHandoff: WiFiHandingOff {}

/// Joins the camera's own network for an import, stays on it for a while afterwards, and leaves it, by the decided rules.
///
/// **Join** (`prepareImport()` with nothing held): with the app in front, connect over Bluetooth (by the stored peripheral,
/// else a scan), run the hand-off (`WiFiHandoff.run`), and call `apply` as soon as it returns, which is as soon as status 2 is
/// in and the details read. Then wait up to `WirelessTiming.gatewayWait` for the camera's gateway. If it doesn't come, look at
/// the camera: CC09 at 3 or 0 (or, with the Bluetooth link gone, the camera's 50 s from status 2 passed) means its Wi-Fi went
/// off, so switch it on again (`rewriteIfLapsed`, or a new connection and `run` when the link dropped) and apply again;
/// otherwise apply again as it is (the 12:34 case), `WirelessTiming.joinAttempts` in all. When `apply` returns after the
/// camera's 50 s, the camera is looked at first, without waiting for the gateway. Then try to open the session for up to
/// `WirelessTiming.portWait`. A declined prompt pauses with `.joinDeclined`.
///
/// **The app away during a join** (bench 19.1, 9 Nov): the foreground is read before every `apply`, and before every rewrite
/// or new hand-off inside the join. With the app away, nothing is applied or written: the join is held
/// (`.awaitingFront`), keeping the Bluetooth link, until `appBecameActive()`, for at most `WirelessTiming.joinHoldWhileAway`;
/// then it lets go of everything and pauses with `.needsJoin`. On the return, when the camera's 50 s have run out, CC09 is
/// read and, with the Wi-Fi off, it is switched on again with a fresh `run` (not counted against
/// `WirelessTiming.rewritesPerJoin`) before the join. `applicationIsNotInForeground` from `apply` holds the same way, and is
/// not a failed try; when it comes while the scene already reads active, `apply` is tried once more after
/// `WirelessTiming.applyAgainInFrontAfter`, then the session pauses. A hand-off that failed on a time limit while the app was
/// away for part of it is run once more from the front, since its limits may have run out during a suspension. A switch-on
/// after a lapse that came while the app was away pauses with `.needsJoin` when it fails; other rewrite failures are
/// `.rewriteFailed`. The first hand-off itself is never held: no wait comes before the first CC08 write. An inactive app
/// (iOS's prompt up, Control Centre) is in front (5 Nov 01:21).
///
/// Why the camera is looked at after `apply` and not during it: iOS's prompt can't be withdrawn, so a lapse seen while it is
/// up can only be acted on once the person has answered. Reading CC09 then gives the same decision without a second waiting
/// place (backlog section 8, "watch CC09 during the join prompt").
///
/// **Inside the stay** (`prepareImport()` while joined): reopen the session with no join (B:190), retrying on Wi-Fi for
/// `WirelessTiming.wifiRetryBeforeBluetooth` (Shamil, 9 Nov) before going back to Bluetooth to switch the camera's Wi-Fi on
/// again and join. When the phone left the camera's network while the app was away more than the camera's 50 s ago, its
/// Wi-Fi is off, so the next preparation goes to Bluetooth at once (B:191).
///
/// **Recovery** (`prepareImport(bluetoothSwitchOnWhenAway:)` during an import whose session or card went, W14): the same
/// order, which is the decided recovery's (backlog section 9): reopen on Wi-Fi for `WiFiRecoveryTiming.waitBeforeBluetooth`,
/// then, in front, Bluetooth and the join as soon as CC09 reads 2, with no second fixed wait. With the app away nothing
/// joins (B:211): when allowed, the camera's Wi-Fi is switched on over Bluetooth and iOS is given
/// `WiFiRecoveryTiming.rejoinWhileAway` to rejoin by itself (the configuration is still saved); if it doesn't, the session
/// pauses with `.needsJoin`, letting go of everything, and the person's return joins.
///
/// **Stay** (`importFinished()` in front): close the session, then one timer of `WirelessTiming.stay` from the end of the
/// import. Keep the Bluetooth link and reconnect it when it drops; if it can't be restored within
/// `WirelessTiming.linkDownStayLimit`, leave. When the stay runs out, leave.
///
/// **Leave** (`leave()`, the stay running out, the app going to the background during the stay, an import finishing in the
/// background): close the session, remove the network's configuration, turn Sony's notifications off and close the Bluetooth
/// link. No Bluetooth write: 1.0 doesn't know the one that switches the camera's Wi-Fi off, so it may stay on for a while
/// (B:188). In the stay the session is already closed, so the order is the plan's: configuration, notifications, link.
///
/// The network's name and password are read over Bluetooth for each join and never kept (plan, section 0, item 7). Every
/// public call may be made at any time: a call that doesn't apply to the current phase does nothing.
public actor WirelessSession {
    private let camera: WirelessCamera
    private let connector: any GATTConnector
    private let joiner: any HotspotJoining
    private let path: any WiFiPathWatching
    private let foreground: any ForegroundSignal
    private let openLink: @Sendable (Bool) async throws(CameraLinkFailure) -> any CameraLink
    private let handoff: any WiFiHandingOff
    private let clock: SessionClock
    private let broadcast = PhaseBroadcast()
    /// The bench log's events (W20); `.none` records nothing.
    private let trace: TransportTrace

    /// The current phase. `phases` reports each change.
    public private(set) var phase: WirelessPhase = .idle

    /// The camera network's name while the phone is on it through this session: the catalogue keeps it (`wifiSSID`) so the
    /// app can remove the configuration after a crash. Nil when not joined.
    public private(set) var network: String?

    /// The peripheral the last Bluetooth connection reached: the catalogue keeps it (`bluetoothPeripheralID`).
    public private(set) var peripheral: PeripheralID?

    /// How long the stay has left now, on the session's clock: `WirelessTiming.stay` when it starts, zero once it has run
    /// out. Nil when not staying.
    public var stayRemaining: Duration? {
        guard case .staying = phase, let stayEnd else { return nil }
        return max(.zero, stayEnd - clock.now())
    }

    private var link: (any CameraLink)?
    private var gatt: (any GATTLink)?
    /// A session has been opened on the current join (no leave since), so the next open is a reopen.
    private var openedSinceLeave = false
    /// The next preparation goes to Bluetooth without retrying on Wi-Fi first.
    private var bluetoothFirst = false
    /// When the app went to the background while joined.
    private var awaySince: Duration?
    /// The last scene change the session was told of was to the background.
    private var inBackground = false
    /// The preparation under way may switch the camera's Wi-Fi on over Bluetooth with the app away, and wait for iOS to
    /// rejoin by itself (W14). Set by the call that starts it.
    private var switchOnWhenAway = false
    /// Counts the scene changes the session was told of, so a read of `foreground` they overtook can be set aside.
    private var sceneChanges = 0
    private var stayEnd: Duration?
    private var stayTask: Task<Void, Never>?
    private var stayToken = 0
    private var operation: Task<Result<any CameraLink, WirelessFailure>, Never>?
    private var leaveTask: Task<Void, Never>?
    /// Bumped by every call that changes what is held, so a call that resumes after an await can tell it was overtaken.
    private var epoch = 0
    /// The preparation under way's time in each phase, for the trace only; nil when the trace is off or none is running.
    private var timeline: StepTimeline?
    /// Wakes a join held while the app is away; `appBecameActive()` opens it.
    private let frontWake = FrontWake()
    /// Counts the moves to the background the session was told of, so `apply` can tell whether the app left meanwhile.
    private var backgroundMoves = 0
    /// The preparation under way: since when the app has been away (nil while it is in front), and how long it was away
    /// before that, in all.
    private var preparationAwaySince: Duration?
    private var preparationAway: Duration = .zero
    /// The preparation's last failed hand-off switched the camera's Wi-Fi on again after a lapse (for the trace).
    private var failedInRewrite = false

    /// - Parameters:
    ///   - camera: the camera's Bluetooth identity from the catalogue.
    ///   - connector: Bluetooth (`BluetoothCentral`, W10).
    ///   - joiner: NetworkExtension (`NEHotspotJoiner`, W12).
    ///   - path: the Wi-Fi path (`NWPathGateway`).
    ///   - foreground: the app's scene phase.
    ///   - openLink: connects to the camera at 192.168.122.1:15740 and opens its session, returning an open link (`IPLink`).
    ///     Its argument is true when a session was already opened on this join and the camera's Wi-Fi hasn't been
    ///     switched on since, so the link may reopen with what it knows (W8); false after a join whose hand-off switched
    ///     the camera's Wi-Fi on (CC08 written: the camera starts its contents mode again), and after a first join.
    ///   - clock: every wait in the join and the stay runs on it.
    ///   - trace: the bench log's events (W20): each step's time, the hand-off's CC09 statuses and CC08 writes, the RSSI
    ///     during the hand-off. Recording changes nothing the session does or when; with `.none` nothing is recorded and the
    ///     RSSI isn't read.
    public init(
        camera: WirelessCamera,
        connector: any GATTConnector,
        joiner: any HotspotJoining,
        path: any WiFiPathWatching,
        foreground: any ForegroundSignal,
        openLink: @escaping @Sendable (_ reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink,
        clock: any Clock<Duration> = ContinuousClock(),
        trace: TransportTrace = .none
    ) {
        self.init(camera: camera, connector: connector, joiner: joiner, path: path, foreground: foreground,
                  openLink: openLink, clock: clock, handoff: WiFiHandoff(clock: clock, trace: trace), trace: trace)
    }

    init(
        camera: WirelessCamera,
        connector: any GATTConnector,
        joiner: any HotspotJoining,
        path: any WiFiPathWatching,
        foreground: any ForegroundSignal,
        openLink: @escaping @Sendable (_ reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink,
        clock: any Clock<Duration>,
        handoff: any WiFiHandingOff,
        trace: TransportTrace = .none
    ) {
        self.camera = camera
        self.connector = connector
        self.joiner = joiner
        self.path = path
        self.foreground = foreground
        self.openLink = openLink
        self.handoff = handoff
        self.trace = trace
        self.clock = SessionClock(clock)
        peripheral = camera.peripheral
    }

    /// Every change of phase. Each read returns a new stream that starts with the current phase.
    public nonisolated var phases: AsyncStream<WirelessPhase> { broadcast.stream() }

    // MARK: - Public calls

    /// Gives an open link to the camera for an import: reopened with no join inside the stay, else after the join. A second
    /// call while one is preparing waits for the same result. Throws `WirelessFailure`, holding nothing afterwards.
    public func prepareImport() async throws(WirelessFailure) -> any CameraLink {
        try await prepareImport(bluetoothSwitchOnWhenAway: false)
    }

    /// `prepareImport()`, as the Wi-Fi recovery calls it (W14). With `bluetoothSwitchOnWhenAway` and the app away when a
    /// join would be needed, the session takes the steps that need no join instead of pausing at once: it switches the
    /// camera's Wi-Fi on over Bluetooth (no write when CC09 already reads 2) and waits up to
    /// `WiFiRecoveryTiming.rejoinWhileAway`, and no longer than what is left of the camera's 50 s, for iOS to rejoin the
    /// network whose configuration it still holds; then it opens the session. If iOS doesn't rejoin, it pauses with
    /// `.needsJoin`. Never `apply`s from the background. Only a call that starts a preparation sets this; a second call
    /// meanwhile waits for the same result.
    public func prepareImport(bluetoothSwitchOnWhenAway: Bool) async throws(WirelessFailure) -> any CameraLink {
        if let leaveTask { await leaveTask.value }
        let task: Task<Result<any CameraLink, WirelessFailure>, Never>
        if let operation {
            task = operation
        } else {
            epoch += 1
            switchOnWhenAway = bluetoothSwitchOnWhenAway
            task = Task { await self.runPreparation() }
            operation = task
        }
        return try await task.value.get()
    }

    /// The import has ended (finished, or stopped by the person). In front: close the session and start the stay. In the
    /// background: leave at once, as the continued task's last step (decided 8 Nov). Does nothing unless `ready`.
    public func importFinished() async {
        guard phase == .ready else { return }
        epoch += 1
        let mine = epoch
        if let old = link {
            link = nil
            await old.close()
        }
        guard epoch == mine else { return }
        let inFront = await isInForeground()
        guard epoch == mine else { return }
        if inFront {
            startStay()
        } else {
            await leave()
        }
    }

    /// The app has gone to the background. During the stay: leave at once, in the short background time iOS gives an app
    /// that has just left (the caller holds it open until this returns; decided 8 Nov, removing the configuration from the
    /// background is to be tested in Iteration 3, week 1). During a join it does nothing: a join with the app away 8.9 s
    /// still worked (5 Nov 01:21), and iOS's prompt only makes the app inactive, which isn't the background; the join reads
    /// the foreground itself before each `apply` or rewrite, and holds while the app is away. During an import it does
    /// nothing: the continued task carries it.
    public func appMovedToBackground() async {
        inBackground = true
        sceneChanges += 1
        backgroundMoves += 1
        if operation != nil, preparationAwaySince == nil {
            preparationAwaySince = clock.now()
            trace(.appWentToBackground(during: currentStep))
        }
        if network != nil { awaySince = clock.now() }
        if case .staying = phase { await leave() }
    }

    /// The app is in front again. Leave if the stay ran out while it was away. When the phone is no longer on the camera's
    /// network and the app was away longer than the camera's 50 s, the camera's Wi-Fi is off, so the next preparation goes
    /// to Bluetooth at once (B:191). A join held while the app was away goes on.
    public func appBecameActive() async {
        inBackground = false
        sceneChanges += 1
        if operation != nil, let since = preparationAwaySince {
            preparationAwaySince = nil
            preparationAway += clock.now() - since
            trace(.appCameBack(after: clock.now() - since, during: currentStep))
        }
        frontWake.open()
        let away = awaySince
        awaySince = nil
        if case .staying = phase, let stayEnd, clock.now() >= stayEnd {
            await leave()
            return
        }
        guard network != nil, let away else { return }
        switch phase {
        case .ready, .staying: break
        default: return
        }
        let mine = epoch
        let gateway = await path.gateway()
        guard epoch == mine, network != nil else { return }
        if gateway != WirelessCamera.cameraNetworkGateway, clock.now() - away > HandoffTiming.cameraWiFiWindow {
            bluetoothFirst = true
        }
    }

    /// Leaves now: stops a preparation in progress (waiting for it to end), closes the session, removes the network's
    /// configuration, turns Sony's notifications off and closes the Bluetooth link. No Bluetooth write. Safe to call twice.
    public func leave() async {
        if let operation {
            operation.cancel()
            _ = await operation.value
        }
        await startLeave().value
    }

    // MARK: - Preparation

    private func runPreparation() async -> Result<any CameraLink, WirelessFailure> {
        defer { operation = nil }
        preparationAwaySince = inBackground ? clock.now() : nil
        preparationAway = .zero
        failedInRewrite = false
        if trace.isOn {
            timeline = StepTimeline(start: clock.now(), phase: phase)
            trace(.preparationStarted(joined: network != nil, bluetoothFirst: network != nil && bluetoothFirst))
        }
        do throws(WirelessFailure) {
            let opened = try await prepare()
            endTimeline(succeeded: true)
            return .success(opened)
        } catch {
            if trace.isOn {
                let away = preparationAway + (preparationAwaySince.map { clock.now() - $0 } ?? .zero)
                trace(.preparationFailed(rewrite: failedInRewrite, appAway: away))
            }
            endTimeline(succeeded: false)
            return .failure(error)
        }
    }

    /// Records the preparation's step times and forgets them (trace only).
    private func endTimeline(succeeded: Bool) {
        guard var ended = timeline else { return }
        timeline = nil
        ended.move(to: phase, at: clock.now())
        trace(.preparationEnded(succeeded: succeeded, times: ended.times))
    }

    private func prepare() async throws(WirelessFailure) -> any CameraLink {
        stopStay()
        if network != nil {
            if let old = link {
                link = nil
                await old.close()
            }
            set(.openingSession)
            if !bluetoothFirst {
                let reopenStart = clock.now()
                switch await openSession(reopening: openedSinceLeave, within: WirelessTiming.wifiRetryBeforeBluetooth) {
                case .opened(let opened):
                    link = opened
                    openedSinceLeave = true
                    set(.ready)
                    return opened
                case .refused(let failure):
                    await abandon()
                    throw .link(failure)
                case .cancelled:
                    await abandon()
                    throw .cancelled
                case .gaveUp:
                    trace(.stayReopenGaveUp(after: clock.now() - reopenStart))
                    // back to Bluetooth (Shamil, 9 Nov)
                }
            }
            bluetoothFirst = false
        }
        return try await join()
    }

    /// What the join holds while it runs. It owns these until it hands them to the session, and lets them go if it fails.
    private struct Held: Sendable {
        var gatt: (any GATTLink)?
        var ssid: String?
        var link: (any CameraLink)?
    }

    private func join() async throws(WirelessFailure) -> any CameraLink {
        var held = Held(gatt: gatt, ssid: network, link: nil)
        gatt = nil
        network = nil
        do throws(WirelessFailure) {
            let opened = try await joinSteps(&held)
            gatt = held.gatt
            network = held.ssid
            link = opened
            openedSinceLeave = true
            set(.ready)
            return opened
        } catch {
            await letGo(held)
            openedSinceLeave = false
            if case .paused(let pause) = error { set(.paused(pause)) } else { set(.idle) }
            throw error
        }
    }

    private func joinSteps(_ held: inout Held) async throws(WirelessFailure) -> any CameraLink {
        guard await isInForeground() else {
            // A join needs the app in front. Without one, iOS can only rejoin a network whose configuration is still saved.
            guard switchOnWhenAway, held.ssid != nil else { throw .paused(.needsJoin) }
            return try await switchOnAndAwaitRejoin(&held)
        }
        try checkCancelled()
        set(.handingOff)
        if let current = held.gatt, !(await isConnected(current)) {
            await current.disconnect()
            held.gatt = nil
        }
        // Never held before the first CC08 write (decided 9 Nov): the person is most likely still there.
        var (handed, switchedOn) = try await switchOn(&held, .first)
        // The camera's 50 s run from status 2, not from the write (B:180).
        var windowEnd = clock.now() + handed.windowRemaining

        var failedTries = 0
        var rewrites = 0
        /// Switch-ons after a lapse that followed time away (`WirelessTiming.switchOnsAfterAway`).
        var switchOnsAfterAway = 0
        var applies = 0
        var lastFailure: JoinFailure?
        /// iOS refused `apply` as not in front while the scene read active: once more after a second, then pause.
        var refusedInFront = false
        /// Why the next hold at the top of the loop would hold.
        var holdReason = WirelessHoldReason.beforeJoin
        joining: while true {
            try checkCancelled()
            // Never `apply` from the background: iOS shows no prompt there (bench 19.1). Hold until the app is back.
            let reason = holdReason
            holdReason = .beforeJoin
            let heldFor = try await holdWhileAway(reason, windowEnd: windowEnd)
            if heldFor != nil, clock.now() >= windowEnd {
                // The camera's 50 s ran out while the app was away: look, and switch its Wi-Fi on again if it went off.
                // Not the person's slowness at the prompt, so not counted against `rewritesPerJoin`.
                if case .off(let linkDown) = await cameraWiFi(held.gatt, windowEnd: windowEnd) {
                    try checkCancelled()
                    guard switchOnsAfterAway < WirelessTiming.switchOnsAfterAway else { throw .paused(.needsJoin) }
                    switchOnsAfterAway += 1
                    let again = try await switchOnAgain(&held, linkDown: linkDown,
                                                        .rewrite(sameLink: false, lapsedWhileAway: true))
                    handed = again.result
                    switchedOn = switchedOn || again.switchedOn
                    windowEnd = clock.now() + handed.windowRemaining
                    failedTries = 0
                    lastFailure = nil
                    // The person may have left again during the switch-on: back to the hold, which reads the foreground
                    // before `apply`. It can't spin: another switch-on needs another hold that ends past the new window.
                    continue joining
                }
            }
            try checkCancelled()
            // A hold that ended inside the window has already moved to `.joining`.
            if heldFor == nil || phase != .joining { set(.joining) }
            held.ssid = handed.credentials.ssid // set first: whatever `apply` did, a leave removes it
            var applied = false
            applies += 1
            let applyStart = clock.now()
            let movesBefore = backgroundMoves
            var refusal: JoinFailure?
            do throws(JoinFailure) {
                try await joiner.apply(handed.credentials)
                applied = true
            } catch {
                refusal = error
            }
            let appliedInFront = backgroundMoves == movesBefore && !inBackground
            trace(.joinApplied(attempt: applies, after: clock.now() - applyStart, failure: refusal, inFront: appliedInFront))
            if let refusal {
                switch refusal {
                case .userDenied: throw .paused(.joinDeclined)
                case .notInForeground:
                    // Not a failed try: hold until the app is back (at the top of the loop), then apply again.
                    if await isInForeground() {
                        // The scene already reads active (an inactive to active race): once more, then pause.
                        guard !refusedInFront else { throw .paused(.needsJoin) }
                        refusedInFront = true
                        do { try await clock.sleep(until: clock.now() + WirelessTiming.applyAgainInFrontAfter) } catch {
                            throw .cancelled
                        }
                    } else {
                        holdReason = .joinRefused
                    }
                    continue joining
                case .invalidCredentials: throw .join(refusal)
                case .cancelled: throw .cancelled
                case .pending, .systemConfiguration, .other: lastFailure = refusal
                }
            }
            try checkCancelled()

            var camera: CameraWiFi?
            if applied {
                if clock.now() >= windowEnd { camera = await cameraWiFi(held.gatt, windowEnd: windowEnd) }
                if camera?.isOff != true {
                    let waitStart = clock.now()
                    let found = await path.waitForGateway(WirelessCamera.cameraNetworkGateway,
                                                          timeout: WirelessTiming.gatewayWait)
                    trace(.gateway(found: found, after: clock.now() - waitStart))
                    if found { break joining }
                    camera = nil
                }
                try checkCancelled()
            }
            if camera == nil { camera = await cameraWiFi(held.gatt, windowEnd: windowEnd) }
            try checkCancelled()

            switch camera {
            case .off(let linkDown):
                // Only a lapse that came with the app in front throughout counts against `rewritesPerJoin`, as on the
                // return from a hold at the top of the loop: one that followed time away (the app left while iOS's prompt
                // was up, or leaves now) is not the person's slowness at the prompt. Each such switch-on still needs the
                // person to come back, within the hold's limit.
                let counted = appliedInFront
                if counted {
                    guard rewrites < WirelessTiming.rewritesPerJoin else { throw .cameraWiFiLapsed }
                }
                // No rewrite while the app is away either: hold first. After time away, a fresh `run` (it resubscribes).
                let wasAway = try await holdWhileAway(.beforeSwitchOn, windowEnd: windowEnd) != nil
                try checkCancelled()
                if counted, !wasAway {
                    rewrites += 1
                    trace(.rewriteStarted(number: rewrites, limit: WirelessTiming.rewritesPerJoin))
                } else {
                    guard switchOnsAfterAway < WirelessTiming.switchOnsAfterAway else { throw .paused(.needsJoin) }
                    switchOnsAfterAway += 1
                }
                // `appliedInFront` false: the app went away while iOS's prompt was up, and the camera's 50 s ran out.
                let rewritten = try await switchOnAgain(&held, linkDown: linkDown,
                                                        .rewrite(sameLink: !wasAway, lapsedWhileAway: !appliedInFront))
                handed = rewritten.result
                switchedOn = switchedOn || rewritten.switchedOn
                windowEnd = clock.now() + handed.windowRemaining
                // A new hand-off: its own `WirelessTiming.joinAttempts`.
                failedTries = 0
                lastFailure = nil
            case .on, nil:
                failedTries += 1
                guard failedTries < WirelessTiming.joinAttempts else {
                    throw lastFailure.map { WirelessFailure.join($0) } ?? .noGateway
                }
                if !applied {
                    do { try await clock.sleep(until: clock.now() + WirelessTiming.applyRetryAfter) } catch { throw .cancelled }
                }
            }
        }

        set(.openingSession)
        switch await openSession(reopening: openedSinceLeave && !switchedOn, within: WirelessTiming.portWait) {
        case .opened(let opened):
            held.link = opened
            return opened
        case .refused(let failure), .gaveUp(let failure):
            throw .link(failure)
        case .cancelled:
            throw .cancelled
        }
    }

    /// Holds the join while the app is away: returns nil at once when it is in front, else waits in `.awaitingFront`,
    /// keeping everything held, until `appBecameActive()` with the app still in front once woken, and returns how long it
    /// waited. A return followed at once by another leave holds on, for the rest of the limit. Throws
    /// `.paused(.needsJoin)` when `WirelessTiming.joinHoldWhileAway` passes first (the caller lets go of everything),
    /// `.cancelled` on `leave()`. `windowEnd`, when given, is the end of the camera's 50 s.
    ///
    /// On the return it moves out of `.awaitingFront` at once, so the person isn't asked to come back while they are back:
    /// to `.joining` when a join follows inside the camera's 50 s, else to `.handingOff` (CC09 is read, and the camera's
    /// Wi-Fi may be switched on again).
    private func holdWhileAway(
        _ reason: WirelessHoldReason, windowEnd: Duration?
    ) async throws(WirelessFailure) -> Duration? {
        // Taken before the read, so a return during the read or before the wait below is not missed.
        var token = frontWake.token
        guard !(await isInForeground()) else { return nil }
        try checkCancelled()
        set(.awaitingFront)
        let started = clock.now()
        let limit = WirelessTiming.joinHoldWhileAway
        trace(.joinHeld(reason: reason, limit: limit))
        while true {
            switch await frontWake.wait(after: token, until: started + limit, on: clock) {
            case .woken:
                try checkCancelled()
                // Read again: the app may have left again since it came back. Taken first, as above.
                token = frontWake.token
                guard await isInForeground() else { continue }
                try checkCancelled()
                let after = clock.now() - started
                let windowPassed = windowEnd.map { clock.now() >= $0 } ?? false
                trace(.joinHoldEnded(after: after, windowPassed: windowPassed))
                switch reason {
                case .beforeJoin, .joinRefused: set(windowPassed ? .handingOff : .joining)
                case .beforeSwitchOn, .retryHandoff: set(.handingOff)
                }
                return after
            case .timedOut:
                trace(.joinHoldRanOut(after: clock.now() - started))
                throw .paused(.needsJoin)
            case .cancelled:
                throw .cancelled
            }
        }
    }

    /// Which switch-on a hand-off is, for its failure.
    private enum SwitchOn {
        /// The join's first hand-off: a failure is `.handoff`.
        case first
        /// Switching the camera's Wi-Fi on again after a lapse: `rewriteIfLapsed` on the same link when `sameLink`, else a
        /// fresh `run`. A failure is `.rewriteFailed`, or `.paused(.needsJoin)` when the lapse came while the app was away.
        case rewrite(sameLink: Bool, lapsedWhileAway: Bool)
    }

    /// Switches the camera's Wi-Fi on again after a lapse, from `.handingOff` back to `.joining`. A link that is down is
    /// let go first, so a new connection runs the hand-off.
    private func switchOnAgain(
        _ held: inout Held, linkDown: Bool, _ kind: SwitchOn
    ) async throws(WirelessFailure) -> (result: HandoffResult, switchedOn: Bool) {
        // A hold just before may have moved here already.
        if phase != .handingOff { set(.handingOff) }
        if linkDown, let current = held.gatt {
            await current.disconnect()
            held.gatt = nil
        }
        let result = try await switchOn(&held, kind)
        set(.joining)
        return result
    }

    /// `handOff`, run once more from the front when it failed on a time limit while the app was away for part of it (its
    /// limits may have come due during a suspension, without the camera having had its time), and with its failure named
    /// by `kind`.
    private func switchOn(
        _ held: inout Held, _ kind: SwitchOn
    ) async throws(WirelessFailure) -> (result: HandoffResult, switchedOn: Bool) {
        let isRewrite: Bool
        let sameLink: Bool
        let lapsedWhileAway: Bool
        switch kind {
        case .first: (isRewrite, sameLink, lapsedWhileAway) = (false, false, false)
        case let .rewrite(same, away): (isRewrite, sameLink, lapsedWhileAway) = (true, same, away)
        }
        // Moves to the background only: an inactive spell in front (Control Centre, a banner) is not time away.
        let movesBefore = backgroundMoves
        // Until it succeeds, a failure of the preparation is this hand-off's.
        failedInRewrite = isRewrite
        var failure: HandoffFailure
        do throws(WirelessFailure) {
            let result = try await handOff(&held, rewriting: sameLink, rewrite: isRewrite)
            failedInRewrite = false
            return result
        } catch {
            guard case .handoff(let handoffFailure) = error else { throw error }
            failure = handoffFailure
        }
        if Self.mayHaveLapsedInSuspension(failure), backgroundMoves != movesBefore {
            trace(.handoffRetriedAfterAway(rewrite: isRewrite, failure: failure))
            // A hold that waited has already moved to `.handingOff`.
            let waited = try await holdWhileAway(.retryHandoff, windowEnd: nil)
            try checkCancelled()
            if waited == nil { set(.handingOff) }
            do throws(WirelessFailure) {
                // A fresh `run`: it reads CC09 and writes only at 0, and resubscribes.
                let result = try await handOff(&held, rewriting: false, rewrite: isRewrite)
                failedInRewrite = false
                return result
            } catch {
                guard case .handoff(let again) = error else { throw error }
                failure = again
            }
        }
        if lapsedWhileAway { throw .paused(.needsJoin) }
        throw isRewrite ? .rewriteFailed(failure) : .handoff(failure)
    }

    /// A failure a suspension of the app can cause by itself: a time limit that came due late (ContinuousClock keeps
    /// counting while the app is suspended).
    private static func mayHaveLapsedInSuspension(_ failure: HandoffFailure) -> Bool {
        switch failure {
        case .timedOut, .wifiDidNotStart, .wifiLapsed, .gatt(.timedOut, _): true
        default: false
        }
    }

    /// With the app away (W14, B:211): switch the camera's Wi-Fi on over Bluetooth, wait for iOS to rejoin by itself, and
    /// open the session; `.needsJoin` when iOS doesn't rejoin in time. A Bluetooth failure is thrown as it is: the person has
    /// to come back for any of them.
    private func switchOnAndAwaitRejoin(_ held: inout Held) async throws(WirelessFailure) -> any CameraLink {
        try checkCancelled()
        set(.handingOff)
        if let current = held.gatt, !(await isConnected(current)) {
            await current.disconnect()
            held.gatt = nil
        }
        let (handed, switchedOn) = try await handOff(&held, rewriting: false, rewrite: false)
        try checkCancelled()
        set(.joining)
        // Nobody joined yet, so the camera's Wi-Fi goes off 50 s after status 2: no point waiting past that.
        let wait = min(WiFiRecoveryTiming.rejoinWhileAway, handed.windowRemaining)
        let waitStart = clock.now()
        let rejoined = await path.waitForGateway(WirelessCamera.cameraNetworkGateway, timeout: wait)
        trace(.rejoinedWhileAway(found: rejoined, after: clock.now() - waitStart))
        try checkCancelled()
        guard rejoined else { throw .paused(.needsJoin) }
        set(.openingSession)
        switch await openSession(reopening: openedSinceLeave && !switchedOn, within: WirelessTiming.portWait) {
        case .opened(let opened):
            held.link = opened
            return opened
        case .refused(let failure), .gaveUp(let failure):
            throw .link(failure)
        case .cancelled:
            throw .cancelled
        }
    }

    /// Connects when there is no link, and runs the hand-off: `run` on a new link (it has no subscriptions), else
    /// `rewriteIfLapsed` when `rewriting`. A dropped link is connected again and the hand-off run again,
    /// `WirelessTiming.handoffReconnects` times: after a drop following the write, `run` reads CC09 and writes only at 0.
    /// `switchedOn`: some run in it wrote CC08, including one whose link dropped after the write. `rewrite`: it switches
    /// the camera's Wi-Fi on again after a lapse (for the trace).
    private func handOff(
        _ held: inout Held, rewriting: Bool, rewrite: Bool
    ) async throws(WirelessFailure) -> (result: HandoffResult, switchedOn: Bool) {
        var reconnects = 0
        var wrote = false
        let started = clock.now()
        while true {
            try checkCancelled()
            let current: any GATTLink
            let fresh: Bool
            if let existing = held.gatt {
                current = existing
                fresh = false
            } else {
                current = try await connect()
                held.gatt = current
                fresh = true
            }
            readSignal(of: current, since: started)
            do throws(HandoffFailure) {
                let result = rewriting && !fresh
                    ? try await handoff.rewriteIfLapsed(on: current) : try await handoff.run(on: current)
                if trace.isOn {
                    trace(.handoffFinished(after: clock.now() - started, rewrite: rewrite,
                                           wroteWiFiOn: wrote || result.wroteWiFiOn,
                                           statusTwoAlready: result.launchedBeforeLooking,
                                           windowLeft: result.windowRemaining))
                    readSignal(of: current, since: started)
                }
                return (result, wrote || result.wroteWiFiOn)
            } catch {
                switch error {
                case .linkDropped(let afterWrite):
                    wrote = wrote || afterWrite
                    reconnects += 1
                    trace(.bluetoothDropped(afterWrite: afterWrite, reconnect: reconnects))
                    await current.disconnect()
                    held.gatt = nil
                    guard reconnects <= WirelessTiming.handoffReconnects else { throw .handoff(error) }
                case .notPaired: throw .paused(.notPaired)
                case .cancelled: throw .cancelled
                default: throw .handoff(error)
                }
            }
        }
    }

    /// For the trace only: reads the link's RSSI on a task of its own, so the hand-off never waits for it, and records it with
    /// the time since `since` (the hand-off's start). Does nothing when the trace is off or the link can't read it.
    private func readSignal(of link: any GATTLink, since: Duration) {
        guard trace.isOn, let reader = link as? any GATTSignalReading else { return }
        let trace = trace
        let clock = clock
        Task {
            let dBm = await reader.readSignalStrength(timeout: GATTSignalTiming.read)
            trace(.bluetoothSignal(dBm: dBm, after: clock.now() - since))
        }
    }

    private func connect() async throws(WirelessFailure) -> any GATTLink {
        let started = clock.now()
        do throws(GATTFailure) {
            let link = try await connector.connect(known: peripheral ?? camera.peripheral)
            peripheral = link.peripheral
            trace(.bluetoothConnected(after: clock.now() - started))
            return link
        } catch {
            switch error {
            case .notPaired: throw .paused(.notPaired)
            case .bluetoothOff: throw .paused(.bluetoothOff)
            case .unauthorised: throw .paused(.bluetoothNotAllowed)
            case .timedOut: throw .cameraNotFound
            case .cancelled: throw .cancelled
            default: throw .bluetooth(error)
            }
        }
    }

    private enum CameraWiFi: Equatable {
        case on
        /// Off, going off or coming on (CC09 not at 2), or presumed off: the link is down and the camera's 50 s have passed.
        case off(linkDown: Bool)

        var isOff: Bool { if case .off = self { true } else { false } }
    }

    /// Reads CC09 to see whether the camera's Wi-Fi is still on. With the link down, the camera's 50 s from status 2 decide.
    private func cameraWiFi(_ link: (any GATTLink)?, windowEnd: Duration) async -> CameraWiFi {
        let windowPassed = clock.now() >= windowEnd
        let (decision, check) = await lookAtCamera(link, windowPassed: windowPassed)
        trace(.cameraWiFiChecked(check, windowPassed: windowPassed, off: decision.isOff))
        return decision
    }

    /// `cameraWiFi`'s decision, with what it saw for the trace.
    private func lookAtCamera(_ link: (any GATTLink)?, windowPassed: Bool) async -> (CameraWiFi, CameraWiFiCheck) {
        guard let link else { return (windowPassed ? .off(linkDown: true) : .on, .noLink) }
        do throws(GATTFailure) {
            let value = try await link.read(.status, timeout: HandoffTiming.pollRead)
            var status = SonyStatus()
            _ = try? status.merge(value)
            return (status.wifiStatus == .launched ? .on : .off(linkDown: false), .read(status.wifiStatus?.rawValue))
        } catch {
            switch error {
            case .linkDropped: return (windowPassed ? .off(linkDown: true) : .on, .linkDown)
            default: return (windowPassed ? .off(linkDown: false) : .on, .readFailed)
            }
        }
    }

    private enum Opening {
        case opened(any CameraLink)
        /// A failure trying again won't fix (a refusal, the wrong camera, no permission).
        case refused(CameraLinkFailure)
        /// Every try failed in the time given; the last failure.
        case gaveUp(CameraLinkFailure)
        case cancelled
    }

    /// Opens the session, trying again every `WirelessTiming.portRetryEvery` while the failure is one a retry can fix, until
    /// `window` has passed since the first try.
    private func openSession(reopening: Bool, within window: Duration) async -> Opening {
        let started = clock.now()
        let deadline = started + window
        var tries = 0
        while true {
            if Task.isCancelled { return .cancelled }
            let failure: CameraLinkFailure
            tries += 1
            do throws(CameraLinkFailure) {
                let opened = try await openLink(reopening)
                trace(.sessionOpened(after: clock.now() - started, tries: tries, reopening: reopening))
                return .opened(opened)
            } catch {
                failure = error
            }
            switch failure.outcome {
            case .retryNow, .retryOnReconnect: break
            case .skipFile, .stopJob:
                trace(.sessionNotOpened(after: clock.now() - started, tries: tries, refused: true))
                return .refused(failure)
            }
            let next = clock.now() + WirelessTiming.portRetryEvery
            guard next <= deadline else {
                trace(.sessionNotOpened(after: clock.now() - started, tries: tries, refused: false))
                return .gaveUp(failure)
            }
            do { try await clock.sleep(until: next) } catch { return .cancelled }
        }
    }

    // MARK: - Stay

    private func startStay() {
        let end = clock.now() + WirelessTiming.stay
        stayEnd = end
        stayToken += 1
        let token = stayToken
        set(.staying)
        let held = gatt
        stayTask = Task { await self.runStay(token: token, end: end, link: held) }
    }

    private func stopStay() {
        stayToken += 1
        stayTask?.cancel()
        stayTask = nil
        stayEnd = nil
    }

    /// The stay's one loop: its timer, and the Bluetooth link kept up.
    private func runStay(token: Int, end: Duration, link: (any GATTLink)?) async {
        let events = StayEvents(clock: clock)
        events.set(.stayEnds, at: end)
        var linkNumber = 0
        var pump: Task<Void, Never>?
        // A link that dropped during the import is seen here, before the first wait, so the reconnect starts at once rather
        // than whenever a pump gets to it.
        if let link, await isConnected(link) {
            pump = Self.pumpDrops(of: link, number: linkNumber, into: events)
        } else {
            events.push(.linkDropped(linkNumber: linkNumber))
        }
        guard token == stayToken else {
            pump?.cancel()
            return
        }
        defer { pump?.cancel() }

        while let wake = await events.next() {
            guard token == stayToken else { return }
            switch wake {
            case .timer(.stayEnds), .timer(.linkDownLimit):
                _ = startLeave()
                return
            case .event(.linkDropped(let number)):
                guard number == linkNumber else { continue }
                let now = clock.now()
                // The first drop reconnects at once; a link that dropped again before it was restored waits the gap.
                let firstDrop = events.setIfAbsent(.linkDownLimit, at: now + WirelessTiming.linkDownStayLimit)
                events.set(.reconnect, at: firstDrop ? now : now + WirelessTiming.bluetoothReconnectEvery)
                if let dropped = gatt {
                    gatt = nil
                    await dropped.disconnect()
                    guard token == stayToken else { return }
                }
            case .timer(.reconnect):
                let fresh: any GATTLink
                do throws(GATTFailure) {
                    fresh = try await connector.connect(known: peripheral ?? camera.peripheral)
                } catch {
                    guard token == stayToken else { return }
                    events.set(.reconnect, at: clock.now() + WirelessTiming.bluetoothReconnectEvery)
                    continue
                }
                guard token == stayToken else {
                    await fresh.disconnect()
                    return
                }
                // As in the 785 s stay that rests on it (4 Nov): the link up with Sony's notifications on. Best effort; a drop
                // shows on the link's state.
                let switchedOn = (try? await NotificationSwitches.turnOn(fresh)) != nil
                let up = await isConnected(fresh)
                guard token == stayToken else {
                    // A bonded camera may keep the switches across links (W5), so they go off first, on a task of its own.
                    await letGo(Held(gatt: fresh, ssid: nil, link: nil))
                    return
                }
                peripheral = fresh.peripheral
                gatt = fresh
                linkNumber += 1
                pump?.cancel()
                pump = nil
                if up {
                    pump = Self.pumpDrops(of: fresh, number: linkNumber, into: events)
                    // Restored, unless the switches failed: then the limit keeps running from the first drop.
                    if switchedOn { events.cancel(.linkDownLimit) }
                } else {
                    // Dropped at once: not restored, so the limit keeps running from the first drop. Queued here rather
                    // than left to a pump, so the drop is seen before the next wait.
                    events.push(.linkDropped(linkNumber: linkNumber))
                }
            }
        }
    }

    private static func pumpDrops(of link: any GATTLink, number: Int, into events: StayEvents) -> Task<Void, Never> {
        let states = link.state
        return Task {
            for await state in states {
                if case .dropped = state {
                    events.push(.linkDropped(linkNumber: number))
                    return
                }
            }
        }
    }

    // MARK: - Leave

    /// Starts the leave, or returns the one under way. Takes everything held, so nothing else can use it meanwhile.
    private func startLeave() -> Task<Void, Never> {
        if let leaveTask { return leaveTask }
        epoch += 1
        stopStay()
        let held = Held(gatt: gatt, ssid: network, link: link)
        gatt = nil
        network = nil
        link = nil
        openedSinceLeave = false
        bluetoothFirst = false
        awaySince = nil
        guard held.gatt != nil || held.ssid != nil || held.link != nil else {
            if case .paused = phase { set(.idle) }
            return Task {}
        }
        set(.leaving)
        let task = Task {
            await self.release(held)
            self.finishLeave()
        }
        leaveTask = task
        return task
    }

    private func finishLeave() {
        leaveTask = nil
        set(.idle)
    }

    /// The preparation failed or was stopped: let go of what the session held.
    private func abandon() async {
        let held = Held(gatt: gatt, ssid: network, link: link)
        gatt = nil
        network = nil
        link = nil
        openedSinceLeave = false
        bluetoothFirst = false
        await letGo(held)
        set(.idle)
    }

    /// Releases on a task of its own, so a cancelled preparation still closes, removes and disconnects everything.
    private func letGo(_ held: Held) async {
        await Task { await self.release(held) }.value
    }

    /// Close the session, remove the configuration, turn the notifications off, close the Bluetooth link. No Bluetooth write.
    private func release(_ held: Held) async {
        if let link = held.link { await link.close() }
        if let ssid = held.ssid { await joiner.leave(ssid: ssid) }
        if let gatt = held.gatt {
            if await isConnected(gatt) { _ = await handoff.release(gatt) }
            await gatt.disconnect()
        }
    }

    // MARK: - Helpers

    /// The step of the preparation under way, for the scene changes the trace records.
    private var currentStep: WirelessStep {
        switch phase {
        case .joining, .awaitingFront: .join
        case .openingSession, .ready: .session
        default: .handOff
        }
    }

    private func set(_ next: WirelessPhase) {
        timeline?.move(to: next, at: clock.now())
        phase = next
        broadcast.send(next)
    }

    /// `foreground`, unless the session was told of a scene change while it read it: then that change decides (an import
    /// ending as the app goes to the background leaves rather than starting a stay in the background).
    private func isInForeground() async -> Bool {
        let before = sceneChanges
        let read = await foreground.isInForeground
        return sceneChanges == before ? read : !inBackground
    }

    private func checkCancelled() throws(WirelessFailure) {
        if Task.isCancelled { throw .cancelled }
    }

    /// The link's state stream starts with its current state (`GATTLink` contract).
    private func isConnected(_ link: any GATTLink) async -> Bool {
        for await state in link.state { return state == .connected }
        return false
    }
}

/// One preparation's time in each phase, summed (the trace's step times). Phases outside the three steps count only towards
/// the total.
struct StepTimeline: Sendable {
    private let start: Duration
    private var phase: WirelessPhase
    private var since: Duration
    private var spent: [WirelessPhase: Duration] = [:]
    private var end: Duration?

    init(start: Duration, phase: WirelessPhase) {
        self.start = start
        self.phase = phase
        since = start
    }

    /// The phase changed (or the preparation ended) at `now`.
    mutating func move(to next: WirelessPhase, at now: Duration) {
        spent[phase, default: .zero] += now - since
        phase = next
        since = now
        end = now
    }

    var times: WirelessStepTimes {
        WirelessStepTimes(total: (end ?? start) - start, handingOff: spent[.handingOff] ?? .zero,
                          joining: spent[.joining] ?? .zero, openingSession: spent[.openingSession] ?? .zero,
                          held: spent[.awaitingFront] ?? .zero)
    }
}
