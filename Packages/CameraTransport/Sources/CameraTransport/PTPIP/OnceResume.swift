import Synchronization

/// A value that the first of several racers delivers and one waiter receives: a channel callback, a timer, a
/// cancellation or `PTPIPConnection.abortTransfer()`, whichever gets there first (the spike's `OnceContinuation`,
/// `PTPIPClient.swift` lines 926-955, without its unchecked sendability).
///
/// `resume` may come before or after `wait()` begins; a value that arrives first is kept for the waiter. Only one
/// `wait()` is allowed. Thread-safe; the continuation is never resumed with the lock held.
final class OnceResume<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiter: CheckedContinuation<Value, Never>?
        var resumed = false
    }

    private let state = Mutex(State())

    init() {}

    /// Delivers `value` if no one has yet. Returns true for the racer that won.
    @discardableResult
    func resume(_ value: Value) -> Bool {
        let waiter = state.withLock { s -> CheckedContinuation<Value, Never>?? in
            guard !s.resumed else { return nil }
            s.resumed = true
            if let w = s.waiter {
                s.waiter = nil
                return .some(w)
            }
            s.value = value
            return .some(nil)
        }
        guard let waiter else { return false }
        waiter?.resume(returning: value)
        return true
    }

    /// Whether a value has been delivered.
    var isResumed: Bool { state.withLock { $0.resumed } }

    /// The winning value, waiting for it if it hasn't arrived.
    func wait() async -> Value {
        await withCheckedContinuation { (c: CheckedContinuation<Value, Never>) in
            let ready = state.withLock { s -> Value? in
                if let v = s.value {
                    s.value = nil
                    return v
                }
                s.waiter = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }
}
