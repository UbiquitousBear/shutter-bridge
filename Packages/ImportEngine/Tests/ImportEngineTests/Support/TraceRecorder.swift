import Foundation
@testable import ImportEngine
import Synchronization
import Testing

/// Records the engine's trace and lets a test wait for an event instead of sleeping.
///
/// `next(where:)` finds the first matching event after a cursor and moves the cursor past it, so a test reads the
/// trace in order. `wait(from:where:)` finds the first match at or after an index without moving the cursor.
///
/// A wait ends when its task is cancelled (a suite's `.timeLimit` cancels a test that runs over), recording an issue
/// and answering `cancelledWait`, so an event that never comes fails the test instead of hanging it.
final class TraceRecorder: Sendable {
    /// What a cancelled wait answers: not an event the engine emits.
    static let cancelledWait = EngineTrace.idle(queued: -1, inFlight: -1)

    private struct Waiter {
        let id: UUID
        let from: Int
        let movesCursor: Bool
        let matches: @Sendable (EngineTrace) -> Bool
        let continuation: CheckedContinuation<EngineTrace, Never>
    }

    private struct State {
        var log: [EngineTrace] = []
        var cursor = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    func record(_ event: EngineTrace) {
        let ready = state.withLock { s -> [(CheckedContinuation<EngineTrace, Never>, EngineTrace)] in
            s.log.append(event)
            let index = s.log.count - 1
            var ready: [(CheckedContinuation<EngineTrace, Never>, EngineTrace)] = []
            var kept: [Waiter] = []
            for w in s.waiters {
                if index >= w.from && w.matches(event) {
                    if w.movesCursor { s.cursor = index + 1 }
                    ready.append((w.continuation, event))
                } else {
                    kept.append(w)
                }
            }
            s.waiters = kept
            return ready
        }
        for (c, e) in ready { c.resume(returning: e) }
    }

    var log: [EngineTrace] { state.withLock { $0.log } }
    var count: Int { state.withLock { $0.log.count } }

    /// The next matching event after the cursor; moves the cursor past it.
    @discardableResult
    func next(where matches: @escaping @Sendable (EngineTrace) -> Bool) async -> EngineTrace {
        await find(from: nil, movesCursor: true, matches)
    }

    /// The next event after the cursor equal to `event`; moves the cursor past it.
    @discardableResult
    func next(_ event: EngineTrace) async -> EngineTrace { await next { $0 == event } }

    /// The first matching event at or after `index`; leaves the cursor where it is.
    @discardableResult
    func wait(from index: Int, where matches: @escaping @Sendable (EngineTrace) -> Bool) async -> EngineTrace {
        await find(from: index, movesCursor: false, matches)
    }

    private func find(from index: Int?, movesCursor: Bool,
                      _ matches: @escaping @Sendable (EngineTrace) -> Bool) async -> EngineTrace {
        let id = UUID()
        let event = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<EngineTrace, Never>) in
                let found = state.withLock { s -> EngineTrace? in
                    let start = index ?? s.cursor
                    if start < s.log.count {
                        for i in start ..< s.log.count where matches(s.log[i]) {
                            if movesCursor { s.cursor = i + 1 }
                            return s.log[i]
                        }
                    }
                    // Checked under the lock the cancellation handler takes: either it finds this waiter, or this
                    // sees the cancellation.
                    if Task.isCancelled { return Self.cancelledWait }
                    s.waiters.append(Waiter(id: id, from: max(start, s.log.count), movesCursor: movesCursor,
                                            matches: matches, continuation: c))
                    return nil
                }
                if let found { c.resume(returning: found) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> Waiter? in
                guard let i = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters.remove(at: i)
            }
            waiter?.continuation.resume(returning: Self.cancelledWait)
        }
        if event == Self.cancelledWait { Issue.record("cancelled while waiting for a trace event (time limit?)") }
        return event
    }

    /// How many recorded events match.
    func count(where matches: (EngineTrace) -> Bool) -> Int { log.filter(matches).count }
}
