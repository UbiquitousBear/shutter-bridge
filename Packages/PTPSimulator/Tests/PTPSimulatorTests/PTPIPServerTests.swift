import Foundation
import PTPKit
import Testing
@testable import PTPSimulator

#if canImport(Network)
@preconcurrency import Network
import Synchronization

/// A small PTP/IP initiator on Network.framework, built from PTPKit's codec: the handshake on two TCP connections to
/// loopback, then one transaction at a time on the command channel (`PTPIPStreamDecoder` and `PTPIPTransaction`),
/// and events read from the event channel.
actor PTPIPTestClient {
    enum Failure: Error, Equatable {
        case connection(String)
        case closed
        case unexpected(String)
    }

    private let queue = DispatchQueue(label: "PTPIPTestClient")
    private let command: NWConnection
    private let event: NWConnection
    private var commandDecoder = PTPIPStreamDecoder()
    private var eventDecoder = PTPIPStreamDecoder()
    private var commandEvents: [PTPIPStreamDecoder.Event] = []
    private var eventEvents: [PTPIPStreamDecoder.Event] = []
    private(set) var ack: PTPIP.InitCommandAck?
    private var counter = PTPTransactionCounter()

    init(port: UInt16) {
        let endpoint = NWEndpoint.Port(rawValue: port)!
        command = NWConnection(host: .ipv4(.loopback), port: endpoint, using: .tcp)
        event = NWConnection(host: .ipv4(.loopback), port: endpoint, using: .tcp)
    }

    /// Connects both channels and does the handshake.
    func connect(name: String = "PTPSimulator tests") async throws -> PTPIP.InitCommandAck {
        try await start(command)
        try await send(PTPIP.initCommandRequest(guid: UUID(), friendlyName: name).encode(), on: command)
        guard case let .packet(p) = try await nextCommandEvent(), p.type == .initCommandAck else {
            throw Failure.unexpected("no Init_Command_Ack")
        }
        let ack = try PTPIP.decodeInitCommandAck(p)
        self.ack = ack
        try await start(event)
        try await send(PTPIP.initEventRequest(connectionNumber: ack.connectionNumber).encode(), on: event)
        guard case let .packet(e) = try await nextEventEvent(), e.type == .initEventAck else {
            throw Failure.unexpected("no Init_Event_Ack")
        }
        return ack
    }

    /// One transaction with the next transaction ID (0 for OpenSession, as PTP requires).
    func transact(_ make: @Sendable (UInt32) -> PTPContainer) async throws -> (data: Data, response: PTPIP.CmdResponse) {
        let container = make(counter.take())
        try await send(PTPIP.cmdRequest(container).encode(), on: command)
        var transaction = PTPIPTransaction(transactionID: container.transactionID)
        var data = Data()
        while !transaction.isComplete {
            for output in try transaction.consume(try await nextCommandEvent()) {
                switch output {
                case let .data(bytes): data += bytes
                case .pingReceived: try await send(PTPIP.pong().encode(), on: command)
                default: break
                }
            }
        }
        guard transaction.dataLengthMismatch == nil, !transaction.dataPhaseUnterminated, let response = transaction.response
        else { throw Failure.unexpected("a broken data phase") }
        return (data, response)
    }

    func openSession() async throws -> PTPIP.CmdResponse {
        try await send(PTPIP.cmdRequest(PTPCommand.openSession(sessionID: 1)).encode(), on: command)
        var transaction = PTPIPTransaction(transactionID: 0)
        while !transaction.isComplete { _ = try transaction.consume(try await nextCommandEvent()) }
        return transaction.response!
    }

    /// The next event on the event channel.
    func nextEvent() async throws -> PTPIP.Event {
        guard case let .packet(p) = try await nextEventEvent(), p.type == .event else {
            throw Failure.unexpected("not an event")
        }
        return try PTPIP.decodeEvent(p)
    }

    func close() {
        command.cancel()
        event.cancel()
    }

    // MARK: - Private

    private func start(_ connection: NWConnection) async throws {
        let ready = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ready.set(continuation)
            connection.stateUpdateHandler = { state in
                let resume: (Result<Void, any Error>)? = switch state {
                case .ready: .success(())
                case let .failed(error): .failure(Failure.connection("\(error)"))
                case let .waiting(error): .failure(Failure.connection("waiting: \(error)"))
                case .cancelled: .failure(Failure.closed)
                default: nil
                }
                if let resume { ready.resume(with: resume) }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: Failure.connection("\(error)")) }
                else { continuation.resume() }
            })
        }
    }

    private func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if let error { continuation.resume(throwing: Failure.connection("\(error)")) }
                else if isComplete { continuation.resume(throwing: Failure.closed) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    private func nextCommandEvent() async throws -> PTPIPStreamDecoder.Event {
        while commandEvents.isEmpty {
            let bytes = try await receive(on: command)
            commandEvents += try commandDecoder.feed(bytes)
        }
        return commandEvents.removeFirst()
    }

    private func nextEventEvent() async throws -> PTPIPStreamDecoder.Event {
        while eventEvents.isEmpty {
            let bytes = try await receive(on: event)
            eventEvents += try eventDecoder.feed(bytes)
        }
        return eventEvents.removeFirst()
    }
}

/// Resumes a continuation once, from whichever thread gets there first.
private final class ResumeOnce: Sendable {
    private let continuation = Mutex<CheckedContinuation<Void, any Error>?>(nil)

    func set(_ c: CheckedContinuation<Void, any Error>) { continuation.withLock { $0 = c } }

    func resume(with result: Result<Void, any Error>) {
        let c = continuation.withLock { c -> CheckedContinuation<Void, any Error>? in
            defer { c = nil }
            return c
        }
        c?.resume(with: result)
    }
}

@Suite("PTP/IP server on loopback", .serialized, .timeLimit(.minutes(1)))
struct PTPIPServerTests {
    @Test func aClientListsTheCard() async throws {
        let card = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 100)
        let server = try PTPIPSimulatorServer(card: card)
        let port = try await server.start()
        #expect(port > 0)
        let client = PTPIPTestClient(port: port)
        let ack = try await client.connect()
        #expect(ack.connectionNumber == 1 && ack.responderName == "ILCE-7CM2 (simulated)")
        #expect(await server.isConnected)

        let info = try PTPDeviceInfo.decode(try await client.transact { PTPCommand.getDeviceInfo(tx: $0) }.data)
        #expect(info.model == "ILCE-7CM2" && info.operationsSupported.count == 24)
        #expect(try await client.openSession().code == .ok)
        let ids = try PTPStorageID.decodeArray(try await client.transact { PTPCommand.getStorageIDs(tx: $0) }.data)
        #expect(ids == [ScriptedCard.defaultStorageID])
        let handles = try PTPObjectHandle.decodeArray(try await client.transact { PTPCommand.getObjectHandles(tx: $0) }.data)
        var names: [String] = []
        for h in handles {
            let reply = try await client.transact { PTPCommand.getObjectInfo(h, tx: $0) }
            names.append(try PTPObjectInfo.decode(reply.data).filename)
        }
        #expect(names == card.objects.map(\.filename))

        // A whole object (about 400 KB) and a range of it, byte for byte.
        let o = card.objects[0]
        let object = try await client.transact { PTPCommand.getObject(o.handle, tx: $0) }
        #expect(object.response.code == .ok && object.data == ScriptedCard.content(of: o.handle, in: 0 ..< o.size))
        let part = try await client.transact { PTPCommand.getPartialObject(o.handle, offset: 1000, length: 5000, tx: $0) }
        #expect(part.response.parameters == [5000] && part.data == ScriptedCard.content(of: o.handle, in: 1000 ..< 6000))

        // A shot on the camera arrives as ObjectAdded on the event channel.
        let added = await server.shoot([.jpeg])
        let event = try await client.nextEvent()
        #expect(event.code == .objectAdded && event.parameters == [added[0].handle.rawValue])

        #expect(try await client.transact { PTPCommand.closeSession(tx: $0) }.response.code == .ok)
        await client.close()
        await server.stop()
    }

    @Test func injectedResponsesReachTheClient() async throws {
        let card = try #require(ScriptedCard.shoot([.jpeg])).scaled(down: 1000)
        let server = try PTPIPSimulatorServer(card: card)
        let client = PTPIPTestClient(port: try await server.start())
        _ = try await client.connect()
        _ = try await client.openSession()
        await server.inject(.deviceBusy, forNext: .getObject)
        let busy = try await client.transact { PTPCommand.getObject(card.objects[0].handle, tx: $0) }
        #expect(busy.response.code == .deviceBusy && busy.data.isEmpty)
        let ok = try await client.transact { PTPCommand.getObject(card.objects[0].handle, tx: $0) }
        #expect(ok.response.code == .ok && UInt64(ok.data.count) == card.objects[0].size)
        await client.close()
        await server.stop()
    }
}
#else
@Suite("PTP/IP server on loopback")
struct PTPIPServerTests {
    @Test(.disabled("Network.framework only: runs in the iOS Simulator under CI (app.yml)"))
    func aClientListsTheCard() {}
}
#endif
