// PTP/IP framing (CIPA DC-005). Two TCP connections to port 15740: a command/data channel and an
// event channel. Every packet is:
//
//   u32 length (whole packet)   u32 packetType   payload
//
// This file only encodes and decodes packets; the socket work lives in the app's IPLink. PTPIPStream.swift
// turns a TCP byte stream into packets without buffering large data phases, and assembles one transaction.
// Responder-side encoders (Init_Command_Ack, Cmd_Response, Data …) exist for tests and the future PTPSimulator.

import Foundation

public enum PTPIPPacketType: UInt32, Sendable {
    case initCommandRequest = 1
    case initCommandAck     = 2
    case initEventRequest   = 3
    case initEventAck       = 4
    case initFail           = 5
    case cmdRequest         = 6
    case cmdResponse        = 7
    case event              = 8
    case startData          = 9
    case data               = 10
    case cancel             = 11
    case endData            = 12
    case ping               = 13
    case pong               = 14
}

public enum PTPIP {
    public static let defaultPort: UInt16 = 15740
    public static let protocolVersion: UInt32 = 0x0001_0000   // 1.0
    public static let headerLength = 8

    /// Data-phase direction flag in Cmd_Request.
    public enum DataPhase: UInt32, Sendable {
        case none = 1          // no data or data flows responder → initiator
        case initiatorToResponder = 2
    }

    public struct Packet: Equatable, Sendable {
        public var type: PTPIPPacketType
        public var payload: Data

        public init(type: PTPIPPacketType, payload: Data = Data()) {
            self.type = type
            self.payload = payload
        }

        public func encode() -> Data {
            var w = PTPWriter()
            w.u32(UInt32(PTPIP.headerLength + payload.count))
            w.u32(type.rawValue)
            w.bytes(payload)
            return w.data
        }

        /// Returns nil if `data` does not yet hold a whole packet (keep reading from the socket).
        public static func decode(_ data: Data) throws -> (packet: Packet, consumed: Int)? {
            guard data.count >= PTPIP.headerLength else { return nil }
            var r = PTPReader(data)
            let length = Int(try r.u32())
            guard length >= PTPIP.headerLength else { throw PTPDecodingError.badContainerLength(UInt32(length)) }
            guard data.count >= length else { return nil }
            let rawType = try r.u32()
            guard let type = PTPIPPacketType(rawValue: rawType) else { throw PTPDecodingError.badPacketType(rawType) }
            let payload = try r.bytes(length - PTPIP.headerLength)
            return (Packet(type: type, payload: payload), length)
        }
    }

    // MARK: Handshake

    /// Init_Command_Request: initiator GUID (16 bytes), friendly name (UTF-16LE, NUL-terminated), protocol version.
    public static func initCommandRequest(guid: UUID, friendlyName: String) -> Packet {
        var w = PTPWriter()
        w.bytes(guidBytes(guid))
        w.bytes(utf16z(friendlyName))
        w.u32(protocolVersion)
        return Packet(type: .initCommandRequest, payload: w.data)
    }

    public struct InitCommandAck: Equatable, Sendable {
        public var connectionNumber: UInt32
        public var responderGUID: UUID
        public var responderName: String
        public var protocolVersion: UInt32
    }

    public static func decodeInitCommandAck(_ p: Packet) throws -> InitCommandAck {
        var r = PTPReader(p.payload)
        let conn = try r.u32()
        let guid = try uuid(from: try r.bytes(16))
        let (name, used) = try utf16zDecode(r.rest())
        var tail = PTPReader(p.payload.suffix(from: p.payload.startIndex + 20 + used))
        let version = (try? tail.u32()) ?? 0
        return InitCommandAck(connectionNumber: conn, responderGUID: guid, responderName: name, protocolVersion: version)
    }

    public static func initEventRequest(connectionNumber: UInt32) -> Packet {
        var w = PTPWriter()
        w.u32(connectionNumber)
        return Packet(type: .initEventRequest, payload: w.data)
    }

    public static func decodeInitFail(_ p: Packet) -> UInt32 {
        var r = PTPReader(p.payload)
        return (try? r.u32()) ?? 0
    }

    /// Init_Fail reasons as listed in CIPA DC-005. Record what the α7C II actually sends (spike day 7): a camera
    /// that hasn't paired this initiator GUID is expected to answer `rejectedInitiator` until the user confirms
    /// on its screen.
    public enum InitFailReason: UInt32, Sendable, CustomStringConvertible {
        case rejectedInitiator = 1
        case busy = 2
        case unspecified = 3

        public var description: String {
            switch self {
            case .rejectedInitiator: "rejected initiator (not paired / refused on camera)"
            case .busy: "busy (another initiator connected?)"
            case .unspecified: "unspecified"
            }
        }

        public static func describe(_ raw: UInt32) -> String {
            InitFailReason(rawValue: raw).map(\.description) ?? String(format: "reason 0x%08X", raw)
        }
    }

    // MARK: Responder side (tests, PTPSimulator)

    public static func initCommandAck(connectionNumber: UInt32, guid: UUID, name: String, version: UInt32 = protocolVersion) -> Packet {
        var w = PTPWriter()
        w.u32(connectionNumber)
        w.bytes(guidBytes(guid))
        w.bytes(utf16z(name))
        w.u32(version)
        return Packet(type: .initCommandAck, payload: w.data)
    }

    public static func initEventAck() -> Packet { Packet(type: .initEventAck) }

    public static func initFail(reason: UInt32) -> Packet {
        var w = PTPWriter()
        w.u32(reason)
        return Packet(type: .initFail, payload: w.data)
    }

    /// Decodes an Init_Command_Request: initiator GUID, friendly name, protocol version.
    public static func decodeInitCommandRequest(_ p: Packet) throws -> (guid: UUID, friendlyName: String, protocolVersion: UInt32) {
        var r = PTPReader(p.payload)
        let guid = try uuid(from: try r.bytes(16))
        let (name, used) = try utf16zDecode(r.rest())
        var tail = PTPReader(p.payload.suffix(from: p.payload.startIndex + 16 + used))
        return (guid, name, (try? tail.u32()) ?? 0)
    }

    /// Decodes a Cmd_Request back into its data-phase flag and PTP command container.
    public static func decodeCmdRequest(_ p: Packet) throws -> (dataPhase: UInt32, command: PTPContainer) {
        var r = PTPReader(p.payload)
        let phase = try r.u32()
        let code = try r.u16()
        let tx = try r.u32()
        return (phase, PTPContainer(type: .command, code: code, transactionID: tx, payload: r.rest()))
    }

    public static func cmdResponse(_ code: PTPResponseCode, transactionID: UInt32, parameters: [UInt32] = []) -> Packet {
        var w = PTPWriter()
        w.u16(code.rawValue)
        w.u32(transactionID)
        for v in parameters { w.u32(v) }
        return Packet(type: .cmdResponse, payload: w.data)
    }

    public static func event(_ code: PTPEventCode, transactionID: UInt32 = 0, parameters: [UInt32] = []) -> Packet {
        var w = PTPWriter()
        w.u16(code.rawValue)
        w.u32(transactionID)
        for v in parameters { w.u32(v) }
        return Packet(type: .event, payload: w.data)
    }

    /// A Data packet (not the last one of a data phase; that is End_Data).
    public static func data(transactionID: UInt32, bytes: Data) -> Packet {
        var w = PTPWriter()
        w.u32(transactionID)
        w.bytes(bytes)
        return Packet(type: .data, payload: w.data)
    }

    /// The whole responder-side data phase for `payload`: Start_Data, zero or more Data packets of at most
    /// `packetSize` bytes, then End_Data with the remainder.
    public static func dataPhase(transactionID: UInt32, payload: Data, packetSize: Int = 64 * 1024) -> [Packet] {
        precondition(packetSize > 0)
        var packets = [startData(transactionID: transactionID, totalLength: UInt64(payload.count))]
        var offset = payload.startIndex
        while payload.endIndex - offset > packetSize {
            packets.append(data(transactionID: transactionID, bytes: payload.subdata(in: offset ..< offset + packetSize)))
            offset += packetSize
        }
        packets.append(endData(transactionID: transactionID, bytes: payload.subdata(in: offset ..< payload.endIndex)))
        return packets
    }

    /// Cancel packet (either direction): the transaction being cancelled.
    public static func cancel(transactionID: UInt32) -> Packet {
        var w = PTPWriter()
        w.u32(transactionID)
        return Packet(type: .cancel, payload: w.data)
    }

    // MARK: Operations

    public static func cmdRequest(_ command: PTPContainer, dataPhase: DataPhase = .none) -> Packet {
        precondition(command.type == .command)
        var w = PTPWriter()
        w.u32(dataPhase.rawValue)
        w.u16(command.code)
        w.u32(command.transactionID)
        w.bytes(command.payload)
        return Packet(type: .cmdRequest, payload: w.data)
    }

    public struct CmdResponse: Equatable, Sendable {
        public var code: PTPResponseCode
        public var transactionID: UInt32
        public var parameters: [UInt32]
    }

    public static func decodeCmdResponse(_ p: Packet) throws -> CmdResponse {
        var r = PTPReader(p.payload)
        let code = PTPResponseCode(rawValue: try r.u16())
        let tx = try r.u32()
        var params: [UInt32] = []
        while r.remaining >= 4 { params.append(try r.u32()) }
        return CmdResponse(code: code, transactionID: tx, parameters: params)
    }

    public struct StartData: Equatable, Sendable {
        public var transactionID: UInt32
        public var totalLength: UInt64
    }

    public static func decodeStartData(_ p: Packet) throws -> StartData {
        var r = PTPReader(p.payload)
        return StartData(transactionID: try r.u32(), totalLength: try r.u64())
    }

    /// Data and End_Data share a shape: transaction ID, then bytes.
    public static func decodeDataChunk(_ p: Packet) throws -> (transactionID: UInt32, bytes: Data) {
        var r = PTPReader(p.payload)
        let tx = try r.u32()
        return (tx, r.rest())
    }

    public static func startData(transactionID: UInt32, totalLength: UInt64) -> Packet {
        var w = PTPWriter()
        w.u32(transactionID)
        w.u64(totalLength)
        return Packet(type: .startData, payload: w.data)
    }

    public static func endData(transactionID: UInt32, bytes: Data) -> Packet {
        var w = PTPWriter()
        w.u32(transactionID)
        w.bytes(bytes)
        return Packet(type: .endData, payload: w.data)
    }

    public struct Event: Equatable, Sendable {
        public var code: PTPEventCode
        public var transactionID: UInt32
        public var parameters: [UInt32]
    }

    public static func decodeEvent(_ p: Packet) throws -> Event {
        var r = PTPReader(p.payload)
        let code = PTPEventCode(rawValue: try r.u16())
        let tx = try r.u32()
        var params: [UInt32] = []
        while r.remaining >= 4 { params.append(try r.u32()) }
        return Event(code: code, transactionID: tx, parameters: params)
    }

    public static func ping() -> Packet { Packet(type: .ping) }
    public static func pong() -> Packet { Packet(type: .pong) }

    // MARK: Helpers

    static func guidBytes(_ uuid: UUID) -> Data {
        let u = uuid.uuid
        return Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }

    static func uuid(from d: Data) throws -> UUID {
        guard d.count == 16 else { throw PTPDecodingError.truncated(needed: 16, available: d.count) }
        let b = [UInt8](d)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func utf16z(_ s: String) -> Data {
        var w = PTPWriter()
        for u in s.utf16 { w.u16(u) }
        w.u16(0)
        return w.data
    }

    /// Decodes a NUL-terminated UTF-16LE string; returns the string and the bytes consumed (terminator included).
    static func utf16zDecode(_ d: Data) throws -> (String, Int) {
        var units: [UInt16] = []
        var i = d.startIndex
        while i + 1 < d.endIndex {
            let u = UInt16(d[i]) | UInt16(d[i + 1]) << 8
            i += 2
            if u == 0 { return (String(utf16CodeUnits: units, count: units.count), i - d.startIndex) }
            units.append(u)
        }
        throw PTPDecodingError.badString
    }
}
