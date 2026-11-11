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
/// **Fault hooks:** `limitThroughput(bytesPerTick:every:)` makes a data phase flow only as fast as a budget that grows
/// with `advance(by:)` (a slow link; the camera's time passes only through `advance(by:)`), and `restart(at:)` has the
/// camera listen at another endpoint, so the old one is refused (`ByteChannelFailure.refused`) and a link that dials
/// the new one, from its location provider, gets through.
///
/// Thread-safe. Lock order is camera, then channel, then the throughput budget (a leaf); no continuation is resumed
/// with a lock held.
public final class InMemoryPTPIPCamera: ByteChannelFactory, Sendable {
    private struct State: ~Copyable {
        var core: PTPIPResponderCore
        var channels: [Int: InMemoryByteChannel] = [:]
        var nextID = 1
        var refusing = false
        var statesOnOpen: [ByteChannelState] = [.connecting, .ready]
        var opens = 0
        /// Where the camera listens; nil answers at any endpoint.
        var listensAt: PTPIPEndpoint?
        /// Endpoints dialled, in order, refused ones included.
        var dialled: [PTPIPEndpoint] = []
    }

    /// The throughput limit's budget, shared by every channel: one link's bandwidth. It also notes that payload went
    /// out, for the camera's idle clock (a transfer in progress is not idle).
    final class Throughput: Sendable {
        private struct Inner {
            var budget: ThroughputBudget?
            var sentPayload = false
        }

        private let inner = Mutex(Inner())

        func set(_ new: ThroughputBudget?) { inner.withLock { $0.budget = new } }
        var isLimited: Bool { inner.withLock { $0.budget != nil } }

        func advance(by elapsed: Duration) { inner.withLock { $0.budget?.advance(by: elapsed) } }

        /// How many of `wanted` bytes may go now: all of them with no limit, else what the budget grants (0 when
        /// it is spent).
        func take(upTo wanted: Int) -> Int {
            inner.withLock { current in
                guard var b = current.budget else {
                    current.sentPayload = current.sentPayload || wanted > 0
                    return wanted
                }
                let granted = b.take(upTo: UInt64(wanted))
                current.budget = b
                if granted > 0 { current.sentPayload = true }
                return Int(granted)
            }
        }

        /// Whether payload went out since the last call.
        func consumeSentPayload() -> Bool {
            inner.withLock { current in
                defer { current.sentPayload = false }
                return current.sentPayload
            }
        }
    }

    private let state: Mutex<State>
    let throughput = Throughput()
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

    /// The endpoint each `open` dialled, in order, refused ones included.
    public var dialled: [PTPIPEndpoint] { state.withLock { $0.dialled } }

    /// Where the camera listens now; nil, the default, answers at any endpoint.
    public var listensAt: PTPIPEndpoint? { state.withLock { $0.listensAt } }

    /// The camera restarts its responder at `endpoint` (another port, or another address on its network): every
    /// connection ends as the camera going away ends them (`dropAll`), and from now a connection to any other endpoint
    /// fails: refused if the host is the same (nothing listens on that port), `.timedOut` if it isn't (nobody answers). Pass nil to answer anywhere again.
    public func restart(at endpoint: PTPIPEndpoint?, as failure: ByteChannelFailure = .linkLost(posix: 53)) {
        state.withLock { $0.listensAt = endpoint }
        dropAll(as: failure)
    }

    /// From now a data phase goes out `bytesPerTick` payload bytes per `tick` of simulated time, with the budget shared
    /// by every connection; the reader sees nothing more until `advance(by:)` grants more. Packets shrink to what the
    /// budget allows, so a tick's worth can arrive in several short ones. Replaces any earlier limit, with nothing
    /// banked.
    ///
    /// `bytesPerTick` must be at least 1 and `tick` positive (a precondition: 0 is not "stalled" and not "unlimited").
    public func limitThroughput(bytesPerTick: UInt64, every tick: Duration = .seconds(1)) {
        precondition(bytesPerTick > 0 && tick > .zero,
                     "a limit grants at least one byte per positive tick; removeThroughputLimit() is the way to lift it")
        throughput.set(ThroughputBudget(bytesPerTick: bytesPerTick, every: tick))
        wakeChannels()
    }

    /// Back to full speed; a read waiting for budget goes on.
    public func removeThroughputLimit() {
        throughput.set(nil)
        wakeChannels()
    }

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
        throughput.advance(by: elapsed)
        let wake = state.withLock { s -> [Wake] in
            // Payload read since the last advance means a transfer is under way, which is not idle time.
            if throughput.consumeSentPayload() { s.core.noteTransferActivity() }
            return Self.apply(s.core.advance(by: elapsed), to: &s, packetSize: packetSize)
        }
        wake.forEach { $0() }
        wakeChannels()
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
    /// fails with `failure` (POSIX 53, "Software caused connection abort", is what the spike saw). With
    /// `losingUndelivered`, bytes the initiator hasn't read yet are lost instead, as a radio drop loses what was in
    /// flight: a data phase stops where the initiator had read to, which cuts a download mid-file.
    public func dropAll(as failure: ByteChannelFailure = .linkLost(posix: 53), losingUndelivered: Bool = false) {
        let wake = state.withLock { s -> [Wake] in
            let actions = s.core.dropAll()
            var wake: [Wake] = []
            for case let .close(id) in actions {
                if let channel = s.channels.removeValue(forKey: id) {
                    wake += channel.endOfStream(failure, losingUndelivered: losingUndelivered)
                }
            }
            return wake
        }
        wake.forEach { $0() }
    }

    // MARK: ByteChannelFactory

    public func open(_ endpoint: PTPIPEndpoint, timeout: Duration,
                     state report: @escaping @Sendable (ByteChannelState) -> Void) async throws(ByteChannelFailure) -> any ByteChannel {
        let (channel, failure, states) = state.withLock { s -> (InMemoryByteChannel?, ByteChannelFailure?, [ByteChannelState]) in
            s.opens += 1
            s.dialled.append(endpoint)
            if s.refusing { return (nil, .refused, [.connecting]) }
            if let at = s.listensAt, at != endpoint {
                // The same address with another port: the host answers and nothing listens (refused). Another
                // address: nobody answers, so the connect times out, as `SimulatedCameraLink` fails that dial.
                return (nil, at.host == endpoint.host ? .refused : .timedOut, [.connecting])
            }
            let id = s.nextID
            s.nextID += 1
            let channel = InMemoryByteChannel(id: id, camera: self, throughput: throughput)
            s.channels[id] = channel
            s.core.connected(id)
            return (channel, nil, s.statesOnOpen)
        }
        states.forEach(report)
        if let failure { throw failure }
        guard let channel else { throw .refused }
        return channel
    }

    // MARK: From the channels

    typealias Wake = @Sendable () -> Void

    /// Lets every channel try its pending read again: a throughput budget grew or went.
    private func wakeChannels() {
        let channels = state.withLock { Array($0.channels.values) }
        let wake = channels.flatMap { $0.retry() }
        wake.forEach { $0() }
    }

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
    private let throughput: InMemoryPTPIPCamera.Throughput
    private let state = Mutex(State())

    init(id: Int, camera: InMemoryPTPIPCamera, throughput: InMemoryPTPIPCamera.Throughput) {
        self.id = id
        self.camera = camera
        self.throughput = throughput
    }

    public func send(_ data: Data) async throws(ByteChannelFailure) {
        let failure = state.withLock { s -> ByteChannelFailure? in s.closed ? .closed : s.end }
        if let failure { throw failure }
        camera.received(data, from: id)
    }

    public func receive(atMost: Int) async throws(ByteChannelFailure) -> Data {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Result<Data, ByteChannelFailure>, Never>) in
            let ready = state.withLock { s -> Result<Data, ByteChannelFailure>? in
                if let r = Self.take(&s, atMost: atMost, throughput: throughput) { return r }
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

    /// The camera ended the stream: queued bytes first (or, `losingUndelivered`, none of them), then `failure`.
    func endOfStream(_ failure: ByteChannelFailure, losingUndelivered: Bool = false) -> [InMemoryPTPIPCamera.Wake] {
        deliver { s in
            if losingUndelivered { s.queue = [] }
            if s.end == nil { s.end = failure }
        }
    }

    /// Tries a pending read again (the throughput budget changed); returns its wake-up, if it can go now.
    func retry() -> [InMemoryPTPIPCamera.Wake] {
        deliver { _ in }
    }

    private func deliver(_ change: (inout State) -> Void) -> [InMemoryPTPIPCamera.Wake] {
        let resume = state.withLock { s -> (CheckedContinuation<Result<Data, ByteChannelFailure>, Never>, Result<Data, ByteChannelFailure>)? in
            guard !s.closed else { return nil }
            change(&s)
            guard let p = s.pending, let r = Self.take(&s, atMost: p.atMost, throughput: throughput) else { return nil }
            s.pending = nil
            return (p.continuation, r)
        }
        guard let (c, r) = resume else { return [] }
        return [{ c.resume(returning: r) }]
    }

    /// What a read gets now. Payload bytes of a data phase are taken from the throughput budget when the packet that
    /// carries them is made; with the budget spent the read finds nothing (it waits for `retry()`), though bytes queued
    /// before it are still delivered.
    private static func take(_ s: inout State, atMost: Int,
                             throughput: InMemoryPTPIPCamera.Throughput) -> Result<Data, ByteChannelFailure>? {
        if s.closed { return .failure(.closed) }
        let limit = max(1, atMost)
        var out = Data()
        loop: while out.count < limit, !s.queue.isEmpty {
            switch s.queue[0] {
            case var .bytes(data):
                let n = min(limit - out.count, data.count)
                out.append(data.prefix(n))
                data = Data(data.dropFirst(n))
                if data.isEmpty { s.queue.removeFirst() } else { s.queue[0] = .bytes(data) }
            case var .packets(packets):
                var granted = packets.packetSize
                let wanted = packets.nextPayloadSize
                if wanted > 0 {
                    granted = throughput.take(upTo: wanted)
                    if granted == 0 { break loop }
                }
                if let next = packets.next(payloadLimit: granted) {
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
