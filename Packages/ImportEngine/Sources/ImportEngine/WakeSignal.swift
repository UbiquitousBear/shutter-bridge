import Synchronization

/// Wakes a job's driver when something it waits for changes: a resume, a reconnect, an append, a removal, a stall
/// lifting, a stop or a cancel. One per job, so a finished job's draining driver can never take the next job's
/// wakeup. A `fire()` with nobody waiting is kept for the next `wait()`; after `finish()` every wait returns at once.
final class WakeSignal: Sendable {
    private struct State {
        var waiter: CheckedContinuation<Void, Never>?
        var pending = false
        var finished = false
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let (now, displaced) = state.withLock { s -> (Bool, CheckedContinuation<Void, Never>?) in
                if s.finished { return (true, nil) }
                if s.pending {
                    s.pending = false
                    return (true, nil)
                }
                let old = s.waiter
                s.waiter = c
                return (false, old)
            }
            displaced?.resume()
            if now { c.resume() }
        }
    }

    func fire() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            if let w = s.waiter {
                s.waiter = nil
                return w
            }
            s.pending = true
            return nil
        }
        waiter?.resume()
    }

    func finish() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.finished = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }
}
