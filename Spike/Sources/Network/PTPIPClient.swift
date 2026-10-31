import Foundation
import Network
import PTPKit

/// Days 7–9: a minimal PTP/IP initiator on Network.framework.
///
/// Two TCP connections (command/data and event), the CIPA DC-005 handshake, then PTP operations whose data
/// phase can be large (GetObject) and streamed to a file. Strictly one operation in flight; the actor's
/// mailbox enforces that for us.
actor PTPIPClient {
    enum ClientError: Error {
        case notConnected
        case handshakeFailed(reason: UInt32)
        case unexpectedPacket(PTPIPPacketType)
        case responseError(PTPResponseCode)
        case connectionFailed(NWError)
        case closed
    }

    struct SessionInfo: Sendable {
        let connectionNumber: UInt32
        let responderName: String
        let responderGUID: UUID
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let guid: UUID
    private let friendlyName: String
    private let queue = DispatchQueue(label: "ptpip.client")

    private var command: NWConnection?
    private var event: NWConnection?
    private var inbox = Data()
    private var tx = PTPTransactionCounter()
    private(set) var session: SessionInfo?

    /// Events from the camera (ObjectAdded etc.). Kept small; the spike only logs them.
    nonisolated let events: AsyncStream<PTPIP.Event>
    private let eventContinuation: AsyncStream<PTPIP.Event>.Continuation

    /// `guid` must be stable per install so the camera remembers us (day 7 question).
    init(host: String, port: UInt16 = PTPIP.defaultPort, guid: UUID, friendlyName: String = "Shutter Bridge spike") {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.guid = guid
        self.friendlyName = friendlyName
        var cont: AsyncStream<PTPIP.Event>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    // MARK: Connection and handshake

    func connect() async throws -> SessionInfo {
        let cmd = try await open()
        command = cmd
        try await sendPacket(PTPIP.initCommandRequest(guid: guid, friendlyName: friendlyName), on: cmd)
        let ackPacket = try await receivePacket(on: cmd)
        switch ackPacket.type {
        case .initCommandAck:
            let ack = try PTPIP.decodeInitCommandAck(ackPacket)
            let evt = try await open()
            event = evt
            try await sendPacket(PTPIP.initEventRequest(connectionNumber: ack.connectionNumber), on: evt)
            let evtAck = try await receivePacket(on: evt)
            guard evtAck.type == .initEventAck else { throw ClientError.unexpectedPacket(evtAck.type) }
            let info = SessionInfo(connectionNumber: ack.connectionNumber, responderName: ack.responderName, responderGUID: ack.responderGUID)
            session = info
            startEventLoop(evt)
            return info
        case .initFail:
            throw ClientError.handshakeFailed(reason: PTPIP.decodeInitFail(ackPacket))
        default:
            throw ClientError.unexpectedPacket(ackPacket.type)
        }
    }

    func disconnect() {
        command?.cancel(); event?.cancel()
        command = nil; event = nil; session = nil
        inbox.removeAll()
    }

    // MARK: Operations

    func openSession(id: UInt32 = 1) async throws {
        _ = try await perform(PTPCommand.openSession(sessionID: id, tx: 0))
        tx = PTPTransactionCounter()
    }

    func getDeviceInfo() async throws -> PTPDeviceInfo {
        let (_, data) = try await perform(PTPCommand.getDeviceInfo(tx: tx.take()))
        return try PTPDeviceInfo.decode(data)
    }

    func getStorageIDs() async throws -> [PTPStorageID] {
        let (_, data) = try await perform(PTPCommand.getStorageIDs(tx: tx.take()))
        var r = PTPReader(data)
        return try r.u32Array().map(PTPStorageID.init(rawValue:))
    }

    func getObjectHandles(storage: PTPStorageID = .all) async throws -> [PTPObjectHandle] {
        let (_, data) = try await perform(PTPCommand.getObjectHandles(storage: storage, tx: tx.take()))
        var r = PTPReader(data)
        return try r.u32Array().map(PTPObjectHandle.init(rawValue:))
    }

    func getObjectInfo(_ handle: PTPObjectHandle) async throws -> PTPObjectInfo {
        let (_, data) = try await perform(PTPCommand.getObjectInfo(handle, tx: tx.take()))
        return try PTPObjectInfo.decode(data)
    }

    func getThumb(_ handle: PTPObjectHandle) async throws -> Data {
        try await perform(PTPCommand.getThumb(handle, tx: tx.take())).data
    }

    func getObject(_ handle: PTPObjectHandle) async throws -> Data {
        try await perform(PTPCommand.getObject(handle, tx: tx.take())).data
    }

    func getPartialObject(_ handle: PTPObjectHandle, offset: UInt32, length: UInt32) async throws -> Data {
        try await perform(PTPCommand.getPartialObject(handle, offset: offset, length: length, tx: tx.take())).data
    }

    /// Sends one command and collects its response and (optional) data phase.
    func perform(_ cmd: PTPContainer) async throws -> (response: PTPIP.CmdResponse, data: Data) {
        guard let command else { throw ClientError.notConnected }
        try await sendPacket(PTPIP.cmdRequest(cmd), on: command)
        var data = Data()
        var expected: UInt64?
        while true {
            let p = try await receivePacket(on: command)
            switch p.type {
            case .startData:
                let s = try PTPIP.decodeStartData(p)
                expected = s.totalLength
                data.reserveCapacity(Int(min(s.totalLength, 64 * 1024 * 1024)))
            case .data:
                data.append(try PTPIP.decodeDataChunk(p).bytes)
            case .endData:
                data.append(try PTPIP.decodeDataChunk(p).bytes)
            case .cmdResponse:
                let resp = try PTPIP.decodeCmdResponse(p)
                if let expected, UInt64(data.count) != expected {
                    // Not fatal for the spike; worth recording when it happens.
                    print("PTP/IP: expected \(expected) bytes, got \(data.count)")
                }
                guard resp.code.isOK else { throw ClientError.responseError(resp.code) }
                return (resp, data)
            case .ping:
                try await sendPacket(PTPIP.pong(), on: command)
            case .event:
                eventContinuation.yield(try PTPIP.decodeEvent(p))
            default:
                throw ClientError.unexpectedPacket(p.type)
            }
        }
    }

    // MARK: Socket plumbing

    private func open() async throws -> NWConnection {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Local-network privacy: the first connect to a private address shows the system prompt.
        let conn = NWConnection(host: host, port: port, using: params)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; c.resume()
                case .failed(let e): resumed = true; c.resume(throwing: ClientError.connectionFailed(e))
                case .cancelled: resumed = true; c.resume(throwing: ClientError.closed)
                default: break
                }
            }
            conn.start(queue: queue)
        }
        return conn
    }

    private func sendPacket(_ p: PTPIP.Packet, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: p.encode(), completion: .contentProcessed { error in
                if let error { c.resume(throwing: ClientError.connectionFailed(error)) } else { c.resume() }
            })
        }
    }

    /// Reads from the socket until one whole packet is buffered. Buffering is per client, not per connection,
    /// because the spike only ever reads the command channel here; the event channel has its own loop.
    private func receivePacket(on conn: NWConnection) async throws -> PTPIP.Packet {
        while true {
            if let (packet, used) = try PTPIP.Packet.decode(inbox) {
                inbox.removeFirst(used)
                return packet
            }
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                    if let error { c.resume(throwing: ClientError.connectionFailed(error)); return }
                    if let data, !data.isEmpty { c.resume(returning: data); return }
                    if isComplete { c.resume(throwing: ClientError.closed); return }
                    c.resume(returning: Data())
                }
            }
            inbox.append(chunk)
        }
    }

    private func startEventLoop(_ conn: NWConnection) {
        var buffer = Data()
        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [eventContinuation] data, _, isComplete, error in
                if let data { buffer.append(data) }
                while let (p, used) = try? PTPIP.Packet.decode(buffer) {
                    buffer.removeFirst(used)
                    if p.type == .event, let e = try? PTPIP.decodeEvent(p) { eventContinuation.yield(e) }
                    if p.type == .ping { conn.send(content: PTPIP.pong().encode(), completion: .idempotent) }
                }
                if error == nil, !isComplete { pump() }
            }
        }
        pump()
    }
}
