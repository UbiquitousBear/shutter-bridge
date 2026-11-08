#if canImport(Network)
import Foundation
@preconcurrency import Network
import PTPKit
import Synchronization

/// The simulated camera over PTP/IP on loopback (backlog section 7): an `NWListener` on 127.0.0.1 / ::1 at a port the
/// system picks, pumping bytes between each TCP connection and a `PTPIPResponderCore`, which does the handshake, the
/// commands and the data phases. Runs in the iOS Simulator, so CI needs no camera; loopback also keeps it clear of
/// the local-network permission on a device.
///
/// One actor owns the core. Each connection has one receive outstanding at a time, re-armed only after its bytes are
/// handled, so packets are handled in order; a data phase is sent a packet at a time, each awaited, so a 40 MB object
/// never sits in memory.
public actor PTPIPSimulatorServer {
    public enum Failure: Error, Sendable, Hashable {
        /// The listener couldn't be made or failed before it was ready.
        case listenerFailed(String)
    }

    private var core: PTPIPResponderCore
    private let packetSize: Int
    private let queue = DispatchQueue(label: "PTPIPSimulatorServer")
    private var listener: NWListener?
    private var connections: [Int: NWConnection] = [:]
    private var nextID = 1
    /// The port the listener is on, once `start()` has returned.
    public private(set) var port: UInt16?

    /// - Parameter packetSize: The payload of each Data packet in a data phase (the camera's size isn't recorded).
    public init(core: PTPIPResponderCore, packetSize: Int = 1 << 20) {
        self.core = core
        self.packetSize = max(1, packetSize)
    }

    /// A server for `card` with the captured α7C II datasets of `flavour`.
    public init(card: ScriptedCard, flavour: SimulatorFlavour = .usbMTP) throws(SimulatorFixtureError) {
        self.init(core: PTPIPResponderCore(responder: try PTPResponder(card: card, flavour: flavour)))
    }

    /// The card as it is now.
    public var card: ScriptedCard { core.responder.card }

    /// Whether an initiator has finished the handshake on both channels.
    public var isConnected: Bool { core.isConnected }

    /// Starts listening on loopback and returns the port. Starting a started server returns its port.
    public func start() async throws(Failure) -> UInt16 {
        if let port { return port }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw .listenerFailed("\(error)")
        }
        let ready = Once<Result<UInt16, Failure>>()
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port?.rawValue {
                    ready.resolve(.success(port))
                } else {
                    ready.resolve(.failure(.listenerFailed("ready without a port")))
                }
            case let .failed(error):
                ready.resolve(.failure(.listenerFailed("\(error)")))
            case let .waiting(error):
                // NWListener waits when it can't listen yet (a loopback-only listener with no loopback interface,
                // say) and would wait for ever; for a test server that is a failure, reported with its reason.
                ready.resolve(.failure(.listenerFailed("waiting: \(error)")))
            case .cancelled:
                ready.resolve(.failure(.listenerFailed("cancelled")))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: queue)
        switch await ready.value {
        case let .success(port):
            self.port = port
            return port
        case let .failure(failure):
            listener.cancel()
            self.listener = nil
            throw failure
        }
    }

    /// Stops listening and closes every connection.
    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        _ = core.dropAll()
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }

    /// Shoots `frames` onto the card and sends ObjectAdded on the event channel (`PTPResponder.ObjectAddedStyle`).
    @discardableResult
    public func shoot(_ frames: [ScriptedCard.Frame], interval: Int = 2) async -> [ScriptedCard.Object] {
        let before = Set(core.responder.card.handles)
        let actions = core.shoot(frames, interval: interval)
        await perform(actions)
        return core.responder.card.objects.filter { !before.contains($0.handle) }
    }

    /// The next `times` commands with `operation` answer `code` (`PTPResponder.inject(_:forNext:times:)`).
    public func inject(_ code: PTPResponseCode, forNext operation: PTPOperationCode, times: Int = 1) {
        core.withResponder { $0.inject(code, forNext: operation, times: times) }
    }

    /// Closes both channels, as the camera going out of range does. The listener keeps listening.
    public func dropConnections() async {
        await perform(core.dropAll())
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        let id = nextID
        nextID += 1
        connections[id] = connection
        core.connected(id)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { await self.ended(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: id)
    }

    private func receive(on id: Int) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let failed = error != nil
            Task { await self.received(data, isComplete: isComplete, failed: failed, on: id) }
        }
    }

    private func received(_ data: Data?, isComplete: Bool, failed: Bool, on id: Int) async {
        guard connections[id] != nil else { return }
        if let data, !data.isEmpty {
            await perform(core.received(data, on: id))
        }
        guard connections[id] != nil else { return }
        if isComplete || failed {
            await ended(id)
        } else {
            receive(on: id)
        }
    }

    private func ended(_ id: Int) async {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.cancel()
        await perform(core.disconnected(id))
    }

    private func perform(_ actions: [PTPIPResponderCore.Action]) async {
        for action in actions {
            switch action {
            case let .send(packet, to: id):
                await send(packet.encode(), on: id)
            case let .sendData(transactionID, phase, to: id):
                for packet in DataPhasePackets(transactionID: transactionID, phase: phase, packetSize: packetSize) {
                    guard connections[id] != nil else { break }
                    await send(packet, on: id)
                }
            case let .close(id):
                if let connection = connections.removeValue(forKey: id) { connection.cancel() }
            }
        }
    }

    private func send(_ data: Data, on id: Int) async {
        guard let connection = connections[id] else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}

/// A value set once from any thread and awaited once.
private final class Once<Value: Sendable>: Sendable {
    private let state = Mutex<(value: Value?, waiter: CheckedContinuation<Value, Never>?)>((nil, nil))

    /// Sets the value; only the first call counts.
    func resolve(_ value: Value) {
        let waiter = state.withLock { s -> CheckedContinuation<Value, Never>? in
            guard s.value == nil else { return nil }
            s.value = value
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: value)
    }

    /// The value, waiting for it if it isn't set yet. One waiter only.
    var value: Value {
        get async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                let ready = state.withLock { s -> Value? in
                    if let value = s.value { return value }
                    s.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}
#endif
