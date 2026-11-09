import CameraTransport
import Foundation
import ImportEngine

/// The Wi-Fi session as the recovery uses it. `WirelessSession` (W11) is the real one; tests script it.
public protocol WiFiRecoverySession: Sendable {
    /// An open link to the camera again, by the decided order (`WirelessSession.prepareImport(bluetoothSwitchOnWhenAway:)`).
    func prepareImport(bluetoothSwitchOnWhenAway: Bool) async throws(WirelessFailure) -> any CameraLink
    /// The import has ended: in front the stay starts, in the background the session leaves. Called when a reopen
    /// finishes after the job it was for has ended, so the session it opened isn't left running.
    func importFinished() async
}

extension WirelessSession: WiFiRecoverySession {}

/// What the recovery needs from the Import screen's model. `ImportModel` is the one (ImportModel+WiFiRecovery.swift).
@MainActor
protocol WiFiRecoveryHost: AnyObject {
    /// The app is in the background.
    var isAppAway: Bool { get }
    /// The person paused the job and hasn't continued it: no pause notification then, as for an expiry (W13).
    var isPausedByPerson: Bool { get }
    /// The carrier of the job's camera; the recovery acts only on Wi-Fi.
    var recoveryCarrier: CameraCarrier? { get }
    /// The items the camera listed before, for listing only the new handles on the new session.
    var recoveryKnownItems: [CameraItem] { get }
    /// The route for the files not yet committed after reading Photos access again (backlog section 5: before a paused
    /// or interrupted import continues); nil when nothing changes.
    func recoveryRoute() async -> ImportRoute?
    /// A recovery is waiting: move the continued task's progress by made-up bytes, so it doesn't stand still.
    func recoveryWaitTick()
    /// Posts the pause notification, once per stay away and only when iOS allows it (W13).
    func notifyPausedWhileAway() async
    /// The job carries on through `link`: hold it for the job, and read the engine again.
    func recoveryCarriesOn(through link: any CameraLink) async
    func refresh() async
}

/// Gets a Wi-Fi import back after the camera drops its card or the session, by the decided order (backlog Iteration 3,
/// section 9; decision 3; Shamil, 9 Nov), with `WiFiRecoveryPlan` deciding each step and `WirelessSession` taking the
/// radio steps.
///
/// It watches the job's state through the Import model (`ImportModel.refresh()` hands each one over):
/// - **Card gone, session up** (`.paused(.cardUnavailable)`): wait up to `WiFiRecoveryTiming.waitForStoreAdded` for
///   StoreAdded, after which the engine lists the card again by itself and goes on.
/// - **No StoreAdded in time, or the session lost** (`.paused(.cameraUnreachable)`): `prepareImport` on the session, which
///   closes the session, tries the port for 30 s and reopens with no join, and otherwise goes to Bluetooth and joins at
///   status 2 with no second fixed wait (in front) or switches the camera's Wi-Fi on and waits for iOS to rejoin (away).
///   Then the card is listed asking only for new handles (`ReusingListing`, W8) and the job carried on through
///   `ImportEngine.reconnect(_:to:knownItems:route:)`, which resumes the file in flight from its checkpoint with 0x9211.
/// - **With the app away**, when a join is needed, anything else fails, or the import has no recovery left, the job pauses
///   with `.needsJoin` and the pause notification is posted ("Import paused. Open Shutter Bridge to continue."; new in
///   1.0, B:211). When the person comes back (`appBecameActive()`), the recovery runs again from the front and joins.
/// - **In front**, a failed reopen gives up: the job stays paused for the camera until `tryAgain()`. So does a join the
///   session still can't make from a reopen that began in front (its scene signal not yet active, or the join refused
///   while the scene is inactive), rather than retrying at once.
/// - At most `WiFiRecoveryTiming.recoveriesPerImport` recoveries by themselves per import; only the person's return or
///   `tryAgain()` starts the count again.
/// - While it waits (for the card, or for the reopen) the continued task's progress moves by made-up bytes, as the
///   spike's did (`ImportBackgroundCoordinator.nudge()`).
///
/// The app (W16) makes one per Import model, attaches it (`ImportModel.attachWiFiRecovery(_:)`), and sets `session` to the
/// job's `WirelessSession` when a Wi-Fi job starts and nil when it ends; setting it forgets any recovery. Without a session
/// it does nothing, so USB jobs and Wi-Fi jobs before W16 are unchanged. A recovery never overrides the continued task: a
/// job paused for an expiry (`.taskExpired`, which a needed join or a removal can hide, so the engine is asked,
/// `isPaused(for:)`) waits for Continue (W13); a wait for the card that sees an expiry stops; and a reopen that finishes
/// after an expiry gives its link to the job keeping the expiry, so the job shows the expiry and Continue carries it on.
@MainActor
public final class WiFiRecoveryCoordinator {
    /// The Wi-Fi session of the job that runs now; nil for none (and for a USB job). Set it once when a Wi-Fi job starts
    /// and to nil when it ends: either forgets any recovery, so none carries over to the next job.
    public var session: (any WiFiRecoverySession)? {
        didSet { reset() }
    }
    /// Whether the camera's Wi-Fi may be switched on over Bluetooth with the app away (B:211, "if allowed"). On by
    /// default: the app's `bluetooth-central` background mode is decided (Shamil, 9 Nov). `unverified`: a switch-on from
    /// the background was never measured.
    public var bluetoothSwitchOnWhenAway: Bool
    /// The recovery's state.
    public private(set) var plan: WiFiRecoveryPlan {
        didSet {
            if plan.phase != oldValue.phase { onPhaseChanged?(plan.phase) }
        }
    }
    /// Told each time the plan's phase changes, so a screen can follow it (the Import model keeps it as
    /// `wifiRecoveryPhase`, which is observed; this class isn't).
    var onPhaseChanged: (@MainActor (WiFiRecoveryPlan.Phase) -> Void)?

    weak var host: (any WiFiRecoveryHost)?

    private let engine: ImportEngine
    private let sleep: @Sendable (Duration) async throws -> Void
    private let tickSleep: @Sendable (Duration) async throws -> Void
    private let listing: @Sendable (any CameraLink, [CameraItem]) async throws(CameraLinkFailure) -> [CameraItem]
    private let log: any BenchLog
    /// The job the recovery under way is for.
    private var job: ImportJobID?
    /// The wait for StoreAdded, cancelled when it is no longer needed. The other steps are never cancelled: a reopen
    /// that ends after a reset still has its session finished (`reopenEnded`), and a late result is set aside by `token`.
    private var cardWait: Task<Void, Never>?
    /// Bumped by every step and by a reset, so a step's late result is set aside.
    private var token = 0
    /// Whether the latest reopen began with the app away: a join it then needs, with the app in front by the time it
    /// pauses, is a return the recovery missed while it reopened, so it runs again from the front, once.
    private var reopenBeganAway = false
    /// Moves the continued task's progress while the recovery waits.
    private var ticker: Task<Void, Never>?
    /// A check that the job the recovery waits on is still the engine's, in flight.
    private var checkingJob = false
    /// The job's state as last handed over.
    private var lastState: ImportJobState = .idle

    /// How often the continued task's progress moves while the recovery waits: the spike's once a second.
    static let tickEvery: Duration = .seconds(1)

    /// - Parameters:
    ///   - clock: the wait for StoreAdded runs on it.
    ///   - tickClock: the progress ticks while the recovery waits run on it.
    ///   - recoveriesPerImport: how many recoveries an import makes by itself (`WiFiRecoveryTiming.recoveriesPerImport`).
    ///   - listing: lists the card on the new session given the items known before; by default `ReusingListing` where the
    ///     link has it (`IPLink`), else `list()`.
    public init(
        engine: ImportEngine,
        clock: some Clock<Duration> = ContinuousClock(),
        tickClock: some Clock<Duration> = ContinuousClock(),
        bluetoothSwitchOnWhenAway: Bool = true,
        recoveriesPerImport: Int = WiFiRecoveryTiming.recoveriesPerImport,
        listing: @escaping @Sendable (any CameraLink, [CameraItem]) async throws(CameraLinkFailure) -> [CameraItem]
            = WiFiRecoveryCoordinator.listNewHandles,
        log: any BenchLog = SilentBenchLog()
    ) {
        self.engine = engine
        self.sleep = { duration in try await clock.sleep(for: duration) }
        self.tickSleep = { duration in try await tickClock.sleep(for: duration) }
        self.bluetoothSwitchOnWhenAway = bluetoothSwitchOnWhenAway
        plan = WiFiRecoveryPlan(recoveriesPerImport: recoveriesPerImport)
        self.listing = listing
        self.log = log
    }

    /// `list(reusing:)` on a link that has it, else the whole card.
    public nonisolated static func listNewHandles(_ link: any CameraLink, known: [CameraItem])
        async throws(CameraLinkFailure) -> [CameraItem] {
        if let reusing = link as? any ReusingListing { return try await reusing.list(reusing: known) }
        return try await link.list()
    }

    /// A recovery is under way or waiting for the person.
    public var isRecovering: Bool { plan.isRecovering }

    /// The person asks to try again (W16's button): runs the recovery from the front when it gave up or waits for a join,
    /// or when the job is left paused for its camera, its card or a join with no recovery under way (a new `session`, or
    /// a step's error, forgets the recovery but leaves the job paused).
    public func tryAgain() {
        if plan.phase == .idle, session != nil, host?.recoveryCarrier == .wifi,
           lastState == .paused(.cameraUnreachable) || lastState == .paused(.cardUnavailable)
            || lastState == .paused(.needsJoin) {
            reset()
            feed(.sessionLost)
            return
        }
        personReturned()
    }

    // MARK: - From the Import model

    /// The job's state, as the model read it last.
    func jobChanged(_ state: ImportJobState) {
        lastState = state
        guard state.isActive, session != nil, let host, host.recoveryCarrier == .wifi else {
            // The job ended, or this isn't a Wi-Fi job with a session: nothing to recover, and nothing carried over.
            if plan.isRecovering || job != nil { reset() }
            return
        }
        // The state shows the pause that comes first (`PauseReason.precedence`): an expiry, the app's leaving or a needed
        // join hide a lost card or session, and the person's pause or a stall show the card is back.
        switch (plan.phase, state) {
        case (.idle, .paused(.cardUnavailable)): feed(.cardRemoved)
        case (.idle, .paused(.cameraUnreachable)), (.waitingForCard, .paused(.cameraUnreachable)): feed(.sessionLost)
        case (.waitingForCard, .running), (.waitingForCard, .paused(.byPerson)), (.waitingForCard, .paused(.stalled)):
            feed(.cardBack)
        case (.waitingForCard, .paused(.taskExpired)):
            // iOS ended the continued task: no reopen without it; Continue carries the job on (W13).
            log.note("wifi recovery: the continued task ended while waiting for the card; waiting for Continue")
            reset()
        case (.pausedForJoin, _), (.gaveUp, _):
            checkStillTheJob()
        default: break
        }
    }

    /// The app is in front again: a recovery waiting for the person runs now.
    func appBecameActive() {
        personReturned()
    }

    private func personReturned() {
        guard session != nil, plan.phase == .pausedForJoin || plan.phase == .gaveUp else { return }
        feed(.personReturned)
    }

    // MARK: - Steps

    private func feed(_ input: RecoveryInput, link: (any CameraLink)? = nil) {
        guard let host else { return }
        let foreground = !host.isAppAway
        let step = plan.next(after: input, foreground: foreground, bluetoothAllowed: bluetoothSwitchOnWhenAway)
        if step != .noChange { log.note("wifi recovery: \(input) → \(step)") }
        // A pause for a join after a reopen began when that reopen did; any other began now.
        let beganAway = input == .needsJoin || input == .reopenFailed ? reopenBeganAway : !foreground
        perform(step, link: link, beganAway: beganAway)
    }

    private func perform(_ step: RecoveryStep, link: (any CameraLink)?, beganAway: Bool) {
        switch step {
        case .noChange:
            return
        case .done:
            _ = begin()
        case .giveUp:
            _ = begin()
            log.note("wifi recovery: gave up; waiting for the person")
        case .waitForCard:
            let mine = begin()
            let sleep = self.sleep
            tickWhileWaiting()
            let engine = self.engine
            cardWait = Task { [weak self] in
                guard await self?.claimJob(mine) == true else { return }
                do { try await sleep(WiFiRecoveryTiming.waitForStoreAdded) } catch { return }
                if await engine.isPaused(for: .taskExpired) {
                    // An expiry the state hid (behind a removal): no reopen without the continued task.
                    guard let self, mine == self.token else { return }
                    self.log.note("wifi recovery: the continued task ended while waiting for the card; waiting for Continue")
                    self.reset()
                    return
                }
                self?.stepEnded(mine, .cardWaitEnded)
            }
        case .reopen(let switchOn):
            guard let session, let host else { return reset() }
            let mine = begin()
            reopenBeganAway = host.isAppAway
            tickWhileWaiting()
            Task { [weak self] in
                guard await self?.claimJob(mine) == true else { return }
                let result: Result<any CameraLink, WirelessFailure>
                do throws(WirelessFailure) {
                    result = .success(try await session.prepareImport(bluetoothSwitchOnWhenAway: switchOn))
                } catch {
                    result = .failure(error)
                }
                await self?.reopenEnded(mine, result, session: session)
            }
        case .relist:
            guard let link else { return reset() }
            let mine = begin()
            Task { [weak self] in await self?.carryOn(through: link, token: mine) }
        case .pauseNeedsJoin:
            let mine = begin()
            Task { [weak self] in await self?.pauseForJoin(mine, beganAway: beganAway) }
        }
    }

    private func begin() -> Int {
        token += 1
        cardWait?.cancel()
        cardWait = nil
        ticker?.cancel()
        ticker = nil
        return token
    }

    /// Moves the continued task's progress every `tickEvery` while the recovery waits for the card or the reopen; the next
    /// step (`begin()`) or a reset stops it.
    private func tickWhileWaiting() {
        let tickSleep = self.tickSleep
        ticker = Task { [weak self] in
            while true {
                do { try await tickSleep(Self.tickEvery) } catch { return }
                guard let self, self.plan.phase == .waitingForCard || self.plan.phase == .reopening else { return }
                self.host?.recoveryWaitTick()
            }
        }
    }

    /// Records the job this recovery is for, at its first step; false when another job has the engine now, which is then
    /// taken up from its own state.
    private func claimJob(_ mine: Int) async -> Bool {
        let current = await engine.currentJobID
        guard mine == token, let current else { return false }
        if job == nil { job = current }
        guard job == current else {
            reset()
            jobChanged(await engine.state)
            return false
        }
        return true
    }

    /// While the recovery waits for the person, the job it waits on may have ended unseen (no refresh read its end) and
    /// another begun: forget it then, and take up the new job from its state.
    private func checkStillTheJob() {
        guard let expected = job, !checkingJob else { return }
        checkingJob = true
        let engine = self.engine
        Task { [weak self] in
            let current = await engine.currentJobID
            let state = await engine.state
            guard let self else { return }
            self.checkingJob = false
            guard self.job == expected, current != expected else { return }
            self.reset()
            self.jobChanged(state)
        }
    }

    private func stepEnded(_ mine: Int, _ input: RecoveryInput) {
        guard mine == token else { return }
        feed(input)
    }

    private func reopenEnded(_ mine: Int, _ result: Result<any CameraLink, WirelessFailure>,
                             session: any WiFiRecoverySession) async {
        guard mine == token else {
            // The job ended meanwhile: the session opened for it goes into its stay, or leaves.
            if case .success = result { await session.importFinished() }
            return
        }
        switch result {
        case .success(let link):
            feed(.reopened, link: link)
        case .failure(.paused(.needsJoin)):
            feed(.needsJoin)
        case .failure(let failure):
            log.note("wifi recovery: reopen failed: \(failure)")
            feed(.reopenFailed)
        }
    }

    /// Lists only the new handles on the new session and carries the job on through it.
    private func carryOn(through link: any CameraLink, token mine: Int) async {
        guard let job, let host else { return }
        let items: [CameraItem]
        do throws(CameraLinkFailure) {
            items = try await listing(link, host.recoveryKnownItems)
        } catch {
            guard mine == token else { return }
            log.note("wifi recovery: listing failed: \(error)")
            feed(.relistFailed)
            return
        }
        guard mine == token else { return }
        // Photos access is read again before the import continues (backlog section 5).
        let route = await host.recoveryRoute()
        guard mine == token else { return }
        // iOS ended the continued task meanwhile (seen whichever pause the state shows: a needed join hides it):
        // carrying on now would run with no task. The job takes the link but keeps the expiry, so it shows it and
        // Continue carries it on (W13).
        let expired = await engine.isPaused(for: .taskExpired)
        guard mine == token else { return }
        do throws(ImportEngineError) {
            do throws(ImportEngineError) {
                try await engine.reconnect(job, to: link, knownItems: items, route: route, keepingExpiry: expired)
            } catch .cameraNotRemoved {
                // The job went on by itself (StoreAdded on the old session came after the reopen had closed it), so
                // it is on a closed session: move it to the new one.
                guard mine == token else { return }
                try? await engine.pause(.cameraUnreachable)
                try await engine.reconnect(job, to: link, knownItems: items, route: route, keepingExpiry: expired)
            }
        } catch {
            if mine == token {
                reset()
                jobChanged(await engine.state)
            }
            return
        }
        guard mine == token else { return }
        if expired { log.note("wifi recovery: the continued task ended; the job waits for Continue on the new session") }
        // The phase goes back to idle first, so the refresh below can start another recovery if the new session has
        // gone already.
        stepEnded(mine, .relisted)
        await host.recoveryCarriesOn(through: link)
    }

    /// Pauses the job for a join and posts the pause notification while the app is away. In front already: when the step
    /// that led here began with the app away, the person came back meanwhile and the recovery joins now, from the front;
    /// otherwise the session can't join even in front, and the recovery waits for the person (`tryAgain()`), rather than
    /// ask again at once and get the same answer.
    private func pauseForJoin(_ mine: Int, beganAway: Bool) async {
        try? await engine.pause(.needsJoin)
        guard mine == token, let host else { return }
        await host.refresh()
        guard mine == token else { return }
        if host.isAppAway {
            if !host.isPausedByPerson { await host.notifyPausedWhileAway() }
        } else if beganAway {
            feed(.personReturned)
        } else {
            feed(.joinRefusedInFront)
        }
    }

    /// Forgets the recovery: the job ended, or another began.
    private func reset() {
        token += 1
        cardWait?.cancel()
        cardWait = nil
        ticker?.cancel()
        ticker = nil
        job = nil
        reopenBeganAway = false
        plan.reset()
    }
}
