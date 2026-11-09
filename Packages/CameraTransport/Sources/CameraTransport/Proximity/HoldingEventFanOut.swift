import Synchronization

/// `EventFanOut`, except that what is sent while no stream is live is held (the newest `limit`) and handed to the next stream
/// subscribed, ahead of anything sent later. For the proximity reports: after iOS relaunches the app for the scan, the camera
/// was reported 70 ms after the launch (5 Nov 22:26), possibly before the app's proximity model has subscribed, and that report
/// is the reason for the launch.
///
/// Thread-safe. Order is kept per stream for elements sent from one serial context (the central's queue). A continuation is
/// never finished with the lock held, since finishing runs its termination handler, which takes the lock.
final class HoldingEventFanOut<Element: Sendable>: Sendable {
    private struct State {
        var nextKey: UInt64 = 0
        var subscribers: [UInt64: AsyncStream<Element>.Continuation] = [:]
        var held: [Element] = []
    }

    /// How many elements are held at most while nobody listens; the oldest go first.
    let limit: Int
    private let state = Mutex(State())

    init(limit: Int = 16) {
        precondition(limit >= 0, "a hold of negative length")   // callers pass constants
        self.limit = limit
    }

    /// A new stream that starts with whatever was held (now no longer held), then gets everything sent from now on.
    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .unbounded)
        // The held elements are yielded under the lock, so no `send` can slip in ahead of them. Yielding to a stream nobody
        // has read yet can't run a termination handler.
        let key = state.withLock { s -> UInt64 in
            for element in s.held { continuation.yield(element) }
            s.held = []
            let key = s.nextKey
            s.nextKey += 1
            s.subscribers[key] = continuation
            return key
        }
        continuation.onTermination = { [weak self] _ in self?.drop(key) }
        return stream
    }

    /// Sends `element` to every live stream, or holds it when there is none.
    func send(_ element: Element) {
        let live = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            if s.subscribers.isEmpty {
                if limit > 0 {
                    s.held.append(element)
                    if s.held.count > limit { s.held.removeFirst(s.held.count - limit) }
                }
                return []
            }
            return Array(s.subscribers.values)
        }
        for continuation in live { continuation.yield(element) }
    }

    /// Elements held for the next stream (for tests).
    var heldCount: Int { state.withLock { $0.held.count } }

    /// Streams still being read (for tests).
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    private func drop(_ key: UInt64) {
        state.withLock { s in _ = s.subscribers.removeValue(forKey: key) }
    }
}
