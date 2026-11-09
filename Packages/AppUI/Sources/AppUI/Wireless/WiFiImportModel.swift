import CameraTransport
import Foundation
import Observation

/// Whether the Local Network prompt has been explained, kept across launches, so the explanation comes once, before the
/// first connection (backlog Iteration 3, section 1: iOS's prompt appears at the first connection and the copy explains it
/// first).
public protocol LocalNetworkExplainedRecord: Sendable {
    var hasExplained: Bool { get }
    func recordExplained()
}

/// The record in memory: for tests and previews.
public final class InMemoryLocalNetworkExplainedRecord: LocalNetworkExplainedRecord, @unchecked Sendable {
    private let lock = NSLock()
    private var explained: Bool

    public init(hasExplained: Bool = false) { explained = hasExplained }

    public var hasExplained: Bool { lock.withLock { explained } }
    public func recordExplained() { lock.withLock { explained = true } }
}

/// The record in `UserDefaults`, one Boolean. Foundation only. (`UserDefaults` is thread-safe, hence `@unchecked
/// Sendable`.)
public final class UserDefaultsLocalNetworkExplainedRecord: LocalNetworkExplainedRecord, @unchecked Sendable {
    public static let key = "localNetworkExplained"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var hasExplained: Bool { defaults.bool(forKey: Self.key) }
    public func recordExplained() { defaults.set(true, forKey: Self.key) }
}

/// Every wait the Wi-Fi models have of their own, with what it rests on.
public enum WiFiImportTiming {
    /// How long iOS's Local Network prompt may be up before the line says it may never have shown (it shows once; after
    /// Don't Allow it doesn't come back, and the connection then waits until its own limit). `unverified`: a starting
    /// value. The probe that was held by the prompt succeeded 1.53 s after it began, with the prompt allowed within that
    /// time (backlog Iteration 3, section 1), so a person who is answering is done well before this.
    public static let localNetworkHintAfter: Duration = .seconds(15)
}

/// What the screens say about a Wi-Fi connection: the Local Network explanation and wait, the steps of the join, the
/// stay, the note about mobile data while joined, and the note that the camera's Wi-Fi may stay on after leaving (backlog
/// Iteration 3, sections 1 and 8; wireless plan W15). The Import screen, Browse and the Cameras screen show its lines
/// beside their own (`statusLine`, `notes`); the model never touches the import job itself.
///
/// **The camera in view.** It follows the camera whose connection was begun last (`WiFiConnectionEvent.connecting`);
/// events about another camera are ignored until that one is begun. The app has one job at a time, so this is the camera
/// the person is looking at.
///
/// **The Local Network explanation** is a gate before each connection (`beforeFirstConnection()`, which `WiFiCameraSource`
/// calls): the first time it sets `isExplainingLocalNetwork` and waits for *Continue* (`continueAfterExplaining()`, which
/// records it, so it never comes again) or *Not Now* (`declineExplaining()`, which cancels the connection). A cancelled
/// caller ends the wait. Once explained it returns at once.
///
/// **The wait for iOS's prompt** is `isWaitingForLocalNetwork`, set by the link's `.waitingForLocalNetwork` event and cleared when
/// the session moves on (it opened, failed or was left). After `WiFiImportTiming.localNetworkHintAfter` the line says the
/// prompt may not have shown. Waiting is never shown as a failure.
///
/// **Unknown is not zero:** nothing here shows a battery level or free space (Wi-Fi reads neither).
///
/// **A join held with the app away** (`WirelessPhase.awaitingFront`, bench 19.1): the line asks the person to come back,
/// and one local notification says the same (`AppNotification.joinWaiting`) through `notifier`, only if notifications are
/// already allowed (it never asks), withdrawn as soon as the session moves on.
///
/// Never logs or shows the camera's serial, its network's name or any address.
@MainActor
@Observable
public final class WiFiImportModel {
    /// The camera in view, once a connection has begun.
    public private(set) var camera: CameraDescriptor.ID?
    /// Where its session is.
    public private(set) var phase: WirelessPhase = .idle
    /// The Local Network explanation is up: the connection waits for Continue or Not Now.
    public private(set) var isExplainingLocalNetwork = false
    /// iOS's Local Network prompt is up (or never showed) and the connection waits for it.
    public private(set) var isWaitingForLocalNetwork = false
    /// The wait has gone on longer than `WiFiImportTiming.localNetworkHintAfter`.
    public private(set) var localNetworkWaitIsLong = false
    /// Why the last connection failed, with its next step; nil when none failed since the last began.
    public private(set) var failure: WirelessFailure?
    /// A leave has finished since the last connection began: the camera's Wi-Fi may stay on for a while.
    public private(set) var wifiMayStayOn = false
    /// When the stay ends, while the phone stays on the camera's network after an import (for a timer in the screen).
    public private(set) var stayEndsAt: Date?

    @ObservationIgnored private let source: any WiFiConnectionSource
    @ObservationIgnored private let record: any LocalNetworkExplainedRecord
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let log: any BenchLog
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var nextWaiter = 0
    /// Posts the held join's notification (the app's W13 notifier, set by `AppModel`); nil posts nothing.
    @ObservationIgnored public var notifier: (any LocalNotifier)?
    /// Whether the held join's notification is wanted now, whether it was posted, and the post and withdrawal in turn.
    @ObservationIgnored private var joinNotificationWanted = false
    @ObservationIgnored private var joinNotificationPosted = false
    @ObservationIgnored private var joinNotificationTask: Task<Void, Never>?

    public init(source: any WiFiConnectionSource,
                record: any LocalNetworkExplainedRecord = InMemoryLocalNetworkExplainedRecord(),
                clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() },
                log: any BenchLog = SilentBenchLog()) {
        self.source = source
        self.record = record
        self.clock = clock
        self.now = now
        self.log = log
    }

    // MARK: - What the screens show

    /// The line for the connection's step, most urgent first: the explanation (the screen shows its own copy), the wait for
    /// iOS's prompt, a failure, else the step the session is at. Nil when there is nothing to say.
    public var statusLine: String? {
        if isExplainingLocalNetwork { return nil }
        if isWaitingForLocalNetwork {
            return localNetworkWaitIsLong ? WiFiWording.stillWaitingForLocalNetwork : WiFiWording.waitingForLocalNetwork
        }
        if let failure, !isConnecting { return WiFiWording.failure(failure) }
        return WiFiWording.step(phase)
    }

    /// The camera is being reached: Bluetooth, the join or the session.
    public var isConnecting: Bool {
        switch phase {
        case .handingOff, .joining, .awaitingFront, .openingSession: true
        case .idle, .ready, .staying, .leaving, .paused: false
        }
    }

    /// The phone is on the camera's network, so its internet goes over mobile data (backlog section 8).
    public var isJoined: Bool {
        switch phase {
        case .joining, .openingSession, .ready, .staying: true
        case .idle, .handingOff, .awaitingFront, .leaving, .paused: false
        }
    }

    /// The notes under the status: mobile data while joined, and the camera's Wi-Fi that may stay on after leaving.
    public var notes: [String] {
        var lines: [String] = []
        if isJoined { lines.append(WiFiWording.mobileDataNote) }
        if wifiMayStayOn, !isJoined, !isConnecting { lines.append(WiFiWording.wifiMayStayOn) }
        return lines
    }

    /// What the person has to do before the connection can go on, if anything (`WirelessPause`).
    public var pause: WirelessPause? {
        if case let .paused(pause) = phase { pause } else { nil }
    }

    // MARK: - Following the source

    /// Starts following the source's events, for the model's lifetime. Does nothing once started.
    public func start() {
        guard watchTask == nil else { return }
        let events = source.connectionEvents
        watchTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    /// Takes the notes off the screen (the person closed them).
    public func dismissNotes() {
        wifiMayStayOn = false
    }

    func apply(_ event: WiFiConnectionEvent) {
        switch event {
        case let .connecting(id):
            camera = id
            phase = .idle
            joinHeld(false)
            failure = nil
            wifiMayStayOn = false
            stayEndsAt = nil
            setWaitingForLocalNetwork(false)
        case let .phase(id, newPhase, remaining):
            guard camera == nil || camera == id else { return }
            camera = id
            let wasLeaving = phase == .leaving
            phase = newPhase
            joinHeld(newPhase == .awaitingFront)
            switch newPhase {
            case .idle:
                if wasLeaving { wifiMayStayOn = true }
                stayEndsAt = nil
                setWaitingForLocalNetwork(false)
            case .staying:
                stayEndsAt = remaining.map { now().addingTimeInterval($0.seconds) }
            case .handingOff:
                wifiMayStayOn = false
                stayEndsAt = nil
            case .openingSession:
                stayEndsAt = nil
            case .joining, .awaitingFront, .ready, .leaving, .paused:
                stayEndsAt = nil
                if newPhase != .joining { setWaitingForLocalNetwork(false) }
            }
        case let .failed(id, why):
            guard camera == nil || camera == id else { return }
            camera = id
            failure = why
            joinHeld(false)
            setWaitingForLocalNetwork(false)
        case let .link(id, linkEvent):
            guard camera == nil || camera == id else { return }
            switch linkEvent {
            case .waitingForLocalNetwork:
                setWaitingForLocalNetwork(true)
            case .sessionLost:
                setWaitingForLocalNetwork(false)
            case .removed, .willSuspend, .didSuspend, .cancelledSuspending, .resumedOperations, .storeRemoved,
                 .storeAdded:
                break
            }
        }
    }

    /// The session entered or left a join held while the app is away: the notification is posted (if allowed) or
    /// withdrawn, one after the other, so a withdrawal never overtakes its post.
    private func joinHeld(_ held: Bool) {
        guard held != joinNotificationWanted else { return }
        joinNotificationWanted = held
        guard let notifier else { return }
        let previous = joinNotificationTask
        let log = self.log
        joinNotificationTask = Task { [weak self] in
            await previous?.value
            if held {
                guard await notifier.authorisation().allowsPosting else {
                    log.note("wifi: the join is held with the app away; notifications aren't allowed")
                    return
                }
                await notifier.post(.joinWaiting)
                self?.joinNotificationPosted = true
                log.note("wifi: posted the join notification")
            } else {
                guard let self, self.joinNotificationPosted else { return }
                self.joinNotificationPosted = false
                await notifier.withdraw(.joinWaiting)
                log.note("wifi: withdrew the join notification")
            }
        }
    }

    /// Waits for the held join's notification to be posted or withdrawn (for tests).
    func joinNotificationSettled() async { await joinNotificationTask?.value }

    private func setWaitingForLocalNetwork(_ waiting: Bool) {
        guard waiting != isWaitingForLocalNetwork else { return }
        isWaitingForLocalNetwork = waiting
        hintTask?.cancel()
        hintTask = nil
        localNetworkWaitIsLong = false
        guard waiting else { return }
        let clock = self.clock
        hintTask = Task { [weak self] in
            do {
                try await clock.sleep(for: WiFiImportTiming.localNetworkHintAfter)
            } catch {
                return
            }
            self?.markWaitLong()
        }
    }

    private func markWaitLong() {
        guard isWaitingForLocalNetwork else { return }
        localNetworkWaitIsLong = true
        log.note("wifi: the Local Network prompt has been waited for a while")
    }

    // MARK: - The Local Network explanation

    /// Before a connection: true to go on. The first time (nothing recorded) it puts the explanation up and waits for the
    /// person; false when they decline or the caller is cancelled. Afterwards it returns true at once.
    public func beforeFirstConnection() async -> Bool {
        guard !record.hasExplained else { return true }
        if Task.isCancelled { return false }
        let id = nextWaiter
        nextWaiter += 1
        isExplainingLocalNetwork = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.resolve(id, with: false) }
        }
    }

    /// *Continue*: records the explanation and lets every waiting connection go on.
    public func continueAfterExplaining() {
        guard isExplainingLocalNetwork else { return }
        record.recordExplained()
        resolveAll(with: true)
    }

    /// *Not Now*: the waiting connections are cancelled, and the explanation comes again at the next one.
    public func declineExplaining() {
        resolveAll(with: false)
    }

    private func resolve(_ id: Int, with result: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: result)
        if waiters.isEmpty { isExplainingLocalNetwork = false }
    }

    private func resolveAll(with result: Bool) {
        let waiting = waiters
        waiters = [:]
        isExplainingLocalNetwork = false
        for continuation in waiting.values { continuation.resume(returning: result) }
    }
}

extension Duration {
    /// The duration in seconds, for a date a screen counts to.
    fileprivate var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
