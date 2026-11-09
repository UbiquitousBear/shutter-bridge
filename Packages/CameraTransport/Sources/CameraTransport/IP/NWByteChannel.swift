#if canImport(Network)
import Foundation
@preconcurrency import Network
import Synchronization

// The Network.framework adapter for `ByteChannelFactory` (wireless plan W9): the only Apple-only part of the PTP/IP link
// (plan decision 3). Its rules are the spike's `PTPIPChannel` (`Spike/Sources/Network/PTPIPClient.swift`, lines
// 692-920), which carried every Wi-Fi run from 2 to 5 Nov. Code compiled only by CI's Xcode 27 job; the integration
// test runs `IPLink` over it against `PTPIPSimulatorServer` on loopback in the iOS Simulator
// (`PTPSimulator/Tests/IntegrationTests/IPLinkOverNetworkTests.swift`).

/// Opens PTP/IP's TCP connections with Network.framework.
///
/// Each connection: TCP with no Nagle delay, the connect limit the caller gives (`PTPIPConnection.Timing.connect`, the
/// spike's 10 s, kept by the channel's own timer; TCP's own connect timeout is no shorter than
/// `Tuning.tcpConnectTimeoutFloor`), and TCP keep-alive (idle 10 s, then every 2 s, 3 probes), so an idle event channel
/// notices a camera that has gone; Wi-Fi only (`.wifi`), so a dead Wi-Fi path is never retried over cellular, or
/// loopback only (`.loopbackForTests`, for the simulated camera).
///
/// While opening, a connection the system holds for the Local Network prompt ("Network is down", POSIX 50, on a
/// satisfied path, or the path's `localNetworkDenied`) is reported as `.waitingForLocalNetwork`, never a failure; from
/// then on the connect limit is left to `PTPIPConnection`, whose `localNetworkPrompt` limit replaces it. "Network is
/// down" on a path that isn't satisfied is no Wi-Fi (dropped, or not joined yet): the connect limit stays, and an open
/// that reaches it that way fails as `.linkLost(posix: 50)`. Telling the two apart by the path is `unverified` (the
/// spike logged POSIX 50 while the prompt showed, not the path's status then): a bench check. A refused port
/// (ECONNREFUSED, also while waiting) is `.refused`. Once open, a connection that stays not viable (Wi-Fi gone) for
/// `Tuning.notViableGrace` fails as `.linkLost`. The simulator can't show the Local Network wait: that is a bench check
/// (wireless plan W9, risks).
public struct NWByteChannelFactory: ByteChannelFactory {
    /// Which interface the connections may use.
    public enum Interface: Sendable, Hashable {
        /// The phone's Wi-Fi: the camera is only ever there.
        case wifi
        /// Loopback, for the simulated camera (`PTPIPSimulatorServer`) in tests.
        case loopbackForTests
    }

    /// The TCP and viability settings, each with what it rests on.
    public enum Tuning {
        /// TCP keep-alive: first probe after this many idle seconds. The spike's (`PTPIPClient.swift`, line 721).
        public static let keepaliveIdle = 10
        /// Seconds between keep-alive probes. The spike's.
        public static let keepaliveInterval = 2
        /// Unanswered probes before TCP gives up. The spike's.
        public static let keepaliveCount = 3
        /// How long an open connection may stay not viable before it fails as `.linkLost`. The spike's
        /// `viabilityGrace` (`PTPIPClient.swift`, line 711); `unverified` as the best value: it was chosen, not
        /// measured, and the spike's channels came back from brief drops within it.
        public static let notViableGrace: Duration = .seconds(3)
        /// The least TCP connect timeout given to Network.framework: `PTPIPConnection.Timing`'s default
        /// `localNetworkPrompt` (60 s). If TCP's timeout counts while the system holds the connection for the prompt
        /// (`unverified`: a bench check), the spike's 10 s would end an open that `PTPIPConnection` still allows. The
        /// caller's connect limit is the channel's own timer, which still ends an open that never waited for the prompt.
        public static let tcpConnectTimeoutFloor: Duration = PTPIPConnection.Timing().localNetworkPrompt
    }

    public let interface: Interface

    public init(interface: Interface = .wifi) {
        self.interface = interface
    }

    public func open(_ endpoint: PTPIPEndpoint, timeout: Duration,
                     state: @escaping @Sendable (ByteChannelState) -> Void) async throws(ByteChannelFailure)
        -> any ByteChannel {
        // Port 0 can't be connected to: nothing listens there.
        guard let port = NWEndpoint.Port(rawValue: endpoint.port), endpoint.port != 0 else { throw .refused }
        if Task.isCancelled { throw .closed }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port,
                                      using: parameters(connectTimeout: timeout))
        let channel = NWByteChannel(connection: connection)
        try await channel.start(timeout: timeout, report: state)
        return channel
    }

    /// The spike's parameters (`PTPIPClient.swift`, lines 715-731), but for TCP's connect timeout
    /// (`Tuning.tcpConnectTimeoutFloor`).
    func parameters(connectTimeout: Duration) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, NWByteChannel.wholeSeconds(max(connectTimeout, Tuning.tcpConnectTimeoutFloor)))
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = Tuning.keepaliveIdle
        tcp.keepaliveInterval = Tuning.keepaliveInterval
        tcp.keepaliveCount = Tuning.keepaliveCount
        let parameters = NWParameters(tls: nil, tcp: tcp)
        switch interface {
        case .wifi: parameters.requiredInterfaceType = .wifi
        case .loopbackForTests: parameters.requiredInterfaceType = .loopback
        }
        return parameters
    }
}

/// One `NWConnection` as a `ByteChannel`. Callbacks arrive on its own queue; the mutable state is behind a lock, and no
/// continuation is resumed with the lock held. The first failure sticks: every later call throws it, and it cancels
/// the connection.
final class NWByteChannel: ByteChannel, Sendable {
    private struct State {
        var failure: ByteChannelFailure?
        /// The open's wait, until it returns.
        var start: OnceResume<Result<Void, ByteChannelFailure>>?
        /// The open's state callback, until it returns.
        var report: (@Sendable (ByteChannelState) -> Void)?
        var lastReported: ByteChannelState?
        var waitedForLocalNetwork = false
        /// The POSIX code of the latest `.waiting` that meant no Wi-Fi path ("Network is down" on a path that isn't
        /// satisfied): the failure the connect limit gives instead of `.timedOut`.
        var noPath: Int32?
        /// The outstanding send and receive (one of each at a time, the protocol's contract).
        var send: OnceResume<Result<Void, ByteChannelFailure>>?
        var receive: OnceResume<Result<Data?, ByteChannelFailure>>?
        var viable = true
        var viabilityChanges = 0
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "NWByteChannel")
    private let state = Mutex(State())

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// A channel let go without `close()` still releases its connection (its callbacks hold the channel only weakly).
    deinit {
        connection.cancel()
    }

    /// Starts the connection and returns once it is ready, or throws its failure.
    func start(timeout: Duration, report: @escaping @Sendable (ByteChannelState) -> Void) async throws(ByteChannelFailure) {
        let ready = OnceResume<Result<Void, ByteChannelFailure>>()
        state.withLock {
            $0.start = ready
            $0.report = report
        }
        connection.stateUpdateHandler = { [weak self] newState in self?.handle(newState) }
        connection.viabilityUpdateHandler = { [weak self] isViable in self?.viabilityChanged(isViable) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.seconds(timeout)) { [weak self] in self?.connectLimitPassed() }
        let result = await withTaskCancellationHandler {
            await ready.wait()
        } onCancel: { [weak self] in
            self?.fail(.closed)
        }
        state.withLock {
            $0.start = nil
            $0.report = nil
        }
        try result.get()
    }

    // MARK: ByteChannel

    func send(_ data: Data) async throws(ByteChannelFailure) {
        let done = OnceResume<Result<Void, ByteChannelFailure>>()
        let blocked = state.withLock { s -> ByteChannelFailure? in
            if let failure = s.failure { return failure }
            s.send = done
            return nil
        }
        if let blocked { throw blocked }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                done.resume(.failure(self?.failed(NWByteChannel.failure(for: error)) ?? .closed))
            } else {
                done.resume(.success(()))
            }
        })
        let result = await done.wait()
        state.withLock { if $0.send === done { $0.send = nil } }
        try result.get()
    }

    func receive(atMost: Int) async throws(ByteChannelFailure) -> Data {
        while true {
            let pending = OnceResume<Result<Data?, ByteChannelFailure>>()
            let blocked = state.withLock { s -> ByteChannelFailure? in
                if let failure = s.failure { return failure }
                s.receive = pending
                return nil
            }
            if let blocked { throw blocked }
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, atMost)) {
                [weak self] data, _, isComplete, error in
                if let data, !data.isEmpty {
                    pending.resume(.success(data))
                    // The other end closed after these bytes: they are delivered, and the next call throws `.closed`.
                    if isComplete { self?.fail(.closed) }
                } else if let error {
                    pending.resume(.failure(self?.failed(NWByteChannel.failure(for: error)) ?? .closed))
                } else if isComplete {
                    pending.resume(.failure(self?.failed(.closed) ?? .closed))
                } else {
                    pending.resume(.success(nil))  // nothing yet: read again (never return empty data)
                }
            }
            let result = await pending.wait()
            state.withLock { if $0.receive === pending { $0.receive = nil } }
            switch result {
            case let .success(data?): return data
            case .success(nil): continue
            case let .failure(failure): throw failure
            }
        }
    }

    func close() async {
        fail(.closed)
    }

    // MARK: Connection states

    private func handle(_ newState: NWConnection.State) {
        switch newState {
        case .preparing:
            report(.connecting)
        case let .waiting(error):
            waiting(error)
        case .ready:
            ready()
        case let .failed(error):
            fail(Self.failure(for: error))
        case .cancelled:
            fail(.closed)
        case .setup:
            break
        @unknown default:
            break
        }
    }

    /// Network.framework holds a connection in `.waiting` and retries it; only a refusal ends it here (and a TCP
    /// connect timeout before any Local Network wait). Other reasons (no route yet, no Wi-Fi) wait for the connect
    /// limit.
    private func waiting(_ error: NWError) {
        if Self.isLocalNetworkWait(error, path: connection.currentPath) {
            state.withLock {
                $0.waitedForLocalNetwork = true
                $0.noPath = nil
            }
            report(.waitingForLocalNetwork)
            return
        }
        guard case let .posix(code) = error else {
            state.withLock { $0.noPath = nil }
            return
        }
        state.withLock { $0.noPath = code == .ENETDOWN ? code.rawValue : nil }
        switch code {
        case .ECONNREFUSED:
            fail(.refused)
        case .ETIMEDOUT:
            if !state.withLock({ $0.waitedForLocalNetwork }) { fail(.timedOut) }
        default:
            break
        }
    }

    private func ready() {
        let (report, start) = state.withLock { s -> ((@Sendable (ByteChannelState) -> Void)?, OnceResume<Result<Void, ByteChannelFailure>>?) in
            guard s.failure == nil else { return (nil, nil) }
            let report = s.lastReported == .ready ? nil : s.report
            s.lastReported = .ready
            s.report = nil
            return (report, s.start)
        }
        report?(.ready)  // just before `open` returns, as the protocol says
        start?.resume(.success(()))
    }

    /// Passes a state to the open's callback, once per change, until the open returns.
    private func report(_ channelState: ByteChannelState) {
        let callback = state.withLock { s -> (@Sendable (ByteChannelState) -> Void)? in
            guard s.failure == nil, let report = s.report, s.lastReported != channelState else { return nil }
            s.lastReported = channelState
            return report
        }
        callback?(channelState)
    }

    /// The connect limit: ends an open still under way, unless it waited for the Local Network prompt (that time isn't
    /// counted here; the connection's own `localNetworkPrompt` limit governs it). Still held for no Wi-Fi path, it is
    /// `.linkLost` with that POSIX code (the factory's contract: no path is `.linkLost`), otherwise `.timedOut`.
    private func connectLimitPassed() {
        let expired = state.withLock { s -> ByteChannelFailure? in
            guard s.start != nil, s.failure == nil, !s.waitedForLocalNetwork else { return nil }
            return s.noPath.map { .linkLost(posix: $0) } ?? .timedOut
        }
        if let expired { fail(expired) }
    }

    private func viabilityChanged(_ isViable: Bool) {
        let change = state.withLock { s -> Int? in
            s.viable = isViable
            s.viabilityChanges += 1
            return isViable || s.failure != nil ? nil : s.viabilityChanges
        }
        guard let change else { return }
        queue.asyncAfter(deadline: .now() + Self.seconds(NWByteChannelFactory.Tuning.notViableGrace)) { [weak self] in
            guard let self else { return }
            let stillDown = self.state.withLock { !$0.viable && $0.viabilityChanges == change }
            if stillDown { self.fail(.linkLost(posix: nil)) }
        }
    }

    // MARK: Failure

    /// Records `failure` if it is the first, wakes every waiter with the first failure, and cancels the connection.
    private func fail(_ failure: ByteChannelFailure) {
        _ = failed(failure)
    }

    /// `fail(_:)`, returning the failure that sticks (the first one).
    private func failed(_ failure: ByteChannelFailure) -> ByteChannelFailure {
        let (first, sticking, waiters) = state.withLock { s -> (Bool, ByteChannelFailure, [Waiter]) in
            let first = s.failure == nil
            if first { s.failure = failure }
            let sticking = s.failure ?? failure
            var waiters: [Waiter] = []
            if let start = s.start { waiters.append(.start(start)) }
            if let send = s.send { waiters.append(.send(send)) }
            if let receive = s.receive { waiters.append(.receive(receive)) }
            s.start = nil
            s.send = nil
            s.receive = nil
            s.report = nil
            return (first, sticking, waiters)
        }
        for waiter in waiters {
            switch waiter {
            case let .start(once): once.resume(.failure(sticking))
            case let .send(once): once.resume(.failure(sticking))
            case let .receive(once): once.resume(.failure(sticking))
            }
        }
        if first { connection.cancel() }
        return sticking
    }

    private enum Waiter {
        case start(OnceResume<Result<Void, ByteChannelFailure>>)
        case send(OnceResume<Result<Void, ByteChannelFailure>>)
        case receive(OnceResume<Result<Data?, ByteChannelFailure>>)
    }

    /// Whether a `.waiting` error is the system holding the connection for the Local Network permission: the path's
    /// `localNetworkDenied`; "Network is down" (POSIX 50, measured in the spike while the prompt showed) on a satisfied
    /// path, since on a path that isn't satisfied it is no Wi-Fi (the spike's hint lists both; `unverified`, a bench
    /// check); or DNS's policy-denied (-65570, kDNSServiceErr_PolicyDenied, for a host name; the spike's hint for it).
    static func isLocalNetworkWait(_ error: NWError, path: NWPath?) -> Bool {
        if let path, path.status != .satisfied, path.unsatisfiedReason == .localNetworkDenied { return true }
        switch error {
        case let .posix(code): return code == .ENETDOWN && path?.status == .satisfied
        case let .dns(code): return code == -65570
        default: return false
        }
    }

    /// A Network.framework error as a channel failure.
    static func failure(for error: NWError) -> ByteChannelFailure {
        guard case let .posix(code) = error else { return .linkLost(posix: nil) }
        switch code {
        case .ECONNREFUSED: return .refused
        case .ETIMEDOUT: return .timedOut
        case .ECANCELED: return .closed
        default: return .linkLost(posix: code.rawValue)
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Whole seconds, rounded up.
    static func wholeSeconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(clamping: parts.seconds) + (parts.attoseconds > 0 ? 1 : 0)
    }
}
#endif
