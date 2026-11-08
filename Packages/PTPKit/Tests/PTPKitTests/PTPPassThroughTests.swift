import Testing
import Foundation
@testable import PTPKit

@Suite("ImageCaptureCore pass-through replies")
struct PTPPassThroughTests {
    static let command = PTPCommand.getDeviceInfo(tx: 7)
    static let payload = PTPDatasetTests.syntheticSonyDeviceInfo.encode()
    static let ok = PTPContainer(type: .response, code: PTPResponseCode.ok.rawValue, transactionID: 7)
    static let dataContainer = PTPContainer(type: .data, code: PTPOperationCode.getDeviceInfo.rawValue, transactionID: 7, payload: payload)

    @Test("(payload, response) — the reading the Objective-C parameter names suggest")
    func dataThenResponse() throws {
        let reply = try PTPPassThrough.decodeReply(Self.payload, Self.ok.encode(), for: Self.command)
        #expect(reply.layout == .dataThenResponse)
        #expect(reply.responseCode.isOK)
        #expect(reply.data == Self.payload)
        #expect(try PTPDeviceInfo.decode(reply.data) == PTPDatasetTests.syntheticSonyDeviceInfo)
    }

    @Test("(response, payload)")
    func responseThenData() throws {
        let reply = try PTPPassThrough.decodeReply(Self.ok.encode(), Self.payload, for: Self.command)
        #expect(reply.layout == .responseThenData)
        #expect(reply.data == Self.payload)
    }

    @Test("A whole data container in the data slot has its header stripped")
    func dataContainerStripped() throws {
        let reply = try PTPPassThrough.decodeReply(Self.dataContainer.encode(), Self.ok.encode(), for: Self.command)
        #expect(reply.layout == .dataContainerThenResponse)
        #expect(reply.data == Self.payload)
    }

    @Test("(response, data container): the header is stripped and the layout keeps the order")
    func responseThenDataContainer() throws {
        let reply = try PTPPassThrough.decodeReply(Self.ok.encode(), Self.dataContainer.encode(), for: Self.command)
        #expect(reply.layout == .responseThenDataContainer)
        #expect(reply.data == Self.payload)
        #expect(reply.responseCode.isOK)
    }

    @Test("A data header renumbered by ImageCaptureCore is still stripped when it matches the response")
    func renumberedTransaction() throws {
        let data = PTPContainer(type: .data, code: PTPOperationCode.getDeviceInfo.rawValue, transactionID: 99, payload: Self.payload)
        let resp = PTPContainer(type: .response, code: PTPResponseCode.ok.rawValue, transactionID: 99)
        let reply = try PTPPassThrough.decodeReply(data.encode(), resp.encode(), for: Self.command)
        #expect(reply.data == Self.payload)
        #expect(reply.response.transactionID == 99)
    }

    @Test("A payload that merely looks like a header is left alone")
    func lookalikeNotStripped() throws {
        // Starts like a data container for a different operation code.
        let lookalike = PTPContainer(type: .data, code: 0x1008, transactionID: 7, payload: Data([1, 2, 3])).encode()
        let reply = try PTPPassThrough.decodeReply(lookalike, Self.ok.encode(), for: Self.command)
        #expect(reply.data == lookalike)
        #expect(reply.layout == .dataThenResponse)
    }

    @Test("Data and response containers concatenated across the two values")
    func concatenated() throws {
        let all = Self.dataContainer.encode() + Self.ok.encode()
        let split = all.count / 3
        let reply = try PTPPassThrough.decodeReply(all.prefix(split), all.suffix(from: split), for: Self.command)
        #expect(reply.layout == .concatenatedContainers)
        #expect(reply.data == Self.payload)
        #expect(reply.responseCode.isOK)
    }

    @Test("No data phase: (empty, response)")
    func noDataPhase() throws {
        let cmd = PTPCommand.openSession(sessionID: 1)
        let resp = PTPContainer(type: .response, code: PTPResponseCode.sessionAlreadyOpen.rawValue, transactionID: 0)
        let reply = try PTPPassThrough.decodeReply(Data(), resp.encode(), for: cmd)
        #expect(reply.data.isEmpty)
        #expect(reply.responseCode == .sessionAlreadyOpen)
    }

    @Test("Garbage in both values throws with the prefixes for the log")
    func garbage() {
        #expect(throws: PTPPassThrough.Failure.self) {
            try PTPPassThrough.decodeReply(Data([1, 2, 3]), Data([4, 5, 6, 7, 8]), for: Self.command)
        }
    }

    @Test("ImageCaptureCore's layout: GetStorageIDs, 8 B data phase and a renumbered 12-byte response (MTP, 1 Nov)")
    func imageCaptureCoreStorageIDs() throws {
        let command = PTPCommand.getStorageIDs(tx: 1)
        let first = Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00])
        let second = Data([0x0C, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x20, 0x21, 0x03, 0x00, 0x00])
        #expect(first.count == 8 && second.count == 12)
        let reply = try PTPPassThrough.decodeReply(first, second, for: command)
        #expect(reply.layout == .dataThenResponse)
        #expect(reply.data == first)
        #expect(reply.response.transactionID == 801)
        #expect(reply.response.parameters.isEmpty)
        #expect(reply.responseCode == .ok)
        #expect(try PTPStorageID.decodeArray(reply.data) == [PTPStorageID(rawValue: 0x0001_0001)])
    }

    @Test("ImageCaptureCore's layout: GetDeviceInfo, 247 B MTP DeviceInfo and a renumbered response (MTP, 5 Nov)")
    func imageCaptureCoreDeviceInfo() throws {
        let command = PTPCommand.getDeviceInfo(tx: 1)
        let first = PTPDatasetTests.syntheticMTPDeviceInfo.encode()
        let second = Data([0x0C, 0, 0, 0, 0x03, 0, 0x01, 0x20, 0x8D, 0x06, 0, 0])
        try #require(first.count == 247)
        let reply = try PTPPassThrough.decodeReply(first, second, for: command)
        // The payload's first u32 is 0xFFFF0064, not 247, so it is not mistaken for a header.
        #expect(reply.layout == .dataThenResponse)
        #expect(reply.data == first)
        #expect(reply.response.transactionID == 1677)
        #expect(try PTPDeviceInfo.decode(reply.data) == PTPDatasetTests.syntheticMTPDeviceInfo)
    }

    @Test("Two empty values are ImageCaptureCore's no answer, for any command")
    func emptyReplyIsNoAnswer() {
        for cmd in [PTPCommand.getAllObjectProps(tx: 1), PTPCommand.getDeviceInfo(tx: 1), PTPCommand.getObjectHandles(tx: 2)] {
            #expect(throws: PTPPassThrough.Failure.noAnswer) { try PTPPassThrough.decodeReply(Data(), Data(), for: cmd) }
        }
        // Empty slices with a non-zero start index: `isEmpty` is what counts, not the index.
        let d = Data([1, 2, 3])
        #expect(throws: PTPPassThrough.Failure.noAnswer) {
            try PTPPassThrough.decodeReply(d.dropFirst(3), d.dropFirst(3), for: PTPCommand.getDeviceInfo(tx: 1))
        }
    }

    @Test("A malformed reply is not no answer")
    func noAnswerIsNotMalformed() {
        #expect(throws: PTPPassThrough.Failure.noResponseContainer(firstPrefix: Data(), secondPrefix: Data([0x01]))) {
            try PTPPassThrough.decodeReply(Data(), Data([0x01]), for: PTPCommand.getDeviceInfo(tx: 1))
        }
        let ids = Data([1, 0, 0, 0, 1, 0, 1, 0])
        #expect(throws: PTPPassThrough.Failure.noResponseContainer(firstPrefix: ids, secondPrefix: Data())) {
            try PTPPassThrough.decodeReply(ids, Data(), for: PTPCommand.getStorageIDs(tx: 1))
        }
    }
}
