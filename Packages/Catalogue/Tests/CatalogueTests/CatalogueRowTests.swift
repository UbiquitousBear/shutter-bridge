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

    // MARK: - Content match (Shamil's rule of 8 Nov), over rows shaped as build 17.1 wrote them

    @Test func contentKeysFoldASCIICaseAndMatchEquivalentUnicode() {
        let key = C.id("dsc04512.arw", "20261108T101530", 40_329_216).contentKey
        #expect(key.filename == "DSC04512.ARW")
        #expect(key == C.id("DSC04512.ARW", "20261108T101530", 40_329_216, folder: "", camera: C.mtpCamera).contentKey)
        #expect(ObjectIdentity.ContentKey.foldingASCIICase("\u{E9}t\u{E9}_1.jpg") == "\u{E9}T\u{E9}_1.JPG")
        #expect(ObjectIdentity.ContentKey.foldingASCIICase("DSC_0001.ARW") == "DSC_0001.ARW")
        #expect(ObjectIdentity.ContentKey.foldingASCIICase("") == "")
        // The folding changes ASCII letters only: a decomposed é keeps its bytes.
        #expect(ObjectIdentity.ContentKey.foldingASCIICase("e\u{301}").utf8.elementsEqual("E\u{301}".utf8))
        // Keys compare names as Swift strings, so canonically equivalent names match: a decomposed É is the
        // precomposed one, in `==` and in a set.
        let decomposed = C.id("E\u{301}.JPG", "20261108T101530", 1_000).contentKey
        let precomposed = C.id("\u{C9}.JPG", "20261108T101530", 1_000, folder: "", camera: C.mtpCamera).contentKey
        #expect(decomposed == precomposed)
        #expect(Set([decomposed, precomposed]).count == 1)
        // Different letters still differ, and so does case outside ASCII.
        #expect(decomposed != C.id("\u{C8}.JPG", "20261108T101530", 1_000).contentKey)
        #expect(precomposed != C.id("\u{E9}.JPG", "20261108T101530", 1_000).contentKey)
        #expect(key.description == "DSC04512.ARW 20261108T101530 40329216B")
    }

    @Test func rowsGiveTheirContentKeyFromTheColumns() {
        let identity = C.id("DSC04512.ARW", "20261108T101530", .max, camera: C.mscCamera)
        var row = CatalogueRow(CatalogueRecord(identity: identity, format: .raw, state: .imported))
        #expect(row.contentKey == identity.contentKey)
        row.captureDate = "2026-11-08"
        #expect(row.contentKey == nil)
    }

    @Test func contentMatchAnswersAcrossCamerasAndFolders() {
        func row(_ name: String, _ date: String, _ size: UInt64, folder: String = "DCIM/100MSDCF",
                 camera: CameraKey = C.mscCamera, state: ObjectState = .imported) -> CatalogueRow {
            CatalogueRow(CatalogueRecord(identity: C.id(name, date, size, folder: folder, camera: camera),
                                         format: .raw, state: state))
        }
        var badDate = row("DSC00005.ARW", "20261108T101534", 5)
        badDate.captureDate = "not a date"
        var unknownState = row("DSC00006.ARW", "20261108T101535", 6)
        unknownState.state = "culled"
        let rows = [
            // One file imported in MSC and again in MTP (17.1's duplicates).
            row("DSC00001.ARW", "20261108T101530", 1),
            row("DSC00001.ARW", "20261108T101530", 1, folder: "", camera: C.mtpCamera),
            // One file partial in MTP, skipped in MSC.
            row("DSC00002.ARW", "20261108T101531", 2, state: .skipped),
            row("DSC00002.ARW", "20261108T101531", 2, folder: "", camera: C.mtpCamera, state: .partial),
            // A size beyond Int64, stored by bit pattern.
            row("DSC00003.ARW", "20261108T101532", .max),
            row("DSC00004.ARW", "20261108T101533", UInt64(Int64.max) + 1),
            badDate,
            unknownState,
        ]
        let asMTP = { (name: String, date: String, size: UInt64) in
            C.id(name, date, size, folder: "", camera: C.mtpCamera)
        }
        let asked = [
            asMTP("DSC00001.ARW", "20261108T101530", 1),
            C.id("DSC00001.ARW", "20261108T101530", 1, camera: C.otherCamera),
            asMTP("DSC00002.ARW", "20261108T101531", 2),
            asMTP("DSC00003.ARW", "20261108T101532", .max),
            asMTP("DSC00004.ARW", "20261108T101533", UInt64(Int64.max) + 1),
            asMTP("DSC00004.ARW", "20261108T101533", UInt64(Int64.max)),
            asMTP("DSC00005.ARW", "20261108T101534", 5),
            asMTP("DSC00006.ARW", "20261108T101535", 6),
            asMTP("DSC00007.ARW", "20261108T101536", 7),
        ]
        #expect(ContentMatch.states(of: asked, among: rows) == [
            asked[0]: .imported, asked[1]: .imported, asked[2]: .partial, asked[3]: .imported, asked[4]: .imported,
            asked[5]: .new,
            // A row whose date doesn't parse matches nothing; an unknown state reads as new.
            asked[6]: .new, asked[7]: .new,
            asked[8]: .new,
        ])
        #expect(ContentMatch.states(of: [], among: rows).isEmpty)
        #expect(ContentMatch.states(of: asked, among: []).values.allSatisfy { $0 == .new })
    }

    @Test func furthestAlongPicksTheFurtherState() {
        for a in ObjectState.allCases {
            for b in ObjectState.allCases {
                let picked = a.furthestAlong(b)
                #expect(picked.progressRank == max(a.progressRank, b.progressRank))
            }
        }
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
