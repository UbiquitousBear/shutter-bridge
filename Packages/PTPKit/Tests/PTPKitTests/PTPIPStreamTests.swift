import Testing
import Foundation
@testable import PTPKit

/// Deterministic generator so "random" chunkings are reproducible in CI.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("PTP/IP stream decoding and transactions")
struct PTPIPStreamTests {

    /// A GetObject reply as a responder would send it: Start_Data, Data packets, End_Data, Cmd_Response, with an
    /// event and a ping interleaved before the response.
    static func getObjectReply(tx: UInt32, payload: Data, packetSize: Int) -> Data {
        var packets = PTPIP.dataPhase(transactionID: tx, payload: payload, packetSize: packetSize)
        packets.insert(PTPIP.event(.objectAdded, parameters: [0x55]), at: 1)
        packets.insert(PTPIP.ping(), at: 2)
        packets.append(PTPIP.cmdResponse(.ok, transactionID: tx))
        return packets.reduce(into: Data()) { $0.append($1.encode()) }
    }

    static func payload(_ n: Int) -> Data { Data((0 ..< n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    /// Runs `stream` through a decoder in the given pieces and one transaction; returns the reassembled data and
    /// every non-data output.
    static func run(_ stream: Data, tx: UInt32, pieces: [Int]) throws -> (data: Data, others: [PTPIPTransaction.Output], transaction: PTPIPTransaction) {
        var decoder = PTPIPStreamDecoder()
        var transaction = PTPIPTransaction(transactionID: tx)
        var data = Data()
        var others: [PTPIPTransaction.Output] = []
        var offset = 0
        for size in pieces where offset < stream.count {
            let end = min(stream.count, offset + size)
            for e in try decoder.feed(stream.subdata(in: offset ..< end)) {
                for o in try transaction.consume(e) {
                    if case .data(let d) = o { data.append(d) } else { others.append(o) }
                }
            }
            offset = end
        }
        #expect(offset == stream.count)
        #expect(decoder.bufferedByteCount == 0)
        #expect(!decoder.isInsideDataPacket)
        return (data, others, transaction)
    }

    @Test("Whole reply in one read")
    func oneRead() throws {
        let body = Self.payload(200_000)
        let stream = Self.getObjectReply(tx: 9, payload: body, packetSize: 65_536)
        let r = try Self.run(stream, tx: 9, pieces: [stream.count])
        #expect(r.data == body)
        #expect(r.transaction.isComplete)
        #expect(r.transaction.receivedDataLength == 200_000)
        #expect(r.transaction.dataLengthMismatch == nil)
        #expect(r.others.first == .dataStarted(totalLength: 200_000))
        #expect(r.others.contains(.pingReceived))
        #expect(r.others.contains(.event(PTPIP.Event(code: .objectAdded, transactionID: 0, parameters: [0x55]))))
        #expect(r.others.last == .response(PTPIP.CmdResponse(code: .ok, transactionID: 9, parameters: [])))
    }

    @Test("Split at every byte boundary of a small reply")
    func everyBoundary() throws {
        let body = Self.payload(100)
        let stream = Self.getObjectReply(tx: 3, payload: body, packetSize: 33)
        for cut in 1 ..< stream.count {
            let r = try Self.run(stream, tx: 3, pieces: [cut, stream.count])
            #expect(r.data == body, "cut at \(cut)")
            #expect(r.transaction.isComplete, "cut at \(cut)")
        }
        // One byte at a time.
        let r = try Self.run(stream, tx: 3, pieces: Array(repeating: 1, count: stream.count))
        #expect(r.data == body)
    }

    @Test("Seeded random read sizes over a 5 MB reply")
    func randomReads() throws {
        let body = Self.payload(5_000_000)
        let stream = Self.getObjectReply(tx: 77, payload: body, packetSize: 1 << 20)
        var rng = SeededGenerator(seed: 15740)
        for _ in 0 ..< 5 {
            var pieces: [Int] = []
            var total = 0
            while total < stream.count {
                let n = Int.random(in: 1 ... 300_000, using: &rng)
                pieces.append(n)
                total += n
            }
            let r = try Self.run(stream, tx: 77, pieces: pieces)
            #expect(r.data == body)
        }
    }

    @Test("Data never accumulates in the decoder: buffered bytes stay below one header")
    func boundedMemory() throws {
        let body = Self.payload(3_000_000)
        let stream = PTPIP.dataPhase(transactionID: 1, payload: body, packetSize: 3_000_000)
            .reduce(into: Data()) { $0.append($1.encode()) }
        var decoder = PTPIPStreamDecoder()
        var offset = 0
        var peak = 0
        while offset < stream.count {
            let end = min(stream.count, offset + 65_536)
            _ = try decoder.feed(stream.subdata(in: offset ..< end))
            peak = max(peak, decoder.bufferedByteCount)
            offset = end
        }
        #expect(peak < PTPIP.headerLength + 4 + 26) // at most a partial header or a Start_Data
    }

    @Test("No data phase: OpenSession → Cmd_Response only")
    func noDataPhase() throws {
        let stream = PTPIP.cmdResponse(.ok, transactionID: 0).encode()
        let r = try Self.run(stream, tx: 0, pieces: [stream.count])
        #expect(r.data.isEmpty)
        #expect(r.transaction.isComplete)
        #expect(!r.transaction.dataStarted)
    }

    @Test("Unknown total length (all ones) is accepted and not checked")
    func unknownLength() throws {
        var packets = PTPIP.dataPhase(transactionID: 2, payload: Self.payload(10), packetSize: 4)
        packets[0] = PTPIP.startData(transactionID: 2, totalLength: .max)
        packets.append(PTPIP.cmdResponse(.ok, transactionID: 2))
        let stream = packets.reduce(into: Data()) { $0.append($1.encode()) }
        let r = try Self.run(stream, tx: 2, pieces: [stream.count])
        #expect(r.others.first == .dataStarted(totalLength: nil))
        #expect(r.transaction.dataLengthMismatch == nil)
    }

    @Test("A short data phase is reported, not thrown")
    func lengthMismatch() throws {
        var packets = PTPIP.dataPhase(transactionID: 2, payload: Self.payload(10), packetSize: 4)
        packets[0] = PTPIP.startData(transactionID: 2, totalLength: 12)
        packets.append(PTPIP.cmdResponse(.incompleteTransfer, transactionID: 2))
        let stream = packets.reduce(into: Data()) { $0.append($1.encode()) }
        let r = try Self.run(stream, tx: 2, pieces: [7, 7, 7, 1000])
        let mismatch = try #require(r.transaction.dataLengthMismatch)
        #expect(mismatch.expected == 12 && mismatch.received == 10)
        #expect(r.transaction.response?.code == .incompleteTransfer)
    }

    @Test("Packets for another transaction are rejected")
    func wrongTransaction() throws {
        var decoder = PTPIPStreamDecoder()
        var t = PTPIPTransaction(transactionID: 5)
        let events = try decoder.feed(PTPIP.startData(transactionID: 6, totalLength: 1).encode())
        #expect(throws: PTPIPTransaction.Failure.transactionMismatch(expected: 5, received: 6)) {
            for e in events { _ = try t.consume(e) }
        }
    }

    @Test("Data before Start_Data, a second Start_Data, and Cancel are protocol errors")
    func ordering() throws {
        var d = PTPIPStreamDecoder()
        var t = PTPIPTransaction(transactionID: 1)
        let early = try d.feed(PTPIP.data(transactionID: 1, bytes: Data([1])).encode())
        #expect(throws: PTPIPTransaction.Failure.dataWithoutStart) { for e in early { _ = try t.consume(e) } }

        var t2 = PTPIPTransaction(transactionID: 1)
        let start = try d.feed(PTPIP.startData(transactionID: 1, totalLength: 1).encode())
        for e in start { _ = try t2.consume(e) }
        #expect(throws: PTPIPTransaction.Failure.dataPhaseOutOfOrder) { for e in start { _ = try t2.consume(e) } }

        var t3 = PTPIPTransaction(transactionID: 1)
        let cancel = try d.feed(PTPIP.cancel(transactionID: 1).encode())
        #expect(throws: PTPIPTransaction.Failure.cancelledByResponder) { for e in cancel { _ = try t3.consume(e) } }
    }

    @Test("After the response only events and pings are accepted")
    func afterCompletion() throws {
        var d = PTPIPStreamDecoder()
        var t = PTPIPTransaction(transactionID: 4)
        for e in try d.feed(PTPIP.cmdResponse(.ok, transactionID: 4).encode()) { _ = try t.consume(e) }
        for e in try d.feed(PTPIP.event(.objectAdded).encode() + PTPIP.ping().encode()) {
            #expect(throws: Never.self) { _ = try t.consume(e) }
        }
        let late = try d.feed(PTPIP.cmdResponse(.ok, transactionID: 4).encode())
        #expect(throws: PTPIPTransaction.Failure.afterCompletion(.cmdResponse)) { for e in late { _ = try t.consume(e) } }
    }

    @Test("Framing errors: tiny length, unknown type, absurd control packet")
    func framingErrors() {
        var w = PTPWriter(); w.u32(4); w.u32(7)
        var d1 = PTPIPStreamDecoder()
        #expect(throws: PTPDecodingError.badContainerLength(4)) { try d1.feed(w.data) }

        var w2 = PTPWriter(); w2.u32(8); w2.u32(0x99)
        var d2 = PTPIPStreamDecoder()
        #expect(throws: PTPDecodingError.badPacketType(0x99)) { try d2.feed(w2.data) }

        var w3 = PTPWriter(); w3.u32(0x7FFF_FFFF); w3.u32(PTPIPPacketType.cmdResponse.rawValue)
        var d3 = PTPIPStreamDecoder()
        #expect(throws: PTPIPStreamDecoder.Failure.controlPacketTooLong(0x7FFF_FFFF)) { try d3.feed(w3.data) }

        var w4 = PTPWriter(); w4.u32(10); w4.u32(PTPIPPacketType.data.rawValue); w4.u16(0)
        var d4 = PTPIPStreamDecoder()
        #expect(throws: PTPDecodingError.badContainerLength(10)) { try d4.feed(w4.data) }
    }

    @Test("Responder-side encoders round-trip through the initiator decoders")
    func responderRoundTrip() throws {
        let guid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let ack = try PTPIP.decodeInitCommandAck(PTPIP.initCommandAck(connectionNumber: 2, guid: guid, name: "ILCE-7CM2"))
        #expect(ack.connectionNumber == 2 && ack.responderName == "ILCE-7CM2" && ack.responderGUID == guid)

        let req = try PTPIP.decodeInitCommandRequest(PTPIP.initCommandRequest(guid: guid, friendlyName: "iPhone"))
        #expect(req.guid == guid && req.friendlyName == "iPhone" && req.protocolVersion == PTPIP.protocolVersion)

        let cmd = PTPCommand.getPartialObject(PTPObjectHandle(rawValue: 9), offset: 4, length: 8, tx: 12)
        let decoded = try PTPIP.decodeCmdRequest(PTPIP.cmdRequest(cmd))
        #expect(decoded.dataPhase == PTPIP.DataPhase.none.rawValue && decoded.command == cmd)

        #expect(PTPIP.decodeInitFail(PTPIP.initFail(reason: 1)) == 1)
        #expect(PTPIP.InitFailReason.describe(1).contains("rejected"))
        #expect(PTPIP.InitFailReason.describe(0x77) == "reason 0x00000077")
    }
}
