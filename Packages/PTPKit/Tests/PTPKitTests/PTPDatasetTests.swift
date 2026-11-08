import Testing
import Foundation
@testable import PTPKit

@Suite("PTP datasets")
struct PTPDatasetTests {

    /// A DeviceInfo shaped like a Sony body. Until the spike captures the real one into
    /// Fixtures/a7c2/usb/deviceinfo.bin this synthetic dataset is what the parser is tested against.
    static let syntheticSonyDeviceInfo = PTPDeviceInfo(
        standardVersion: 100,
        vendorExtensionID: PTPVendorExtension.sony.rawValue,
        vendorExtensionVersion: 100,
        vendorExtensionDescription: "Sony PTP Extensions",
        functionalMode: 0,
        operationsSupported: [0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1007, 0x1008, 0x1009, 0x100A, 0x101B],
        eventsSupported: [0x4002, 0x4003, 0x4004, 0x4005, 0x4008],
        devicePropertiesSupported: [0x5001, 0xD200],
        captureFormats: [0x3801],
        imageFormats: [0x3801, 0xB101],
        manufacturer: "Sony Corporation",
        model: "ILCE-7CM2",
        deviceVersion: "2.00",
        serialNumber: "00000000000000001234567"
    )

    /// MTP mode's DeviceInfo as the spike logged it (1 and 5 Nov): 247 B, vendor extension 0xFFFFFFFF, 24 operations,
    /// 3 events, 5 properties, 10 image formats, firmware "2.0". The description, serial and extension version are
    /// placeholders chosen to give the logged size, not captured values.
    static let syntheticMTPDeviceInfo = PTPDeviceInfo(
        standardVersion: 100, vendorExtensionID: 0xFFFF_FFFF, vendorExtensionVersion: 100,
        vendorExtensionDescription: "", functionalMode: 0,
        operationsSupported: [0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1006, 0x1007, 0x1008, 0x1009, 0x100A,
                              0x1014, 0x1015, 0x1016, 0x101B, 0x9801, 0x9802, 0x9803, 0x9805,
                              0x9280, 0x9281, 0x9282, 0x9283, 0x9284, 0x9285],
        eventsSupported: [0x4004, 0x4005, 0x4006],
        devicePropertiesSupported: [0x5001, 0xD402, 0xD406, 0xD407, 0xD303],
        captureFormats: [],
        imageFormats: [0x3001, 0x300B, 0x3801, 0xB982, 0xB301, 0x3000, 0xB101, 0xB310, 0x3008, 0xB110],
        manufacturer: "Sony Corporation", model: "ILCE-7CM2", deviceVersion: "2.0",
        serialNumber: String(repeating: "0", count: 32))

    @Test("DeviceInfo survives encode → decode and answers capability questions")
    func deviceInfoRoundTrip() throws {
        let info = Self.syntheticSonyDeviceInfo
        let decoded = try PTPDeviceInfo.decode(info.encode())
        #expect(decoded == info)
        #expect(decoded.vendorExtension == .sony)
        #expect(decoded.supports(.getPartialObject))
        #expect(!decoded.supports(.getPartialObject64))
        #expect(decoded.emits(.objectAdded))
        #expect(decoded.model == "ILCE-7CM2")
    }

    @Test("Vendor extension IDs match libgphoto2; Sony over PTP/IP or MTP (0xFFFFFFFF) still counts as Sony")
    func vendorExtension() throws {
        #expect(PTPVendorExtension(rawValue: 0x0E) == .fujifilm)
        #expect(PTPVendorExtension(rawValue: 0x12) == nil)
        var info = Self.syntheticSonyDeviceInfo
        #expect(info.isSony)
        info.vendorExtensionID = 0xFFFF_FFFF
        let decoded = try PTPDeviceInfo.decode(info.encode())
        #expect(decoded.vendorExtension == .mtp)
        #expect(decoded.isSony)
        info.vendorExtensionID = PTPVendorExtension.microsoftMTP.rawValue
        #expect(info.isSony)
        info.manufacturer = "Acme"
        #expect(!info.isSony)
        info.vendorExtensionID = PTPVendorExtension.canon.rawValue
        info.manufacturer = "Sony Corporation"
        #expect(!info.isSony)
    }

    @Test("ObjectInfo round trip and derived fields")
    func objectInfoRoundTrip() throws {
        let info = PTPObjectInfo(
            storageID: PTPStorageID(rawValue: 0x0001_0001),
            objectFormat: .sonyARW,
            protectionStatus: 0,
            objectCompressedSize: 36_412_928,
            thumbFormat: .exifJPEG,
            thumbCompressedSize: 6_240,
            thumbPixWidth: 160, thumbPixHeight: 120,
            imagePixWidth: 7008, imagePixHeight: 4672, imageBitDepth: 14,
            parentObject: PTPObjectHandle(rawValue: 0x0000_0010),
            associationType: 0, associationDescription: 0, sequenceNumber: 0,
            filename: "DSC04512.ARW",
            captureDateRaw: "20261031T211412",
            modificationDateRaw: "20261031T211412",
            keywords: ""
        )
        let decoded = try PTPObjectInfo.decode(info.encode())
        #expect(decoded == info)
        #expect(decoded.pairStem == "DSC04512")
        #expect(decoded.fileExtension == "ARW")
        #expect(!decoded.isFolder)
        #expect(decoded.captureDate != nil)
        #expect(decoded.mediaKind == .raw)
        #expect(decoded.identity(cameraSerial: "S1") == PTPObjectIdentity(cameraSerial: "S1", filename: "DSC04512.ARW", captureDateRaw: "20261031T211412", size: 36_412_928))
        #expect(!decoded.sizeExceeds32Bits)

        var clip = decoded
        clip.filename = "C0042.MP4"
        clip.objectCompressedSize = .max   // ≥ 4 GiB: the 32-bit field saturates
        #expect(clip.sizeExceeds32Bits)
        #expect(clip.identity(cameraSerial: "S1", size: 6_442_450_944).size == 6_442_450_944)
    }

    @Test("Object identity's description never shows the camera serial")
    func identityDescriptionOmitsSerial() throws {
        let identity = PTPObjectIdentity(cameraSerial: "4012345", filename: "DSC04512.ARW",
                                         captureDateRaw: "20261031T211412", size: 36_412_928)
        #expect(identity.description == "DSC04512.ARW 20261031T211412 36412928B @camera-key(7 chars)")
        #expect(!"\(identity)".contains("4012345"))
        // Equality and Codable still use the serial itself.
        #expect(identity != PTPObjectIdentity(cameraSerial: "4012346", filename: "DSC04512.ARW",
                                              captureDateRaw: "20261031T211412", size: 36_412_928))
        let decoded = try JSONDecoder().decode(PTPObjectIdentity.self, from: JSONEncoder().encode(identity))
        #expect(decoded.cameraSerial == "4012345")
    }

    @Test("Media kind: extension first, vendor format code as fallback", arguments: [
        ("DSC00001.ARW", PTPObjectFormat.undefined, PTPMediaKind.raw),
        ("DSC00001.JPG", .undefined, .jpeg),
        ("DSC00001.HIF", .undefined, .heif),
        ("C0001.MP4", .undefined, .video),
        ("C0001M01.XML", .undefined, .sidecar),
        ("NOEXT", .sonyARW, .raw),
        ("NOEXT", .sonyHEIF, .heif),
        ("NOEXT", .exifJPEG, .jpeg),
        ("NOEXT", .mp4, .video),
        ("DCIM", .association, .folder),
        ("README.TXT", .undefined, .other),
    ])
    func mediaKind(name: String, format: PTPObjectFormat, kind: PTPMediaKind) {
        var info = PTPObjectInfo(
            storageID: PTPStorageID(rawValue: 0x0001_0001), objectFormat: format, protectionStatus: 0,
            objectCompressedSize: 1, thumbFormat: .undefined, thumbCompressedSize: 0, thumbPixWidth: 0, thumbPixHeight: 0,
            imagePixWidth: 0, imagePixHeight: 0, imageBitDepth: 0, parentObject: .root, associationType: 0,
            associationDescription: 0, sequenceNumber: 0, filename: name, captureDateRaw: "", modificationDateRaw: "", keywords: "")
        #expect(info.mediaKind == kind)
        info.filename = name.lowercased()
        #expect(info.mediaKind == kind, "extension match is case-insensitive")
        #expect(kind.isStill == [.raw, .jpeg, .heif].contains(kind))
    }

    @Test("StorageInfo round trip")
    func storageInfoRoundTrip() throws {
        let info = PTPStorageInfo(storageType: 0x0004, filesystemType: 0x0002, accessCapability: 0x0000,
                                  maxCapacity: 256_000_000_000, freeSpaceInBytes: 190_000_000_000, freeSpaceInImages: 4_200,
                                  storageDescription: "SLOT 1", volumeLabel: "")
        #expect(try PTPStorageInfo.decode(info.encode()) == info)
    }

    @Test("GetStorageIDs and GetObjectHandles arrays")
    func arrays() throws {
        let ids = [PTPStorageID(rawValue: 0x0001_0001), PTPStorageID(rawValue: 0x0002_0000)]
        #expect(try PTPStorageID.decodeArray(PTPStorageID.encodeArray(ids)) == ids)
        #expect(ids[0].hasLogicalStore && !ids[1].hasLogicalStore)

        let handles = (1 ... 500).map { PTPObjectHandle(rawValue: UInt32($0)) }
        #expect(try PTPObjectHandle.decodeArray(PTPObjectHandle.encodeArray(handles)) == handles)
        #expect(try PTPObjectHandle.decodeArray(PTPObjectHandle.encodeArray([])).isEmpty)

        // A count larger than the bytes that follow throws instead of reading past the end.
        var w = PTPWriter(); w.u32(1_000_000); w.u32(1)
        #expect(throws: PTPDecodingError.self) { try PTPObjectHandle.decodeArray(w.data) }
    }

    @Test("PTP strings: empty, ASCII, non-Latin")
    func strings() throws {
        for s in ["", "ILCE-7CM2", "α7C II — Shamil's camera"] {
            var w = PTPWriter()
            w.string(s)
            var r = PTPReader(w.data)
            #expect(try r.string() == s)
            #expect(r.isAtEnd)
        }
    }

    @Test("DateTime parsing honours tenths and zone suffixes")
    func dateTime() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let d1 = try #require(PTPDateTime.parse("20261031T211412Z", defaultTimeZone: utc))
        let d2 = try #require(PTPDateTime.parse("20261031T221412+0100", defaultTimeZone: utc))
        #expect(d1 == d2)

        let d3 = try #require(PTPDateTime.parse("20261031T211412.5Z", defaultTimeZone: utc))
        #expect(abs(d3.timeIntervalSince(d1) - 0.5) < 0.001)

        let local = try #require(PTPDateTime.parse("20261031T211412", defaultTimeZone: TimeZone(identifier: "Europe/London")!))
        let cal = Calendar(identifier: .gregorian)
        var c = cal.dateComponents(in: TimeZone(identifier: "Europe/London")!, from: local)
        c.calendar = cal
        #expect(c.hour == 21 && c.minute == 14)

        #expect(PTPDateTime.parse("not a date") == nil)
        #expect(PTPDateTime.parse("20261031X211412") == nil)
    }

    @Test("Truncated datasets throw rather than crash")
    func truncated() {
        let bytes = Self.syntheticSonyDeviceInfo.encode().prefix(20)
        #expect(throws: PTPDecodingError.self) { try PTPDeviceInfo.decode(Data(bytes)) }
    }
}
