// The one place the hand-off waits: notifications, a dropped link and timers arrive as events in one queue, so the
// sequencer is plain sequential code and every timeline is decided by the order of events, not by races.

import BLEKit
import Foundation
import Synchronization

enum HandoffTimer: Hashable, Sendable {
    /// The whole wait for a status ends (`HandoffTiming.statusTwo`).
    case overall
    /// No CC09 notification yet: start reading it (`HandoffTiming.pollIfSilentAfter`).
    case silence
    /// The next read of CC09 (`HandoffTiming.pollEvery`).
    case pollTick
    /// The camera gave up (`HandoffTiming.fallbackGrace`).
    case grace
    /// The next try at CC06 and CC07 (`HandoffTiming.credentialRetry`).
    case credentialRetry
    /// The pause after the switches ends (`HandoffTiming.afterSubscribe`).
    case afterSubscribe
}

extension HandoffTimer {
    /// Which of two timers due at the same instant goes first: the ones that end a wait, so a deadline is never overtaken
    /// by one more poll. Without a fixed order, ties would follow the dictionary's per-process hash order.
    var priority: Int {
        switch self {
        case .overall: 0
        case .grace: 1
        case .silence: 2
        case .pollTick: 3
        case .credentialRetry: 4
        case .afterSubscribe: 5
        }
    }
}

enum HandoffEvent: Sendable {
    case notification(CameraControlCharacteristic, Data)
    case linkDropped(GATTFailure)
    case timer(HandoffTimer)
}

/// Events from the link plus named timers on an injected clock, consumed by one task.
///
/// `next()` returns, in this order: a queued event (so notifications are drained before any timer, as the spike did), else a
/// timer that is due, else it waits. While it waits it holds exactly one sleeper on the clock, for the earliest timer, and
/// none when no timer is set. Timers are values, not tasks: setting one never touches the clock, so the order in which a
/// test clock sees sleepers is the order in which the sequencer parks.
///
/// One task calls `next()` and the timer methods; `push` is safe from any task.
final class HandoffEvents<C: Clock<Duration>>: Sendable {
    private struct State {
        var events: [HandoffEvent] = []
        var timers: [HandoffTimer: C.Instant] = [:]
        var waiter: CheckedContinuation<Void, Never>?
        var parkID = 0
        var wakeRequested = false
        var cancelled = false
    }

    let clock: C
    private let state = Mutex(State())

    init(clock: C) { self.clock = clock }

    // MARK: Producers

    func push(_ event: HandoffEvent) {
        state.withLock { $0.events.append(event) }
        wake(parkID: nil, remember: false)
    }

    // MARK: Timers (the consumer's task only)

    func set(_ timer: HandoffTimer, at instant: C.Instant) {
        state.withLock { $0.timers[timer] = instant }
    }

    /// Sets the timer unless it is already running.
    func setIfAbsent(_ timer: HandoffTimer, at instant: C.Instant) {
        state.withLock { if $0.timers[timer] == nil { $0.timers[timer] = instant } }
    }

    func cancel(_ timer: HandoffTimer) {
        state.withLock { _ = $0.timers.removeValue(forKey: timer) }
    }

    func cancelAllTimers() {
        state.withLock { $0.timers.removeAll() }
    }

    // MARK: Consumer

    /// A queued event, without waiting.
    func takeQueued() -> HandoffEvent? {
        state.withLock { $0.events.isEmpty ? nil : $0.events.removeFirst() }
    }

    /// The next event or due timer. Nil when the consuming task is cancelled.
    func next() async -> HandoffEvent? {
        while true {
            if state.withLock({ $0.cancelled }) || Task.isCancelled { return nil }
            if let event = takeQueued() { return event }
            let now = clock.now
            let earliest: (timer: HandoffTimer, at: C.Instant)? = state.withLock { s in
                s.timers.min { ($0.value, $0.key.priority) < ($1.value, $1.key.priority) }.map { ($0.key, $0.value) }
            }
            if let earliest, earliest.at <= now {
                cancel(earliest.timer)
                return .timer(earliest.timer)
            }
            await park(until: earliest?.at)
        }
    }

    private func park(until instant: C.Instant?) async {
        let id = state.withLock { s -> Int in
            s.parkID += 1
            return s.parkID
        }
        let clock = self.clock
        let sleeper: Task<Void, Never>? = instant.map { instant in
            Task { [self] in
                do { try await clock.sleep(until: instant, tolerance: nil) } catch { return }
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

    /// Wakes the parked consumer. A wake from a sleeper that belongs to an earlier park is ignored. A timer's wake that
    /// finds the consumer not yet suspended is remembered (`remember`); a push or a cancel needs no memory, since the park
    /// looks at the queue and the cancelled flag itself.
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

/// Feeds a link's notifications and drops into a `HandoffEvents`, for as long as the pumps live.
struct LinkPumps {
    private let tasks: [Task<Void, Never>]

    /// Takes both streams before returning, so nothing the link sends from now on is missed.
    init<C: Clock<Duration>>(link: any GATTLink, into events: HandoffEvents<C>) {
        let notifications = link.notifications
        let state = link.state
        tasks = [
            Task {
                for await (characteristic, value) in notifications {
                    events.push(.notification(characteristic, value))
                }
            },
            Task {
                for await next in state {
                    if case .dropped(let failure) = next { events.push(.linkDropped(failure)) }
                }
            },
        ]
    }

    func stop() {
        for task in tasks { task.cancel() }
    }
}
