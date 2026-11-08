import Foundation
import Synchronization

/// Hands every value sent to each live subscriber, keeping only the newest one a slow subscriber hasn't read yet
/// (`bufferingNewest(1)`): for "something changed, look again" signals such as `ImportModel.importedUpdates()`,
/// where a reader that falls behind needs the latest value, not each one. A subscriber's stream ends when its reader
/// stops (the task is cancelled) or when `finish()` is called.
final class LatestValueFanOut<Element: Sendable>: Sendable {
    private struct State {
        var nextKey: UInt64 = 0
        /// Nil once finished.
        var subscribers: [UInt64: AsyncStream<Element>.Continuation]? = [:]
    }

    private let state = Mutex(State())

    init() {}

    /// A new stream that gets what is sent from now on; already finished if `finish()` has been called.
    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(1))
        let key: UInt64? = state.withLock { s in
            guard s.subscribers != nil else { return nil }
            let key = s.nextKey
            s.nextKey += 1
            s.subscribers?[key] = continuation
            return key
        }
        if let key {
            continuation.onTermination = { [weak self] _ in self?.drop(key) }
        } else {
            continuation.finish()
        }
        return stream
    }

    func send(_ element: Element) {
        let live = state.withLock { s in s.subscribers.map { Array($0.values) } ?? [] }
        for continuation in live { continuation.yield(element) }
    }

    /// Ends every stream; later subscriptions are finished at once. Idempotent.
    func finish() {
        let live = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            defer { s.subscribers = nil }
            return s.subscribers.map { Array($0.values) } ?? []
        }
        for continuation in live { continuation.finish() }
    }

    /// Live subscribers (tests).
    var subscriberCount: Int { state.withLock { $0.subscribers?.count ?? 0 } }

    private func drop(_ key: UInt64) {
        _ = state.withLock { s in s.subscribers?.removeValue(forKey: key) }
    }
}
