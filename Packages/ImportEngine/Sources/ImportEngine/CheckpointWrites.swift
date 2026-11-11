import Synchronization

/// The checkpoint writes (`markPartial`) in flight for one file. Its commit waits for them before it writes its row
/// (`ImportEngine.commitAndRecord`), so a checkpoint issued before the commit began can't land after the row and turn
/// a staged file's row back to `.partial`. Waiting is cancellable, so the commit can bound it.
final class CheckpointWrites: Sendable {
    private struct State {
        var inFlight = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var next = 0
    }

    private let state = Mutex(State())

    /// Whether no write is in flight.
    var isEmpty: Bool { state.withLock { $0.inFlight == 0 } }

    /// A write is about to be sent to the catalogue.
    func begin() { state.withLock { $0.inFlight += 1 } }

    /// A write `begin()` counted has returned or thrown.
    func end() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.inFlight = max(0, s.inFlight - 1)
            guard s.inFlight == 0 else { return [] }
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        for w in waiters { w.resume() }
    }

    /// Returns once no write is in flight, or at once if the waiting task is cancelled.
    func waitUntilNone() async {
        let token = state.withLock { s -> Int in
            s.next += 1
            return s.next
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if s.inFlight == 0 || Task.isCancelled { return true }
                    s.waiters[token] = c
                    return false
                }
                if ready { c.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: token) }
            waiter?.resume()
        }
    }
}
