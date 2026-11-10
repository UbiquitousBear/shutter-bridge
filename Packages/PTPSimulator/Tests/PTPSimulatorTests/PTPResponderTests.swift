import Foundation
import PTPKit
import Testing
@testable import PTPSimulator

/// A responder over three RAW+JPEG frames and a HIF, with a session open unless a test says otherwise.
private func responder(_ flavour: SimulatorFlavour = .usbMTP, open: Bool = true) throws -> PTPResponder {
    let card = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .rawPlusHEIF]))
    var r = try PTPResponder(card: card, flavour: flavour)
    if open { #expect(r.respond(to: PTPCommand.openSession(sessionID: 1)).code == .ok) }
    return r
}

@Suite("PTP responder")
struct PTPResponderTests {
    @Test func deviceInfoIsTheCapturedOneOfTheFlavour() throws {
        var usb = try responder(.usbMTP, open: false)
        let usbReply = usb.respond(to: PTPCommand.getDeviceInfo(tx: 7))
        #expect(usbReply.code == .ok && usbReply.response.transactionID == 7 && usbReply.response.type == .response)
        let usbInfo = try PTPDeviceInfo.decode(try #require(usbReply.data).allBytes)
        #expect(usbInfo.model == "ILCE-7CM2" && usbInfo.deviceVersion == "2.0")
        #expect(usbInfo.operationsSupported.count == 24 && usbInfo.vendorExtension == .mtp)
        #expect(usbInfo.serialNumber.allSatisfy { $0 == "0" })
        #expect(try #require(usbReply.data).allBytes == CapturedA7C2.bytes("a7c2-usb-deviceinfo"))

        var ip = try responder(.ptpIP, open: false)
        let ipInfo = try PTPDeviceInfo.decode(try #require(ip.respond(to: PTPCommand.getDeviceInfo(tx: 1)).data).allBytes)
        #expect(ipInfo.operationsSupported.count == 81 && ipInfo.eventsSupported.count == 48)
        #expect(ipInfo.vendorExtension == .sony && ipInfo.deviceVersion == "2.01")
    }

    @Test func sessionRules() throws {
        var r = try responder(open: false)
        #expect(r.respond(to: PTPCommand.getStorageIDs(tx: 1)).code == .sessionNotOpen)
        #expect(r.respond(to: PTPCommand.closeSession(tx: 1)).code == .sessionNotOpen)
        #expect(r.respond(to: PTPCommand.openSession(sessionID: 0)).code == .invalidParameter)
        #expect(r.respond(to: PTPCommand.openSession(sessionID: 5)).code == .ok)
        #expect(r.sessionID == 5)
        let again = r.respond(to: PTPCommand.openSession(sessionID: 6))
        #expect(again.code == .sessionAlreadyOpen && again.response.parameters == [5])
        #expect(r.respond(to: PTPCommand.closeSession(tx: 2)).code == .ok)
        #expect(r.sessionID == nil)
        // GetDeviceInfo needs no session.
        #expect(r.respond(to: PTPCommand.getDeviceInfo(tx: 3)).code == .ok)
        r.endSession()
        #expect(r.respond(to: PTPCommand.getObjectHandles(tx: 4)).code == .sessionNotOpen)
    }

    @Test func storage() throws {
        var r = try responder()
        let ids = try PTPStorageID.decodeArray(try #require(r.respond(to: PTPCommand.getStorageIDs(tx: 1)).data).allBytes)
        #expect(ids == [ScriptedCard.defaultStorageID])
        let reply = r.respond(to: PTPCommand.getStorageInfo(ScriptedCard.defaultStorageID, tx: 2))
        let info = try PTPStorageInfo.decode(try #require(reply.data).allBytes)
        #expect(info.storageDescription == "Storage Media" && info.maxCapacity == 255_936_430_080)
        let used = r.card.objects.reduce(UInt64(0)) { $0 + $1.size }
        #expect(info.freeSpaceInBytes == info.maxCapacity - used)
        #expect(r.respond(to: PTPCommand.getStorageInfo(PTPStorageID(rawValue: 0x0002_0001), tx: 3)).code == .invalidStorageID)

        // PTP/IP: sent as the camera sent it, capacity and free space 0, once the whole-card session offers the card
        // (a plain session answers StoreNotAvailable: WholeCardSessionTests).
        var ip = try responder(.ptpIP, open: false)
        #expect(ip.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1)).code == .ok)
        #expect(ip.respond(to: PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 2)).code == .ok)
        _ = ip.advance(by: .seconds(2))
        let ipInfo = try PTPStorageInfo.decode(
            try #require(ip.respond(to: PTPCommand.getStorageInfo(ScriptedCard.defaultStorageID, tx: 3)).data).allBytes)
        #expect(ipInfo.maxCapacity == 0 && ipInfo.freeSpaceInBytes == 0 && ipInfo.storageDescription == "Storage Media 1")
    }

    @Test func objectHandlesFilterByStoreAndFormat() throws {
        var r = try responder()
        let all = try PTPObjectHandle.decodeArray(try #require(r.respond(to: PTPCommand.getObjectHandles(tx: 1)).data).allBytes)
        #expect(all == r.card.handles && all.count == 6)
        let raws = try PTPObjectHandle.decodeArray(
            try #require(r.respond(to: PTPCommand.getObjectHandles(format: .sonyARW, tx: 2)).data).allBytes)
        #expect(raws.count == 3)
        let mine = r.respond(to: PTPCommand.getObjectHandles(storage: ScriptedCard.defaultStorageID, tx: 3))
        #expect(mine.code == .ok)
        #expect(r.respond(to: PTPCommand.getObjectHandles(storage: PTPStorageID(rawValue: 9), tx: 4)).code == .invalidStorageID)
        // No folder objects are served, so a parent filter isn't supported.
        #expect(r.respond(to: PTPCommand.getObjectHandles(parent: .root, tx: 5)).code == .parameterNotSupported)
    }

    @Test func objectInfoIsSeededFromTheCapturedOnes() throws {
        var r = try responder()
        let arw = try PTPObjectInfo.decode(try #require(r.respond(to: PTPCommand.getObjectInfo(r.card.handles[0], tx: 1)).data).allBytes)
        #expect(arw.filename == "DSC00001.ARW" && arw.objectFormat == .sonyARW)
        #expect(arw.thumbFormat == .jfif && arw.thumbCompressedSize == 6_584)
        #expect(arw.thumbPixWidth == 160 && arw.thumbPixHeight == 120)
        #expect(arw.imagePixWidth == 7008 && arw.imagePixHeight == 4672)
        let jpg = try #require(r.card.objectInfo(for: r.card.handles[1]))
        #expect(jpg.thumbCompressedSize == 7_376 && jpg.mediaKind == .jpeg)
        let hif = try #require(r.card.objectInfo(for: r.card.handles[5]))
        #expect(hif.mediaKind == .heif && hif.thumbCompressedSize == 7_376)
        #expect(r.respond(to: PTPCommand.getObjectInfo(PTPObjectHandle(rawValue: 99), tx: 2)).code == .invalidObjectHandle)
    }

    @Test func thumbnails() throws {
        var r = try responder()
        let thumb = try #require(r.respond(to: PTPCommand.getThumb(r.card.handles[0], tx: 1)).data).allBytes
        #expect(thumb.count == 6_584)
        #expect(thumb.prefix(2) == Data([0xFF, 0xD8]) && thumb.suffix(2) == Data([0xFF, 0xD9]))
        #expect(r.respond(to: PTPCommand.getThumb(PTPObjectHandle(rawValue: 99), tx: 2)).code == .invalidObjectHandle)
        // A format without a captured template has no thumbnail.
        let clip = ScriptedCard.Object(handle: PTPObjectHandle(rawValue: 50), folder: "PRIVATE/M4ROOT/CLIP",
                                       filename: "C0001.MP4", size: 1000, captureDateRaw: "20261101T090000", format: .mp4)
        _ = r.add([clip])
        #expect(r.respond(to: PTPCommand.getThumb(clip.handle, tx: 3)).code == .noThumbnailPresent)
    }

    @Test func getObjectSendsTheScriptedBytes() throws {
        let card = try #require(ScriptedCard.shoot([.rawPlusJPEG])).scaled(down: 1000)
        var r = try PTPResponder(card: card)
        _ = r.respond(to: PTPCommand.openSession(sessionID: 1))
        let o = card.objects[1]
        let reply = r.respond(to: PTPCommand.getObject(o.handle, tx: 2))
        let data = try #require(reply.data)
        #expect(reply.code == .ok && data.length == o.size)
        #expect(data.allBytes == card.content(of: o.handle, in: 0 ..< o.size))
        // Read in pieces, as a server does, it is the same.
        var pieces = Data()
        var offset: UInt64 = 0
        while offset < data.length {
            pieces += data.read(from: offset, count: 4096)
            offset += 4096
        }
        #expect(pieces == data.allBytes)
        #expect(data.read(from: data.length, count: 10).isEmpty)
        #expect(r.respond(to: PTPCommand.getObject(PTPObjectHandle(rawValue: 99), tx: 3)).code == .invalidObjectHandle)
    }

    @Test func getPartialObjectAsOverUSBInMTP() throws {
        let card = try #require(ScriptedCard.shoot([.jpeg])).scaled(down: 1000)
        var r = try PTPResponder(card: card)
        _ = r.respond(to: PTPCommand.openSession(sessionID: 1))
        let o = card.objects[0]
        let mid = r.respond(to: PTPCommand.getPartialObject(o.handle, offset: 100, length: 500, tx: 2))
        #expect(mid.code == .ok && mid.response.parameters == [500])
        #expect(try #require(mid.data).allBytes == card.content(of: o.handle, in: 100 ..< 600))
        // Past the end it sends what there is, and says how much.
        let tail = r.respond(to: PTPCommand.getPartialObject(o.handle, offset: UInt32(o.size - 10), length: 500, tx: 3))
        #expect(tail.response.parameters == [10] && tail.data?.length == 10)
        let rest = r.respond(to: PTPCommand.getPartialObject(o.handle, offset: 0, length: .max, tx: 4))
        #expect(rest.data?.length == o.size)
        #expect(r.respond(to: PTPCommand.getPartialObject(o.handle, offset: UInt32(o.size + 1), length: 1, tx: 5)).code == .invalidParameter)
        let short = PTPContainer(type: .command, code: PTPOperationCode.getPartialObject.rawValue, transactionID: 6,
                                 parameters: [o.handle.rawValue])
        #expect(r.respond(to: short).code == .invalidParameter)
    }

    @Test func unservedOperationsAreNotSupported() throws {
        var r = try responder()
        // Listed in the MTP DeviceInfo but not served by v1.
        #expect(r.deviceInfo.supports(.getObjectPropList))
        #expect(r.respond(to: PTPCommand.getAllObjectProps(tx: 1)).code == .operationNotSupported)
        #expect(r.respond(to: PTPCommand.getNumObjects(tx: 2)).code == .operationNotSupported)
        // Not listed in the MTP DeviceInfo: Sony's SDIO operations, and the property read.
        #expect(r.respond(to: PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 3)).code == .operationNotSupported)
        #expect(r.respond(to: PTPCommand.sonySDIOConnect(phase: 1, tx: 3)).code == .operationNotSupported)
        #expect(r.respond(to: PTPCommand.getDevicePropValue(.batteryLevel, tx: 3)).code == .operationNotSupported)
        // A non-command container.
        let event = PTPContainer(type: .event, code: 0x4002, transactionID: 4, parameters: [1])
        #expect(r.respond(to: event).code == .generalError)
        #expect(r.commandsAnswered.contains(.getObjectPropList))
    }

    @Test func injectedResponses() throws {
        var r = try responder()
        let h = r.card.handles[0]
        r.inject(.deviceBusy, forNext: .getObject, times: 2)
        #expect(r.respond(to: PTPCommand.getObject(h, tx: 1)).code == .deviceBusy)
        let busy = r.respond(to: PTPCommand.getObject(h, tx: 2))
        #expect(busy.code == .deviceBusy && busy.data == nil)
        #expect(r.respond(to: PTPCommand.getObject(h, tx: 3)).code == .ok)
    }

    @Test func silencedCommandsGetNoResponse() throws {
        var r = try responder()
        let h = r.card.handles[0]
        r.silence(forNext: .getThumb)
        let silent = r.respond(to: PTPCommand.getThumb(h, tx: 1))
        #expect(silent.isSilent && silent.data == nil)
        let answered = r.respond(to: PTPCommand.getThumb(h, tx: 2))
        #expect(!answered.isSilent && answered.code == .ok)
        #expect(Array(r.commandsAnswered.suffix(2)) == [.getThumb, .getThumb])
    }

    @Test func shootingSendsObjectAdded() throws {
        var usb = try responder()
        let events = usb.shoot([.rawPlusJPEG])
        #expect(usb.card.objects.count == 8)
        #expect(usb.card.objects.suffix(2).map(\.filename) == ["DSC00004.ARW", "DSC00004.JPG"])
        #expect(events.map(\.eventCode) == [.objectAdded, .objectAdded])
        #expect(events.map(\.parameters) == [[7], [8]])
        #expect(events.allSatisfy { $0.type == .event && $0.transactionID == 0 })

        // PTP/IP: Sony's 0xC201 with the buffer slot, as in event-objectadded.bin.
        var ip = try responder(.ptpIP)
        let sony = ip.shoot([.jpeg])
        #expect(sony.count == 1 && sony[0].eventCode == .sonyObjectAdded)
        #expect(sony[0].parameters == [0xFFFF_C001] && sony[0].transactionID == 0xFFFF_FFFF)
        let packet = PTPIP.event(sony[0].eventCode, transactionID: sony[0].transactionID, parameters: sony[0].parameters)
        #expect(packet.encode() == (CapturedFixtureCopyTests.repositoryFixture("ptpip/event-objectadded.bin") ?? packet.encode()))
    }
}
