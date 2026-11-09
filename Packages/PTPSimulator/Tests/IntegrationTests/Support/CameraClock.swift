import Synchronization

// A virtual clock that moves the simulated camera's time with its own, so a link's waits (the session plan's pauses,
// the listing poll, the keep-alive) and the camera's (the card's arrival, the idle drop) stay in step, and a test that
// waits 40 virtual seconds takes microseconds and gives the same answer on a loaded runner. Time moves only when a test
// says so: `advance(by:)`, or `drive(_:within:)`, which moves it only while the code under test is parked on the clock.

final class CameraClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        var deadline: Duration
        var continuation: CheckedContinuation<Void, Error>
    }

    /// What a waiter's condition sees.
    struct Snapshot: Sendable {
        var now: Duration
        /// The earliest deadline among the sleepers, if any.
        var nextDeadline: Duration?
        var sleepers: Int
        var finished: Bool
    }

    private struct State {
        var now: Duration = .zero
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var cancelledBeforeRegistering: Set<Int> = []
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []

        var snapshot: Snapshot {
            Snapshot(now: now, nextDeadline: sleepers.values.map(\.deadline).min(), sleepers: sleepers.count,
                     finished: finished)
        }
    }

    private let state = Mutex(State())
    /// Called with each step of time, before the sleepers due at its end are woken: the camera's `advance(by:)`.
    private let onAdvance: @Sendable (Duration) -> Void

    init(onAdvance: @escaping @Sendable (Duration) -> Void = { _ in }) {
        self.onAdvance = onAdvance
    }

    var now: Instant { Instant(offset: state.withLock { $0.now }) }
    var minimumResolution: Duration { .zero }

    /// Virtual time since the clock was made.
    var elapsed: Duration { state.withLock { $0.now } }

    var snapshot: Snapshot { state.withLock { $0.snapshot } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = mutate { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Outcome { case registered, due, cancelled }
                let outcome = mutate { s -> Outcome in
                    if s.cancelledBeforeRegistering.remove(id) != nil { return .cancelled }
                    if deadline.offset <= s.now { return .due }
                    s.sleepers[id] = Sleeper(deadline: deadline.offset, continuation: continuation)
                    return .registered
                }
                switch outcome {
                case .registered: break
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = mutate { s -> Sleeper? in
                if let sleeper = s.sleepers.removeValue(forKey: id) { return sleeper }
                s.cancelledBeforeRegistering.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward by `duration`, waking each sleeper as its deadline is reached (and moving the camera first).
    func advance(by duration: Duration) {
        let target = elapsed + duration
        while let next = snapshot.nextDeadline, next <= target { advanceToNext() }
        let step = mutate { s -> Duration in
            let step = max(.zero, target - s.now)
            s.now = max(s.now, target)
            return step
        }
        if step > .zero { onAdvance(step) }
    }

    /// Moves to the earliest deadline and wakes every sleeper due then. Returns false when no one sleeps.
    @discardableResult
    func advanceToNext() -> Bool {
        guard let next = snapshot.nextDeadline else { return false }
        let step = state.withLock { s in max(.zero, next - s.now) }
        if step > .zero { onAdvance(step) }
        let woken = mutate { s -> [Sleeper] in
            s.now = max(s.now, next)
            let ids = s.sleepers.filter { $0.value.deadline <= s.now }.keys
            return ids.compactMap { s.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in woken { sleeper.continuation.resume() }
        return true
    }

    /// Waits until `condition` holds, however long that takes in real time (the suite's time limit is the backstop).
    func waitUntil(_ condition: @escaping @Sendable (Snapshot) -> Bool) async {
        while true {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if condition(s.snapshot) { return true }
                    s.waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
            if condition(snapshot) { return }
        }
    }

    /// Runs `body` while moving time only to deadlines before `horizon` from now, and only once something sleeps on
    /// the clock (the code under test is parked on a wait). A sleeper at or past the horizon is left alone, so a timer
    /// the code starts as it finishes (the keep-alive, armed as an open ends) is never fired by the driving.
    func drive<T: Sendable>(within horizon: Duration, _ body: @escaping @Sendable () async -> T) async -> T {
        let limit = elapsed + horizon
        mutate { $0.finished = false }
        let task = Task {
            let result = await body()
            self.mutate { $0.finished = true }
            return result
        }
        while true {
            await waitUntil { s in s.finished || (s.nextDeadline.map { $0 < limit } ?? false) }
            if snapshot.finished { break }
            advanceToNext()
        }
        return await task.value
    }

    /// Advances by `duration` and waits until something sleeps past the new time again: a periodic timer (the
    /// keep-alive) has fired, done its work and re-armed.
    func tick(_ duration: Duration) async {
        advance(by: duration)
        await waitUntil { s in (s.nextDeadline.map { $0 > s.now } ?? false) }
    }

    @discardableResult
    private func mutate<T>(_ body: (inout State) -> T) -> T {
        let (result, waiters) = state.withLock { s -> (T, [CheckedContinuation<Void, Never>]) in
            let result = body(&s)
            let waiters = s.waiters
            s.waiters = []
            return (result, waiters)
        }
        for waiter in waiters { waiter.resume() }
        return result
    }
}
