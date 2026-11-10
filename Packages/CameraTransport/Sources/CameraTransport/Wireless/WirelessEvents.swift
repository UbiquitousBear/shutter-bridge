// The session's clock and its one waiting place: the stay's timers and the Bluetooth link's drops arrive as events in one
// queue, so the stay is plain sequential code decided by the order of events, as the hand-off is (`HandoffEvents`).

import Synchronization

/// An injected `any Clock<Duration>` opened once into closures, with time as the duration since the session was made. The
/// session's timers are then plain `Duration`s, whatever clock a test or the app passed in.
struct SessionClock: Sendable {
    private let elapsed: @Sendable () -> Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    /// Opens the clock from a parameter, which Swift 6.4.2 on Linux does (see ClockOpening.swift for why never from a stored
    /// property).
    init(_ clock: any Clock<Duration>) {
        func open<C: Clock<Duration>>(_ clock: C) -> SessionClock {
            let origin = clock.now
            return SessionClock(
                elapsed: { origin.duration(to: clock.now) },
                sleeper: { offset in try await clock.sleep(until: origin.advanced(by: offset), tolerance: nil) }
            )
        }
        self = open(clock)
    }

    private init(elapsed: @escaping @Sendable () -> Duration, sleeper: @escaping @Sendable (Duration) async throws -> Void) {
        self.elapsed = elapsed
        self.sleeper = sleeper
    }

    /// Time since the session was made.
    func now() -> Duration { elapsed() }

    /// Sleeps until `offset` since the session was made; returns at once when that has passed. Throws when the task is
    /// cancelled.
    func sleep(until offset: Duration) async throws { try await sleeper(offset) }
}

/// What the stay's loop wakes for.
enum StayTimer: Hashable, Sendable {
    /// The stay is over (`WirelessTiming.stay` from the end of the import).
    case stayEnds
    /// The Bluetooth link has been down `WirelessTiming.linkDownStayLimit`.
    case linkDownLimit
    /// The next try to reconnect the Bluetooth link.
    case reconnect

    /// Which of two timers due at the same instant goes first: the ones that end the stay, so a reconnect never starts at
    /// the limit.
    var priority: Int {
        switch self {
        case .linkDownLimit: 0
        case .stayEnds: 1
        case .reconnect: 2
        }
    }
}

enum StayEvent: Sendable {
    /// The Bluetooth link with this number dropped. Numbers tell an old link's late drop from the current one's.
    case linkDropped(linkNumber: Int)
}

enum StayWake: Sendable {
    case event(StayEvent)
    case timer(StayTimer)
}

/// Events plus named timers on the session's clock, consumed by one task.
///
/// `next()` returns, in this order: a queued event, else a timer that is due (earliest first, ties by priority), else it
/// waits. While it waits it holds exactly one sleeper on the clock, for the earliest timer, and none when no timer is set.
/// Timers are values, not tasks: setting one never touches the clock, so a test clock sees one sleeper at a time.
///
/// One task calls `next()` and the timer methods; `push` is safe from any task.
final class StayEvents: Sendable {
    private struct State {
        var events: [StayEvent] = []
        var timers: [StayTimer: Duration] = [:]
        var waiter: CheckedContinuation<Void, Never>?
        var parkID = 0
        var wakeRequested = false
        var cancelled = false
    }

    let clock: SessionClock
    private let state = Mutex(State())

    init(clock: SessionClock) { self.clock = clock }

    func push(_ event: StayEvent) {
        state.withLock { $0.events.append(event) }
        wake(parkID: nil, remember: false)
    }

    func set(_ timer: StayTimer, at offset: Duration) {
        state.withLock { $0.timers[timer] = offset }
    }

    /// Sets the timer unless it is already running. Returns whether it set it.
    @discardableResult
    func setIfAbsent(_ timer: StayTimer, at offset: Duration) -> Bool {
        state.withLock { s -> Bool in
            guard s.timers[timer] == nil else { return false }
            s.timers[timer] = offset
            return true
        }
    }

    func cancel(_ timer: StayTimer) {
        state.withLock { _ = $0.timers.removeValue(forKey: timer) }
    }

    /// The next event or due timer. Nil once the consuming task is cancelled.
    func next() async -> StayWake? {
        while true {
            if state.withLock({ $0.cancelled }) || Task.isCancelled { return nil }
            if let event = state.withLock({ $0.events.isEmpty ? nil : $0.events.removeFirst() }) { return .event(event) }
            let now = clock.now()
            let earliest: (timer: StayTimer, at: Duration)? = state.withLock { s in
                s.timers.min { ($0.value, $0.key.priority) < ($1.value, $1.key.priority) }.map { ($0.key, $0.value) }
            }
            if let earliest, earliest.at <= now {
                cancel(earliest.timer)
                return .timer(earliest.timer)
            }
            await park(until: earliest?.at)
        }
    }

    private func park(until offset: Duration?) async {
        let id = state.withLock { s -> Int in
            s.parkID += 1
            return s.parkID
        }
        let clock = self.clock
        let sleeper: Task<Void, Never>? = offset.map { offset in
            Task { [self] in
                do { try await clock.sleep(until: offset) } catch { return }
                wake(parkID: id, remember: true)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if !s.events.isEmpty || s.cancelled || s.wakeRequested {
                        s.wakeRequested = false
                        return true
                    }
                    s.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.cancelled = true }
            wake(parkID: nil, remember: false)
        }
        sleeper?.cancel()
        // Whatever the sleeper does from here on belongs to a park that is over.
        state.withLock { s in
            s.parkID += 1
            s.wakeRequested = false
            s.waiter = nil
        }
    }

    /// Wakes the parked consumer. A wake from a sleeper of an earlier park is ignored; a timer's wake that finds the consumer
    /// not yet suspended is remembered.
    private func wake(parkID: Int?, remember: Bool) {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
            if let parkID, parkID != s.parkID { return nil }
            guard let waiter = s.waiter else {
                if remember { s.wakeRequested = true }
                return nil
            }
            s.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

/// `WirelessSession.phases`: every stream starts with the current phase, then gets each change, in order. Sends come from the
/// session's actor; a stream may be taken from anywhere.
final class PhaseBroadcast: Sendable {
    private struct State {
        var current: WirelessPhase = .idle
        var nextKey: UInt64 = 0
        var sinks: [UInt64: AsyncStream<WirelessPhase>.Continuation] = [:]
    }

    private let state = Mutex(State())

    func stream() -> AsyncStream<WirelessPhase> {
        let (stream, continuation) = AsyncStream.makeStream(of: WirelessPhase.self, bufferingPolicy: .unbounded)
        let key = state.withLock { s -> UInt64 in
            let key = s.nextKey
            s.nextKey += 1
            s.sinks[key] = continuation
            // Under the lock, so a send can't slip in ahead of the current phase.
            continuation.yield(s.current)
            return key
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.sinks.removeValue(forKey: key) }
        }
        return stream
    }

    /// Sends a phase unless it is the current one.
    func send(_ phase: WirelessPhase) {
        state.withLock { s in
            guard s.current != phase else { return }
            s.current = phase
            for sink in s.sinks.values { sink.yield(phase) }
        }
    }
}

/// Wakes a join held while the app is away (`WirelessSession`'s hold): `appBecameActive()` opens it.
///
/// Opening counts up, and a wait names the count it saw before it decided to wait, so a return that lands between that
/// decision and the wait is not missed. A wait ends when the wake opens, when its deadline passes on the session's clock, or
/// when its task is cancelled (`leave()`), whichever comes first.
final class FrontWake: Sendable {
    enum Outcome: Sendable, Equatable {
        case woken
        case timedOut
        case cancelled
    }

    private enum Slot {
        case pending
        case waiting(CheckedContinuation<Bool, Never>)
        case cancelled
    }

    private struct State {
        var opened = 0
        var nextID = 0
        var slots: [Int: Slot] = [:]
    }

    private let state = Mutex(State())

    /// How many times the wake has opened; pass it to `wait`.
    var token: Int { state.withLock { $0.opened } }

    /// Ends every wait whose token is older.
    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Bool, Never>] in
            s.opened += 1
            var woken: [CheckedContinuation<Bool, Never>] = []
            for (id, slot) in s.slots {
                if case .waiting(let continuation) = slot {
                    woken.append(continuation)
                    s.slots.removeValue(forKey: id)
                }
            }
            return woken
        }
        for waiter in waiters { waiter.resume(returning: true) }
    }

    /// Waits until the wake opens after `token`, `deadline` passes on `clock`, or the task is cancelled.
    func wait(after token: Int, until deadline: Duration, on clock: SessionClock) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await self.wait(after: token) ? .woken : .cancelled }
            group.addTask {
                do { try await clock.sleep(until: deadline) } catch { return .cancelled }
                return .timedOut
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
    }

    /// True once the wake has opened after `token`; false when the task was cancelled first.
    private func wait(after token: Int) async -> Bool {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            s.slots[s.nextID] = .pending
            return s.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let now = state.withLock { s -> Bool? in
                    if s.opened > token {
                        s.slots.removeValue(forKey: id)
                        return true
                    }
                    if case .cancelled? = s.slots[id] {
                        s.slots.removeValue(forKey: id)
                        return false
                    }
                    s.slots[id] = .waiting(continuation)
                    return nil
                }
                if let now { continuation.resume(returning: now) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<Bool, Never>? in
                switch s.slots[id] {
                case .waiting(let continuation)?:
                    s.slots.removeValue(forKey: id)
                    return continuation
                case .pending?:
                    s.slots[id] = .cancelled
                    return nil
                case .cancelled?, nil:
                    return nil
                }
            }
            waiter?.resume(returning: false)
        }
    }
}
