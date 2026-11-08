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

@Suite("In-memory catalogue")
struct InMemoryCatalogueTests {
    let first = ObjectIdentityTests.id("DSC00001.ARW", "20261101T143005", 44_000_000)

    @Test func unknownIdentitiesAreNew() async throws {
        let memory = InMemoryCatalogue()
        let store: any CatalogueStore = memory
        #expect(try await store.states(of: [first]) == [first: .new])
        #expect(try await store.record(for: first) == nil)
    }

    @Test func secondInsertUpdatesInsteadOfDuplicating() async throws {
        let memory = InMemoryCatalogue()
        let store: any CatalogueStore = memory
        try await store.upsert(CatalogueRecord(identity: first, format: .raw, state: .partial))
        try await store.upsert(CatalogueRecord(identity: first, format: .raw, state: .imported,
                                               location: .photosAsset(localIdentifier: "A/L0/001")))
        #expect(await memory.allRecords.count == 1)
        #expect(try await store.record(for: first)?.state == .imported)
        #expect(try await store.states(of: [first]) == [first: .imported])
    }

    @Test func filenameReusedAfterTheCounterWrapsIsANewFile() async throws {
        // DSC00001 again, 10,000 frames later, in the next folder: a different file.
        let store: any CatalogueStore = InMemoryCatalogue(records: [CatalogueRecord(identity: first, format: .raw, state: .imported)])
        let sameNameNextFolder = ObjectIdentityTests.id("DSC00001.ARW", "20270301T090000", 45_123_456,
                                                        folder: "DCIM/101MSDCF")
        let sameNameSameFolder = ObjectIdentityTests.id("DSC00001.ARW", "20270301T090000", 45_123_456)
        let states = try await store.states(of: [first, sameNameNextFolder, sameNameSameFolder])
        #expect(states == [first: .imported, sameNameNextFolder: .new, sameNameSameFolder: .new])
    }

    @Test func filesFolderLocationRoundTrips() async throws {
        let memory = InMemoryCatalogue()
        let store: any CatalogueStore = memory
        let r = CatalogueRecord(identity: first, format: .raw, state: .imported,
                                location: .file(relativePath: "Imports/DSC00001.ARW"))
        try await store.upsert(r)
        #expect(try await store.record(for: first) == r)
        let json = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(CatalogueRecord.self, from: json) == r)
    }

    @Test func lastListingIsPerCameraAndReplaced() async throws {
        let memory = InMemoryCatalogue()
        let store: any CatalogueStore = memory
        let other = CameraKey(rawValue: "other")
        let old = CardListing(camera: ObjectIdentityTests.camera, listedAt: Date(timeIntervalSinceReferenceDate: 0),
                              entries: [.init(identity: first, format: .raw)])
        let new = CardListing(camera: ObjectIdentityTests.camera, listedAt: Date(timeIntervalSinceReferenceDate: 60),
                              entries: [])
        try await store.saveListing(old)
        try await store.saveListing(new)
        #expect(try await store.lastListing(for: ObjectIdentityTests.camera) == new)
        #expect(try await store.lastListing(for: other) == nil)
    }
}
