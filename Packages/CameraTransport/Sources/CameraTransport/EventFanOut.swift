import Synchronization

/// Live events for any number of readers, as `CameraLink.events` requires: each `subscribe()` returns a new stream
/// that gets only what is sent after it, never anything from before; every live stream gets every event, in the order
/// sent; a stream whose reader has gone (its task cancelled, or the stream dropped) is removed; `finish()` ends every
/// stream, and a stream subscribed after that is finished at once. Pure Swift, so the links' fan-out is tested on
/// Linux, though `USBLink` itself is Apple-only.
///
/// Thread-safe. Order is kept per stream for events sent from one serial context (a link's actor); a continuation is
/// never called with the lock held, since finishing a stream runs its termination handler, which takes the lock.
final class EventFanOut<Element: Sendable>: Sendable {
    private struct State {
        var nextKey: UInt64 = 0
        /// Nil once finished.
        var subscribers: [UInt64: AsyncStream<Element>.Continuation]? = [:]
    }

    private let state = Mutex(State())

    init() {}

    /// A new stream that gets only what is sent from now on; already finished if `finish()` has been called.
    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .unbounded)
        let key: UInt64? = state.withLock { s in
            guard s.subscribers != nil else { return nil }
            let key = s.nextKey
            s.nextKey += 1
            s.subscribers?[key] = continuation
            return key
        }
        if let key {
            // Set once the key is known. No reader can end the stream before this (no one has it yet), and a
            // `finish()` racing with it has already removed every subscriber, so the handler isn't needed then.
            continuation.onTermination = { [weak self] _ in self?.drop(key) }
        } else {
            continuation.finish()
        }
        return stream
    }

    /// Sends `element` to every live stream.
    func send(_ element: Element) {
        let live = state.withLock { s in s.subscribers.map { Array($0.values) } ?? [] }
        for continuation in live { continuation.yield(element) }
    }

    /// Ends every stream; later sends go nowhere and later subscriptions are finished at once. Idempotent.
    func finish() {
        let live = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            defer { s.subscribers = nil }
            return s.subscribers.map { Array($0.values) } ?? []
        }
        for continuation in live { continuation.finish() }
    }

    /// Streams still being read (for tests).
    var subscriberCount: Int { state.withLock { $0.subscribers?.count ?? 0 } }

    /// Whether `finish()` has been called.
    var isFinished: Bool { state.withLock { $0.subscribers == nil } }

    private func drop(_ key: UInt64) {
        state.withLock { s in _ = s.subscribers?.removeValue(forKey: key) }
    }
}
