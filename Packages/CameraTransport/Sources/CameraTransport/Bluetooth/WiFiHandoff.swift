// The hand-off: switch the camera's Wi-Fi on over Bluetooth and read its network name and password, in the order the spike
// proved (docs/iteration-3-4-backlog.md section 7; spike `doSwitchWiFiOn` and `doReadCredentials`).

import BLEKit
import Foundation

/// A point on an injected clock, readable later as "how long ago". The clock's own instant type stays inside, so a result can
/// carry it whatever clock the sequencer ran on.
public struct ClockMark: Sendable {
    private let measure: @Sendable () -> Duration

    init<C: Clock<Duration>>(_ clock: C, at instant: C.Instant) {
        measure = { instant.duration(to: clock.now) }
    }

    /// Time since the mark, on the clock it was made with.
    public var elapsed: Duration { measure() }
}

/// The step a failure happened in, for the log.
public enum HandoffStep: Sendable, Equatable {
    case subscribe
    case readStatus
    case writeWiFiOn
    case pollStatus
    case readCredentials
}

/// Why the hand-off ended without credentials. None of the cases carries a network name or password.
public enum HandoffFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// A call failed for a reason the hand-off can't act on (`GATTFailure` says which).
    case gatt(GATTFailure, during: HandoffStep)
    /// The camera refused because the phone isn't paired with it: send the person to the camera's Pairing screen.
    case notPaired
    /// The link went away. `afterWrite` is true when CC08 had been written, or the write's outcome is unknown, so the camera
    /// may well be switching its Wi-Fi on: reconnect, read CC09 and don't write again unless the status says 0 (a drop after
    /// the write is an outcome, not an error: spike `doSwitchWiFiOn`).
    case linkDropped(afterWrite: Bool)
    /// The task was cancelled.
    case cancelled
    /// CC09 gave no usable status: the bytes didn't decode, or tag 0x0001 wasn't in them.
    case statusUnreadable
    /// CC09's Wi-Fi status is a value outside 0 to 3 (never seen, so the sequencer doesn't guess what to do).
    case unexpectedStatus(UInt8)
    /// After the write, the status left its earlier value and fell back to it without reaching 2 (0 → 1 → 0, what the
    /// camera did without the five notifications, 3 Nov).
    case wifiDidNotStart(lastStatus: WiFiStatus?)
    /// Status 2 didn't come in `HandoffTiming.statusTwo`.
    case timedOut(lastStatus: WiFiStatus?)
    /// The status left 2 (the camera's 50 s elapsed with nobody joined, or it dropped its Wi-Fi) before the details were
    /// read. `rewriteIfLapsed` writes again.
    case wifiLapsed(lastStatus: WiFiStatus?)
    /// CC06 and CC07 read, but not as a network name and a password. Lengths only.
    case credentialsInvalid(SonyNetworkDetailsError)

    public var description: String {
        switch self {
        case .gatt(let failure, let step): "\(failure) while \(step)"
        case .notPaired: "not paired"
        case .linkDropped(let afterWrite): "link dropped" + (afterWrite ? " after the Wi-Fi write" : "")
        case .cancelled: "cancelled"
        case .statusUnreadable: "camera status unreadable"
        case .unexpectedStatus(let value): "unexpected Wi-Fi status \(SonyMasking.maskedByte(value))"
        case .wifiDidNotStart(let status): "Wi-Fi did not start (last status \(status.map { "\($0)" } ?? "unknown"))"
        case .timedOut(let status): "timed out waiting for Wi-Fi (last status \(status.map { "\($0)" } ?? "unknown"))"
        case .wifiLapsed(let status): "Wi-Fi lapsed (last status \(status.map { "\($0)" } ?? "unknown"))"
        case .credentialsInvalid(let error): "network details invalid: \(error)"
        }
    }
}

public struct HandoffResult: Sendable {
    /// The camera's network, to join at once and to forget. Redacts itself when printed.
    public let credentials: SonyWiFiCredentials
    /// When status 2 was first seen. The camera's 50 s count (`HandoffTiming.cameraWiFiWindow`) runs from status 2, so
    /// this starts the join's clock.
    public let statusTwoAt: ClockMark
    /// The status was already 2 when the sequencer first looked (the camera's Wi-Fi was on already, perhaps for a while, or
    /// held up by a joined phone), so the 50 s count may have started before `statusTwoAt`.
    public let launchedBeforeLooking: Bool
    /// This run wrote CC08.
    public let wroteWiFiOn: Bool
    /// Notification switches that weren't confirmed (`NotificationSwitches.turnOn`). Empty in every measured run.
    public let unconfirmedSwitches: [CameraControlCharacteristic]

    /// What is left of the camera's 50 s from `statusTwoAt`, zero at the least. An upper bound when `launchedBeforeLooking`.
    public var windowRemaining: Duration {
        max(.zero, HandoffTiming.cameraWiFiWindow - statusTwoAt.elapsed)
    }
}

/// Switches the camera's Wi-Fi on over Bluetooth and reads the network's details.
public struct WiFiHandoff: Sendable {
    private let clock: any Clock<Duration>
    private let trace: TransportTrace

    /// - Parameter trace: gets each change of CC09's Wi-Fi status, the CC08 write and the details' read, with times since
    ///   the run began (W20). Recording changes nothing the sequencer does.
    public init(clock: any Clock<Duration> = ContinuousClock(), trace: TransportTrace = .none) {
        self.clock = clock
        self.trace = trace
    }

    /// The whole hand-off on a connected, paired link:
    ///
    /// 1. Subscribe CC09, CC10, CC0F, CC03 and CC0E, in that order, each confirmed (without them the camera starts its Wi-Fi
    ///    and gives up: 0 → 1 → 0).
    /// 2. Wait `HandoffTiming.afterSubscribe` for the first notifications, then read CC09 and merge it into the status.
    /// 3. Branch on the Wi-Fi status. 2: go on. 0: empty the queue of notifications that came before (a status that is no
    ///    longer 0 goes back to this step), write CC08 = 0x01, then wait for status 2 from the notifications that come from
    ///    the write on (read CC09 once a second only when none has come 3 s after the acknowledgement; give up 3 s after
    ///    the status falls back to its value from before the write). 1: wait. 3: wait for 0, then write.
    /// 4. Read CC06 and CC07, only after status 2, retrying every 2 s for up to 20 s (and at least three tries) while the
    ///    status stays 2.
    ///
    /// Writes CC08 at most once. Nothing here logs a value: the credentials print as lengths.
    public func run(on link: any GATTLink) async throws(HandoffFailure) -> HandoffResult {
        try await performHandoff(clock: clock, link: link, subscribe: true, trace: trace)
    }

    /// The status fell to 3 or 0 during the join (the camera's 50 s elapsed, or it dropped its Wi-Fi): look again and, when
    /// the Wi-Fi is off, write CC08 = 0x01 again and read the details afresh (backlog section 8, decision 3).
    ///
    /// For the link `run(on:)` already subscribed on. After a reconnect, call `run(on:)` instead: a new link has no
    /// subscriptions. Whether a second write while the status is 2 restarts the camera's count is untested (one run hints
    /// that it does), so a status that still reads 2 is not written to. What a write during status 3 does is unknown
    /// (`unverified`), so the sequencer waits for 0 first.
    public func rewriteIfLapsed(on link: any GATTLink) async throws(HandoffFailure) -> HandoffResult {
        try await performHandoff(clock: clock, link: link, subscribe: false, trace: trace)
    }

    /// Turns Sony's five notifications off, best effort, before the link is closed (the spike's release path).
    public func release(_ link: any GATTLink) async -> ReleaseReport {
        await NotificationSwitches.turnOff(link)
    }
}

// MARK: - The sequencer

/// The sequencer on a concrete clock; `performHandoff` (ClockOpening.swift) opens the public type's `any Clock` into it.
func performHandoffOnConcrete<C: Clock<Duration>>(
    clock: C, link: any GATTLink, subscribe: Bool, trace: TransportTrace
) async throws(HandoffFailure) -> HandoffResult {
    try await HandoffRunner<C>.run(clock: clock, link: link, subscribe: subscribe, trace: trace)
}

/// One hand-off on one link. Confined to the task that calls `run`.
private final class HandoffRunner<C: Clock<Duration>> {
    private let link: any GATTLink
    private let clock: C
    private let events: HandoffEvents<C>
    private var status = SonyStatus()
    private var wroteWiFiOn = false
    private var launchedAt: C.Instant?
    private var launchedBeforeLooking = false
    /// For the trace only: when the run began, and the last Wi-Fi status it recorded.
    private let trace: TransportTrace
    private let startedAt: C.Instant
    private var tracedStatus: UInt8??

    private init(clock: C, link: any GATTLink, trace: TransportTrace) {
        self.clock = clock
        self.link = link
        self.trace = trace
        startedAt = clock.now
        events = HandoffEvents(clock: clock)
    }

    static func run(
        clock: C, link: any GATTLink, subscribe: Bool, trace: TransportTrace
    ) async throws(HandoffFailure) -> HandoffResult {
        let runner = HandoffRunner(clock: clock, link: link, trace: trace)
        let pumps = LinkPumps(link: link, into: runner.events)
        defer { pumps.stop() }
        return try await runner.execute(subscribe: subscribe)
    }

    private func execute(subscribe: Bool) async throws(HandoffFailure) -> HandoffResult {
        var unconfirmed: [CameraControlCharacteristic] = []
        if subscribe {
            do throws(GATTFailure) { unconfirmed = try await NotificationSwitches.turnOn(link) }
            catch { throw failure(error, during: .subscribe) }
            try await pauseAfterSubscribe()
        }
        try await readBaseline()
        guard let first = status.wifiStatus else { throw HandoffFailure.statusUnreadable }
        if case .unknown(let value) = first { throw HandoffFailure.unexpectedStatus(value) }
        noteIfLaunched()
        launchedBeforeLooking = launchedAt != nil

        settling: while true {
            // A status in between settles first: 1 resolves to 2 (or falls back to 0), 3 to 0 (or, unseen, back to 2).
            switch status.wifiStatus {
            case .launching:
                try await waitForStatus([.launched, .terminated], silentFrom: clock.now, fellBackFrom: nil)
            case .terminating:
                try await waitForStatus([.terminated, .launched], silentFrom: clock.now, fellBackFrom: nil)
            default:
                break
            }
            guard status.wifiStatus == .terminated else { break settling }

            // The spike emptied its CC09 queue just before the write, so only notifications from the write on count towards
            // "no notification came" and none from the subscriptions or the baseline read is mistaken for one. Anything
            // queued is still merged, in arrival order, because a status that is no longer 0 means the write isn't due.
            while let queued = events.takeQueued() { _ = try absorb(queued) }
            if case .unknown(let value)? = status.wifiStatus { throw HandoffFailure.unexpectedStatus(value) }
            noteIfLaunched()
            guard status.wifiStatus == .terminated else { continue settling }

            let before = WiFiStatus.terminated
            wroteWiFiOn = true // set first: a drop during the write counts as a drop after it
            do throws(GATTFailure) { try await link.write(.wifiOn, timeout: HandoffTiming.wifiOnAck) }
            catch { throw failure(error, during: .writeWiFiOn) }
            trace(.handoffWroteWiFiOn(after: elapsed))
            try await waitForStatus([.launched], silentFrom: clock.now, fellBackFrom: before)
            break settling
        }
        guard let launchedAt else { throw HandoffFailure.wifiLapsed(lastStatus: status.wifiStatus) }

        let credentials = try await readCredentials()
        return HandoffResult(
            credentials: credentials,
            statusTwoAt: ClockMark(clock, at: launchedAt),
            launchedBeforeLooking: launchedBeforeLooking,
            wroteWiFiOn: wroteWiFiOn,
            unconfirmedSwitches: unconfirmed
        )
    }

    // MARK: Status

    /// The spike's pause after the switches ("collecting the first notifications", `doSubscribe`), spent on the event queue so
    /// what the camera sends meanwhile is merged and a drop ends it. Every proven run had it.
    private func pauseAfterSubscribe() async throws(HandoffFailure) {
        events.cancelAllTimers()
        events.set(.afterSubscribe, at: clock.now.advanced(by: HandoffTiming.afterSubscribe))
        defer { events.cancelAllTimers() }
        while true {
            guard let event = await events.next() else { throw HandoffFailure.cancelled }
            if try absorb(event) == .afterSubscribe { return }
        }
    }

    private func readBaseline() async throws(HandoffFailure) {
        let value: Data
        do throws(GATTFailure) { value = try await link.read(.status, timeout: HandoffTiming.statusRead) }
        catch { throw failure(error, during: .readStatus) }
        let decoded = (try? status.merge(value)) != nil
        traceStatus()
        guard decoded else { throw HandoffFailure.statusUnreadable }
    }

    /// Time since the run began, for the trace.
    private var elapsed: Duration { startedAt.duration(to: clock.now) }

    /// Records the Wi-Fi status when it differs from the last one recorded (the first reading included). Reads only.
    private func traceStatus() {
        guard trace.isOn else { return }
        let current = status.wifiStatus?.rawValue
        if let traced = tracedStatus, traced == current { return }
        tracedStatus = .some(current)
        trace(.handoffStatus(current, after: elapsed))
    }

    /// Records when status 2 was first seen.
    private func noteIfLaunched() {
        if launchedAt == nil, status.wifiStatus == .launched { launchedAt = clock.now }
    }

    /// Waits until the Wi-Fi status is one of `accept`.
    ///
    /// - Parameters:
    ///   - silentFrom: when the 3 s of silence is counted from (the write's acknowledgement, or the start of the wait).
    ///   - fellBackFrom: the status from before our write, or nil when we haven't written. With it, the wait ends
    ///     `fallbackGrace` after the status has left that value and come back to it.
    private func waitForStatus(
        _ accept: Set<WiFiStatus>, silentFrom: C.Instant, fellBackFrom: WiFiStatus?
    ) async throws(HandoffFailure) {
        events.cancelAllTimers()
        events.set(.overall, at: clock.now.advanced(by: HandoffTiming.statusTwo))
        events.set(.silence, at: silentFrom.advanced(by: HandoffTiming.pollIfSilentAfter))
        defer { events.cancelAllTimers() }
        var sawStatusNotification = false
        var polling = false
        var leftEarlierValue = false

        while true {
            noteIfLaunched()
            if let current = status.wifiStatus, accept.contains(current) { return }
            if let earlier = fellBackFrom, let current = status.wifiStatus {
                if current != earlier {
                    leftEarlierValue = true
                    events.cancel(.grace)
                } else if leftEarlierValue {
                    events.setIfAbsent(.grace, at: clock.now.advanced(by: HandoffTiming.fallbackGrace))
                }
            }
            guard let event = await events.next() else { throw HandoffFailure.cancelled }
            switch event {
            case .notification(.status, let value):
                sawStatusNotification = true
                _ = try? status.merge(value) // a notification that doesn't decode says nothing; the next one will
                traceStatus()
            case .notification:
                break
            case .linkDropped:
                throw HandoffFailure.linkDropped(afterWrite: wroteWiFiOn)
            case .timer(.overall):
                throw HandoffFailure.timedOut(lastStatus: status.wifiStatus)
            case .timer(.grace):
                throw HandoffFailure.wifiDidNotStart(lastStatus: status.wifiStatus)
            case .timer(.silence):
                if !sawStatusNotification {
                    polling = true
                    try await pollStatus()
                    events.set(.pollTick, at: clock.now.advanced(by: HandoffTiming.pollEvery))
                }
            case .timer(.pollTick):
                if polling {
                    try await pollStatus()
                    events.set(.pollTick, at: clock.now.advanced(by: HandoffTiming.pollEvery))
                }
            case .timer(.credentialRetry), .timer(.afterSubscribe):
                break
            }
        }
    }

    /// One read of CC09 while no notification has come. A read that fails without ending the link is skipped: the next
    /// second tries again.
    private func pollStatus() async throws(HandoffFailure) {
        do throws(GATTFailure) {
            let value = try await link.read(.status, timeout: HandoffTiming.pollRead)
            _ = try? status.merge(value)
            traceStatus()
        } catch {
            switch error {
            case .timedOut, .other: break
            default: throw failure(error, during: .pollStatus)
            }
        }
    }

    // MARK: Network details

    private enum Attempt {
        case credentials(SonyWiFiCredentials)
        case gatt(GATTFailure)
        case invalid(SonyNetworkDetailsError)
    }

    /// Reads CC06 and CC07, retrying every `credentialRetry` for up to `credentialWindow` from the first try, and in any case
    /// until `credentialMinimumTries` have been made (reads that time out take 15 s each), while the status stays 2. The
    /// reads wait for status 2 because the camera refuses them with ATT 0x9D while its Wi-Fi is off.
    private func readCredentials() async throws(HandoffFailure) -> SonyWiFiCredentials {
        events.cancelAllTimers()
        defer { events.cancelAllTimers() }
        let windowEnd = clock.now.advanced(by: HandoffTiming.credentialWindow)
        var attempts = 0
        while true {
            while let queued = events.takeQueued() { _ = try absorb(queued) }
            if status.wifiStatus != .launched { throw HandoffFailure.wifiLapsed(lastStatus: status.wifiStatus) }

            let problem: HandoffFailure
            attempts += 1
            switch await attemptCredentials() {
            case .credentials(let credentials):
                trace(.handoffDetailsRead(after: elapsed, tries: attempts))
                return credentials
            case .gatt(let error):
                switch error {
                case .wifiOff, .timedOut, .other: problem = .gatt(error, during: .readCredentials)
                default: throw failure(error, during: .readCredentials)
                }
            case .invalid(let error):
                problem = .credentialsInvalid(error)
            }

            let retryAt = clock.now.advanced(by: HandoffTiming.credentialRetry)
            if attempts >= HandoffTiming.credentialMinimumTries && retryAt > windowEnd { throw problem }
            events.set(.credentialRetry, at: retryAt)
            waiting: while true {
                guard let event = await events.next() else { throw HandoffFailure.cancelled }
                if try absorb(event) == .credentialRetry { break waiting }
                if status.wifiStatus != .launched { throw HandoffFailure.wifiLapsed(lastStatus: status.wifiStatus) }
            }
        }
    }

    private func attemptCredentials() async -> Attempt {
        do throws(GATTFailure) {
            let ssid = try await link.read(.ssid, timeout: HandoffTiming.credentialRead)
            let passphrase = try await link.read(.passphrase, timeout: HandoffTiming.credentialRead)
            do {
                return .credentials(try SonyWiFiCredentials.decode(ssidValue: ssid, passphraseValue: passphrase))
            } catch let error as SonyNetworkDetailsError {
                return .invalid(error)
            } catch {
                return .invalid(.noText(.ssid, byteCount: 0)) // decode throws only SonyNetworkDetailsError
            }
        } catch {
            return .gatt(error)
        }
    }

    /// Takes one event into the status. Returns the timer when it was one; a dropped link throws.
    private func absorb(_ event: HandoffEvent) throws(HandoffFailure) -> HandoffTimer? {
        switch event {
        case .notification(.status, let value):
            _ = try? status.merge(value)
            traceStatus()
            return nil
        case .notification:
            return nil
        case .linkDropped:
            throw HandoffFailure.linkDropped(afterWrite: wroteWiFiOn)
        case .timer(let timer):
            return timer
        }
    }

    // MARK: Failures

    private func failure(_ error: GATTFailure, during step: HandoffStep) -> HandoffFailure {
        switch error {
        case .notPaired: .notPaired
        case .linkDropped: .linkDropped(afterWrite: wroteWiFiOn)
        case .cancelled: .cancelled
        default: .gatt(error, during: step)
        }
    }
}
