import Synchronization

// A virtual clock that moves the simulated camera's time with its own, so a link's waits (the session plan's pauses,
// the listing poll, the keep-alive) and the camera's (the card's arrival, the idle drop) stay in step, and a test that
// waits 40 virtual seconds takes microseconds and gives the same answer on a loaded runner. Time moves only when a test
// says so: `advance(by:)`, or `drive(_:within:)`, which moves it only while the code under test is parked on the clock.
// Every wait for the code under test (`waitUntil`, and `drive` and `tick` through it) is bounded in real time and throws
// `Stalled` when that runs out: a wait on a continuation can't be ended by the suite's time limit, so an unbounded one
// would leave the test, and its runner, waiting forever.

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
        var nextWaiterID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        /// Waiters whose patience ran out, or whose task was cancelled, before they registered.
        var abandonedBeforeRegistering: Set<Int> = []

        var snapshot: Snapshot {
            Snapshot(now: now, nextDeadline: sleepers.values.map(\.deadline).min(), sleepers: sleepers.count,
                     finished: finished)
        }
    }

    /// The real time a wait for the code under test may take before it is a stall. The code under test answers in
    /// microseconds (the simulated camera answers at once); this is far beyond that on a loaded runner, and well inside
    /// the suite's time limit.
    static let patience: Duration = .seconds(10)

    /// A wait on the clock didn't see its condition within `patience`: what the clock looked like then.
    struct Stalled: Error, CustomStringConvertible {
        var snapshot: Snapshot
        var description: String {
            "CameraClock stalled: waited \(CameraClock.patience) of real time; now \(snapshot.now), "
                + "\(snapshot.sleepers) sleeper(s), next deadline \(snapshot.nextDeadline.map { "\($0)" } ?? "none"), "
                + "finished \(snapshot.finished)"
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
        while let next = snapshot.nextDeadline, next <= target { move(to: next) }
        // The last step, to `target`, also wakes whoever is due by then: a sleeper can register after the loop has
        // looked (a timer armed just before this advance, its deadline read from the clock then), and moving `now`
        // past it without waking it would leave it asleep for good.
        move(to: target)
    }

    /// Moves to the earliest deadline and wakes every sleeper due then. Returns false when no one sleeps.
    @discardableResult
    func advanceToNext() -> Bool {
        guard let next = snapshot.nextDeadline else { return false }
        move(to: next)
        return true
    }

    /// Moves the camera, then `now`, to `instant` (never back), and wakes every sleeper due by then, in the same change
    /// as `now`: no sleeper is ever left registered at or before `now`.
    private func move(to instant: Duration) {
        let step = state.withLock { s in max(.zero, instant - s.now) }
        if step > .zero { onAdvance(step) }
        let woken = mutate { s -> [Sleeper] in
            s.now = max(s.now, instant)
            let ids = s.sleepers.filter { $0.value.deadline <= s.now }.keys
            return ids.compactMap { s.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in woken { sleeper.continuation.resume() }
    }

    /// Waits until `condition` holds, for at most `patience` of real time: past that, or when the task is cancelled, it
    /// throws (`Stalled`, or `CancellationError`) rather than wait forever.
    func waitUntil(_ condition: @escaping @Sendable (Snapshot) -> Bool) async throws {
        let giveUp = ContinuousClock.now.advanced(by: Self.patience)
        while true {
            if condition(snapshot) { return }
            try Task.checkCancellation()
            guard ContinuousClock.now < giveUp else { throw Stalled(snapshot: snapshot) }
            let id = state.withLock { s -> Int in
                s.nextWaiterID += 1
                return s.nextWaiterID
            }
            // Wakes this waiter when its patience runs out; the loop above then throws.
            let alarm = Task {
                guard (try? await Task.sleep(until: giveUp, clock: .continuous)) != nil else { return }  // woken first
                self.abandon(id)
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = state.withLock { s -> Bool in
                        if s.abandonedBeforeRegistering.remove(id) != nil || condition(s.snapshot) { return true }
                        s.waiters[id] = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            } onCancel: {
                abandon(id)
            }
            alarm.cancel()
        }
    }

    /// Wakes waiter `id` without its condition (its patience ran out, or its task was cancelled).
    private func abandon(_ id: Int) {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            if let waiter = s.waiters.removeValue(forKey: id) { return waiter }
            s.abandonedBeforeRegistering.insert(id)
            return nil
        }
        waiter?.resume()
    }

    /// Runs `body` while moving time only to deadlines before `horizon` from now, and only once something sleeps on
    /// the clock (the code under test is parked on a wait). A sleeper at or past the horizon is left alone, so a timer
    /// the code starts as it finishes (the keep-alive, armed as an open ends) is never fired by the driving.
    func drive<T: Sendable>(within horizon: Duration, _ body: @escaping @Sendable () async -> T) async throws -> T {
        let limit = elapsed + horizon
        mutate { $0.finished = false }
        let task = Task {
            let result = await body()
            self.mutate { $0.finished = true }
            return result
        }
        do {
            while true {
                try await waitUntil { s in s.finished || (s.nextDeadline.map { $0 < limit } ?? false) }
                let now = snapshot
                if now.finished { break }
                // Read again: a sleeper cancelled since the wait may have left only one at or past the horizon.
                if let next = now.nextDeadline, next < limit { move(to: next) }
            }
        } catch {
            task.cancel()
            throw error
        }
        return await task.value
    }

    /// Advances by `duration` and waits until something sleeps past the new time again: a periodic timer (the
    /// keep-alive) has fired, done its work and re-armed.
    func tick(_ duration: Duration) async throws {
        advance(by: duration)
        try await waitUntil { s in (s.nextDeadline.map { $0 > s.now } ?? false) }
    }

    @discardableResult
    private func mutate<T>(_ body: (inout State) -> T) -> T {
        let (result, waiters) = state.withLock { s -> (T, [CheckedContinuation<Void, Never>]) in
            let result = body(&s)
            let waiters = Array(s.waiters.values)
            s.waiters = [:]
            return (result, waiters)
        }
        for waiter in waiters { waiter.resume() }
        return result
    }
}
