// Turning a PTP/IP TCP byte stream into packets, and packets into one transaction's result, without holding a
// large data phase in memory. A 1 GB clip arrives as Data/End_Data packets that may each be many megabytes;
// the decoder passes their payload through in whatever pieces the socket delivers, so memory stays bounded by
// the socket read size (the proposal's 150 MB budget), and the caller streams bytes straight to a file.
//
// Both types are pure value types: feed them bytes or events, get events or outputs back. No I/O.

import Foundation

/// Incremental PTP/IP framing for one TCP connection. Control packets (acks, Cmd_Response, Start_Data, Event,
/// Ping …) are small and are delivered whole; Data and End_Data packets are delivered as a header, the payload
/// in pieces, and an end marker.
public struct PTPIPStreamDecoder: Sendable {
    public enum Event: Equatable, Sendable {
        /// A whole control packet (any type other than Data and End_Data).
        case packet(PTPIP.Packet)
        /// A Data or End_Data packet began. `payloadLength` counts the bytes after the transaction ID.
        case dataPacketBegan(type: PTPIPPacketType, transactionID: UInt32, payloadLength: Int)
        /// Some of the current Data/End_Data payload, in arrival order. Never empty.
        case dataBytes(Data)
        /// The current Data/End_Data packet is complete.
        case dataPacketEnded(type: PTPIPPacketType)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A control packet claimed more than `maxControlPacketLength` bytes: a framing error, not a real packet.
        case controlPacketTooLong(Int)
    }

    /// Control packets are tens of bytes; anything near this size means the stream is out of step.
    public static let defaultMaxControlPacketLength = 1 << 20

    public let maxControlPacketLength: Int
    private var buffer = Data()
    private var current: (type: PTPIPPacketType, remaining: Int)?

    public init(maxControlPacketLength: Int = defaultMaxControlPacketLength) {
        self.maxControlPacketLength = maxControlPacketLength
    }

    /// Bytes held back waiting for the rest of a header or control packet.
    public var bufferedByteCount: Int { buffer.count }
    /// True while inside a Data/End_Data payload.
    public var isInsideDataPacket: Bool { current != nil }

    /// Feeds bytes read from the socket and returns every event they complete, in order. Throws on a malformed
    /// stream (bad length, unknown packet type); the connection should then be closed.
    public mutating func feed(_ bytes: Data) throws -> [Event] {
        buffer.append(bytes)
        var events: [Event] = []
        var cursor = buffer.startIndex
        defer {
            // Keep only the unconsumed tail (at most one partial header or control packet).
            buffer = cursor == buffer.endIndex ? Data() : Data(buffer[cursor...])
        }

        while cursor < buffer.endIndex {
            if let (type, remaining) = current {
                let n = min(remaining, buffer.endIndex - cursor)
                events.append(.dataBytes(Data(buffer[cursor ..< cursor + n])))
                cursor += n
                if remaining - n == 0 {
                    current = nil
                    events.append(.dataPacketEnded(type: type))
                } else {
                    current = (type, remaining - n)
                }
                continue
            }

            let available = buffer.endIndex - cursor
            guard available >= PTPIP.headerLength else { break }
            var r = PTPReader(buffer[cursor...])
            let length = Int(try r.u32())
            let rawType = try r.u32()
            guard length >= PTPIP.headerLength else { throw PTPDecodingError.badContainerLength(UInt32(length)) }
            guard let type = PTPIPPacketType(rawValue: rawType) else { throw PTPDecodingError.badPacketType(rawType) }

            if type == .data || type == .endData {
                // Header plus the transaction ID, then the payload streams.
                let fixed = PTPIP.headerLength + 4
                guard length >= fixed else { throw PTPDecodingError.badContainerLength(UInt32(length)) }
                guard available >= fixed else { break }
                let tx = try r.u32()
                cursor += fixed
                let payloadLength = length - fixed
                events.append(.dataPacketBegan(type: type, transactionID: tx, payloadLength: payloadLength))
                if payloadLength == 0 {
                    events.append(.dataPacketEnded(type: type))
                } else {
                    current = (type, payloadLength)
                }
                continue
            }

            guard length <= maxControlPacketLength else { throw Failure.controlPacketTooLong(length) }
            guard available >= length else { break }
            let payload = Data(buffer[(cursor + PTPIP.headerLength) ..< (cursor + length)])
            events.append(.packet(PTPIP.Packet(type: type, payload: payload)))
            cursor += length
        }
        return events
    }
}

/// The initiator's view of one PTP/IP transaction on the command channel: after sending Cmd_Request, feed it the
/// decoder's events until `isComplete`. It checks that every packet belongs to this transaction and reports
/// data, events and pings for the caller to act on.
public struct PTPIPTransaction: Sendable {
    public enum Output: Equatable, Sendable {
        /// Start_Data arrived. `totalLength` is nil when the responder said "unknown" (all ones).
        case dataStarted(totalLength: UInt64?)
        /// Data-phase bytes, in order. Write them out; they are not kept.
        case data(Data)
        /// An event that arrived on the command channel (most cameras use the event channel; some don't).
        case event(PTPIP.Event)
        /// The responder pinged; the caller must answer with Pong on the same connection.
        case pingReceived
        /// Cmd_Response: the transaction is complete. Check `response.code`.
        case response(PTPIP.CmdResponse)
    }

    public enum Failure: Error, Equatable, Sendable {
        case transactionMismatch(expected: UInt32, received: UInt32)
        case unexpectedPacket(PTPIPPacketType)
        /// Data or End_Data before Start_Data.
        case dataWithoutStart
        /// A second Start_Data, or data after End_Data.
        case dataPhaseOutOfOrder
        /// The responder cancelled the transaction.
        case cancelledByResponder
        /// Anything other than an event or ping after Cmd_Response.
        case afterCompletion(PTPIPPacketType?)
    }

    public let transactionID: UInt32
    public private(set) var dataStarted = false
    public private(set) var endDataSeen = false
    /// What Start_Data announced; nil before Start_Data or when the responder said "unknown".
    public private(set) var expectedDataLength: UInt64?
    public private(set) var receivedDataLength: UInt64 = 0
    public private(set) var response: PTPIP.CmdResponse?

    public init(transactionID: UInt32) {
        self.transactionID = transactionID
    }

    public var isComplete: Bool { response != nil }

    /// Set when the response arrived and the bytes received differ from what Start_Data announced. Not thrown,
    /// so the spike can log it; the engine should treat it as a failed transfer.
    public var dataLengthMismatch: (expected: UInt64, received: UInt64)? {
        guard isComplete, let expected = expectedDataLength, expected != receivedDataLength else { return nil }
        return (expected, receivedDataLength)
    }

    /// Set when Cmd_Response arrived while the data phase was still open (Start_Data seen, End_Data not). With an
    /// unknown total length this is the only sign of a truncated transfer. Not thrown, so the spike can log it;
    /// the engine should treat it as a failed transfer.
    public var dataPhaseUnterminated: Bool { isComplete && dataStarted && !endDataSeen }

    public mutating func consume(_ event: PTPIPStreamDecoder.Event) throws -> [Output] {
        switch event {
        case .packet(let p):
            return try consume(packet: p)

        case .dataPacketBegan(let type, let tx, _):
            if isComplete { throw Failure.afterCompletion(type) }
            guard dataStarted else { throw Failure.dataWithoutStart }
            guard !endDataSeen else { throw Failure.dataPhaseOutOfOrder }
            try check(tx)
            return []

        case .dataBytes(let bytes):
            if isComplete { throw Failure.afterCompletion(nil) }
            guard dataStarted, !endDataSeen else { throw Failure.dataPhaseOutOfOrder }
            receivedDataLength += UInt64(bytes.count)
            return [.data(bytes)]

        case .dataPacketEnded(let type):
            if type == .endData { endDataSeen = true }
            return []
        }
    }

    private mutating func consume(packet p: PTPIP.Packet) throws -> [Output] {
        switch p.type {
        case .event:
            return [.event(try PTPIP.decodeEvent(p))]
        case .ping:
            return [.pingReceived]
        case .pong:
            return []
        default:
            break
        }
        if isComplete { throw Failure.afterCompletion(p.type) }

        switch p.type {
        case .startData:
            let s = try PTPIP.decodeStartData(p)
            try check(s.transactionID)
            guard !dataStarted else { throw Failure.dataPhaseOutOfOrder }
            dataStarted = true
            expectedDataLength = s.totalLength == UInt64.max ? nil : s.totalLength
            return [.dataStarted(totalLength: expectedDataLength)]
        case .cmdResponse:
            let r = try PTPIP.decodeCmdResponse(p)
            try check(r.transactionID)
            response = r
            return [.response(r)]
        case .cancel:
            throw Failure.cancelledByResponder
        default:
            throw Failure.unexpectedPacket(p.type)
        }
    }

    private func check(_ tx: UInt32) throws {
        guard tx == transactionID else { throw Failure.transactionMismatch(expected: transactionID, received: tx) }
    }
}
