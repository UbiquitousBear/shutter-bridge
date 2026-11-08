import Testing
import Foundation
@testable import PTPKit

/// What the α7C II's own bytes say, field by field (Fixtures/a7c2/, copied in by `make fixtures`). The golden tests in
/// `PTPFixtureTests` prove every fixture decodes and re-encodes to the same bytes; these pin the values, so a codec
/// change that kept the round trip but shifted a field still fails, and so each fact the findings recorded is held
/// against the camera's bytes. The USB fixtures are *Image Transfer (MTP)* mode (firmware string "2.0"). The PTP/IP
/// ones (firmware 2.01) come from several runs, by the export's file times (UTC+1): the SSDP description (4 Nov 03:23)
/// and the events c223, c206, c234 and objectadded (03:39:54–03:40:02) from *PC Remote* on the home network through an
/// access point; the rest from the camera's own network: deviceinfo, sdio-extdeviceinfo, the storage IDs, StorageInfo,
/// handles, both ObjectInfo files and event c225 from the 5 Nov 01:09–01:14 run *Bluetooth: switch Wi-Fi on, join and
/// import* (Wi-Fi switched on over Bluetooth; that guided run's setup has PC Remote Function off), events 4004 and c203
/// from the 4 Nov 12:39 join over Bluetooth, and event 4005 from the 4 Nov 01:08 *Copy all RAW to Files* run. The serials in both DeviceInfo files are zeroed.
///
/// Values come from docs/spike-findings.md where it recorded them, and from the bytes where it didn't; the findings'
/// rows are named in each test. Nothing here says what a code *means* beyond what the bytes show.

/// Space-separated hex codes, e.g. `codes("1001 1002")`, so a 81-entry list stays readable.
private func codes(_ s: String) -> [UInt16] {
    s.split(separator: " ").map { UInt16($0, radix: 16)! }
}

private let utc = TimeZone(secondsFromGMT: 0)!

private func utcParts(_ raw: String) -> [Int]? {
    guard let date = PTPDateTime.parse(raw, defaultTimeZone: utc) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return [c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!]
}

private func deviceInfo(_ name: String) throws -> PTPDeviceInfo {
    try PTPDeviceInfo.decode(try CapturedFixtures.data(name))
}

private func objectInfo(_ name: String) throws -> PTPObjectInfo {
    try PTPObjectInfo.decode(try CapturedFixtures.data(name))
}

@Suite("Captured α7C II fixtures: DeviceInfo")
struct PTPFixtureDeviceInfoTests {

    @Test("USB, MTP mode: PTP 1.00, plain MTP (0xFFFFFFFF), Sony Corporation ILCE-7CM2, firmware string 2.0")
    func usbIdentity() throws {
        let info = try deviceInfo("a7c2-usb-deviceinfo.bin")
        #expect(info.standardVersion == 100)
        #expect(info.vendorExtensionID == 0xFFFF_FFFF)
        #expect(info.vendorExtension == .mtp)
        #expect(info.vendorExtensionVersion == 100)
        #expect(info.vendorExtensionDescription == "")
        #expect(info.functionalMode == 0)
        #expect(info.manufacturer == "Sony Corporation")
        #expect(info.model == "ILCE-7CM2")
        #expect(info.deviceVersion == "2.0")
        #expect(info.isSony)
    }

    @Test("USB, MTP mode: 24 operations, 3 events, 5 device properties, no capture formats, 10 image formats")
    func usbLists() throws {
        let info = try deviceInfo("a7c2-usb-deviceinfo.bin")
        #expect(info.operationsSupported == codes("1002 1003 1001 1004 1005 1006 1007 1008 1009 100A 1014 1015 1016 101B 9801 9802 9803 9805 9280 9281 9282 9283 9284 9285"))
        #expect(info.operationsSupported.count == 24)
        #expect(info.eventsSupported == codes("4004 4005 4006"))
        #expect(info.devicePropertiesSupported == codes("5001 D402 D406 D407 D303"))
        #expect(info.captureFormats.isEmpty)
        #expect(info.imageFormats == codes("3001 300B 3801 B982 B301 3000 B101 B310 3008 B110"))
        // What the findings' "DeviceInfo in MTP mode" row says, by name.
        #expect(info.supports(.getThumb))
        #expect(info.supports(.getPartialObject))
        #expect(!info.supports(.getPartialObject64))
        #expect(info.supports(.getObjectPropList))
        #expect(!info.supports(.sonySDIOOpenSession) && !info.supports(.sonySDIOGetPartialLargeObject))
        #expect(info.emits(.storeAdded) && info.emits(.storeRemoved) && info.emits(.devicePropChanged))
        #expect(!info.emits(.objectAdded) && !info.emits(.sonyObjectAdded))
        #expect(PTPObjectFormat(rawValue: 0xB101) == .sonyARW && info.imageFormats.contains(PTPObjectFormat.sonyARW.rawValue))
        #expect(info.imageFormats.contains(PTPObjectFormat.sonyHEIF.rawValue))
        #expect(info.imageFormats.contains(PTPObjectFormat.sonyMPO.rawValue))
        #expect(info.imageFormats.contains(PTPObjectFormat.mp4.rawValue))
    }

    @Test("PTP/IP: Sony's own extension (0x11, v100, \"Sony PTP Extensions\"), firmware string 2.01")
    func ptpipIdentity() throws {
        let info = try deviceInfo("a7c2-ptpip-deviceinfo.bin")
        #expect(info.standardVersion == 100)
        #expect(info.vendorExtensionID == 0x11)
        #expect(info.vendorExtension == .sony)
        #expect(info.vendorExtensionVersion == 100)
        #expect(info.vendorExtensionDescription == "Sony PTP Extensions")
        #expect(info.functionalMode == 0)
        #expect(info.manufacturer == "Sony Corporation")
        #expect(info.model == "ILCE-7CM2")
        #expect(info.deviceVersion == "2.01")
        #expect(info.isSony)
    }

    @Test("PTP/IP: 81 operations, 48 events, no device properties, 6 image formats")
    func ptpipLists() throws {
        let info = try deviceInfo("a7c2-ptpip-deviceinfo.bin")
        #expect(info.operationsSupported == codes("""
            1001 1002 1003 1004 1005 1006 1007 1008 1009 100A 100D 101B \
            9201 9202 9203 9204 9205 9206 9207 9208 9209 920A 920B 920C 920D 920E 920F \
            9210 9211 9212 9213 9214 9215 9216 9219 921A 921B 921C 921D 921E 921F \
            9220 9221 9222 9223 9224 9225 9226 9227 9228 9229 922B 922C 922F \
            9230 9231 9232 9233 9234 9238 9239 923A 923B 923C 923D 923E 923F \
            9240 9243 9244 9248 9249 9250 9251 9252 9253 9254 \
            9801 9802 9803 9805
            """))
        #expect(info.operationsSupported.count == 81)
        #expect(info.eventsSupported == codes("""
            4004 4005 C201 C202 C203 C204 C205 C206 C207 C208 C209 C20A C20B C20C C20D C20E C20F \
            C210 C211 C213 C214 C216 C217 C218 C219 C21A C21B C21C C21D C21E C21F \
            C220 C221 C222 C223 C224 C225 C226 C227 C228 C229 C230 C231 C232 C234 C235 C237 C240
            """))
        #expect(info.eventsSupported.count == 48)
        #expect(info.devicePropertiesSupported.isEmpty)
        #expect(info.captureFormats.isEmpty)
        #expect(info.imageFormats == codes("3001 3801 B101 300B B982 B110"))
    }

    @Test("PTP/IP: the Sony codes PTPKit names are listed; the standard property reads and 0x95C1 are not")
    func ptpipNamedCodes() throws {
        let info = try deviceInfo("a7c2-ptpip-deviceinfo.bin")
        // Listed (the spike's findings: "Operations listed in DeviceInfo over PTP/IP, compared with USB").
        for op in [PTPOperationCode.getThumb, .getPartialObject, .getObjectPropsSupported, .getObjectPropDesc, .getObjectPropValue,
                   .getObjectPropList, .sonySDIOConnect, .sonySDIOGetExtDeviceInfo, .sonySDIOOpenSession,
                   .sonySDIOGetPartialLargeObject, .sonySDIOSetContentsTransferMode, .sonySDIO0x9219] {
            #expect(info.supports(op), "\(op) is not in the PTP/IP DeviceInfo")
        }
        // Not listed: Android's 64-bit partial read, and (the camera lists no device properties) the property reads.
        #expect(!info.supports(.getPartialObject64))
        #expect(!info.supports(.getDevicePropValue) && !info.supports(.getDevicePropDesc))
        #expect(info.emits(.storeAdded) && info.emits(.storeRemoved))
        #expect(info.emits(.sonyObjectAdded) && info.emits(PTPEventCode(rawValue: 0xC202)))
        #expect(!info.emits(.objectAdded))
    }

    @Test("Both DeviceInfo files carry a zeroed serial number (nothing private in the repo)")
    func serialsAreZeroed() throws {
        for name in ["a7c2-usb-deviceinfo.bin", "a7c2-ptpip-deviceinfo.bin"] {
            let info = try deviceInfo(name)
            #expect(info.serialNumber.count == 32 && info.serialNumber.allSatisfy { $0 == "0" }, "\(name)")
        }
    }
}

@Suite("Captured α7C II fixtures: storage")
struct PTPFixtureStorageTests {

    @Test("One store, 0x00010001, over both links")
    func storageIDs() throws {
        for name in ["a7c2-usb-storageids.bin", "a7c2-ptpip-storageids.bin"] {
            let ids = try PTPStorageID.decodeArray(try CapturedFixtures.data(name))
            #expect(ids == [PTPStorageID(rawValue: 0x0001_0001)], "\(name)")
            #expect(ids.allSatisfy { $0.hasLogicalStore }, "\(name)")
        }
    }

    @Test("USB: removable RAM, generic hierarchical, read-only without deletion, 255.94 GB with 242.57 GB free")
    func usbStorageInfo() throws {
        let info = try PTPStorageInfo.decode(try CapturedFixtures.data("a7c2-usb-storageinfo.bin"))
        #expect(info.storageType == 4)
        #expect(info.filesystemType == 2)
        #expect(info.accessCapability == 1)
        #expect(info.maxCapacity == 255_936_430_080)
        #expect(info.freeSpaceInBytes == 242_572_591_104)
        #expect(info.freeSpaceInImages == 0xFFFF_FFFF)
        #expect(info.storageDescription == "Storage Media")
        #expect(info.volumeLabel == "")
    }

    @Test("PTP/IP: the same type, filesystem and access, but capacity and free space 0, and the name \"Storage Media 1\"")
    func ptpipStorageInfo() throws {
        let info = try PTPStorageInfo.decode(try CapturedFixtures.data("a7c2-ptpip-storageinfo.bin"))
        #expect(info.storageType == 4)
        #expect(info.filesystemType == 2)
        #expect(info.accessCapability == 1)
        #expect(info.maxCapacity == 0)
        #expect(info.freeSpaceInBytes == 0)
        #expect(info.freeSpaceInImages == 0xFFFF_FFFF)
        #expect(info.storageDescription == "Storage Media 1")
        #expect(info.volumeLabel == "")
    }

    @Test("USB: 397 distinct handles, none 0; 6 are multiples of 0x80000 (fits 6 folders; 391 matches ImageCaptureCore's file count); the ARW's parent is one of them")
    func usbHandles() throws {
        let handles = try PTPObjectHandle.decodeArray(try CapturedFixtures.data("a7c2-usb-objecthandles.bin"))
        #expect(handles.count == 397)
        #expect(Set(handles).count == 397)
        #expect(!handles.contains(PTPObjectHandle(rawValue: 0)))
        #expect(handles.first == PTPObjectHandle(rawValue: 0x0008_0000) && handles.last == PTPObjectHandle(rawValue: 0x0030_0123))
        // Six handles are multiples of 0x80000 (0x80000 ... 0x300000), likely the folders; 0x300000 is the ARW's and JPG's parent.
        let folders = handles.filter { $0.rawValue % 0x8_0000 == 0 }
        #expect(folders.map(\.rawValue) == [0x8_0000, 0x10_0000, 0x18_0000, 0x20_0000, 0x28_0000, 0x30_0000])
        #expect(handles.count - folders.count == 391)
        let arw = try objectInfo("a7c2-usb-objectinfo-arw.bin")
        #expect(handles.contains(arw.parentObject))
    }

    @Test("PTP/IP: 741 distinct handles, all 0x4000xxxx and ascending; the pair's parent is the first")
    func ptpipHandles() throws {
        let handles = try PTPObjectHandle.decodeArray(try CapturedFixtures.data("a7c2-ptpip-objecthandles.bin"))
        #expect(handles.count == 741)
        #expect(Set(handles).count == 741)
        #expect(handles.allSatisfy { $0.rawValue >> 16 == 0x4000 })
        #expect(handles == handles.sorted { $0.rawValue < $1.rawValue })
        #expect(handles.first == PTPObjectHandle(rawValue: 0x4000_0010) && handles.last == PTPObjectHandle(rawValue: 0x4000_1ED3))
        // The handles the findings recorded for DSC02046.ARW and DSC02052.ARW (2 Nov, same card) are still in the list.
        #expect(handles.contains(PTPObjectHandle(rawValue: 0x4000_10A3)) && handles.contains(PTPObjectHandle(rawValue: 0x4000_1103)))
        let arw = try objectInfo("a7c2-ptpip-objectinfo-arw.bin")
        #expect(arw.parentObject == handles.first)
    }
}

@Suite("Captured α7C II fixtures: ObjectInfo")
struct PTPFixtureObjectInfoTests {

    @Test("USB DSC02018.ARW (findings: GetObjectInfo of an ARW and a JPG in MTP mode)")
    func usbARW() throws {
        let o = try objectInfo("a7c2-usb-objectinfo-arw.bin")
        #expect(o.filename == "DSC02018.ARW")
        #expect(o.storageID == PTPStorageID(rawValue: 0x0001_0001))
        #expect(o.objectFormat == .sonyARW && o.objectFormat.rawValue == 0xB101)
        #expect(o.mediaKind == .raw && o.fileExtension == "ARW" && o.pairStem == "DSC02018")
        #expect(o.protectionStatus == 0)
        #expect(o.objectCompressedSize == 40_329_216 && !o.sizeExceeds32Bits)
        #expect(o.thumbFormat == .jfif)
        #expect(o.thumbCompressedSize == 6_584 && o.thumbPixWidth == 160 && o.thumbPixHeight == 120)
        #expect(o.imagePixWidth == 7008 && o.imagePixHeight == 4672 && o.imageBitDepth == 0)
        #expect(o.parentObject == PTPObjectHandle(rawValue: 0x0030_0000))
        #expect(o.associationType == 0 && o.associationDescription == 0 && o.sequenceNumber == 0)
        #expect(o.captureDateRaw == "20261101T180520" && utcParts(o.captureDateRaw) == [2026, 11, 1, 18, 5, 20])
        #expect(o.modificationDateRaw == "" && o.modificationDate == nil)
        #expect(o.keywords == "")
        #expect(!o.isFolder)
    }

    @Test("USB DSC01997.JPG: the same layout, a JFIF thumbnail of 7,376 B")
    func usbJPG() throws {
        let o = try objectInfo("a7c2-usb-objectinfo-jpg.bin")
        #expect(o.filename == "DSC01997.JPG")
        #expect(o.objectFormat == .exifJPEG && o.mediaKind == .jpeg && o.fileExtension == "JPG")
        #expect(o.objectCompressedSize == 21_013_936)
        #expect(o.thumbFormat == .jfif && o.thumbCompressedSize == 7_376 && o.thumbPixWidth == 160 && o.thumbPixHeight == 120)
        #expect(o.imagePixWidth == 7008 && o.imagePixHeight == 4672 && o.imageBitDepth == 0)
        #expect(o.parentObject == PTPObjectHandle(rawValue: 0x0030_0000))
        #expect(o.sequenceNumber == 0 && o.associationType == 0)
        #expect(o.captureDateRaw == "20261101T165446" && utcParts(o.captureDateRaw) == [2026, 11, 1, 16, 54, 46])
        #expect(o.modificationDateRaw == "" && o.keywords == "")
    }

    @Test("PTP/IP: DSC01779.ARW and DSC01779.JPG are one RAW+JPEG pair: same stem, parent, capture second and thumbnail size")
    func ptpipPair() throws {
        let arw = try objectInfo("a7c2-ptpip-objectinfo-arw.bin")
        let jpg = try objectInfo("a7c2-ptpip-objectinfo-jpg.bin")
        #expect(arw.filename == "DSC01779.ARW" && jpg.filename == "DSC01779.JPG")
        #expect(arw.pairStem == "DSC01779" && arw.pairStem == jpg.pairStem)
        #expect(arw.objectFormat == .sonyARW && arw.mediaKind == .raw)
        #expect(jpg.objectFormat == .exifJPEG && jpg.mediaKind == .jpeg)
        #expect(arw.objectCompressedSize == 43_933_696 && jpg.objectCompressedSize == 22_057_701)
        #expect(arw.storageID == PTPStorageID(rawValue: 0x0001_0001) && jpg.storageID == arw.storageID)
        #expect(arw.parentObject == PTPObjectHandle(rawValue: 0x4000_0010) && jpg.parentObject == arw.parentObject)
        #expect(arw.captureDateRaw == "20261027T230018" && jpg.captureDateRaw == arw.captureDateRaw)
        #expect(utcParts(arw.captureDateRaw) == [2026, 10, 27, 23, 0, 18])
        for o in [arw, jpg] {
            #expect(o.thumbFormat == .jfif && o.thumbCompressedSize == 7_397 && o.thumbPixWidth == 160 && o.thumbPixHeight == 120)
            #expect(o.imagePixWidth == 7008 && o.imagePixHeight == 4672 && o.imageBitDepth == 0)
            #expect(o.protectionStatus == 0 && o.associationType == 0 && o.sequenceNumber == 0)
            #expect(o.modificationDateRaw == "" && o.keywords == "")
        }
    }

    @Test("Identity of the PTP/IP ARW is its filename, capture string and size (serial only as a length in logs)")
    func identity() throws {
        let arw = try objectInfo("a7c2-ptpip-objectinfo-arw.bin")
        let identity = arw.identity(cameraSerial: "tag")
        #expect(identity == PTPObjectIdentity(cameraSerial: "tag", filename: "DSC01779.ARW", captureDateRaw: "20261027T230018", size: 43_933_696))
        #expect(identity.description == "DSC01779.ARW 20261027T230018 43933696B @camera-key(3 chars)")
    }
}

@Suite("Captured α7C II fixtures: events")
struct PTPFixtureEventTests {

    private func event(_ name: String) throws -> PTPIP.Event {
        let (packet, _) = try #require(try PTPIP.Packet.decode(try CapturedFixtures.data(name)))
        return try PTPIP.decodeEvent(packet)
    }

    /// (fixture, code, parameters). Every event came with transaction ID 0xFFFFFFFF.
    static let table: [(String, UInt16, [UInt32])] = [
        ("a7c2-ptpip-event-4004.bin", 0x4004, [0x0001_0001]),
        ("a7c2-ptpip-event-4005.bin", 0x4005, [0x0001_0001]),
        ("a7c2-ptpip-event-objectadded.bin", 0xC201, [0xFFFF_C001]),
        ("a7c2-ptpip-event-c203.bin", 0xC203, [0]),
        ("a7c2-ptpip-event-c206.bin", 0xC206, []),
        ("a7c2-ptpip-event-c223.bin", 0xC223, [1]),
        ("a7c2-ptpip-event-c225.bin", 0xC225, [0, 0x0001_0001, 0]),
        ("a7c2-ptpip-event-c234.bin", 0xC234, [1, 1, 0]),
    ]

    @Test("Each captured PTP/IP event has the code and parameters the bytes hold", arguments: table)
    func codeAndParameters(entry: (String, UInt16, [UInt32])) throws {
        let e = try event(entry.0)
        #expect(e.code.rawValue == entry.1)
        #expect(e.parameters == entry.2)
        #expect(e.transactionID == 0xFFFF_FFFF)
    }

    @Test("StoreAdded and StoreRemoved name the store 0x00010001; Sony's ObjectAdded names 0xFFFFC001")
    func named() throws {
        #expect(try event("a7c2-ptpip-event-4004.bin").code == .storeAdded)
        #expect(try event("a7c2-ptpip-event-4005.bin").code == .storeRemoved)
        let added = try event("a7c2-ptpip-event-objectadded.bin")
        #expect(added.code == .sonyObjectAdded && added.code.signalsNewObject)
        #expect(added.parameters == [0xFFFF_C001])
        // A buffer slot, not a card handle: it is in no object list the camera sent.
        let handles = try PTPObjectHandle.decodeArray(try CapturedFixtures.data("a7c2-ptpip-objecthandles.bin"))
        #expect(!handles.contains(PTPObjectHandle(rawValue: 0xFFFF_C001)))
    }

    @Test("Every captured event code is one the PTP/IP DeviceInfo lists")
    func listed() throws {
        let info = try deviceInfo("a7c2-ptpip-deviceinfo.bin")
        for entry in Self.table { #expect(info.eventsSupported.contains(entry.1), "0x\(String(entry.1, radix: 16)) is not listed") }
    }

    @Test("The session's event mapping on the camera's own events")
    func sessionEvents() throws {
        #expect(SonySessionEvent(try event("a7c2-ptpip-event-4004.bin")) == .storeAdded(PTPStorageID(rawValue: 0x0001_0001)))
        #expect(SonySessionEvent(try event("a7c2-ptpip-event-4005.bin")) == .storeRemoved(PTPStorageID(rawValue: 0x0001_0001)))
        #expect(SonySessionEvent(try event("a7c2-ptpip-event-objectadded.bin")) == .objectAdded(PTPObjectHandle(rawValue: 0xFFFF_C001)))
        for name in ["c203", "c206", "c223", "c225", "c234"] {
            let e = try event("a7c2-ptpip-event-\(name).bin")
            #expect(SonySessionEvent(e) == .other(e.code), "\(name)")
        }
    }
}

@Suite("Captured α7C II fixtures: Sony ExtDeviceInfo and capability gating")
struct PTPFixtureSonyTests {

    /// There is no ExtDeviceInfo parser in Iteration 1. This reads the layout the one capture shows (970 B, over PTP/IP on firmware 2.01, from the 5 Nov Bluetooth hand-off run; the findings recorded
    /// the same size, version and counts in PC Remote on 2 Nov): a u16 version, then two lists, each a u32 count and that many u16
    /// codes, consumed exactly. Seen in one capture, so the layout may differ on another firmware or body; what the
    /// codes mean is not known.
    @Test("sdio-extdeviceinfo.bin: version 0x12C, then 421 and 59 u16 codes, consumed exactly (one capture)")
    func extDeviceInfoLayout() throws {
        let data = try CapturedFixtures.data("a7c2-ptpip-sdio-extdeviceinfo.bin")
        #expect(data.count == 970)
        var r = PTPReader(data)
        #expect(try r.u16() == 0x12C)
        let first = try r.u16Array()
        let second = try r.u16Array()
        #expect(first.count == 421)
        #expect(second.count == 59)
        #expect(r.isAtEnd)
        #expect(2 + 4 + first.count * 2 + 4 + second.count * 2 == data.count)
    }

    @Test("MTP-mode DeviceInfo: Sony by manufacturer, but none of the Sony features")
    func usbCapabilities() throws {
        let caps = SonyCapabilities(deviceInfo: try deviceInfo("a7c2-usb-deviceinfo.bin"))
        #expect(caps.isSony)
        #expect(!caps.wholeCardContentsTransfer && !caps.sdioInitSequence && !caps.extDeviceInfo)
        #expect(!caps.largeObjectPartialRead && !caps.sonyObjectAdded)
        #expect(caps.mayRead(.batteryLevel))
        #expect(caps.partialReadVariant(objectSize: 40_329_216, in: .plain) == .standard32)
        #expect(caps.partialReadVariant(objectSize: 40_329_216, in: .wholeCardContentsTransfer) == nil)
        #expect(caps.description == "Sony ILCE-7CM2 2.0: 0x9210 not listed, 0x9212 not listed")
    }

    @Test("PTP/IP DeviceInfo: every Sony feature, 0x9211 for a byte range, and no property reads")
    func ptpipCapabilities() throws {
        let caps = SonyCapabilities(deviceInfo: try deviceInfo("a7c2-ptpip-deviceinfo.bin"))
        #expect(caps.isSony)
        #expect(caps.wholeCardContentsTransfer && caps.sdioInitSequence && caps.extDeviceInfo)
        #expect(caps.largeObjectPartialRead && caps.sonyObjectAdded)
        #expect(!caps.mayRead(.batteryLevel))
        #expect(caps.partialReadVariant(objectSize: 46_313_472, in: .wholeCardContentsTransfer) == .sonyLarge9211)
        #expect(caps.description == "Sony ILCE-7CM2 2.01: 0x9210 listed, 0x9212 listed")
        #expect(!caps.description.contains("00000000"))
    }

    @Test("The whole-card plan's gate accepts the PTP/IP DeviceInfo and stops on the MTP one")
    func planGate() throws {
        func atGate(_ info: PTPDeviceInfo) -> SonySessionRunner.Action {
            var runner = SonySessionRunner(plan: .wholeCard())
            _ = runner.next(nil)                         // SDIO_OpenSession
            _ = runner.next(.response(.ok))
            return runner.next(.deviceInfo(info))        // GetDeviceInfo, the step that verifies capabilities
        }
        if case .stop = atGate(try deviceInfo("a7c2-ptpip-deviceinfo.bin")) { Issue.record("the PTP/IP DeviceInfo was refused") }
        guard case .stop(.unsupported(let caps)) = atGate(try deviceInfo("a7c2-usb-deviceinfo.bin")) else {
            Issue.record("the MTP DeviceInfo passed the whole-card gate"); return
        }
        #expect(!caps.wholeCardContentsTransfer)
    }
}
