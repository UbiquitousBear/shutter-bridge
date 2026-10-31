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

    @Test("Real DeviceInfo fixture parses, once it exists")
    func deviceInfoFixture() throws {
        guard let url = Bundle.module.url(forResource: "a7c2-deviceinfo", withExtension: "bin") else {
            // Fixture not captured yet (spike day 2). Not a failure: the test is a placeholder for the real bytes.
            return
        }
        let info = try PTPDeviceInfo.decode(try Data(contentsOf: url))
        #expect(info.manufacturer.lowercased().contains("sony"))
        #expect(info.vendorExtension == .sony)
    }

    @Test("ObjectInfo round trip and derived fields")
    func objectInfoRoundTrip() throws {
        let info = PTPObjectInfo(
            storageID: PTPStorageID(rawValue: 0x0001_0001),
            objectFormat: .sonyRAWUnverified,
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
