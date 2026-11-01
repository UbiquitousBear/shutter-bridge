import Testing
import Foundation
@testable import PTPKit

@Suite("PTP container")
struct PTPContainerTests {

    @Test("GetPartialObject encodes a 24-byte command with three parameters")
    func getPartialObjectEncoding() throws {
        let c = PTPCommand.getPartialObject(PTPObjectHandle(rawValue: 0x0001_0203), offset: 4 * 1024 * 1024, length: 4 * 1024 * 1024, tx: 7)
        let bytes = c.encode()
        #expect(bytes.count == 24)
        #expect(Array(bytes.prefix(4)) == [0x18, 0, 0, 0])        // length 24
        #expect(Array(bytes[4..<6]) == [0x01, 0x00])              // type command
        #expect(Array(bytes[6..<8]) == [0x1B, 0x10])              // 0x101B
        #expect(Array(bytes[8..<12]) == [0x07, 0, 0, 0])          // tx 7
        #expect(c.parameters == [0x0001_0203, 0x0040_0000, 0x0040_0000])
    }

    @Test("Round trip through encode/decode is identity")
    func roundTrip() throws {
        let original = PTPContainer(type: .response, code: PTPResponseCode.ok.rawValue, transactionID: 42, parameters: [1, 2])
        let (decoded, consumed) = try PTPContainer.decode(original.encode())
        #expect(decoded == original)
        #expect(consumed == 20)
        #expect(decoded.responseCode.isOK)
    }

    @Test("Back-to-back containers decode as a sequence")
    func decodeAll() throws {
        let data = PTPContainer(type: .data, code: 0x1001, transactionID: 1, payload: Data([9, 9, 9]))
        let resp = PTPContainer(type: .response, code: 0x2001, transactionID: 1)
        let all = try PTPContainer.decodeAll(data.encode() + resp.encode())
        #expect(all.count == 2)
        #expect(all[0].payload == Data([9, 9, 9]))
        #expect(all[1].type == .response)
    }

    @Test("A length larger than the buffer is rejected, not read past the end")
    func badLength() {
        var bytes = PTPContainer(type: .command, code: 0x1001, transactionID: 1).encode()
        bytes[0] = 0xFF
        #expect(throws: PTPDecodingError.self) { try PTPContainer.decode(bytes) }
    }

    @Test("Transaction counter starts at 1 and wraps past UInt32.max back to 1")
    func counter() {
        var c = PTPTransactionCounter()
        #expect(c.take() == 1)
        #expect(c.take() == 2)
        #expect(c.peek == 3)

        var w = PTPTransactionCounter(next: .max)
        #expect(w.take() == .max)
        #expect(w.take() == 1, "0 is reserved for OpenSession, so the counter skips it")
        #expect(PTPTransactionCounter(next: 0).peek == 1)
    }

    @Test("Unknown codes still describe themselves in hex")
    func descriptions() {
        #expect(PTPOperationCode.getPartialObject.description == "GetPartialObject")
        #expect(PTPOperationCode(rawValue: 0x9FFF).description == "Op(0x9FFF)")
        #expect(PTPEventCode.objectAdded.description == "ObjectAdded")
        #expect(PTPOperationCode.sonySDIOConnect.description == "Sony SDIO_Connect")
        #expect(PTPObjectFormat.sonyHEIF.description == "Sony HEIF")
    }

    @Test("GetDevicePropValue(BatteryLevel) carries the property code as its only parameter")
    func devicePropValue() {
        let c = PTPCommand.getDevicePropValue(.batteryLevel, tx: 4)
        #expect(c.operationCode == .getDevicePropValue)
        #expect(c.parameters == [0x5001])
        #expect(PTPDevicePropCode.batteryLevel.description == "BatteryLevel")
        #expect(PTPDevicePropCode(rawValue: 0xD20F).description == "Prop(0xD20F)")
    }

    @Test("Sony SDIO builders use libgphoto2's parameter layout")
    func sonySDIO() {
        #expect(PTPCommand.sonySDIOConnect(phase: 2, tx: 3).parameters == [2, 0, 0])
        #expect(PTPCommand.sonySDIOConnect(phase: 2, tx: 3).operationCode == .sonySDIOConnect)
        #expect(PTPCommand.sonySDIOGetExtDeviceInfo(tx: 4).parameters == [0x12C, 1])
        #expect(PTPResponseCode.objectWriteProtected.description == "ObjectWriteProtected")
    }

    @Test("Both the standard and Sony ObjectAdded signal a new object")
    func newObjectEvents() {
        #expect(PTPEventCode.objectAdded.signalsNewObject)
        #expect(PTPEventCode.sonyObjectAdded.signalsNewObject)
        #expect(!PTPEventCode.objectRemoved.signalsNewObject)
        #expect(!PTPEventCode.devicePropChanged.signalsNewObject)
    }
}
