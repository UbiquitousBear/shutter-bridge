import CameraTransport
import Foundation
import PTPKit
import PTPSimulator
import Synchronization

/// The simulated camera on an in-memory network: a `ByteChannelFactory` whose channels are wired to a
/// `PTPIPResponderCore`, so `PTPIPConnection` (and the Wi-Fi link built on it) runs against the simulated camera on
/// Linux with no socket. The loopback `PTPIPSimulatorServer` does the same over Network.framework, Apple-only.
///
/// Each `open` is a new TCP connection to the camera; its role (command or event channel) is set by its first packet,
/// as on the camera. Bytes the initiator sends go straight to the core; what the core answers is queued on the right
/// channel. A data phase is queued as a lazy packet sequence, so a large object is produced a packet at a time as it
/// is read, never held whole. When the camera closes a connection, bytes already queued are still delivered, then the
/// channel ends, as TCP does.
///
/// Thread-safe. Lock order is camera, then channel; no continuation is resumed with a lock held.
public final class InMemoryPTPIPCamera: ByteChannelFactory, Sendable {
    private struct State: ~Copyable {
        var core: PTPIPResponderCore
        var channels: [Int: InMemoryByteChannel] = [:]
        var nextID = 1
        var refusing = false
        var statesOnOpen: [ByteChannelState] = [.connecting, .ready]
        var opens = 0
    }

    private let state: Mutex<State>
    /// The payload of each Data packet in a data phase (the camera's own size isn't recorded).
    public let packetSize: Int

    public init(core: PTPIPResponderCore, packetSize: Int = 1 << 20) {
        state = Mutex(State(core: core))
        self.packetSize = max(1, packetSize)
    }

    /// A camera for `card` with the captured α7C II datasets of `flavour` (PTP/IP by default).
    public convenience init(card: ScriptedCard, flavour: SimulatorFlavour = .ptpIP,
                            packetSize: Int = 1 << 20) throws(SimulatorFixtureError) {
        self.init(core: PTPIPResponderCore(responder: try PTPResponder(card: card, flavour: flavour)),
                  packetSize: packetSize)
    }

    // MARK: Scripting

    /// Whether new connections are refused (nothing listening on the port: the camera in another mode).
    public var refusesConnections: Bool {
        get { state.withLock { $0.refusing } }
        set { state.withLock { $0.refusing = newValue } }
    }

    /// The states each `open` reports before it returns (add `.waitingForLocalNetwork` to play the permission wait).
    public var statesOnOpen: [ByteChannelState] {
        get { state.withLock { $0.statesOnOpen } }
        set { state.withLock { $0.statesOnOpen = newValue } }
    }

    /// Connections opened so far, refused ones included.
    public var openCount: Int { state.withLock { $0.opens } }

    /// Whether an initiator has finished the handshake on both channels.
    public var isConnected: Bool { state.withLock { $0.core.isConnected } }

    /// The card as it is now.
    public var card: ScriptedCard { state.withLock { $0.core.responder.card } }

    /// Shoots `frames` onto the card and sends ObjectAdded on the event channel. Returns the new objects.
    @discardableResult
    public func shoot(_ frames: [ScriptedCard.Frame], interval: Int = 2) -> [ScriptedCard.Object] {
        let (added, wake) = state.withLock { s -> ([ScriptedCard.Object], [Wake]) in
            let before = Set(s.core.responder.card.handles)
            let actions = s.core.shoot(frames, interval: interval)
            let added = s.core.responder.card.objects.filter { !before.contains($0.handle) }
            return (added, Self.apply(actions, to: &s, packetSize: packetSize))
        }
        wake.forEach { $0() }
        return added
    }

    /// Lets `elapsed` time go by for the whole-card behaviour (`PTPIPResponderCore.advance(by:)`): a held
    /// Init_Command_Ack is sent, StoreAdded goes out when the card appears, and an idle session is dropped (both
    /// channels end with `.closed`, as the camera closing them does). Time passes only through this, so a test that
    /// drives a link on a virtual clock moves the camera with it.
    public func advance(by elapsed: Duration) {
        let wake = state.withLock { s in Self.apply(s.core.advance(by: elapsed), to: &s, packetSize: packetSize) }
        wake.forEach { $0() }
    }

    /// The camera drops its card from the session: StoreRemoved on the event channel, and the card's operations
    /// answer StoreNotAvailable from then on (`PTPResponder.dropCard()`).
    public func dropCard() {
        let wake = state.withLock { s in Self.apply(s.core.dropCard(), to: &s, packetSize: packetSize) }
        wake.forEach { $0() }
    }

    /// The card comes back: StoreAdded on the event channel (`PTPResponder.restoreCard()`).
    public func restoreCard() {
        let wake = state.withLock { s in Self.apply(s.core.restoreCard(), to: &s, packetSize: packetSize) }
        wake.forEach { $0() }
    }

    /// Every command the camera has answered, in order (`PTPResponder.commandsAnswered`).
    public var commandsAnswered: [PTPOperationCode] { state.withLock { $0.core.responder.commandsAnswered } }

    /// Lets the caller script the responder (`PTPResponder.inject(_:forNext:times:)` and the like).
    public func withResponder<T: Sendable>(_ body: (inout PTPResponder) -> T) -> T {
        state.withLock { s in s.core.withResponder(body) }
    }

    /// Ends every connection, as the camera going out of range does: queued bytes are delivered, then each channel
    /// fails with `failure` (POSIX 53, "Software caused connection abort", is what the spike saw).
    public func dropAll(as failure: ByteChannelFailure = .linkLost(posix: 53)) {
        let wake = state.withLock { s -> [Wake] in
            let actions = s.core.dropAll()
            var wake: [Wake] = []
            for case let .close(id) in actions {
                if let channel = s.channels.removeValue(forKey: id) { wake += channel.endOfStream(failure) }
            }
            return wake
        }
        wake.forEach { $0() }
    }

    // MARK: ByteChannelFactory

    public func open(_ endpoint: PTPIPEndpoint, timeout: Duration,
                     state report: @escaping @Sendable (ByteChannelState) -> Void) async throws(ByteChannelFailure) -> any ByteChannel {
        let (channel, states) = state.withLock { s -> (InMemoryByteChannel?, [ByteChannelState]) in
            s.opens += 1
            guard !s.refusing else { return (nil, [.connecting]) }
            let id = s.nextID
            s.nextID += 1
            let channel = InMemoryByteChannel(id: id, camera: self)
            s.channels[id] = channel
            s.core.connected(id)
            return (channel, s.statesOnOpen)
        }
        states.forEach(report)
        guard let channel else { throw .refused }
        return channel
    }

    // MARK: From the channels

    typealias Wake = @Sendable () -> Void

    func received(_ bytes: Data, from id: Int) {
        let wake = state.withLock { s -> [Wake] in
            guard s.channels[id] != nil else { return [] }
            return Self.apply(s.core.received(bytes, on: id), to: &s, packetSize: packetSize)
        }
        wake.forEach { $0() }
    }

    func closed(_ id: Int) {
        let wake = state.withLock { s -> [Wake] in
            guard s.channels.removeValue(forKey: id) != nil else { return [] }
            return Self.apply(s.core.disconnected(id), to: &s, packetSize: packetSize)
        }
        wake.forEach { $0() }
    }

    private static func apply(_ actions: [PTPIPResponderCore.Action], to s: inout State, packetSize: Int) -> [Wake] {
        var wake: [Wake] = []
        for action in actions {
            switch action {
            case let .send(packet, to: id):
                if let channel = s.channels[id] { wake += channel.enqueue(.bytes(packet.encode())) }
            case let .sendData(transactionID, phase, to: id):
                if let channel = s.channels[id] {
                    let packets = DataPhasePackets(transactionID: transactionID, phase: phase, packetSize: packetSize)
                    wake += channel.enqueue(.packets(packets))
                }
            case let .close(id):
                if let channel = s.channels.removeValue(forKey: id) { wake += channel.endOfStream(.closed) }
            }
        }
        return wake
    }
}

/// One in-memory TCP connection to an `InMemoryPTPIPCamera`, with the `ByteChannel` contract: receives return at
/// least one byte, `close()` wakes a pending call, and the first failure is final.
public final class InMemoryByteChannel: ByteChannel, Sendable {
    enum Chunk: Sendable {
        case bytes(Data)
        case packets(DataPhasePackets)
    }

    private struct State: ~Copyable {
        var queue: [Chunk] = []
        /// What the camera ended the stream with, delivered once the queue is empty.
        var end: ByteChannelFailure?
        var closed = false
        var pending: (atMost: Int, continuation: CheckedContinuation<Result<Data, ByteChannelFailure>, Never>)?
    }

    let id: Int
    private let camera: InMemoryPTPIPCamera
    private let state = Mutex(State())

    init(id: Int, camera: InMemoryPTPIPCamera) {
        self.id = id
        self.camera = camera
    }

    public func send(_ data: Data) async throws(ByteChannelFailure) {
        let failure = state.withLock { s -> ByteChannelFailure? in s.closed ? .closed : s.end }
        if let failure { throw failure }
        camera.received(data, from: id)
    }

    public func receive(atMost: Int) async throws(ByteChannelFailure) -> Data {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Result<Data, ByteChannelFailure>, Never>) in
            let ready = state.withLock { s -> Result<Data, ByteChannelFailure>? in
                if let r = Self.take(&s, atMost: atMost) { return r }
                s.pending = (atMost, c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
        return try result.get()
    }

    public func close() async {
        let (pending, wasOpen) = state.withLock { s -> (CheckedContinuation<Result<Data, ByteChannelFailure>, Never>?, Bool) in
            let wasOpen = !s.closed
            s.closed = true
            s.queue = []
            defer { s.pending = nil }
            return (s.pending?.continuation, wasOpen)
        }
        pending?.resume(returning: .failure(.closed))
        if wasOpen { camera.closed(id) }
    }

    /// Queues what the camera sent; returns the wake-up for a pending receive, to run outside every lock.
    func enqueue(_ chunk: Chunk) -> [InMemoryPTPIPCamera.Wake] {
        deliver { $0.queue.append(chunk) }
    }

    /// The camera ended the stream: queued bytes first, then `failure`.
    func endOfStream(_ failure: ByteChannelFailure) -> [InMemoryPTPIPCamera.Wake] {
        deliver { s in if s.end == nil { s.end = failure } }
    }

    private func deliver(_ change: (inout State) -> Void) -> [InMemoryPTPIPCamera.Wake] {
        let resume = state.withLock { s -> (CheckedContinuation<Result<Data, ByteChannelFailure>, Never>, Result<Data, ByteChannelFailure>)? in
            guard !s.closed else { return nil }
            change(&s)
            guard let p = s.pending, let r = Self.take(&s, atMost: p.atMost) else { return nil }
            s.pending = nil
            return (p.continuation, r)
        }
        guard let (c, r) = resume else { return [] }
        return [{ c.resume(returning: r) }]
    }

    private static func take(_ s: inout State, atMost: Int) -> Result<Data, ByteChannelFailure>? {
        if s.closed { return .failure(.closed) }
        let limit = max(1, atMost)
        var out = Data()
        while out.count < limit, !s.queue.isEmpty {
            switch s.queue[0] {
            case var .bytes(data):
                let n = min(limit - out.count, data.count)
                out.append(data.prefix(n))
                data = Data(data.dropFirst(n))
                if data.isEmpty { s.queue.removeFirst() } else { s.queue[0] = .bytes(data) }
            case var .packets(packets):
                if let next = packets.next() {
                    s.queue[0] = .bytes(next)
                    s.queue.insert(.packets(packets), at: 1)
                } else {
                    s.queue.removeFirst()
                }
            }
        }
        if !out.isEmpty { return .success(out) }
        if let end = s.end { return .failure(end) }
        return nil
    }
}
