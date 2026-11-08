import Foundation
import PTPKit

/// The simulated camera's PTP/IP side, with no I/O (CIPA DC-005): bytes in from each TCP connection, actions out.
/// It does the Init_Command / Init_Event handshake, decodes Cmd_Request packets (and swallows an initiator's data
/// phase, which no served operation takes), answers through `PTPResponder`, and sends events on the event channel.
/// `PTPIPSimulatorServer` pumps it over Network.framework on loopback; the tests drive it directly on Linux, with an
/// initiator built from PTPKit, so the whole protocol is tested without a socket.
///
/// One initiator at a time, as the camera allows: a second Init_Command_Request while a session's command channel is
/// up gets Init_Fail (busy). Closing the command channel ends the session and closes the event channel, as losing the
/// camera does.
public struct PTPIPResponderCore: Sendable {
    /// The caller's name for one TCP connection.
    public typealias ConnectionID = Int

    public enum Action: Sendable, Equatable {
        /// Send this packet on the connection.
        case send(PTPIP.Packet, to: ConnectionID)
        /// Send a data phase on the connection: Start_Data, Data packets, End_Data (`DataPhasePackets` encodes it
        /// a packet at a time).
        case sendData(transactionID: UInt32, PTPResponder.DataPhase, to: ConnectionID)
        /// Close the connection.
        case close(ConnectionID)
    }

    private enum Role: Sendable, Hashable {
        case unknown
        case command(connectionNumber: UInt32)
        case event
    }

    private struct Connection: Sendable {
        var role: Role = .unknown
        var decoder = PTPIPStreamDecoder()
        /// A Cmd_Request whose initiator data phase is still arriving.
        var awaitingData: PTPContainer?
    }

    public private(set) var responder: PTPResponder
    public let name: String
    public let guid: UUID
    private var connections: [ConnectionID: Connection] = [:]
    private var commandChannel: ConnectionID?
    private var eventChannel: ConnectionID?
    private var nextConnectionNumber: UInt32 = 1

    /// - Parameters:
    ///   - name: The friendly name in Init_Command_Ack. The default is the camera's model name with a note that it
    ///     is simulated (no Sony marks reach the app from here: this is test-only).
    ///   - guid: The responder GUID in Init_Command_Ack.
    public init(responder: PTPResponder, name: String = "ILCE-7CM2 (simulated)",
                guid: UUID = UUID(uuidString: "5A5A0000-0000-4000-8000-00000000A7C2")!) {
        self.responder = responder
        self.name = name
        self.guid = guid
    }

    /// Whether an initiator has finished the handshake on both channels.
    public var isConnected: Bool { commandChannel != nil && eventChannel != nil }

    /// A new TCP connection; its role is set by its first packet.
    public mutating func connected(_ id: ConnectionID) {
        connections[id] = Connection()
    }

    /// Bytes read from a connection. A malformed stream closes it (and, for the command channel, the session).
    public mutating func received(_ bytes: Data, on id: ConnectionID) -> [Action] {
        guard var connection = connections[id] else { return [] }
        let events: [PTPIPStreamDecoder.Event]
        do {
            events = try connection.decoder.feed(bytes)
        } catch {
            return disconnected(id, closing: true)
        }
        connections[id] = connection
        var actions: [Action] = []
        for event in events {
            guard connections[id] != nil else { break }
            actions += handle(event, on: id)
        }
        return actions
    }

    /// The connection closed or failed. Returns what else to close.
    public mutating func disconnected(_ id: ConnectionID) -> [Action] {
        disconnected(id, closing: false)
    }

    /// Shoots `frames` onto the card and returns the ObjectAdded events to send on the event channel (none if no
    /// initiator is connected; the objects are added either way).
    public mutating func shoot(_ frames: [ScriptedCard.Frame], interval: Int = 2) -> [Action] {
        eventActions(responder.shoot(frames, interval: interval))
    }

    /// Adds objects and returns their events, as `shoot` does.
    public mutating func add(_ objects: [ScriptedCard.Object]) -> [Action] {
        eventActions(responder.add(objects))
    }

    /// Lets the caller script the responder (`inject(_:forNext:times:)`).
    public mutating func withResponder<T>(_ body: (inout PTPResponder) -> T) -> T { body(&responder) }

    /// Closes every connection, as the camera going away does.
    public mutating func dropAll() -> [Action] {
        let ids = connections.keys.sorted()
        connections = [:]
        commandChannel = nil
        eventChannel = nil
        responder.endSession()
        return ids.map(Action.close)
    }

    // MARK: - Private

    private mutating func disconnected(_ id: ConnectionID, closing: Bool) -> [Action] {
        guard connections.removeValue(forKey: id) != nil else { return [] }
        var actions: [Action] = closing ? [.close(id)] : []
        if commandChannel == id {
            commandChannel = nil
            responder.endSession()
            if let e = eventChannel {
                eventChannel = nil
                connections[e] = nil
                actions.append(.close(e))
            }
        } else if eventChannel == id {
            eventChannel = nil
        }
        return actions
    }

    private mutating func eventActions(_ events: [PTPContainer]) -> [Action] {
        guard let e = eventChannel else { return [] }
        return events.map { event in
            .send(PTPIP.event(event.eventCode, transactionID: event.transactionID, parameters: event.parameters), to: e)
        }
    }

    private mutating func handle(_ event: PTPIPStreamDecoder.Event, on id: ConnectionID) -> [Action] {
        switch event {
        case let .packet(packet):
            return handle(packet, on: id)
        case .dataPacketBegan, .dataBytes:
            // An initiator's data phase: no served operation takes one, so its bytes are dropped.
            return []
        case let .dataPacketEnded(type):
            guard type == .endData, let command = connections[id]?.awaitingData else { return [] }
            connections[id]?.awaitingData = nil
            return answer(command, on: id)
        }
    }

    private mutating func handle(_ packet: PTPIP.Packet, on id: ConnectionID) -> [Action] {
        guard let role = connections[id]?.role else { return [] }
        switch (packet.type, role) {
        case (.initCommandRequest, .unknown):
            guard (try? PTPIP.decodeInitCommandRequest(packet)) != nil else { return refuse(id, .unspecified) }
            guard commandChannel == nil else { return refuse(id, .busy) }
            let number = nextConnectionNumber
            nextConnectionNumber = nextConnectionNumber == UInt32.max ? 1 : nextConnectionNumber + 1
            connections[id]?.role = .command(connectionNumber: number)
            commandChannel = id
            return [.send(PTPIP.initCommandAck(connectionNumber: number, guid: guid, name: name), to: id)]

        case (.initEventRequest, .unknown):
            var r = PTPReader(packet.payload)
            guard let number = try? r.u32(), let c = commandChannel, eventChannel == nil,
                  case let .command(expected)? = connections[c]?.role, expected == number
            else { return refuse(id, .unspecified) }
            connections[id]?.role = .event
            eventChannel = id
            return [.send(PTPIP.initEventAck(), to: id)]

        case (.cmdRequest, .command):
            guard let request = try? PTPIP.decodeCmdRequest(packet) else {
                return disconnected(id, closing: true)
            }
            if request.dataPhase == PTPIP.DataPhase.initiatorToResponder.rawValue {
                connections[id]?.awaitingData = request.command
                return []
            }
            return answer(request.command, on: id)

        case (.ping, _):
            return [.send(PTPIP.pong(), to: id)]

        case (.startData, .command), (.pong, _), (.cancel, _):
            // Start_Data opens an initiator data phase (its bytes are dropped); a Cancel has nothing to stop, since
            // every reply is produced at once.
            return []

        default:
            // A packet out of place: a handshake twice, a command on the event channel. The camera would drop the
            // connection, and so does the simulator.
            return disconnected(id, closing: true)
        }
    }

    private mutating func answer(_ command: PTPContainer, on id: ConnectionID) -> [Action] {
        let reply = responder.respond(to: command)
        var actions: [Action] = []
        if let data = reply.data {
            actions.append(.sendData(transactionID: command.transactionID, data, to: id))
        }
        actions.append(.send(PTPIP.cmdResponse(reply.code, transactionID: command.transactionID,
                                               parameters: reply.response.parameters), to: id))
        return actions
    }

    private mutating func refuse(_ id: ConnectionID, _ reason: PTPIP.InitFailReason) -> [Action] {
        connections[id] = nil
        return [.send(PTPIP.initFail(reason: reason.rawValue), to: id), .close(id)]
    }
}

/// A responder-side data phase as encoded PTP/IP packets, produced one at a time: Start_Data, Data packets of
/// `packetSize` payload bytes, then End_Data with the rest (CIPA DC-005), so a 40 MB object never sits in memory.
public struct DataPhasePackets: Sequence, IteratorProtocol, Sendable {
    public let transactionID: UInt32
    public let phase: PTPResponder.DataPhase
    public let packetSize: Int
    private var offset: UInt64 = 0
    private var started = false
    private var ended = false

    public init(transactionID: UInt32, phase: PTPResponder.DataPhase, packetSize: Int = 1 << 20) {
        self.transactionID = transactionID
        self.phase = phase
        self.packetSize = Swift.max(1, packetSize)
    }

    public mutating func next() -> Data? {
        if ended { return nil }
        if !started {
            started = true
            return PTPIP.startData(transactionID: transactionID, totalLength: phase.length).encode()
        }
        let left = phase.length - offset
        if left > UInt64(packetSize) {
            let bytes = phase.read(from: offset, count: packetSize)
            offset += UInt64(packetSize)
            return PTPIP.data(transactionID: transactionID, bytes: bytes).encode()
        }
        ended = true
        return PTPIP.endData(transactionID: transactionID, bytes: phase.read(from: offset, count: Int(left))).encode()
    }
}
