import Foundation

// The seam between `PTPIPConnection` and the network: one TCP connection as a byte pipe. `PTPIPConnection` is written
// against these protocols only, so the whole PTP/IP initiator builds and is tested on Linux (plan decision 3). The
// Network.framework adapter (`NWByteChannel`, a later PR) is the only Apple-only part; tests use scripted fakes and
// `SimulatedLink`'s in-memory channel wired to the simulated camera.

/// What a connection that is being opened is doing, passed through to `PTPIPConnection.states` so the app can explain
/// a wait instead of showing a failure.
public enum ByteChannelState: Sendable, Equatable {
    /// Trying to reach the endpoint.
    case connecting
    /// The system is holding the connection until the person answers the Local Network prompt, or because Local
    /// Network access is off. Until they allow it the connection waits with "Network is down" (POSIX 50); the spike's
    /// probe got through 1.53 s after it started, with the prompt allowed in that time (backlog section 1).
    case waitingForLocalNetwork
    /// Connected: bytes can flow.
    case ready
}

/// Why a byte channel could not open, or stopped. The first failure of a channel is final: every later send or
/// receive on it throws.
public enum ByteChannelFailure: Error, Sendable, Equatable {
    /// Nothing listens on the port (TCP refused): the camera's PTP/IP responder isn't up, or it's in another mode.
    case refused
    /// The path went away (Wi-Fi off, out of range), with the POSIX error when the system gave one (53, "Software
    /// caused connection abort", is what both channels showed when the spike came back from the background).
    case linkLost(posix: Int32?)
    /// The channel's own time limit passed (an adapter may enforce one, such as the TCP connect timeout).
    case timedOut
    /// The connection was closed: by `close()`, or by the other end (end of stream).
    case closed
}

/// One open TCP connection.
///
/// The contract `PTPIPConnection` relies on:
/// - `receive` returns at least one byte and at most `atMost`, or throws. End of stream throws `.closed`; it never
///   returns empty data.
/// - At most one `send` and one `receive` are outstanding at a time (the connection serialises them).
/// - `close()` is idempotent, and it ends a pending `send` or `receive` with `.closed`. A pending read can't be
///   withdrawn any other way, which is why a timeout fails the whole channel (the spike's rule, `PTPIPClient.swift`
///   lines 787-788): the connection closes the channel to get its receive back.
/// - After any failure or `close()`, every call throws.
public protocol ByteChannel: Sendable {
    /// Sends all of `data`, returning once the system has taken it.
    func send(_ data: Data) async throws(ByteChannelFailure)
    /// Waits for the next bytes, at least one and at most `atMost`. No time limit of its own is required: the caller
    /// races it against its clock.
    func receive(atMost: Int) async throws(ByteChannelFailure) -> Data
    /// Closes the connection and wakes any pending call with `.closed`. Idempotent.
    func close() async
}

/// Opens byte channels: Network.framework on the phone, in-memory pairs in tests.
public protocol ByteChannelFactory: Sendable {
    /// Opens one TCP connection to `endpoint` and returns it once it is ready.
    ///
    /// - Parameters:
    ///   - timeout: The limit on trying to connect, not counting time spent in `.waitingForLocalNetwork`; the
    ///     connection also enforces its own limits on its injected clock, so an adapter that overruns is still cut off.
    ///   - state: Called with each state the connection passes through, from any thread, until `open` returns. The
    ///     adapter calls it with `.waitingForLocalNetwork` when the system holds the connection for the permission
    ///     (rather than failing), and with `.ready` just before returning.
    /// - Throws: `.refused` when the port refuses the connection (also while waiting: `ECONNREFUSED`), `.timedOut`
    ///   when its own limit passes, `.linkLost` when there is no path, `.closed` when cancelled.
    func open(_ endpoint: PTPIPEndpoint, timeout: Duration,
              state: @escaping @Sendable (ByteChannelState) -> Void) async throws(ByteChannelFailure) -> any ByteChannel
}
