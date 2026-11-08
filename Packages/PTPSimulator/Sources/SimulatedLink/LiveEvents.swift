import Synchronization

/// Live events for any number of readers, as `CameraLink.events` requires: each `subscribe()` returns a stream that
/// gets only what is sent after it; `finish()` ends every stream, and a later subscription is finished at once. The
/// same contract as CameraTransport's internal `EventFanOut`, which this target can't reach.
final class LiveEvents<Element: Sendable>: Sendable {
    private let state = Mutex<(next: UInt64, subscribers: [UInt64: AsyncStream<Element>.Continuation]?)>((0, [:]))

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .unbounded)
        let key: UInt64? = state.withLock { s in
            guard s.subscribers != nil else { return nil }
            let key = s.next
            s.next += 1
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

    func finish() {
        let live = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            defer { s.subscribers = nil }
            return s.subscribers.map { Array($0.values) } ?? []
        }
        for continuation in live { continuation.finish() }
    }

    var subscriberCount: Int { state.withLock { $0.subscribers?.count ?? 0 } }

    private func drop(_ key: UInt64) {
        state.withLock { s in _ = s.subscribers?.removeValue(forKey: key) }
    }
}
