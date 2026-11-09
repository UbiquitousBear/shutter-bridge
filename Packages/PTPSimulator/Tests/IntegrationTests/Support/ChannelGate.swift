import CameraTransport
import Foundation
import Synchronization

// A `ByteChannelFactory` in front of another that can hold every receive, so a test keeps a transaction on the wire
// (its command sent and answered by the camera, its reply not yet read) for as long as it likes, then lets it go.
// Sends always go through. Release the gate before closing a link: a receive held at the gate ends only then.

final class ChannelGate: ByteChannelFactory, Sendable {
    private struct State {
        var holding = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let inner: any ByteChannelFactory

    init(_ inner: any ByteChannelFactory) {
        self.inner = inner
    }

    /// From now on, every receive waits at the gate (one already reading carries on).
    func hold() {
        state.withLock { $0.holding = true }
    }

    /// Lets every receive held at the gate, and every later one, through.
    func release() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.holding = false
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    fileprivate func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let through = state.withLock { s -> Bool in
                guard s.holding else { return true }
                s.waiters.append(continuation)
                return false
            }
            if through { continuation.resume() }
        }
    }

    func open(_ endpoint: PTPIPEndpoint, timeout: Duration,
              state report: @escaping @Sendable (ByteChannelState) -> Void) async throws(ByteChannelFailure) -> any ByteChannel {
        GatedChannel(inner: try await inner.open(endpoint, timeout: timeout, state: report), gate: self)
    }
}

private struct GatedChannel: ByteChannel {
    let inner: any ByteChannel
    let gate: ChannelGate

    func send(_ data: Data) async throws(ByteChannelFailure) {
        try await inner.send(data)
    }

    func receive(atMost: Int) async throws(ByteChannelFailure) -> Data {
        await gate.pass()
        return try await inner.receive(atMost: atMost)
    }

    func close() async {
        await inner.close()
    }
}
