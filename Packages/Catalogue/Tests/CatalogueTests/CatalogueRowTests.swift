import Foundation
import PTPKit
import Testing
@testable import Catalogue

/// The storage mapping in plain values, so what SwiftData stores is checked on Linux too.
@Suite("Catalogue rows")
struct CatalogueRowTests {
    typealias C = CatalogueContractTests

    @Test func storageKeysAreDistinctForDistinctIdentities() {
        // Pairs that a plain join of the parts would confuse.
        let ids = [
            C.id("B.JPG", "20261101T143005", 1, folder: "A|"),
            C.id("|B.JPG", "20261101T143005", 1, folder: "A"),
            C.id("B.JPG", "20261101T143005", 11, folder: "A"),
            C.id("B.JPG1", "20261101T143005", 1, folder: "A"),
            C.id("B.JPG", "20261101T143005", 1, folder: "A"),
            C.id("B.JPG", "20261101T143006", 1, folder: "A"),
            C.id("B.JPG", "20261101T143005", 1, folder: "A", camera: C.otherCamera),
            ObjectIdentity(camera: CameraKey(rawValue: "k|1:"), folder: "", filename: "B.JPG",
                           captureDate: CaptureDate(rawValue: "20261101T143005")!, size: 1),
            ObjectIdentity(camera: CameraKey(rawValue: "k"), folder: "|1:", filename: "B.JPG",
                           captureDate: CaptureDate(rawValue: "20261101T143005")!, size: 1),
        ]
        #expect(Set(ids.map(\.storageKey)).count == ids.count)
        #expect(C.id("B.JPG", "20261101T143005", 1, folder: "A").storageKey
            == C.id("B.JPG", "20261101T143005", 1, folder: "A").storageKey)
        #expect(C.id("DSC00001.ARW", "20261101T143005", 44, folder: "DCIM/100MSDCF").storageKey
            == "v1|15:hashed-key-0001|13:DCIM/100MSDCF|12:DSC00001.ARW|15:20261101T143005|2:44")
    }

    @Test func rowsRoundTripEveryRecord() {
        let id = C.id("DSC00001.ARW", "20261101T143005", .max)
        let locations: [ImportedLocation?] = [nil, .photosAsset(localIdentifier: "A/L0/001"),
                                              .file(relativePath: "Camera 0001/DSC00001.ARW")]
        for kind in PTPMediaKind.allCases {
            for state in ObjectState.allCases {
                for location in locations {
                    let r = CatalogueRecord(identity: id, format: kind, state: state, location: location,
                                            resumeOffset: .max)
                    #expect(CatalogueRow(r).record == r)
                }
            }
        }
    }

    @Test func rowColumnsAreWhatTheSchemaStores() {
        let r = CatalogueRecord(identity: C.id("DSC00001.ARW", "20261101T143005", 44_000_000), format: .raw,
                                state: .imported, location: .file(relativePath: "Camera 0001/DSC00001.ARW"))
        let row = CatalogueRow(r)
        #expect(row.cameraKey == "hashed-key-0001")
        #expect(row.identityKey == r.identity.storageKey)
        #expect(row.folder == "DCIM/100MSDCF")
        #expect(row.filename == "DSC00001.ARW")
        #expect(row.captureDate == "20261101T143005")
        #expect(row.size == 44_000_000)
        #expect(row.format == "raw")
        #expect(row.state == "imported")
        #expect(row.resumeOffset == 0)
        #expect(row.assetLocalID == nil)
        #expect(row.fileRelativePath == "Camera 0001/DSC00001.ARW")
        #expect(row.pairStem == "DSC00001")
    }

    @Test func unknownRawValuesFallBack() {
        var row = CatalogueRow(CatalogueRecord(identity: C.id("X.JPG", "20261101T143005", 1), format: .jpeg,
                                               state: .imported))
        row.format = "a-format-from-a-later-version"
        row.state = "culled"
        #expect(row.record?.format == .other)
        #expect(row.record?.state == .new)
        row.captureDate = "2026-11-01"
        #expect(row.record == nil)
    }

    @Test func progressRankOrdersStates() {
        let ranked = ObjectState.allCases.sorted { $0.progressRank < $1.progressRank }
        #expect(ranked == [.new, .skipped, .partial, .imported])
    }

    @Test func storedListingsRoundTripAndRejectOtherBlobs() throws {
        let listing = CardListing(camera: C.camera, listedAt: Date(timeIntervalSinceReferenceDate: 42.5), entries: [
            .init(identity: C.id("DSC00001.ARW", "20261101T143005", 44), format: .raw),
            .init(identity: C.id("DSC00001.JPG", "20261101T143005", .max, folder: ""), format: .jpeg),
        ])
        let data = try StoredListing.encode(listing)
        #expect(try StoredListing.decode(data, camera: C.camera, listedAt: listing.listedAt) == listing)
        // The blob carries no camera key: it is the stored row's.
        #expect(!String(decoding: data, as: UTF8.self).contains("hashed-key"))

        #expect(throws: StoredListing.Failure.unreadable) {
            try StoredListing.decode(Data("nonsense".utf8), camera: C.camera, listedAt: listing.listedAt)
        }
        #expect(throws: StoredListing.Failure.unreadable) {
            try StoredListing.decode(Data(#"{"version":2,"entries":[]}"#.utf8), camera: C.camera, listedAt: .now)
        }
        #expect(throws: StoredListing.Failure.unreadable) {
            let badDate = #"{"version":1,"entries":[{"folder":"","filename":"A","captureDate":"x","size":1,"#
                + #""format":"raw"}]}"#
            _ = try StoredListing.decode(Data(badDate.utf8), camera: C.camera, listedAt: .now)
        }
    }

    @Test func recordsEncodedBeforeResumeOffsetStillDecode() throws {
        let r = CatalogueRecord(identity: C.id("DSC00001.ARW", "20261101T143005", 44), format: .raw, state: .partial,
                                location: nil, resumeOffset: 7)
        let json = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(CatalogueRecord.self, from: json) == r)

        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        object.removeValue(forKey: "resumeOffset")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CatalogueRecord.self, from: old)
        #expect(decoded.resumeOffset == 0)
        #expect(decoded.identity == r.identity && decoded.state == .partial && decoded.location == nil)
    }
}
