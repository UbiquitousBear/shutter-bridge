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
}
