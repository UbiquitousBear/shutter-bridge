// A clock that moves only when a test says so, and a driver that says so only when the code under test has nothing left to
// do at the current time. No wall-clock sleeps: a test that waits 30 virtual seconds takes microseconds and gives the same
// answer on a loaded runner.

import Synchronization

final class ManualClock: Clock, Sendable {
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

    private struct Scheduled {
        var deadline: Duration
        var order: Int
        var action: @Sendable () -> Void
    }

    private struct State {
        var now: Duration = .zero
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var cancelledBeforeRegistering: Set<Int> = []
        var scheduled: [Scheduled] = []
        /// Bumped whenever a sleeper is added or removed or the work finishes: the driver's way to see the code under test
        /// react (a sleeper it was parked on goes, and it parks again).
        var generation = 0
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var now: Instant { Instant(offset: state.withLock { $0.now }) }
    var minimumResolution: Duration { .zero }

    /// Virtual time since the clock was made.
    var elapsed: Duration { state.withLock { $0.now } }

    /// Moves time forward and wakes whatever is due. For tests that check `ClockMark` or other readers of `now`.
    func advance(by duration: Duration) {
        let target = elapsed + duration
        while let next = nextDeadline(), next <= target { advanceToNext() }
        mutate { $0.now = max($0.now, target) }
    }

    // MARK: Clock

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
                    s.generation += 1
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
                if let sleeper = s.sleepers.removeValue(forKey: id) {
                    s.generation += 1
                    return sleeper
                }
                s.cancelledBeforeRegistering.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: Scripted events

    /// Runs `action` synchronously, from `advanceToNext`, when virtual time reaches `offset`. Registered at once, unlike a
    /// task that sleeps, so a driver can't move past it by being quicker than the task.
    func schedule(at offset: Duration, _ action: @escaping @Sendable () -> Void) {
        mutate { s in
            s.scheduled.append(Scheduled(deadline: offset, order: s.nextID, action: action))
            s.nextID += 1
        }
    }

    // MARK: Driving

    private func nextDeadline() -> Duration? {
        state.withLock { s in
            let all = s.sleepers.values.map(\.deadline) + s.scheduled.map(\.deadline)
            return all.min()
        }
    }

    /// Moves to the earliest deadline among sleepers and scheduled actions and fires everything due then: actions first, in
    /// the order they were scheduled, then the sleepers. Returns false when there is none.
    @discardableResult
    func advanceToNext() -> Bool {
        guard let next = nextDeadline() else { return false }
        let (actions, sleepers) = mutate { s -> ([@Sendable () -> Void], [Sleeper]) in
            s.now = max(s.now, next)
            let due = s.scheduled.filter { $0.deadline <= s.now }.sorted { ($0.deadline, $0.order) < ($1.deadline, $1.order) }
            s.scheduled.removeAll { $0.deadline <= s.now }
            let ids = s.sleepers.filter { $0.value.deadline <= s.now }.keys
            let woken = ids.compactMap { s.sleepers.removeValue(forKey: $0) }
            s.generation += woken.count
            return (due.map(\.action), woken)
        }
        for action in actions { action() }
        for sleeper in sleepers { sleeper.continuation.resume() }
        return true
    }

    func markFinished() {
        mutate { s in
            s.finished = true
            s.generation += 1
        }
    }

    /// Waits until `predicate` holds, however long that takes in real time (a test's time limit is the backstop).
    func waitUntil(_ predicate: @escaping @Sendable (_ sleepers: Int, _ generation: Int, _ finished: Bool) -> Bool) async {
        while true {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if predicate(s.sleepers.count, s.generation, s.finished) { return true }
                    s.waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
            if state.withLock({ predicate($0.sleepers.count, $0.generation, $0.finished) }) { return }
        }
    }

    /// Waits until something is waiting on the clock.
    func waitUntilSomeoneSleeps() async {
        await waitUntil { sleepers, _, finished in sleepers > 0 || finished }
    }

    /// Runs virtual time until the work is `finished`: each round waits for a sleeper (the code under test is parked, with a
    /// timer on the clock), fires the earliest deadline, then waits for the code to react (its parked sleeper goes and it
    /// parks again, or it finishes) before the next round.
    func runUntilFinished() async {
        while true {
            await waitUntilSomeoneSleeps()
            if state.withLock({ $0.finished }) { return }
            let before = state.withLock { $0.generation }
            advanceToNext()
            await waitUntil { _, generation, finished in finished || generation >= before + 2 }
        }
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

/// Runs `body` on its own task while the clock is driven, and returns its result.
func driven<T: Sendable>(_ clock: ManualClock, _ body: @escaping @Sendable () async -> T) async -> T {
    let task = Task {
        let result = await body()
        clock.markFinished()
        return result
    }
    await clock.runUntilFinished()
    return await task.value
}
