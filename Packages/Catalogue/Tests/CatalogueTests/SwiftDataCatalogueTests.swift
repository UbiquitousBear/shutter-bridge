#if canImport(SwiftData)
import Foundation
import PTPKit
import SwiftData
import Testing
@testable import Catalogue

/// What only the SwiftData store has: the schema opening, a store on disk reopening, a version-1 store (as every
/// build before Catalogue V2, 17.1 and 18.1, wrote it) migrating to version 2, and duplicates written by someone else
/// being healed. Runs where SwiftData exists (a Mac, CI's iOS Simulator run), not on Linux.
@Suite("SwiftData catalogue")
struct SwiftDataCatalogueTests {
    typealias C = CatalogueContractTests

    @Test func theSchemaIsVersionedWithAPlan() {
        #expect(CatalogueSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(CatalogueSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(CatalogueSchemaV1.models.count == 3)
        #expect(CatalogueSchemaV2.models.count == 3)
        #expect(CatalogueMigrationPlan.schemas.count == 2)
        #expect(CatalogueMigrationPlan.stages.count == 1)
        // The store opens the current version.
        #expect(ObjectIdentifier(CatalogueCurrentSchema.self) == ObjectIdentifier(CatalogueSchemaV2.self))
        // CloudKit-compatible: nothing is unique, neither an attribute nor a `#Unique` constraint on the model (the
        // store enforces identity), and every relationship is optional. Both versions.
        for version in [CatalogueSchemaV1.self, CatalogueSchemaV2.self] as [any VersionedSchema.Type] {
            let schema = Schema(versionedSchema: version)
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
    }

    /// Version 2 is version 1 plus one optional attribute on `Camera`, which is what makes the stage lightweight.
    @Test func versionTwoAddsOnlyTheOptionalPeripheralIdentifier() throws {
        let v1 = Schema(versionedSchema: CatalogueSchemaV1.self)
        let v2 = Schema(versionedSchema: CatalogueSchemaV2.self)
        func names(_ schema: Schema) -> [String: Set<String>] {
            Dictionary(uniqueKeysWithValues: schema.entities.map { ($0.name, Set($0.attributes.map(\.name))) })
        }
        func relationships(_ schema: Schema) -> [String: Set<String>] {
            Dictionary(uniqueKeysWithValues: schema.entities.map { ($0.name, Set($0.relationships.map(\.name))) })
        }
        var expected = names(v1)
        expected["Camera", default: []].insert("bluetoothPeripheralID")
        #expect(names(v2) == expected)
        #expect(relationships(v2) == relationships(v1))
        let camera = try #require(v2.entities.first { $0.name == "Camera" })
        let peripheral = try #require(camera.attributes.first { $0.name == "bluetoothPeripheralID" })
        #expect(peripheral.isOptional)
        // No column could hold a password.
        for entity in v2.entities {
            for attribute in entity.attributes {
                #expect(!attribute.name.lowercased().contains("pass"), "\(entity.name).\(attribute.name)")
            }
        }
    }

    /// The schema every build before Catalogue V2 (17.1 and 18.1) shipped, which every later build has to open as it
    /// is: changing a version-1 model without a new version and a stage would leave the store unopenable ("Shutter
    /// Bridge couldn't start"). Shamil's rule of 8 Nov needed no change (it reads the name, date and size columns every
    /// row has). This pins the version, the plan and the **names** of V1's attributes and relationships only: an
    /// in-place edit that keeps the names (a type, optionality or attribute options) changes the model's version hash
    /// and isn't caught here.
    @Test func theShippedSchemaIsUnchanged() {
        #expect(CatalogueSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        // Version 1 stays first in the plan, so a store it wrote migrates rather than failing to open.
        #expect(CatalogueMigrationPlan.schemas.map { ObjectIdentifier($0) }
            == [ObjectIdentifier(CatalogueSchemaV1.self), ObjectIdentifier(CatalogueSchemaV2.self)])
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
            // Written with version 1's schema and a version-1-only plan, as build 17.1 wrote it.
            let container = try Self.makeVersion1Container(storeURL: url)
            let context = ModelContext(container)
            for record in [bothInMSC, bothInMTP, onlyInMSC] {
                context.insert(CatalogueSchemaV1.CameraObject(row: CatalogueRow(record)))
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

    // MARK: - Version 1 → version 2 (Iteration 3)

    /// The plan every build before Catalogue V2 (17.1 and 18.1) shipped with: version 1 only.
    enum Version1OnlyPlan: SchemaMigrationPlan, Sendable {
        static var schemas: [any VersionedSchema.Type] { [CatalogueSchemaV1.self] }
        static var stages: [MigrationStage] { [] }
    }

    /// A container on disk exactly as every build before Catalogue V2 (17.1 and 18.1) made one: version 1's schema
    /// and plan, CloudKit off.
    static func makeVersion1Container(storeURL: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: CatalogueSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL,
                                               cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none)
        return try ModelContainer(for: schema, migrationPlan: Version1OnlyPlan.self, configurations: configuration)
    }

    /// The silent-failure risk of a migration: a version-1 store holding real data (a camera with every field set,
    /// a last listing, imported, partial and skipped rows linked to it, an import job) opens as version 2 with every
    /// value carried, the new peripheral identifier nil, and takes version 2's writes, which survive a reopen.
    @Test func aVersion1StoreWithRealDataOpensAsVersion2WithEverythingCarried() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "catalogue-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Catalogue.store", directoryHint: .notDirectory)
        let key = C.camera
        let imported = CatalogueRecord(identity: C.id("DSC04512.ARW", "20261108T101530", 40_329_216),
                                       format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "E/L0/001"))
        let partial = CatalogueRecord(identity: C.id("DSC04513.ARW", "20261108T101602", 41_000_000),
                                      format: .raw, state: .partial, resumeOffset: 16_777_216)
        let skipped = CatalogueRecord(identity: C.id("DSC04514.JPG", "20261108T101603", 9_400_124),
                                      format: .jpeg, state: .skipped)
        let toFiles = CatalogueRecord(identity: C.id("DSC04515.HIF", "20261108T101604", 9_000_000, folder: ""),
                                      format: .heif, state: .imported,
                                      location: .file(relativePath: "ILCE-7CM2/DSC04515.HIF"))
        let listing = CardListing(camera: key, listedAt: Date(timeIntervalSinceReferenceDate: 815_000_100.25),
                                  entries: [.init(identity: imported.identity, format: .raw),
                                            .init(identity: partial.identity, format: .raw)])
        let lastSeen = Date(timeIntervalSinceReferenceDate: 815_000_200.5)
        let guid = CameraFixtures.guid
        let partialFile = CameraFixtures.partialFile("DSC04513")
        do {
            let container = try Self.makeVersion1Container(storeURL: url)
            let context = ModelContext(container)
            let camera = CatalogueSchemaV1.Camera(serial: key.rawValue)
            camera.model = "ILCE-7CM2"
            camera.friendlyName = "Shamil's camera"
            camera.lastSeen = lastSeen
            camera.preferredCarrier = "wifi"
            camera.autoImport = true
            camera.wifiSSID = CameraFixtures.ssid
            camera.lastIP = CameraFixtures.ip
            camera.ptpipGUID = guid
            camera.lastListedAt = listing.listedAt
            camera.lastListing = try StoredListing.encode(listing)
            context.insert(camera)
            for record in [imported, partial, skipped, toFiles] {
                let object = CatalogueSchemaV1.CameraObject(row: CatalogueRow(record))
                if record.state == .partial { object.tempURL = partialFile }
                context.insert(object)
                object.camera = camera
            }
            let job = CatalogueSchemaV1.ImportJob(startedAt: Date(timeIntervalSinceReferenceDate: 815_000_000))
            context.insert(job)
            job.camera = camera
            try context.save()
        }

        var partialWithFile = partial
        partialWithFile.tempURL = partialFile
        let carried = CameraRecord(key: key, model: "ILCE-7CM2", friendlyName: "Shamil's camera", lastSeen: lastSeen,
                                   preferredCarrier: .wifi, autoImport: true, wifiSSID: CameraFixtures.ssid,
                                   lastIP: CameraFixtures.ip, ptpipGUID: guid, bluetoothPeripheralID: nil)
        do {
            let store = SwiftDataCatalogue(modelContainer: try SwiftDataCatalogue.makeContainer(storeURL: url))
            #expect(Set(try await store.allRecords()) == [imported, partialWithFile, skipped, toFiles])
            #expect(try await store.record(for: partial.identity) == partialWithFile)
            #expect(try await store.states(of: [imported.identity, partial.identity, skipped.identity])
                == [imported.identity: .imported, partial.identity: .partial, skipped.identity: .skipped])
            #expect(try await store.lastListing(for: key) == listing)
            #expect(try await store.camera(key) == carried)
            #expect(try await store.cameras() == [carried])

            // The relationships came across: one camera row, its four files and its job.
            let context = ModelContext(store.modelContainer)
            let cameras = try context.fetch(FetchDescriptor<Camera>())
            #expect(cameras.count == 1)
            #expect(cameras.first?.objects?.count == 4)
            #expect(cameras.first?.jobs?.count == 1)
            #expect(cameras.first?.bluetoothPeripheralID == nil)

            // Version 2's writes.
            var paired = carried
            paired.bluetoothPeripheralID = CameraFixtures.peripheral
            try await store.upsertCamera(paired)
            try await store.markPartial(partial.identity, format: .raw, tempURL: partialFile, offset: 33_554_432)
        }

        let reopened = SwiftDataCatalogue(modelContainer: try SwiftDataCatalogue.makeContainer(storeURL: url))
        #expect(try await reopened.camera(key)?.bluetoothPeripheralID == CameraFixtures.peripheral)
        #expect(try await reopened.camera(key)?.wifiSSID == CameraFixtures.ssid)
        #expect(try await reopened.record(for: partial.identity)?.resumeOffset == 33_554_432)
        #expect(try await reopened.record(for: imported.identity) == imported)
        #expect(try await reopened.lastListing(for: key) == listing)
    }

    /// A version-1 store with no rows at all (a fresh install of 17.1 or 18.1 that never imported) opens too.
    @Test func anEmptyVersion1StoreOpensAsVersion2() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "catalogue-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Catalogue.store", directoryHint: .notDirectory)
        do {
            let container = try Self.makeVersion1Container(storeURL: url)
            try ModelContext(container).save()
        }
        let store = SwiftDataCatalogue(modelContainer: try SwiftDataCatalogue.makeContainer(storeURL: url))
        #expect(try await store.cameras().isEmpty)
        #expect(try await store.allRecords().isEmpty)
        try await store.upsertCamera(CameraFixtures.full)
        #expect(try await store.camera(CameraFixtures.key) == CameraFixtures.full)
    }

    @Test func aCheckpointHealsDuplicatesAndLinksTheCameraRow() async throws {
        let container = try SwiftDataCatalogue.makeContainer(storeURL: nil)
        let identity = C.id("DSC00004.ARW", "20261101T143008", 44_000_000)
        let context = ModelContext(container)
        for state in [ObjectState.skipped, .new] {
            context.insert(CameraObject(row: CatalogueRow(CatalogueRecord(identity: identity, format: .raw,
                                                                          state: state))))
        }
        try context.save()

        let store = SwiftDataCatalogue(modelContainer: container)
        let url = CameraFixtures.partialFile("DSC00004")
        try await store.markPartial(identity, format: .raw, tempURL: url, offset: 16_777_216)
        #expect(try await store.allRecords()
            == [CatalogueRecord(identity: identity, format: .raw, state: .partial, resumeOffset: 16_777_216,
                                tempURL: url)])
        let objects = try ModelContext(container).fetch(FetchDescriptor<CameraObject>())
        #expect(objects.count == 1)
        #expect(objects.first?.camera?.serial == C.camera.rawValue)
        #expect(objects.first?.tempURL == url)
    }

    @Test func theCameraRowKeepsItsListingWhenItsFieldsAreWritten() async throws {
        let container = try SwiftDataCatalogue.makeContainer(storeURL: nil)
        let store = SwiftDataCatalogue(modelContainer: container)
        let listing = CardListing(camera: CameraFixtures.key, listedAt: Date(timeIntervalSinceReferenceDate: 7),
                                  entries: [])
        try await store.saveListing(listing)
        try await store.upsertCamera(CameraFixtures.full)
        let cameras = try ModelContext(container).fetch(FetchDescriptor<Camera>())
        #expect(cameras.count == 1)
        #expect(cameras.first?.lastListedAt == Date(timeIntervalSinceReferenceDate: 7))
        #expect(try await store.lastListing(for: CameraFixtures.key) == listing)
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

    @Test func duplicateCameraRowsWrittenElsewhereReadAlikeAndAreAllWritten() async throws {
        let container = try SwiftDataCatalogue.makeContainer(storeURL: nil)
        let key = CameraFixtures.key
        // Two rows for one key, as a second store on the same file or a sync could leave them: the one seen last
        // is inserted first, the other has the peripheral.
        let context = ModelContext(container)
        let seenLast = Camera(serial: key.rawValue)
        seenLast.lastSeen = Date(timeIntervalSinceReferenceDate: 200)
        seenLast.lastIP = CameraFixtures.ip
        let withPeripheral = Camera(serial: key.rawValue)
        withPeripheral.lastSeen = Date(timeIntervalSinceReferenceDate: 100)
        withPeripheral.bluetoothPeripheralID = CameraFixtures.peripheral
        context.insert(withPeripheral)
        context.insert(seenLast)
        try context.save()

        let store = SwiftDataCatalogue(modelContainer: container)
        let expected = CameraRecord(key: key, lastSeen: Date(timeIntervalSinceReferenceDate: 200),
                                    lastIP: CameraFixtures.ip)
        #expect(try await store.camera(key) == expected)
        #expect(try await store.cameras() == [expected])

        // A camera write reaches both rows, so either answers the same; neither is deleted (each may own files).
        let stored = try await store.updateCamera(key) { $0.ptpipGUID = CameraFixtures.guid }
        var written = expected
        written.ptpipGUID = CameraFixtures.guid
        #expect(stored == written)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Camera>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.columns.record == written })
        #expect(try await store.camera(key) == written)
    }
}
#endif
