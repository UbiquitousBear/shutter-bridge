import Foundation
import PTPKit
import Testing
@testable import Catalogue

/// A store to run the contract against, with a way to read every row it holds (duplicates included).
struct StoreUnderTest: Sendable {
    let store: any CatalogueStore
    let rows: @Sendable () async throws -> [CatalogueRecord]
}

/// Every `CatalogueStore` this platform has: the in-memory one everywhere, and the SwiftData one (an in-memory
/// container) where SwiftData exists, so on a Mac and in CI's iOS Simulator run, not on Linux.
enum StoreKind: String, Sendable, CustomTestStringConvertible {
    case inMemory
    case swiftData

    static var available: [StoreKind] {
        #if canImport(SwiftData)
        return [.inMemory, .swiftData]
        #else
        return [.inMemory]
        #endif
    }

    var testDescription: String { rawValue }

    func make(records: [CatalogueRecord] = []) async throws -> StoreUnderTest {
        switch self {
        case .inMemory:
            let store = InMemoryCatalogue(records: records)
            return StoreUnderTest(store: store, rows: { await store.allRecords })
        case .swiftData:
            #if canImport(SwiftData)
            let store = SwiftDataCatalogue(modelContainer: try SwiftDataCatalogue.makeContainer(storeURL: nil))
            for r in records { try await store.upsert(r) }
            return StoreUnderTest(store: store, rows: { try await store.allRecords() })
            #else
            preconditionFailure("SwiftData isn't available here; StoreKind.available leaves it out")
            #endif
        }
    }
}

/// The rules every catalogue store keeps (backlog section 4), written once.
@Suite("Catalogue store contract")
struct CatalogueContractTests {
    static let camera = CameraKey(rawValue: "hashed-key-0001")
    static let otherCamera = CameraKey(rawValue: "hashed-key-0002")

    static func id(_ name: String, _ date: String, _ size: UInt64, folder: String = "DCIM/100MSDCF",
                   camera: CameraKey = camera) -> ObjectIdentity {
        ObjectIdentity(camera: camera, folder: folder, filename: name, captureDate: CaptureDate(rawValue: date)!,
                       size: size)
    }

    let first = Self.id("DSC00001.ARW", "20261101T143005", 44_000_000)

    @Test(arguments: StoreKind.available)
    func unknownIdentitiesAreNew(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        #expect(try await s.store.states(of: [first]) == [first: .new])
        #expect(try await s.store.record(for: first) == nil)
        #expect(try await s.store.states(of: []) == [:])
        #expect(try await s.rows().isEmpty)
    }

    @Test(arguments: StoreKind.available)
    func secondInsertUpdatesInsteadOfDuplicating(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.upsert(CatalogueRecord(identity: first, format: .raw, state: .partial))
        let imported = CatalogueRecord(identity: first, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        try await s.store.upsert(imported)
        #expect(try await s.rows() == [imported])
        #expect(try await s.store.record(for: first) == imported)
        #expect(try await s.store.states(of: [first]) == [first: .imported])

        // The same record again changes nothing.
        try await s.store.upsert(imported)
        #expect(try await s.rows() == [imported])
    }

    @Test(arguments: StoreKind.available)
    func filenameReusedAfterTheCounterWrapsIsANewFile(_ kind: StoreKind) async throws {
        // DSC00001 again, 10,000 frames later: same name, a different capture date (and size), in the same folder
        // or the next one. Each is a file of its own.
        let s = try await kind.make(records: [CatalogueRecord(identity: first, format: .raw, state: .imported)])
        let sameFolder = Self.id("DSC00001.ARW", "20270301T090000", 45_123_456)
        let nextFolder = Self.id("DSC00001.ARW", "20270301T090000", 45_123_456, folder: "DCIM/101MSDCF")
        let sameSizeOtherDate = Self.id("DSC00001.ARW", "20270301T090000", 44_000_000)
        #expect(try await s.store.states(of: [first, sameFolder, nextFolder, sameSizeOtherDate])
            == [first: .imported, sameFolder: .new, nextFolder: .new, sameSizeOtherDate: .new])

        try await s.store.upsert(CatalogueRecord(identity: sameSizeOtherDate, format: .raw, state: .imported))
        #expect(try await s.rows().count == 2)
        #expect(try await s.store.states(of: [first, sameSizeOtherDate, sameFolder])
            == [first: .imported, sameSizeOtherDate: .imported, sameFolder: .new])
    }

    @Test(arguments: StoreKind.available)
    func identityIncludesTheCamera(_ kind: StoreKind) async throws {
        let s = try await kind.make(records: [CatalogueRecord(identity: first, format: .raw, state: .imported)])
        let onOtherCamera = Self.id("DSC00001.ARW", "20261101T143005", 44_000_000, camera: Self.otherCamera)
        #expect(try await s.store.states(of: [first, onOtherCamera]) == [first: .imported, onOtherCamera: .new])
    }

    @Test(arguments: StoreKind.available)
    func everyStateRoundTrips(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        var expected: [ObjectIdentity: ObjectState] = [:]
        for (i, state) in ObjectState.allCases.enumerated() {
            let identity = Self.id(String(format: "DSC%05d.JPG", i + 10), "20261101T1430\(10 + i)", UInt64(1000 + i))
            let record = CatalogueRecord(identity: identity, format: .jpeg, state: state,
                                         resumeOffset: state == .partial ? 1_048_576 : 0)
            try await s.store.upsert(record)
            #expect(try await s.store.record(for: identity) == record, "\(state)")
            expected[identity] = state
        }
        #expect(try await s.store.states(of: Array(expected.keys)) == expected)

        // A state moves both ways: imported back to partial (a later decision) and partial to skipped.
        let identity = try #require(expected.first(where: { $0.value == .imported })?.key)
        let backToPartial = CatalogueRecord(identity: identity, format: .jpeg, state: .partial, resumeOffset: 4096)
        try await s.store.upsert(backToPartial)
        #expect(try await s.store.states(of: [identity]) == [identity: .partial])
        #expect(try await s.store.record(for: identity) == backToPartial)
        let skipped = CatalogueRecord(identity: identity, format: .jpeg, state: .skipped)
        try await s.store.upsert(skipped)
        #expect(try await s.store.states(of: [identity]) == [identity: .skipped])
        #expect(try await s.store.record(for: identity) == skipped)
    }

    @Test(arguments: StoreKind.available)
    func everyColumnRoundTrips(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let records = [
            CatalogueRecord(identity: first, format: .raw, state: .imported,
                            location: .file(relativePath: "Camera 0001/DSC00001.ARW")),
            CatalogueRecord(identity: Self.id("DSC00002.HIF", "20261101T143006", 9_000_000), format: .heif,
                            state: .imported, location: .photosAsset(localIdentifier: "B/L0/001")),
            CatalogueRecord(identity: Self.id("DSC00003.MP4", "20261101T143007", 6_000_000_000, folder: ""),
                            format: .video, state: .new),
            // Sizes beyond Int64 (none a card holds) still round-trip.
            CatalogueRecord(identity: Self.id("BIG.ARW", "20261101T143008", .max), format: .raw, state: .partial,
                            resumeOffset: .max - 1),
            // Names that look like the storage key's separators.
            CatalogueRecord(identity: Self.id("A|3:B.JPG", "20261101T143009", 1, folder: "x|1:"), format: .jpeg,
                            state: .skipped),
        ]
        for r in records { try await s.store.upsert(r) }
        for r in records {
            #expect(try await s.store.record(for: r.identity) == r)
        }
        #expect(Set(try await s.rows()) == Set(records))
    }

    @Test(arguments: StoreKind.available)
    func anImportToFilesStaysImportedWithItsPath(_ kind: StoreKind) async throws {
        // Decision 9: a file imported to Files keeps its path and stays imported when Photos access is granted later.
        let s = try await kind.make()
        let toFiles = CatalogueRecord(identity: first, format: .raw, state: .imported,
                                      location: .file(relativePath: "Camera 0001/DSC00001.ARW"))
        try await s.store.upsert(toFiles)
        #expect(try await s.store.record(for: first)?.location == .file(relativePath: "Camera 0001/DSC00001.ARW"))
        #expect(try await s.store.states(of: [first]) == [first: .imported])

        // Updating the row to a Photos asset replaces the location.
        let toPhotos = CatalogueRecord(identity: first, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "C/L0/001"))
        try await s.store.upsert(toPhotos)
        #expect(try await s.store.record(for: first) == toPhotos)
    }

    @Test(arguments: StoreKind.available)
    func theLastListingRoundTripsPerCameraAndIsReplaced(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let entries: [CardListing.Entry] = [
            .init(identity: first, format: .raw),
            .init(identity: Self.id("DSC00001.JPG", "20261101T143005", 9_100_000), format: .jpeg),
            .init(identity: Self.id("DSC00001.ARW", "20270301T090000", 45_123_456, folder: "DCIM/101MSDCF"),
                  format: .raw),
            .init(identity: Self.id("C0001.MP4", "20261102T080000", 5_000_000_000, folder: "PRIVATE/M4ROOT/CLIP"),
                  format: .video),
            .init(identity: Self.id("UNFILED.JPG", "20261103T120000", 1, folder: ""), format: .jpeg),
        ]
        let old = CardListing(camera: Self.camera, listedAt: Date(timeIntervalSinceReferenceDate: 815_000_000.25),
                              entries: entries)
        try await s.store.saveListing(old)
        #expect(try await s.store.lastListing(for: Self.camera) == old)
        #expect(try await s.store.lastListing(for: Self.otherCamera) == nil)

        let new = CardListing(camera: Self.camera, listedAt: Date(timeIntervalSinceReferenceDate: 815_000_060),
                              entries: Array(entries.prefix(2)))
        let other = CardListing(camera: Self.otherCamera, listedAt: Date(timeIntervalSinceReferenceDate: 1),
                                entries: [])
        try await s.store.saveListing(new)
        try await s.store.saveListing(other)
        #expect(try await s.store.lastListing(for: Self.camera) == new)
        #expect(try await s.store.lastListing(for: Self.otherCamera) == other)

        // A listing is not a row: nothing was imported.
        #expect(try await s.rows().isEmpty)
        #expect(try await s.store.states(of: [first]) == [first: .new])
    }

    @Test(arguments: StoreKind.available)
    func concurrentUpsertsOfOneIdentityGiveOneRow(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let store = s.store
        let identity = first
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0 ..< 64 {
                group.addTask {
                    let state: ObjectState = i.isMultiple(of: 2) ? .partial : .imported
                    try await store.upsert(CatalogueRecord(identity: identity, format: .raw, state: state))
                }
            }
            // Other identities alongside, so the writes interleave with unrelated ones.
            for i in 0 ..< 16 {
                group.addTask {
                    let other = Self.id(String(format: "DSC%05d.ARW", 100 + i), "20261101T143005", 44_000_000)
                    try await store.upsert(CatalogueRecord(identity: other, format: .raw, state: .imported))
                }
            }
            try await group.waitForAll()
        }
        let rows = try await s.rows()
        #expect(rows.filter { $0.identity == identity }.count == 1)
        #expect(rows.count == 17)
        let state = try #require(try await store.states(of: [identity])[identity])
        #expect(state == .partial || state == .imported)
    }
}
