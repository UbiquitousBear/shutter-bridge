import Testing
import Foundation
@testable import PTPKit

@Suite("PTP/IP framing")
struct PTPIPTests {

    @Test("Init_Command_Request layout: GUID, UTF-16LE name with NUL, version 1.0")
    func initCommandRequest() throws {
        let guid = UUID(uuidString: "0D5D3C6E-6F2E-4A29-9F1B-8C2E1D4F5A6B")!
        let p = PTPIP.initCommandRequest(guid: guid, friendlyName: "iPhone")
        let bytes = p.encode()
        // 8 header + 16 guid + (6 + 1) * 2 name + 4 version
        #expect(bytes.count == 8 + 16 + 14 + 4)
        #expect(Array(bytes[4..<8]) == [1, 0, 0, 0])
        #expect(Array(bytes.suffix(4)) == [0, 0, 1, 0])  // 0x00010000 LE
        #expect(bytes[8] == 0x0D && bytes[9] == 0x5D)      // GUID is sent as raw bytes, not little-endian fields
    }

    @Test("Init_Command_Ack decodes connection number, GUID and name")
    func initCommandAck() throws {
        var w = PTPWriter()
        w.u32(3)
        w.bytes(PTPIP.guidBytes(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!))
        w.bytes(PTPIP.utf16z("ILCE-7CM2"))
        w.u32(PTPIP.protocolVersion)
        let ack = try PTPIP.decodeInitCommandAck(PTPIP.Packet(type: .initCommandAck, payload: w.data))
        #expect(ack.connectionNumber == 3)
        #expect(ack.responderName == "ILCE-7CM2")
        #expect(ack.responderGUID.uuidString == "11111111-2222-3333-4444-555555555555")
        #expect(ack.protocolVersion == PTPIP.protocolVersion)
    }

    @Test("Cmd_Request wraps a PTP command with the data-phase flag")
    func cmdRequest() throws {
        let cmd = PTPCommand.getObjectInfo(PTPObjectHandle(rawValue: 0x44), tx: 9)
        let p = PTPIP.cmdRequest(cmd)
        let bytes = p.encode()
        #expect(bytes.count == 8 + 4 + 2 + 4 + 4)
        #expect(Array(bytes[8..<12]) == [1, 0, 0, 0])      // data phase: none / in
        #expect(Array(bytes[12..<14]) == [0x08, 0x10])     // GetObjectInfo
        #expect(Array(bytes[14..<18]) == [9, 0, 0, 0])     // tx
    }

    @Test("Partial packets return nil until the whole frame has arrived")
    func partialDecode() throws {
        let full = PTPIP.cmdRequest(PTPCommand.getStorageIDs(tx: 1)).encode()
        for cut in 0 ..< full.count {
            #expect(try PTPIP.Packet.decode(full.prefix(cut)) == nil)
        }
        let whole = try #require(try PTPIP.Packet.decode(full))
        #expect(whole.consumed == full.count)
        #expect(whole.packet.type == .cmdRequest)
    }

    @Test("Start_Data / Data / End_Data / Cmd_Response decode in order")
    func dataPhase() throws {
        let start = try PTPIP.decodeStartData(PTPIP.startData(transactionID: 5, totalLength: 1 << 33))
        #expect(start.transactionID == 5 && start.totalLength == 1 << 33)

        let end = try PTPIP.decodeDataChunk(PTPIP.endData(transactionID: 5, bytes: Data([1, 2, 3])))
        #expect(end.transactionID == 5 && end.bytes == Data([1, 2, 3]))

        var w = PTPWriter()
        w.u16(PTPResponseCode.ok.rawValue); w.u32(5); w.u32(99)
        let resp = try PTPIP.decodeCmdResponse(PTPIP.Packet(type: .cmdResponse, payload: w.data))
        #expect(resp.code.isOK && resp.transactionID == 5 && resp.parameters == [99])
    }

    @Test("Events decode with their parameters")
    func event() throws {
        var w = PTPWriter()
        w.u16(PTPEventCode.objectAdded.rawValue); w.u32(0); w.u32(0x0000_1234)
        let e = try PTPIP.decodeEvent(PTPIP.Packet(type: .event, payload: w.data))
        #expect(e.code == .objectAdded)
        #expect(e.parameters == [0x1234])
    }

    @Test("Unknown packet types are rejected")
    func unknownType() {
        var w = PTPWriter()
        w.u32(8); w.u32(0xFF)
        #expect(throws: PTPDecodingError.self) { try PTPIP.Packet.decode(w.data) }
    }
}
