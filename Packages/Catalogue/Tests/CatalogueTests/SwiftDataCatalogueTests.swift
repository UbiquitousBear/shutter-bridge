#if canImport(SwiftData)
import Foundation
import PTPKit
import SwiftData
import Testing
@testable import Catalogue

/// What only the SwiftData store has: the schema opening, a store on disk reopening, and duplicates written by
/// someone else being healed. Runs where SwiftData exists (a Mac, CI's iOS Simulator run), not on Linux.
@Suite("SwiftData catalogue")
struct SwiftDataCatalogueTests {
    typealias C = CatalogueContractTests

    @Test func theSchemaIsVersionedWithAPlan() {
        #expect(CatalogueSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(CatalogueSchemaV1.models.count == 3)
        #expect(CatalogueMigrationPlan.schemas.count == 1)
        #expect(CatalogueMigrationPlan.stages.isEmpty)
        // CloudKit-compatible: nothing is unique, neither an attribute nor a `#Unique` constraint on the model (the
        // store enforces identity), and every relationship is optional.
        let schema = Schema(versionedSchema: CatalogueSchemaV1.self)
        for entity in schema.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name)")
            for attribute in entity.attributes {
                #expect(!attribute.isUnique, "\(entity.name).\(attribute.name)")
            }
            for relationship in entity.relationships {
                #expect(relationship.isOptional, "\(entity.name).\(relationship.name)")
            }
        }
    }

    /// The schema build 17.1 shipped, which every later build has to open as it is: changing a version-1 model
    /// without a new version and a stage would leave the store unopenable ("Shutter Bridge couldn't start"). Shamil's
    /// rule of 8 Nov needed no change (it reads the name, date and size columns every row has). This pins the version,
    /// the plan and the **names** of V1's attributes and relationships only: an in-place edit that keeps the names
    /// (a type, optionality or attribute options) changes the model's version hash and isn't caught here.
    @Test func theShippedSchemaIsUnchanged() {
        #expect(CatalogueSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(CatalogueMigrationPlan.schemas.map { ObjectIdentifier($0) }
            == [ObjectIdentifier(CatalogueSchemaV1.self)])
        #expect(CatalogueMigrationPlan.stages.isEmpty)
        let schema = Schema(versionedSchema: CatalogueSchemaV1.self)
        let attributes = Set(schema.entities.map { Set($0.attributes.map(\.name)) })
        #expect(attributes == [
            // Camera
            ["serial", "model", "friendlyName", "lastSeen", "preferredCarrier", "autoImport", "wifiSSID", "lastIP",
             "ptpipGUID", "lastListedAt", "lastListing"],
            // CameraObject
            ["cameraKey", "identityKey", "folder", "filename", "captureDate", "size", "format", "state",
             "resumeOffset", "tempURL", "assetLocalID", "fileRelativePath", "pairStem"],
            // ImportJob
            ["jobID", "startedAt", "finishedAt", "selection", "bytesTotal", "bytesDone", "outcome"],
        ])
        let relationships = Set(schema.entities.map { Set($0.relationships.map(\.name)) })
        #expect(relationships == [["objects", "jobs"], ["camera"]])
    }

    /// Rows as build 17.1 wrote them (it matched per camera): a file imported in MSC and again in MTP has two rows,
    /// and another file only an MSC row. The new build opens that store as it is and finds them by content.
    @Test func rowsWrittenByBuild17_1AreFoundByContent() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "catalogue-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Catalogue.store", directoryHint: .notDirectory)
        let msc = C.mscCamera
        let mtp = C.mtpCamera
        let bothInMSC = CatalogueRecord(identity: C.id("DSC04512.ARW", "20261108T101530", 40_329_216, camera: msc),
                                        format: .raw, state: .imported,
                                        location: .file(relativePath: "Untitled/DSC04512.ARW"))
        let bothInMTP = CatalogueRecord(identity: C.id("DSC04512.ARW", "20261108T101530", 40_329_216, folder: "",
                                                       camera: mtp),
                                        format: .raw, state: .imported,
                                        location: .file(relativePath: "ILCE-7CM2/DSC04512.ARW"))
        let onlyInMSC = CatalogueRecord(identity: C.id("DSC04513.JPG", "20261108T101602", 9_400_123, camera: msc),
                                        format: .jpeg, state: .imported,
                                        location: .photosAsset(localIdentifier: "E/L0/001"))
        do {
            let container = try SwiftDataCatalogue.makeContainer(storeURL: url)
            let context = ModelContext(container)
            for record in [bothInMSC, bothInMTP, onlyInMSC] {
                context.insert(CameraObject(row: CatalogueRow(record)))
            }
            try context.save()
        }

        let reopened = SwiftDataCatalogue(modelContainer: try SwiftDataCatalogue.makeContainer(storeURL: url))
        let onlyListedInMTP = C.id("DSC04513.JPG", "20261108T101602", 9_400_123, folder: "", camera: mtp)
        let neverImported = C.id("DSC04514.JPG", "20261108T101603", 9_400_124, folder: "", camera: mtp)
        #expect(try await reopened.states(of: [bothInMTP.identity, onlyListedInMTP, neverImported])
            == [bothInMTP.identity: .imported, onlyListedInMTP: .imported, neverImported: .new])
        #expect(Set(try await reopened.allRecords()) == [bothInMSC, bothInMTP, onlyInMSC])
        #expect(try await reopened.record(for: bothInMSC.identity) == bothInMSC)
        #expect(try await reopened.record(for: bothInMTP.identity) == bothInMTP)
        // Writing one of the pair again keeps all three rows.
        try await reopened.upsert(bothInMTP)
        #expect(try await reopened.allRecords().count == 3)
    }

    @Test func aRequestLargerThanOneFetchChunkAnswersEveryIdentity() async throws {
        let store = try await SwiftDataCatalogue.open(storeURL: nil)
        let count = SwiftDataCatalogue.sizesPerFetch * 2 + 200
        var asked: [ObjectIdentity] = []
        for i in 0 ..< count {
            let identity = C.id(String(format: "DSC%05d.ARW", i), "20261108T101530", UInt64(40_000_000 + i))
            asked.append(identity)
            // Every third file was imported, under another camera and with no folder.
            if i.isMultiple(of: 3) {
                var elsewhere = identity
                elsewhere.camera = C.mtpCamera
                elsewhere.folder = ""
                try await store.upsert(CatalogueRecord(identity: elsewhere, format: .raw, state: .imported))
            }
        }
        let states = try await store.states(of: asked)
        #expect(states.count == count)
        for (i, identity) in asked.enumerated() {
            #expect(states[identity] == (i.isMultiple(of: 3) ? .imported : .new), "\(identity.filename)")
        }
    }

    @MainActor @Test func openedFromTheMainActorItWritesOffIt() async throws {
        let store = try await SwiftDataCatalogue.open(storeURL: nil)
        #expect(await store.isOnMainThread() == false)
        let record = CatalogueRecord(identity: C.id("DSC00009.ARW", "20261101T143009", 1), format: .raw,
                                     state: .imported)
        try await store.upsert(record)
        #expect(try await store.record(for: record.identity) == record)
    }

    struct WriteFailed: Error {}

    @Test func aWriteThatFailsPartWayLeavesNothingPending() async throws {
        let store = try await SwiftDataCatalogue.open(storeURL: nil)
        let stray = C.id("DSC00010.ARW", "20261101T143010", 1)
        // Changes made, then a throw before the save, as when a fetch fails after the row was touched.
        await #expect(throws: WriteFailed.self) {
            try await store.write { context in
                context.insert(CameraObject(row: CatalogueRow(CatalogueRecord(identity: stray, format: .raw,
                                                                              state: .imported))))
                throw WriteFailed()
            }
        }
        #expect(try await store.states(of: [stray]) == [stray: .new])
        #expect(try await store.record(for: stray) == nil)
        // The next write saves only its own change.
        let next = CatalogueRecord(identity: C.id("DSC00011.ARW", "20261101T143011", 1), format: .raw,
                                   state: .imported)
        try await store.upsert(next)
        #expect(try await store.allRecords() == [next])
    }

    @Test func anOnDiskStoreReopensWithItsRows() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "catalogue-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Catalogue.store", directoryHint: .notDirectory)
        let record = CatalogueRecord(identity: C.id("DSC00001.ARW", "20261101T143005", 44_000_000), format: .raw,
                                     state: .imported, location: .file(relativePath: "Camera 0001/DSC00001.ARW"))
        let listing = CardListing(camera: C.camera, listedAt: Date(timeIntervalSinceReferenceDate: 100),
                                  entries: [.init(identity: record.identity, format: .raw)])
        do {
            let store = SwiftDataCatalogue(modelContainer: try SwiftDataCatalogue.makeContainer(storeURL: url))
            try await store.upsert(record)
            try await store.saveListing(listing)
        }
        let reopened = SwiftDataCatalogue(modelContainer: try SwiftDataCatalogue.makeContainer(storeURL: url))
        #expect(try await reopened.record(for: record.identity) == record)
        #expect(try await reopened.lastListing(for: C.camera) == listing)
    }

    @Test func aSecondStoreOnTheContainerSeesSavedWrites() async throws {
        let container = try SwiftDataCatalogue.makeContainer(storeURL: nil)
        let writer = SwiftDataCatalogue(modelContainer: container)
        let reader = SwiftDataCatalogue(modelContainer: container)
        let record = CatalogueRecord(identity: C.id("DSC00002.ARW", "20261101T143006", 1), format: .raw,
                                     state: .imported)
        try await writer.upsert(record)
        #expect(try await reader.record(for: record.identity) == record)
    }

    @Test func rowsLinkToOneCameraRow() async throws {
        let container = try SwiftDataCatalogue.makeContainer(storeURL: nil)
        let store = SwiftDataCatalogue(modelContainer: container)
        for i in 0 ..< 3 {
            try await store.upsert(CatalogueRecord(identity: C.id("DSC0000\(i).ARW", "20261101T143005", 1),
                                                   format: .raw, state: .imported))
        }
        try await store.saveListing(CardListing(camera: C.camera, listedAt: Date(timeIntervalSinceReferenceDate: 9),
                                                entries: []))
        let context = ModelContext(container)
        let cameras = try context.fetch(FetchDescriptor<Camera>())
        #expect(cameras.count == 1)
        #expect(cameras.first?.serial == C.camera.rawValue)
        #expect(cameras.first?.objects?.count == 3)
        #expect(cameras.first?.lastSeen == Date(timeIntervalSinceReferenceDate: 9))
        let objects = try context.fetch(FetchDescriptor<CameraObject>())
        #expect(objects.allSatisfy { $0.camera?.serial == C.camera.rawValue && $0.resumeOffset == 0 })
    }

    @Test func duplicatesWrittenElsewhereAreReadAsTheFurthestAlongAndHealedOnWrite() async throws {
        let container = try SwiftDataCatalogue.makeContainer(storeURL: nil)
        let identity = C.id("DSC00003.ARW", "20261101T143007", 1)
        let partial = CatalogueRecord(identity: identity, format: .raw, state: .partial)
        let imported = CatalogueRecord(identity: identity, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "D/L0/001"))
        // Two rows for one identity, as a second store on the same file or a sync could leave them.
        let context = ModelContext(container)
        context.insert(CameraObject(row: CatalogueRow(partial)))
        context.insert(CameraObject(row: CatalogueRow(imported)))
        try context.save()

        let store = SwiftDataCatalogue(modelContainer: container)
        #expect(try await store.allRecords().count == 2)
        #expect(try await store.record(for: identity) == imported)
        #expect(try await store.states(of: [identity]) == [identity: .imported])

        let skipped = CatalogueRecord(identity: identity, format: .raw, state: .skipped)
        try await store.upsert(skipped)
        #expect(try await store.allRecords() == [skipped])
    }
}
#endif
