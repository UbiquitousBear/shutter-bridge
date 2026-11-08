import Foundation
import Synchronization

/// A clock that moves only when a test says so. Sleepers wake when `advance(by:)` reaches their deadline; a deadline
/// already passed returns at once; cancellation throws `CancellationError`.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var nextID = 0
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                enum Next { case resume, cancel, wait }
                let next = state.withLock { s -> Next in
                    if Task.isCancelled { return .cancel }
                    if deadline <= s.now { return .resume }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
                    return .wait
                }
                switch next {
                case .resume: c.resume()
                case .cancel: c.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let c = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: i).continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            s.now = s.now.advanced(by: duration)
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= now }
            return due.map(\.continuation)
        }
        for c in due { c.resume() }
    }
}
