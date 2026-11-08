import Foundation
import PTPKit
import Testing
@testable import Catalogue

@Suite("Capture dates are the camera's wall clock")
struct CaptureDateTests {
    @Test func acceptsOnlyWellFormedStrings() {
        #expect(CaptureDate(rawValue: "20261101T143005")?.rawValue == "20261101T143005")
        for bad in ["", "20261101 143005", "20261301T143005", "20261100T143005", "20261101T243005",
                    "20261101T146005", "2026110T1430055", "20261101T14300", "20261101T1430050", "２0261101T143005"] {
            #expect(CaptureDate(rawValue: bad) == nil, "\(bad)")
        }
    }

    @Test func ptpStringsLoseTenthsAndZone() {
        #expect(CaptureDate(ptpDateTime: "20261101T143005")?.rawValue == "20261101T143005")
        #expect(CaptureDate(ptpDateTime: "20261101T143005.3")?.rawValue == "20261101T143005")
        #expect(CaptureDate(ptpDateTime: "20261101T143005Z")?.rawValue == "20261101T143005")
        #expect(CaptureDate(ptpDateTime: "20261101T143005+0100")?.rawValue == "20261101T143005")
        #expect(CaptureDate(ptpDateTime: "20261101T143005junk") == nil)
        #expect(CaptureDate(ptpDateTime: "") == nil)
    }

    @Test func keyStaysPutWhenThePhoneChangesZone() throws {
        // ImageCaptureCore turns the camera's 14:30:05 into a Date in whatever zone the phone is in. Read back in
        // that same zone, the wall clock (and so the identity) is the same in London and in Tokyo.
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let camera = try #require(CaptureDate(rawValue: "20261101T143005"))
        let inLondon = try #require(camera.date(in: london))
        let inTokyo = try #require(camera.date(in: tokyo))
        #expect(inLondon != inTokyo)
        #expect(CaptureDate(inLondon, in: london) == camera)
        #expect(CaptureDate(inTokyo, in: tokyo) == camera)
    }

    @Test func ordersAsTimesDo() throws {
        let a = try #require(CaptureDate(rawValue: "20261101T235959"))
        let b = try #require(CaptureDate(rawValue: "20261102T000000"))
        #expect(a < b)
    }

    @Test func codableChecksTheValue() throws {
        let d = try #require(CaptureDate(rawValue: "20261101T143005"))
        let data = try JSONEncoder().encode([d])
        #expect(try JSONDecoder().decode([CaptureDate].self, from: data) == [d])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([CaptureDate].self, from: Data(#"["2026-11-01"]"#.utf8))
        }
    }
}

@Suite("Object identity")
struct ObjectIdentityTests {
    static let camera = CameraKey(rawValue: "hashed-key-0001")

    static func id(_ name: String, _ date: String, _ size: UInt64, folder: String = "DCIM/100MSDCF") -> ObjectIdentity {
        ObjectIdentity(camera: camera, folder: folder, filename: name, captureDate: CaptureDate(rawValue: date)!,
                       size: size)
    }

    @Test func pairStemDropsTheExtension() {
        #expect(Self.id("DSC04512.ARW", "20261101T143005", 1).pairStem == "DSC04512")
        #expect(Self.id("NOEXT", "20261101T143005", 1).pairStem == "NOEXT")
    }

    @Test func fromPTPKitIdentity() {
        let ptp = PTPObjectIdentity(cameraSerial: "hashed-key-0001", filename: "DSC04512.JPG",
                                    captureDateRaw: "20261101T143005", size: 22_000_000)
        #expect(ObjectIdentity(ptp, folder: "DCIM/100MSDCF") == Self.id("DSC04512.JPG", "20261101T143005", 22_000_000))
        let undated = PTPObjectIdentity(cameraSerial: "k", filename: "X.JPG", captureDateRaw: "", size: 1)
        #expect(ObjectIdentity(undated, folder: "") == nil)
    }

    @Test func descriptionNeverPrintsTheCameraKey() {
        let s = Self.id("DSC04512.ARW", "20261101T143005", 44).description
        #expect(!s.contains("hashed-key"))
        #expect(s == "DCIM/100MSDCF/DSC04512.ARW 20261101T143005 44B @camera-key(15 chars)")
    }
}

// The store's behaviour is in CatalogueContractTests.swift, run against every store this platform has.
