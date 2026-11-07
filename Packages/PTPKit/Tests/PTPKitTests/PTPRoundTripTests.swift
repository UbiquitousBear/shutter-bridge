// Seeded randomised round trips for every encoder/decoder pair in PTPKit (backlog §1). Generators and the
// determinism rules are in SeededRandom.swift. Every test builds iteration i's generator from a literal base
// seed, so a failure names "seed 0x… iteration N" and replays with
// `SplitMix64.iteration(N, of: seed)`.
//
// Lossy by design, and how the tests treat it:
//   - PTPWriter.string writes at most 255 UTF-16 units (the count byte's limit, NUL included). Identity tests
//     use at most 254 units and no U+0000; `stringTruncation` pins what happens beyond that.
//   - PTP/IP names are NUL-terminated, so the generator never emits U+0000.
//   - MTPObjectPropList.encode writes each value as its element's datatype says, so identity holds only for
//     well-typed values; for any value, one encode/decode pass normalises (`mtpNormalises`).
//   - PTPContainer.parameters ignores a trailing partial word; parameters are compared only for containers
//     built from parameters, and payload identity is always exact.
//   - Not paired with a decoder, so covered only as random packet types: initEventRequest, initEventAck,
//     cancel, ping, pong.

import Testing
import Foundation
@testable import PTPKit

private func seedTag(_ seed: UInt64, _ i: Int) -> Comment {
    Comment(rawValue: "seed 0x\(String(seed, radix: 16, uppercase: true)) iteration \(i)")
}

private func sameText(_ a: String, _ b: String) -> Bool { Array(a.utf16) == Array(b.utf16) }

@Suite("Seeded round trips")
struct PTPRoundTripTests {

    // MARK: Generator

    @Test("SplitMix64 is the reference generator and is reproducible")
    func generator() {
        var ref = SplitMix64(seed: 0)
        #expect(ref.next() == 0xE220_A839_7B1D_CDAF)
        #expect(ref.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(ref.next() == 0x06C4_5D18_8009_454F)

        var a = SplitMix64(seed: 0x5EED), b = SplitMix64(seed: 0x5EED)
        for _ in 0 ..< 100 { #expect(a.next() == b.next()) }

        var g = SplitMix64(seed: 1)
        #expect(g.below(1) == 0)
        #expect(g.below(0) == 0)
        for n: UInt64 in [2, 3, 7, 1000, UInt64.max] {
            for _ in 0 ..< 1000 { #expect(g.below(n) < n) }
        }

        var i0 = SplitMix64.iteration(0, of: 1), i1 = SplitMix64.iteration(1, of: 1)
        #expect(i0.next() != i1.next())
    }

    // MARK: Primitives and strings

    private enum Op {
        case u8(UInt8), u16(UInt16), u32(UInt32), u64(UInt64)
        case bytes(Data), u16Array([UInt16]), u32Array([UInt32]), string(String)
    }

    @Test("Reader/writer primitives read back what was written")
    func primitives() throws {
        let seed: UInt64 = 0xA001
        for i in 0 ..< 500 {
            var g = SplitMix64.iteration(i, of: seed)
            var ops: [Op] = []
            for _ in 0 ..< g.int(1 ... 64) {
                switch g.below(8) {
                case 0: ops.append(.u8(g.u8()))
                case 1: ops.append(.u16(g.u16()))
                case 2: ops.append(.u32(g.u32()))
                case 3: ops.append(.u64(g.u64()))
                case 4: ops.append(.bytes(g.bytes(g.int(0 ... 32))))
                case 5: ops.append(.u16Array((0 ..< g.int(0 ... 16)).map { _ in g.u16() }))
                case 6: ops.append(.u32Array((0 ..< g.int(0 ... 16)).map { _ in g.u32() }))
                default: ops.append(.string(g.ptpString()))
                }
            }
            var w = PTPWriter()
            for op in ops {
                switch op {
                case .u8(let v): w.u8(v)
                case .u16(let v): w.u16(v)
                case .u32(let v): w.u32(v)
                case .u64(let v): w.u64(v)
                case .bytes(let v): w.bytes(v)
                case .u16Array(let v): w.u16Array(v)
                case .u32Array(let v): w.u32Array(v)
                case .string(let v): w.string(v)
                }
            }
            var r = PTPReader(w.data)
            for op in ops {
                switch op {
                case .u8(let v): try #require(try r.u8() == v, seedTag(seed, i))
                case .u16(let v): try #require(try r.u16() == v, seedTag(seed, i))
                case .u32(let v): try #require(try r.u32() == v, seedTag(seed, i))
                case .u64(let v): try #require(try r.u64() == v, seedTag(seed, i))
                case .bytes(let v): try #require(try r.bytes(v.count) == v, seedTag(seed, i))
                case .u16Array(let v): try #require(try r.u16Array() == v, seedTag(seed, i))
                case .u32Array(let v): try #require(try r.u32Array() == v, seedTag(seed, i))
                case .string(let v): try #require(sameText(try r.string(), v), seedTag(seed, i))
                }
            }
            try #require(r.isAtEnd, seedTag(seed, i))
        }
    }

    @Test("PTP strings up to 254 UTF-16 units round-trip exactly")
    func strings() throws {
        let seed: UInt64 = 0xA002
        for i in 0 ..< 1000 {
            var g = SplitMix64.iteration(i, of: seed)
            let s = g.ptpString()
            var w = PTPWriter()
            w.string(s)
            let units = s.utf16.count
            try #require(w.data.count == (s.isEmpty ? 1 : 1 + 2 * (units + 1)), seedTag(seed, i))
            var r = PTPReader(w.data)
            let back = try r.string()
            try #require(Array(back.utf16) == Array(s.utf16), seedTag(seed, i))
            try #require(r.isAtEnd, seedTag(seed, i))
        }
        for s in [String(repeating: "a", count: 254), String(repeating: "\u{1F4F7}", count: 127)] {
            #expect(s.utf16.count == 254)
            var w = PTPWriter()
            w.string(s)
            #expect(w.data.count == 1 + 2 * 255)
            var r = PTPReader(w.data)
            #expect(Array(try r.string().utf16) == Array(s.utf16))
            #expect(r.isAtEnd)
        }
    }

    @Test("PTP strings past the limit are cut to 255 units, never trap")
    func stringTruncation() throws {
        let seed: UInt64 = 0xA003
        for i in 0 ..< 200 {
            var g = SplitMix64.iteration(i, of: seed)
            let bmp = g.longString(atLeastUnits: g.int(255 ... 600), bmpOnly: true)
            var w = PTPWriter()
            w.string(bmp)
            try #require(w.data.count == 511, seedTag(seed, i))
            var r = PTPReader(w.data)
            let back = try r.string()
            try #require(Array(back.utf16) == Array(bmp.utf16.prefix(255)), seedTag(seed, i))
            var again = PTPWriter()
            again.string(back)
            try #require(again.data == w.data, seedTag(seed, i))

            let mixed = g.longString(atLeastUnits: g.int(255 ... 600), bmpOnly: false)
            var w2 = PTPWriter()
            w2.string(mixed)
            var r2 = PTPReader(w2.data)
            let back2 = try r2.string()
            try #require(back2.utf16.count <= 255, seedTag(seed, i))
            try #require(Array(back2.utf16.prefix(254)) == Array(mixed.utf16.prefix(254)), seedTag(seed, i))
        }

        // A 255-unit string is written with no NUL and still decodes whole; a 255-unit string ending in U+0000
        // loses its last unit (the NUL is the string's own, indistinguishable from the terminator).
        let full = String(repeating: "x", count: 255)
        var w = PTPWriter()
        w.string(full)
        #expect(w.data.count == 511)
        var r = PTPReader(w.data)
        #expect(try r.string() == full)
        let nulEnded = String(repeating: "x", count: 254) + "\u{0}"
        var w2 = PTPWriter()
        w2.string(nulEnded)
        var r2 = PTPReader(w2.data)
        #expect(try r2.string() == String(repeating: "x", count: 254))
    }

    @Test("Truncating a long string never leaves half a surrogate pair on the wire")
    func stringTruncationKeepsPairsWhole() throws {
        // 254 ASCII units, then astral scalars: the 255th unit is the high half of the first pair.
        let s = String(repeating: "a", count: 254) + "\u{1F4F7}" + "tail"
        #expect(s.utf16.count > 255)
        var w = PTPWriter()
        w.string(s)
        var r = PTPReader(w.data)
        _ = try r.u8()
        var units: [UInt16] = []
        while !r.isAtEnd { units.append(try r.u16()) }
        // Every high surrogate must be followed by a low one, and every low one preceded by a high one.
        var i = 0
        while i < units.count {
            let u = units[i]
            if (0xD800 ... 0xDBFF).contains(u) {
                #expect(i + 1 < units.count && (0xDC00 ... 0xDFFF).contains(units[i + 1]))
                i += 2
            } else {
                #expect(!(0xDC00 ... 0xDFFF).contains(u))
                i += 1
            }
        }
        var back = PTPReader(w.data)
        let decoded = try back.string()
        #expect(Array(decoded.utf16.prefix(254)) == Array(s.utf16.prefix(254)))
        #expect(!decoded.unicodeScalars.contains("\u{FFFD}"))
    }

    // MARK: Containers

    @Test("Containers of every type round-trip, with trailing bytes and on a slice")
    func containers() throws {
        let seed: UInt64 = 0xA004
        for i in 0 ..< 1000 {
            var g = SplitMix64.iteration(i, of: seed)
            let (c, params) = g.container()
            let e = c.encode()
            try #require(e.count == 12 + c.payload.count, seedTag(seed, i))
            try #require(Array(e.prefix(4)) == (0 ..< 4).map { UInt8(truncatingIfNeeded: UInt32(e.count) >> UInt32(8 * $0)) }, seedTag(seed, i))

            let (d, used) = try PTPContainer.decode(e)
            try #require(d == c && used == e.count, seedTag(seed, i))
            if let params { try #require(d.parameters == params, seedTag(seed, i)) }

            let (d2, used2) = try PTPContainer.decode(e + g.bytes(g.int(1 ... 16)))
            try #require(d2 == c && used2 == e.count, seedTag(seed, i))

            let junk = g.bytes(g.int(1 ... 16))
            let (d3, used3) = try PTPContainer.decode((junk + e).dropFirst(junk.count))
            try #require(d3 == c && used3 == e.count, seedTag(seed, i))
        }
    }

    @Test("Container sequences decode back to the list")
    func containerSequences() throws {
        let seed: UInt64 = 0xA005
        #expect(try PTPContainer.decodeAll(Data()) == [])
        for i in 0 ..< 300 {
            var g = SplitMix64.iteration(i, of: seed)
            let list = (0 ..< g.int(0 ... 8)).map { _ in g.container().container }
            let joined = list.reduce(into: Data()) { $0.append($1.encode()) }
            try #require(try PTPContainer.decodeAll(joined) == list, seedTag(seed, i))
            let junk = g.bytes(g.int(1 ... 16))
            try #require(try PTPContainer.decodeAll((junk + joined).dropFirst(junk.count)) == list, seedTag(seed, i))
        }
    }

    // MARK: Datasets

    @Test("DeviceInfo round-trips")
    func deviceInfo() throws {
        let seed: UInt64 = 0xA006
        for i in 0 ..< 300 {
            var g = SplitMix64.iteration(i, of: seed)
            let x = g.deviceInfo()
            let back = try PTPDeviceInfo.decode(x.encode())
            try #require(back == x, seedTag(seed, i))
            try #require([x.vendorExtensionDescription, x.manufacturer, x.model, x.deviceVersion, x.serialNumber].map { Array($0.utf16) }
                         == [back.vendorExtensionDescription, back.manufacturer, back.model, back.deviceVersion, back.serialNumber].map { Array($0.utf16) },
                         seedTag(seed, i))
            try #require(x.encode() == back.encode(), seedTag(seed, i))
        }
    }

    @Test("StorageInfo round-trips")
    func storageInfo() throws {
        let seed: UInt64 = 0xA007
        for i in 0 ..< 500 {
            var g = SplitMix64.iteration(i, of: seed)
            let x = g.storageInfo()
            let back = try PTPStorageInfo.decode(x.encode())
            try #require(back == x, seedTag(seed, i))
            try #require(sameText(back.storageDescription, x.storageDescription) && sameText(back.volumeLabel, x.volumeLabel), seedTag(seed, i))
            try #require(x.encode() == back.encode(), seedTag(seed, i))
        }
    }

    @Test("ObjectInfo round-trips, including the 0xFFFFFFFF size marker")
    func objectInfo() throws {
        let seed: UInt64 = 0xA008
        for i in 0 ..< 500 {
            var g = SplitMix64.iteration(i, of: seed)
            let x = g.objectInfo()
            let back = try PTPObjectInfo.decode(x.encode())
            try #require(back == x, seedTag(seed, i))
            try #require(sameText(back.filename, x.filename) && sameText(back.captureDateRaw, x.captureDateRaw)
                         && sameText(back.modificationDateRaw, x.modificationDateRaw) && sameText(back.keywords, x.keywords),
                         seedTag(seed, i))
            try #require(x.encode() == back.encode(), seedTag(seed, i))
        }
        var g = SplitMix64.iteration(0, of: seed)
        var marker = g.objectInfo()
        marker.objectCompressedSize = 0xFFFF_FFFF
        #expect(try PTPObjectInfo.decode(marker.encode()).sizeExceeds32Bits)
    }

    @Test("Storage ID and object handle arrays round-trip")
    func arrays() throws {
        let seed: UInt64 = 0xA009
        let handleSeed: UInt64 = 0xA109
        for i in 0 ..< 300 {
            var g = SplitMix64.iteration(i, of: seed)
            let n = i == 0 ? 4096 : g.int(0 ... 512)
            let ids = (0 ..< n).map { _ in PTPStorageID(rawValue: g.u32()) }
            let idData = PTPStorageID.encodeArray(ids)
            try #require(idData.count == 4 + 4 * n, seedTag(seed, i))
            try #require(try PTPStorageID.decodeArray(idData) == ids, seedTag(seed, i))

            var h = SplitMix64.iteration(i, of: handleSeed)
            let m = i == 0 ? 4096 : h.int(0 ... 512)
            let handles = (0 ..< m).map { _ in PTPObjectHandle(rawValue: h.u32()) }
            let hData = PTPObjectHandle.encodeArray(handles)
            try #require(hData.count == 4 + 4 * m, seedTag(handleSeed, i))
            try #require(try PTPObjectHandle.decodeArray(hData) == handles, seedTag(handleSeed, i))
        }
    }

    // MARK: PTP/IP

    /// Sends a packet over the wire format and back, so every decoder below is fed what a socket would deliver.
    private func overTheWire(_ p: PTPIP.Packet, _ comment: Comment) throws -> PTPIP.Packet {
        let e = p.encode()
        let (back, used) = try #require(try PTPIP.Packet.decode(e), comment)
        try #require(back == p && used == e.count, comment)
        return back
    }

    @Test("PTP/IP packets of every type round-trip; a partial packet is nil")
    func ptpipPackets() throws {
        let seed: UInt64 = 0xA00A
        for i in 0 ..< 1000 {
            var g = SplitMix64.iteration(i, of: seed)
            let p = PTPIP.Packet(type: PTPIPPacketType(rawValue: UInt32(g.int(1 ... 14)))!, payload: g.bytes(g.length(512)))
            let e = p.encode()
            let (d, used) = try #require(try PTPIP.Packet.decode(e), seedTag(seed, i))
            try #require(d == p && used == e.count, seedTag(seed, i))

            let (d2, used2) = try #require(try PTPIP.Packet.decode(e + g.bytes(g.int(1 ... 16))), seedTag(seed, i))
            try #require(d2 == p && used2 == e.count, seedTag(seed, i))

            var cuts = [0, 7, e.count - 1]
            for _ in 0 ..< 4 { cuts.append(g.int(0 ... e.count - 1)) }
            for cut in cuts {
                try #require(try PTPIP.Packet.decode(e.prefix(cut)) == nil, seedTag(seed, i))
            }
        }
    }

    @Test("PTP/IP handshake packets round-trip")
    func ptpipHandshake() throws {
        let seed: UInt64 = 0xA00B
        for i in 0 ..< 300 {
            var g = SplitMix64.iteration(i, of: seed)
            let c = seedTag(seed, i)

            let guid = g.uuid(), name = g.utf16zName()
            let req = try PTPIP.decodeInitCommandRequest(try overTheWire(PTPIP.initCommandRequest(guid: guid, friendlyName: name), c))
            try #require(req.guid == guid && sameText(req.friendlyName, name) && req.protocolVersion == PTPIP.protocolVersion, c)

            let conn = g.u32(), rguid = g.uuid(), rname = g.utf16zName(), version = g.u32()
            let ack = try PTPIP.decodeInitCommandAck(try overTheWire(PTPIP.initCommandAck(connectionNumber: conn, guid: rguid, name: rname, version: version), c))
            try #require(ack == PTPIP.InitCommandAck(connectionNumber: conn, responderGUID: rguid, responderName: rname, protocolVersion: version), c)
            try #require(sameText(ack.responderName, rname), c)

            let reason = g.u32()
            try #require(PTPIP.decodeInitFail(try overTheWire(PTPIP.initFail(reason: reason), c)) == reason, c)
        }
    }

    @Test("PTP/IP operation packets round-trip")
    func ptpipOperations() throws {
        let seed: UInt64 = 0xA00C
        for i in 0 ..< 1000 {
            var g = SplitMix64.iteration(i, of: seed)
            let c = seedTag(seed, i)

            let (command, _) = g.commandContainer()
            let phase = g.element([PTPIP.DataPhase.none, .initiatorToResponder])
            let req = try PTPIP.decodeCmdRequest(try overTheWire(PTPIP.cmdRequest(command, dataPhase: phase), c))
            try #require(req.dataPhase == phase.rawValue && req.command == command, c)

            let rcode = PTPResponseCode(rawValue: g.u16()), rtx = g.u32(), rparams = g.parameters(0 ... 5)
            let resp = try PTPIP.decodeCmdResponse(try overTheWire(PTPIP.cmdResponse(rcode, transactionID: rtx, parameters: rparams), c))
            try #require(resp == PTPIP.CmdResponse(code: rcode, transactionID: rtx, parameters: rparams), c)

            let ecode = PTPEventCode(rawValue: g.u16()), etx = g.u32(), eparams = g.parameters(0 ... 3)
            let ev = try PTPIP.decodeEvent(try overTheWire(PTPIP.event(ecode, transactionID: etx, parameters: eparams), c))
            try #require(ev == PTPIP.Event(code: ecode, transactionID: etx, parameters: eparams), c)

            let stx = g.u32(), total = g.u64()
            let start = try PTPIP.decodeStartData(try overTheWire(PTPIP.startData(transactionID: stx, totalLength: total), c))
            try #require(start == PTPIP.StartData(transactionID: stx, totalLength: total), c)

            let dtx = g.u32(), chunk = g.bytes(g.length(512))
            let d = try PTPIP.decodeDataChunk(try overTheWire(PTPIP.data(transactionID: dtx, bytes: chunk), c))
            try #require(d.transactionID == dtx && d.bytes == chunk, c)
            let etxn = g.u32(), tail = g.bytes(g.length(512))
            let end = try PTPIP.decodeDataChunk(try overTheWire(PTPIP.endData(transactionID: etxn, bytes: tail), c))
            try #require(end.transactionID == etxn && end.bytes == tail, c)
        }
    }

    @Test("A data phase reassembles through the stream decoder and transaction")
    func dataPhaseReassembly() throws {
        let seed: UInt64 = 0xA00D
        for i in 0 ..< 200 {
            var g = SplitMix64.iteration(i, of: seed)
            let c = seedTag(seed, i)
            let payload = g.bytes(g.length(16_384))
            let packetSize = max(g.int(1 ... 8192), payload.count / 512 + 1)
            let tx = g.u32()

            var stream = Data()
            for p in PTPIP.dataPhase(transactionID: tx, payload: payload, packetSize: packetSize) { stream.append(p.encode()) }
            stream.append(PTPIP.cmdResponse(.ok, transactionID: tx).encode())

            var decoder = PTPIPStreamDecoder()
            var transaction = PTPIPTransaction(transactionID: tx)
            var reassembled = Data()
            var offset = 0
            while offset < stream.count {
                let n = min(g.int(1 ... 4096), stream.count - offset)
                for event in try decoder.feed(stream.subdata(in: offset ..< offset + n)) {
                    for case .data(let bytes) in try transaction.consume(event) { reassembled.append(bytes) }
                }
                offset += n
            }
            try #require(reassembled == payload, c)
            try #require(transaction.isComplete && transaction.dataLengthMismatch == nil && !transaction.dataPhaseUnterminated, c)
            try #require(decoder.bufferedByteCount == 0 && !decoder.isInsideDataPacket, c)
        }
    }

    // MARK: Date and time

    @Test("PTP DateTime strings parse to the instant they name")
    func dateTimes() throws {
        let seed: UInt64 = 0xA00E
        let utc = TimeZone(secondsFromGMT: 0)!
        for i in 0 ..< 1000 {
            var g = SplitMix64.iteration(i, of: seed)
            let (text, expected) = g.ptpDateTimeString()
            let parsed = try #require(PTPDateTime.parse(text, defaultTimeZone: utc), Comment(rawValue: "\(text): \(seedTag(seed, i))"))
            try #require(abs(parsed.timeIntervalSince1970 - expected) < 0.001, Comment(rawValue: "\(text): \(seedTag(seed, i))"))
        }
    }

    // MARK: MTP

    private func isScalarCanonical(_ v: MTPValue, size: Int, signed: Bool) -> Bool {
        if size == 16 {
            switch v {
            case .int128(let d): return signed && d.count == 16
            case .uint128(let d): return !signed && d.count == 16
            default: return false
            }
        }
        switch v {
        case .int(let x):
            guard signed else { return false }
            if size == 8 { return true }
            let limit = Int64(1) << Int64(8 * size - 1)
            return x >= -limit && x < limit
        case .uint(let x):
            guard !signed else { return false }
            return size == 8 || x < UInt64(1) << UInt64(8 * size)
        default:
            return false
        }
    }

    private func isCanonical(_ v: MTPValue, _ type: MTPDataType) -> Bool {
        if type == .string {
            if case .string = v { return true }
            return false
        }
        guard let size = type.elementSize else { return false }
        if type.isArray {
            guard case .array(let items) = v else { return false }
            return items.allSatisfy { isScalarCanonical($0, size: size, signed: type.isSigned) }
        }
        return isScalarCanonical(v, size: size, signed: type.isSigned)
    }

    @Test("Well-typed MTP property lists round-trip exactly")
    func mtpWellTyped() throws {
        let seed: UInt64 = 0xA00F
        for i in 0 ..< 300 {
            var g = SplitMix64.iteration(i, of: seed)
            var elements: [MTPObjectPropElement] = []
            for _ in 0 ..< g.int(0 ... 64) {
                let handle = PTPObjectHandle(rawValue: g.u32())
                let property = MTPObjectPropertyCode(rawValue: g.u16())
                let type = g.mtpType()
                elements.append(MTPObjectPropElement(handle: handle, property: property, dataType: type, value: g.wellTypedValue(for: type)))
            }
            let list = MTPObjectPropList(elements: elements)
            let e = list.encode()
            let back = try MTPObjectPropList.decode(e)
            try #require(back == list, seedTag(seed, i))
            try #require(back.encode() == e, seedTag(seed, i))
        }
    }

    @Test("Any MTP property list normalises in one pass, never traps")
    func mtpNormalises() throws {
        let seed: UInt64 = 0xA010
        for i in 0 ..< 300 {
            var g = SplitMix64.iteration(i, of: seed)
            var elements: [MTPObjectPropElement] = []
            for _ in 0 ..< g.int(0 ... 32) {
                elements.append(MTPObjectPropElement(handle: PTPObjectHandle(rawValue: g.u32()),
                                                     property: MTPObjectPropertyCode(rawValue: g.u16()),
                                                     dataType: g.mtpType(), value: g.anyValue()))
            }
            let list = MTPObjectPropList(elements: elements)
            let e = list.encode()
            let d = try MTPObjectPropList.decode(e)
            try #require(d.encode() == e, seedTag(seed, i))
            try #require(d.elements.count == list.elements.count, seedTag(seed, i))
            for (a, b) in zip(list.elements, d.elements) {
                try #require(a.handle == b.handle && a.property == b.property && a.dataType == b.dataType, seedTag(seed, i))
                try #require(isCanonical(b.value, b.dataType), seedTag(seed, i))
            }
        }
    }

    // MARK: Composed decoders

    @Test("Pass-through replies decode in every layout")
    func passThroughLayouts() throws {
        let seed: UInt64 = 0xA011
        for i in 0 ..< 300 {
            var g = SplitMix64.iteration(i, of: seed)
            let c = seedTag(seed, i)
            let (command, _) = g.commandContainer()
            let payload = g.bytes(g.int(13 ... 512))
            let tx = g.chance(2) ? command.transactionID : g.u32()
            let response = PTPContainer(type: .response, code: g.u16(), transactionID: tx, parameters: g.parameters(0 ... 5))
            let dc = PTPContainer(type: .data, code: command.code,
                                  transactionID: g.element([command.transactionID, response.transactionID]),
                                  payload: payload).encode()
            let resp = response.encode()

            func check(_ first: Data, _ second: Data, _ layout: PTPPassThrough.Layout) throws {
                let reply = try PTPPassThrough.decodeReply(first, second, for: command)
                try #require(reply.response == response && reply.data == payload && reply.layout == layout, c)
            }
            try check(payload, resp, .dataThenResponse)
            try check(resp, payload, .responseThenData)
            try check(dc, resp, .dataContainerThenResponse)
            try check(resp, dc, .responseThenDataContainer)
            // The split falls inside the 12-byte header, so neither half can look like a lone response container.
            let split = g.int(1 ... 11)
            try check(dc.prefix(split), dc.dropFirst(split) + resp, .concatenatedContainers)
        }
    }

    @Test("Partial-read commands carry the chunk back out")
    func partialReadCommands() throws {
        let seed: UInt64 = 0xA012
        let variants: [PTPPartialRead.Variant] = [.standard32, .extended64, .sony64, .sonyLarge9211, .sonyLarge9219]
        for i in 0 ..< 500 {
            var g = SplitMix64.iteration(i, of: seed)
            let c = seedTag(seed, i)
            for variant in variants {
                let handle = PTPObjectHandle(rawValue: g.u32())
                let offset = g.u64(), length = g.u32(), tx = g.u32()
                let chunk = PTPPartialRead.Chunk(offset: offset, length: length)
                let lo = UInt32(offset & 0xFFFF_FFFF), hi = UInt32(offset >> 32)

                if variant == .standard32 {
                    // Computed here with a guard rather than from `chunk.end`, so the oracle is independent of it.
                    let tooFar = offset > UInt64(UInt32.max) || (length > 0 && offset + UInt64(length) - 1 > UInt64(UInt32.max))
                    if tooFar {
                        try #require(throws: PTPPartialRead.PlanError.beyond32BitOffset(chunk)) {
                            _ = try PTPPartialRead.command(handle, chunk: chunk, variant: variant, tx: tx)
                        }
                        continue
                    }
                }
                let cmd = try PTPPartialRead.command(handle, chunk: chunk, variant: variant, tx: tx)
                let expected: [UInt32]
                switch variant {
                case .standard32: expected = [handle.rawValue, lo, length]
                case .extended64, .sony64: expected = [handle.rawValue, lo, hi, length]
                case .sonyLarge9211, .sonyLarge9219: expected = [handle.rawValue, lo, hi, length, 0]
                }
                try #require(cmd.type == .command && cmd.parameters == expected, c)
                try #require(cmd.code == PTPPartialRead.operationCode(for: variant).rawValue && cmd.transactionID == tx, c)
            }
        }
    }

    @Test("A chunk at the top of the address space has a saturated end, not a trap")
    func chunkEndSaturates() {
        // Found by partialReadCommands: offset near UInt64.max made `end` (and so `description`, which error
        // values and test output call) overflow.
        let top = PTPPartialRead.Chunk(offset: UInt64.max, length: 5)
        #expect(top.end == UInt64.max)
        #expect(top.description == "[\(UInt64.max), \(UInt64.max))")
        #expect(PTPPartialRead.Chunk(offset: UInt64.max - 4, length: 5).end == UInt64.max)
        #expect(PTPPartialRead.Chunk(offset: 10, length: 5).end == 15)
    }

    // MARK: Codable

    @Test("Object identity and media kind survive JSON")
    func codable() throws {
        let seed: UInt64 = 0xA013
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for i in 0 ..< 200 {
            var g = SplitMix64.iteration(i, of: seed)
            let id = PTPObjectIdentity(cameraSerial: g.ptpString(), filename: g.ptpString(), captureDateRaw: g.ptpString(), size: g.u64())
            let back = try decoder.decode(PTPObjectIdentity.self, from: encoder.encode(id))
            try #require(back == id && back.size == id.size, seedTag(seed, i))
            try #require(sameText(back.cameraSerial, id.cameraSerial) && sameText(back.filename, id.filename)
                         && sameText(back.captureDateRaw, id.captureDateRaw), seedTag(seed, i))
        }
        let big = PTPObjectIdentity(cameraSerial: "s", filename: "f", captureDateRaw: "d", size: UInt64.max)
        #expect(try decoder.decode(PTPObjectIdentity.self, from: encoder.encode(big)).size == UInt64.max)
        for kind in PTPMediaKind.allCases {
            #expect(try decoder.decode(PTPMediaKind.self, from: encoder.encode(kind)) == kind)
        }
    }
}
