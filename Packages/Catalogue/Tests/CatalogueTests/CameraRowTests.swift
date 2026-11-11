import Foundation
import PTPKit
import Testing
@testable import Catalogue

// Catalogue V2 (wireless plan, W4): the Camera row's reader and writer, and partial-file rows. The pure parts run
// everywhere; the contract runs against every store this platform has (`StoreKind.available`): the in-memory store on
// Linux, and the SwiftData store too in CI's iOS Simulator run.

/// Made-up values only: no real identifier, network name or address.
enum CameraFixtures {
    static let key = CatalogueContractTests.camera
    static let otherKey = CatalogueContractTests.otherCamera
    static let peripheral = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
    static let guid = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let ssid = "EXAMPLE-SSID-0000"
    static let ip = "192.0.2.10"   // TEST-NET-1, documentation only

    static var full: CameraRecord {
        CameraRecord(key: key, model: "ILCE-7CM2", friendlyName: "Shamil's camera",
                     lastSeen: Date(timeIntervalSinceReferenceDate: 815_000_000.5), preferredCarrier: .wifi,
                     autoImport: true, wifiSSID: ssid, lastIP: ip, ptpipGUID: guid, bluetoothPeripheralID: peripheral)
    }

    /// A partial file as the engine names it: relative to its staging folder, in the job's own folder.
    static func partialFile(_ name: String) -> URL {
        URL(string: "00000000-0000-4000-8000-0000000000C1/\(name).partial")!
    }

    /// The staging folder under two container paths, before and after an app update moved the container.
    static let stagingBefore = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/A/tmp/staging",
                                   isDirectory: true)
    static let stagingAfter = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/B/tmp/staging",
                                  isDirectory: true)
}

@Suite("Camera records")
struct CameraRecordTests {
    typealias F = CameraFixtures

    @Test func aNewRecordHasTheColumnDefaults() {
        let r = CameraRecord(key: F.key)
        #expect(r.model == "")
        #expect(r.friendlyName == "")
        #expect(r.lastSeen == .distantPast)
        #expect(r.preferredCarrier == .usb)
        #expect(r.autoImport == false)
        #expect(r.wifiSSID == nil && r.lastIP == nil && r.ptpipGUID == nil && r.bluetoothPeripheralID == nil)
        // The same as a row with untouched columns (what SwiftData's model initialises).
        let untouched = CameraColumns(serial: F.key.rawValue, model: "", friendlyName: "", lastSeen: .distantPast,
                                      preferredCarrier: "usb", autoImport: false, wifiSSID: nil, lastIP: nil,
                                      ptpipGUID: nil, bluetoothPeripheralID: nil)
        #expect(untouched.record == r)
    }

    @Test func descriptionAndDumpNeverShowPrivateValues() {
        let r = F.full
        var dumped = ""
        dump(r, to: &dumped)
        for text in [r.description, String(describing: r), String(reflecting: r), "\(r)", dumped] {
            for secret in [F.key.rawValue, F.ssid, F.ip, F.guid.uuidString, F.peripheral.uuidString,
                           r.friendlyName] {
                #expect(!text.contains(secret), "\(text)")
            }
        }
        #expect(r.description
            == "CameraRecord(camera-key(15 chars), ILCE-7CM2, wifi, named, auto-import, ssid, ip, guid, peripheral)")
        #expect(CameraRecord(key: F.key).description == "CameraRecord(camera-key(15 chars), no model, usb)")
    }

    @Test func columnsRoundTripEveryRecord() {
        for carrier in CameraRecord.Carrier.allCases {
            for full in [false, true] {
                var r = full ? F.full : CameraRecord(key: F.key)
                r.preferredCarrier = carrier
                let columns = CameraColumns(r)
                #expect(columns.record == r)
                #expect(columns.serial == F.key.rawValue)
                #expect(columns.preferredCarrier == carrier.rawValue)
            }
        }
        let columns = CameraColumns(F.full)
        #expect(columns.wifiSSID == F.ssid)
        #expect(columns.lastIP == F.ip)
        #expect(columns.ptpipGUID == F.guid)
        #expect(columns.bluetoothPeripheralID == F.peripheral)
        #expect(columns.model == "ILCE-7CM2")
        #expect(columns.autoImport)
    }

    @Test func carriersMatchCameraTransportsRawValues() {
        // CameraTransport's `CameraCarrier` is "usb" and "wifi"; the V1 column's default is "usb".
        #expect(CameraRecord.Carrier.allCases.map(\.rawValue) == ["usb", "wifi"])
    }

    @Test func anUnknownCarrierReadsAsUSB() {
        var columns = CameraColumns(F.full)
        columns.preferredCarrier = "a-carrier-from-a-later-version"
        #expect(columns.record.preferredCarrier == .usb)
        columns.preferredCarrier = ""
        #expect(columns.record.preferredCarrier == .usb)
    }

    @Test func aWriteKeepsTheLaterLastSeen() {
        let earlier = Date(timeIntervalSinceReferenceDate: 100)
        let later = Date(timeIntervalSinceReferenceDate: 200)
        var stored = CameraRecord(key: F.key, lastSeen: later)
        var incoming = F.full
        incoming.lastSeen = earlier
        let written = incoming.written(over: stored)
        #expect(written.lastSeen == later)
        var expected = incoming
        expected.lastSeen = later
        #expect(written == expected)

        stored.lastSeen = earlier
        incoming.lastSeen = later
        #expect(incoming.written(over: stored) == incoming)
        #expect(incoming.written(over: nil) == incoming)
    }

    @Test func duplicateRowsOfOneKeyAnswerAlikeWhateverTheirOrder() {
        let older = CameraRecord(key: F.key, lastSeen: Date(timeIntervalSinceReferenceDate: 100),
                                 bluetoothPeripheralID: F.peripheral)
        let newer = CameraRecord(key: F.key, lastSeen: Date(timeIntervalSinceReferenceDate: 200), lastIP: F.ip)
        var sameTimeWithPeripheral = newer
        sameTimeWithPeripheral.bluetoothPeripheralID = F.peripheral
        // The most recently seen wins, then the one with a peripheral, in either order.
        for (rows, winner) in [([older, newer], newer), ([newer, older], newer),
                               ([newer, sameTimeWithPeripheral], sameTimeWithPeripheral),
                               ([sameTimeWithPeripheral, newer], sameTimeWithPeripheral)] {
            #expect(CameraOrder.preferred(rows).map { rows[$0] } == winner)
            #expect(CameraOrder.sorted(rows) == [winner])
        }
        // The first of equals; none for no rows.
        let twin = CameraRecord(key: F.key, model: "twin", lastSeen: newer.lastSeen, lastIP: F.ip)
        #expect(CameraOrder.preferred([newer, twin]) == 0)
        #expect(CameraOrder.preferred([twin, newer]) == 0)
        #expect(CameraOrder.preferred([]) == nil)
    }

    @Test func recordsRoundTripThroughCodable() throws {
        for r in [F.full, CameraRecord(key: F.key)] {
            let data = try JSONEncoder().encode(r)
            #expect(try JSONDecoder().decode(CameraRecord.self, from: data) == r)
        }
    }
}

@Suite("Partial-file rows")
struct PartialFileRowTests {
    typealias C = CatalogueContractTests
    typealias F = CameraFixtures

    let file = C.id("DSC00001.ARW", "20261101T143005", 44_000_000)

    @Test func aCheckpointWithNoRowMakesAPartialRow() throws {
        let url = F.partialFile("DSC00001")
        let r = try PartialMark.record(for: file, format: .raw, tempURL: url, offset: 16_777_216, existing: nil)
        #expect(r == CatalogueRecord(identity: file, format: .raw, state: .partial, resumeOffset: 16_777_216,
                                     tempURL: url))
    }

    @Test func anImportedRowIsLeftAlone() throws {
        let imported = CatalogueRecord(identity: file, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        #expect(try PartialMark.record(for: file, format: .raw, tempURL: F.partialFile("x"), offset: 1,
                                       existing: imported) == nil)
    }

    @Test func aSkippedOrPartialRowBecomesPartialAndKeepsItsLocation() throws {
        let url = F.partialFile("DSC00001")
        for state in [ObjectState.new, .skipped, .partial] {
            let existing = CatalogueRecord(identity: file, format: .other, state: state,
                                           location: .file(relativePath: "Camera/DSC00001.ARW"), resumeOffset: 5,
                                           tempURL: F.partialFile("old"))
            let r = try PartialMark.record(for: file, format: .raw, tempURL: url, offset: 33_554_432,
                                           existing: existing)
            #expect(r == CatalogueRecord(identity: file, format: .raw, state: .partial,
                                         location: .file(relativePath: "Camera/DSC00001.ARW"),
                                         resumeOffset: 33_554_432, tempURL: url), "\(state)")
        }
    }

    @Test func anOffsetPastTheEndThrowsAndTheWholeFileDoesNot() throws {
        let url = F.partialFile("DSC00001")
        #expect(throws: CatalogueFailure.resumeOffsetPastEnd(offset: 44_000_001, size: 44_000_000)) {
            try PartialMark.record(for: file, format: .raw, tempURL: url, offset: 44_000_001, existing: nil)
        }
        #expect(throws: CatalogueFailure.resumeOffsetPastEnd(offset: .max, size: 44_000_000)) {
            try PartialMark.record(for: file, format: .raw, tempURL: url, offset: .max, existing: nil)
        }
        // Every byte written but not yet committed, and nothing written (a restart), are both checkpoints.
        #expect(try PartialMark.record(for: file, format: .raw, tempURL: url, offset: 44_000_000,
                                       existing: nil)?.resumeOffset == 44_000_000)
        #expect(try PartialMark.record(for: file, format: .raw, tempURL: url, offset: 0,
                                       existing: nil)?.resumeOffset == 0)
    }

    @Test func rowsCarryTheTemporaryFile() {
        let url = F.partialFile("DSC00001")
        let r = CatalogueRecord(identity: file, format: .raw, state: .partial, resumeOffset: .max, tempURL: url)
        let row = CatalogueRow(r)
        #expect(row.tempURL == url)
        #expect(row.resumeOffset == -1)   // UInt64.max by bit pattern
        #expect(row.record == r)
        #expect(CatalogueRow(CatalogueRecord(identity: file, format: .raw, state: .imported)).tempURL == nil)
    }

    @Test func thePartialFileIsStoredRelativeToTheStagingFolder() throws {
        // Relative already: stored as it is.
        let relative = F.partialFile("DSC00001")
        #expect(try PartialMark.stored(relative) == relative)
        // Relative to the staging folder: only the relative part is kept, so no container path is stored.
        let inStaging = URL(fileURLWithPath: "job/DSC 00001.partial", relativeTo: F.stagingBefore)
        let stored = try PartialMark.stored(inStaging)
        #expect(stored.baseURL == nil)
        #expect(stored.relativePath == "job/DSC 00001.partial")
        #expect(!stored.absoluteString.contains("Containers"))
        let r = try #require(try PartialMark.record(for: file, format: .raw, tempURL: inStaging, offset: 1,
                                                    existing: nil))
        #expect(r.tempURL == stored)
    }

    @Test func anAbsolutePartialFileIsRefused() {
        for url in [F.stagingBefore.appendingPathComponent("job/DSC00001.partial"),
                    URL(string: "/private/var/mobile/DSC00001.partial")!,
                    URL(string: "https://example.com/DSC00001.partial")!] {
            #expect(throws: CatalogueFailure.partialFileNotRelative, "\(url)") {
                try PartialMark.record(for: file, format: .raw, tempURL: url, offset: 1, existing: nil)
            }
        }
    }

    @Test func thePartialFileResolvesUnderTheCurrentStagingFolder() throws {
        // Written before an app update, read after it moved the container: the file is found at the new path.
        let inStaging = URL(fileURLWithPath: "job/DSC 00001.partial", relativeTo: F.stagingBefore)
        let written = try #require(try PartialMark.record(for: file, format: .raw, tempURL: inStaging, offset: 4096,
                                                          existing: nil))
        let decoded = try JSONDecoder().decode(CatalogueRecord.self, from: JSONEncoder().encode(written))
        #expect(decoded.partialFile(in: F.stagingAfter)?.path
            == "/private/var/mobile/Containers/Data/Application/B/tmp/staging/job/DSC 00001.partial")
        #expect(CatalogueRecord(identity: file, format: .raw, state: .imported).partialFile(in: F.stagingAfter) == nil)
    }

    @Test func aRecordEncodedBeforeTheTemporaryFileExistedStillDecodes() throws {
        let r = CatalogueRecord(identity: file, format: .raw, state: .partial, resumeOffset: 4096)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        #expect(json["tempURL"] == nil)
        json.removeValue(forKey: "resumeOffset")
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(CatalogueRecord.self, from: old)
        #expect(decoded.tempURL == nil)
        #expect(decoded.resumeOffset == 0)

        let withFile = CatalogueRecord(identity: file, format: .raw, state: .partial, resumeOffset: 4096,
                                       tempURL: F.partialFile("DSC00001"))
        #expect(try JSONDecoder().decode(CatalogueRecord.self, from: JSONEncoder().encode(withFile)) == withFile)
    }
}

/// The Camera row and partial-file rules every store keeps.
@Suite("Catalogue store contract: the Camera row and partial files")
struct CameraRowContractTests {
    typealias C = CatalogueContractTests
    typealias F = CameraFixtures

    let file = C.id("DSC00001.ARW", "20261101T143005", 44_000_000)

    // MARK: The Camera row

    @Test(arguments: StoreKind.available)
    func anUnknownCameraHasNoRow(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        #expect(try await s.store.camera(F.key) == nil)
        #expect(try await s.store.cameras().isEmpty)
    }

    @Test(arguments: StoreKind.available)
    func everyCameraFieldRoundTrips(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.upsertCamera(F.full)
        #expect(try await s.store.camera(F.key) == F.full)
        #expect(try await s.store.camera(F.otherKey) == nil)
        #expect(try await s.store.cameras() == [F.full])
        // A camera is not a file row.
        #expect(try await s.rows().isEmpty)
    }

    @Test(arguments: StoreKind.available)
    func aSecondUpsertUpdatesTheRowAndCanClearFields(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.upsertCamera(F.full)
        var changed = F.full
        changed.wifiSSID = nil
        changed.lastIP = nil
        changed.bluetoothPeripheralID = nil
        changed.preferredCarrier = .usb
        changed.autoImport = false
        changed.friendlyName = ""
        try await s.store.upsertCamera(changed)
        #expect(try await s.store.camera(F.key) == changed)
        #expect(try await s.store.cameras() == [changed])

        var again = changed
        again.bluetoothPeripheralID = F.peripheral
        try await s.store.upsertCamera(again)
        #expect(try await s.store.camera(F.key)?.bluetoothPeripheralID == F.peripheral)
        #expect(try await s.store.cameras().count == 1)
    }

    @Test(arguments: StoreKind.available)
    func lastSeenNeverMovesBackwards(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let t1 = Date(timeIntervalSinceReferenceDate: 2_000)
        let t2 = Date(timeIntervalSinceReferenceDate: 3_000)
        try await s.store.upsertCamera(CameraRecord(key: F.key, lastSeen: t1))
        // A write built from an older read keeps the later date and changes the rest.
        try await s.store.upsertCamera(CameraRecord(key: F.key, model: "ILCE-7CM2", lastSeen: t0))
        #expect(try await s.store.camera(F.key) == CameraRecord(key: F.key, model: "ILCE-7CM2", lastSeen: t1))
        // A listing moves it forward, never back.
        try await s.store.saveListing(CardListing(camera: F.key, listedAt: t0, entries: []))
        #expect(try await s.store.camera(F.key)?.lastSeen == t1)
        try await s.store.saveListing(CardListing(camera: F.key, listedAt: t2, entries: []))
        #expect(try await s.store.camera(F.key)?.lastSeen == t2)
        #expect(try await s.store.camera(F.key)?.model == "ILCE-7CM2")
    }

    @Test(arguments: StoreKind.available)
    func aFileRowOrAListingGivesTheCameraARow(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.upsert(CatalogueRecord(identity: file, format: .raw, state: .imported))
        #expect(try await s.store.camera(F.key) == CameraRecord(key: F.key))
        let listedAt = Date(timeIntervalSinceReferenceDate: 815_000_000)
        try await s.store.saveListing(CardListing(camera: F.otherKey, listedAt: listedAt, entries: []))
        #expect(try await s.store.camera(F.otherKey) == CameraRecord(key: F.otherKey, lastSeen: listedAt))
        #expect(try await s.store.cameras() == [CameraRecord(key: F.otherKey, lastSeen: listedAt),
                                                CameraRecord(key: F.key)])
    }

    @Test(arguments: StoreKind.available)
    func writingTheCameraLeavesItsFilesAndListingAlone(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let imported = CatalogueRecord(identity: file, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        try await s.store.upsert(imported)
        let listing = CardListing(camera: F.key, listedAt: Date(timeIntervalSinceReferenceDate: 50),
                                  entries: [.init(identity: file, format: .raw)])
        try await s.store.saveListing(listing)
        try await s.store.upsertCamera(F.full)
        #expect(try await s.rows() == [imported])
        #expect(try await s.store.lastListing(for: F.key) == listing)
        #expect(try await s.store.states(of: [file]) == [file: .imported])
        // And the other way round: file rows and listings leave the camera's fields alone.
        let second = CatalogueRecord(identity: C.id("DSC00002.ARW", "20261101T143006", 1), format: .raw,
                                     state: .imported)
        try await s.store.upsert(second)
        try await s.store.saveListing(listing)
        #expect(try await s.store.camera(F.key) == F.full)
    }

    @Test(arguments: StoreKind.available)
    func camerasComeMostRecentlySeenFirst(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let a = CameraRecord(key: CameraKey(rawValue: "a"), lastSeen: Date(timeIntervalSinceReferenceDate: 10))
        let b = CameraRecord(key: CameraKey(rawValue: "b"), lastSeen: Date(timeIntervalSinceReferenceDate: 30))
        let c = CameraRecord(key: CameraKey(rawValue: "c"), lastSeen: Date(timeIntervalSinceReferenceDate: 20))
        let tie = CameraRecord(key: CameraKey(rawValue: "0"), lastSeen: Date(timeIntervalSinceReferenceDate: 20))
        for r in [a, b, c, tie] { try await s.store.upsertCamera(r) }
        #expect(try await s.store.cameras() == [b, tie, c, a])
    }

    @Test(arguments: StoreKind.available)
    func updateCameraChangesOnlyWhatItIsGiven(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        // No row yet: made from the defaults.
        let made = try await s.store.updateCamera(F.key) { $0.bluetoothPeripheralID = F.peripheral }
        #expect(made == CameraRecord(key: F.key, bluetoothPeripheralID: F.peripheral))
        #expect(try await s.store.camera(F.key) == made)
        // Another field: the first stays.
        try await s.store.updateCamera(F.key) { $0.ptpipGUID = F.guid }
        #expect(try await s.store.camera(F.key)
            == CameraRecord(key: F.key, ptpipGUID: F.guid, bluetoothPeripheralID: F.peripheral))
        // The key can't be changed, and `lastSeen` never moves backwards.
        let seen = Date(timeIntervalSinceReferenceDate: 300)
        try await s.store.updateCamera(F.key) { $0.lastSeen = seen }
        let stored = try await s.store.updateCamera(F.key) {
            $0.key = F.otherKey
            $0.lastSeen = .distantPast
            $0.lastIP = F.ip
        }
        #expect(stored == CameraRecord(key: F.key, lastSeen: seen, lastIP: F.ip, ptpipGUID: F.guid,
                                       bluetoothPeripheralID: F.peripheral))
        #expect(try await s.store.camera(F.key) == stored)
        #expect(try await s.store.camera(F.otherKey) == nil)
    }

    @Test(arguments: StoreKind.available)
    func concurrentUpdatesOfDifferentFieldsAreAllKept(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.upsertCamera(CameraRecord(key: F.key, model: "ILCE-7CM2"))
        let store = s.store
        let renames = 20
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await store.updateCamera(F.key) { $0.bluetoothPeripheralID = F.peripheral } }
            group.addTask { try await store.updateCamera(F.key) { $0.ptpipGUID = F.guid } }
            group.addTask { try await store.updateCamera(F.key) { $0.wifiSSID = F.ssid } }
            for _ in 0 ..< renames {
                group.addTask { try await store.updateCamera(F.key) { $0.friendlyName += "." } }
            }
            try await group.waitForAll()
        }
        let camera = try #require(try await s.store.camera(F.key))
        #expect(camera.model == "ILCE-7CM2")
        #expect(camera.bluetoothPeripheralID == F.peripheral)
        #expect(camera.ptpipGUID == F.guid)
        #expect(camera.wifiSSID == F.ssid)
        #expect(camera.friendlyName == String(repeating: ".", count: renames))
    }

    // MARK: Partial files

    @Test(arguments: StoreKind.available)
    func aCheckpointMakesAPartialRowWithItsOffsetAndFile(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        let url = F.partialFile("DSC00001")
        try await s.store.markPartial(file, format: .raw, tempURL: url, offset: 16_777_216)
        let expected = CatalogueRecord(identity: file, format: .raw, state: .partial, resumeOffset: 16_777_216,
                                       tempURL: url)
        #expect(try await s.store.record(for: file) == expected)
        #expect(try await s.rows() == [expected])
        #expect(try await s.store.states(of: [file]) == [file: .partial])
        // The next checkpoint moves the offset; still one row.
        try await s.store.markPartial(file, format: .raw, tempURL: url, offset: 33_554_432)
        #expect(try await s.store.record(for: file)?.resumeOffset == 33_554_432)
        #expect(try await s.rows().count == 1)
        // The checkpoint's camera has a row, as for any file row.
        #expect(try await s.store.camera(F.key) == CameraRecord(key: F.key))
    }

    @Test(arguments: StoreKind.available)
    func committingTheFileClearsTheCheckpoint(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.markPartial(file, format: .raw, tempURL: F.partialFile("DSC00001"), offset: 16_777_216)
        let imported = CatalogueRecord(identity: file, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        try await s.store.upsert(imported)
        #expect(try await s.store.record(for: file) == imported)
        #expect(try await s.store.record(for: file)?.tempURL == nil)
        #expect(try await s.store.record(for: file)?.resumeOffset == 0)
    }

    @Test(arguments: StoreKind.available)
    func aCheckpointAfterTheCommitChangesNothing(_ kind: StoreKind) async throws {
        let imported = CatalogueRecord(identity: file, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        let s = try await kind.make(records: [imported])
        try await s.store.markPartial(file, format: .raw, tempURL: F.partialFile("DSC00001"), offset: 16_777_216)
        #expect(try await s.rows() == [imported])
        #expect(try await s.store.states(of: [file]) == [file: .imported])
    }

    @Test(arguments: StoreKind.available)
    func aSkippedFileTakenUpAgainBecomesPartial(_ kind: StoreKind) async throws {
        let s = try await kind.make(records: [CatalogueRecord(identity: file, format: .raw, state: .skipped)])
        let url = F.partialFile("DSC00001")
        try await s.store.markPartial(file, format: .raw, tempURL: url, offset: 0)
        #expect(try await s.store.record(for: file)
            == CatalogueRecord(identity: file, format: .raw, state: .partial, resumeOffset: 0, tempURL: url))
    }

    @Test(arguments: StoreKind.available)
    func anOffsetPastTheEndIsRefusedAndWritesNothing(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        await #expect(throws: CatalogueFailure.resumeOffsetPastEnd(offset: 44_000_001, size: 44_000_000)) {
            try await s.store.markPartial(file, format: .raw, tempURL: CameraFixtures.partialFile("x"),
                                          offset: 44_000_001)
        }
        #expect(try await s.rows().isEmpty)
        #expect(try await s.store.camera(F.key) == nil)
    }

    @Test(arguments: StoreKind.available)
    func anAbsolutePartialFileIsRefusedAndWritesNothing(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        await #expect(throws: CatalogueFailure.partialFileNotRelative) {
            try await s.store.markPartial(file, format: .raw,
                                          tempURL: F.stagingBefore.appendingPathComponent("DSC00001.partial"),
                                          offset: 4096)
        }
        #expect(try await s.rows().isEmpty)
    }

    @Test(arguments: StoreKind.available)
    func aCheckpointStoresOnlyThePathInsideTheStagingFolder(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        try await s.store.markPartial(file, format: .raw,
                                      tempURL: URL(fileURLWithPath: "job/DSC00001.partial",
                                                   relativeTo: F.stagingBefore),
                                      offset: 4096)
        let stored = try #require(try await s.store.record(for: file))
        #expect(stored.tempURL?.baseURL == nil)
        #expect(stored.tempURL?.relativePath == "job/DSC00001.partial")
        #expect(stored.partialFile(in: F.stagingAfter)
            == F.stagingAfter.appendingPathComponent("job/DSC00001.partial", isDirectory: false))
    }

    // MARK: Resetting a partial whose file is gone (I13)

    @Test(arguments: StoreKind.available)
    func partialRecordsListsThePartialRowsThatHaveAFile(_ kind: StoreKind) async throws {
        let second = C.id("DSC00002.ARW", "20261101T143006", 44_000_001)
        let third = C.id("DSC00003.ARW", "20261101T143007", 44_000_002)
        let imported = CatalogueRecord(identity: C.id("DSC00004.ARW", "20261101T143008", 44_000_003), format: .raw,
                                       state: .imported, location: .photosAsset(localIdentifier: "A/L0/001"))
        let s = try await kind.make(records: [imported,
                                              CatalogueRecord(identity: third, format: .raw, state: .new)])
        try await s.store.markPartial(file, format: .raw, tempURL: F.partialFile("DSC00001"), offset: 16_777_216)
        try await s.store.markPartial(second, format: .raw, tempURL: F.partialFile("DSC00002"), offset: 4096)
        #expect(try await s.store.resetPartial(second, ifTempURL: F.partialFile("DSC00002"), offset: 4096))
        let listed = try await s.store.partialRecords()
        #expect(listed == [CatalogueRecord(identity: file, format: .raw, state: .partial, resumeOffset: 16_777_216,
                                           tempURL: F.partialFile("DSC00001"))])
    }

    @Test(arguments: StoreKind.available)
    func aResetPartialStaysPartialWithNoFileAndKeepsTheRest(_ kind: StoreKind) async throws {
        let staged = StagedLocation(root: .onThisIPhone, relativePath: "Staging/ILCE-7CM2/2026-11-01/DSC00001.ARW")
        let s = try await kind.make()
        try await s.store.markStaged(file, format: .raw, at: staged)
        let url = F.partialFile("DSC00001")
        try await s.store.markPartial(file, format: .raw, tempURL: url, offset: 33_554_432)
        // Given in the other form `markPartial` takes: relative to a staging folder.
        let sameFile = URL(fileURLWithPath: url.relativePath, relativeTo: F.stagingAfter)
        #expect(try await s.store.resetPartial(file, ifTempURL: sameFile, offset: 33_554_432))
        let expected = CatalogueRecord(identity: file, format: .raw, state: .partial, resumeOffset: 0, tempURL: nil,
                                       staged: staged)
        #expect(try await s.store.record(for: file) == expected)
        #expect(try await s.rows() == [expected])
        #expect(try await s.store.states(of: [file]) == [file: .partial])
        #expect(try await s.store.partialRecords().isEmpty)
        // Nothing left to reset.
        #expect(try await !s.store.resetPartial(file, ifTempURL: url, offset: 33_554_432))
    }

    @Test(arguments: StoreKind.available)
    func aRowThatMovedOnIsNotReset(_ kind: StoreKind) async throws {
        let s = try await kind.make()
        // No row.
        #expect(try await !s.store.resetPartial(file, ifTempURL: F.partialFile("DSC00001"), offset: 0))
        #expect(try await s.rows().isEmpty)
        // A checkpoint at a higher offset in the same file since the row was read at 4096.
        try await s.store.markPartial(file, format: .raw, tempURL: F.partialFile("DSC00001"), offset: 4096)
        try await s.store.markPartial(file, format: .raw, tempURL: F.partialFile("DSC00001"), offset: 8_388_608)
        #expect(try await !s.store.resetPartial(file, ifTempURL: F.partialFile("DSC00001"), offset: 4096))
        #expect(try await s.store.record(for: file)?.tempURL == F.partialFile("DSC00001"))
        #expect(try await s.store.record(for: file)?.resumeOffset == 8_388_608)
        // A checkpoint in another file since the row was read (the file restarted in a new folder).
        let newer = URL(string: "00000000-0000-4000-8000-0000000000C2/DSC00001.partial")!
        try await s.store.markPartial(file, format: .raw, tempURL: newer, offset: 16_777_216)
        #expect(try await !s.store.resetPartial(file, ifTempURL: F.partialFile("DSC00001"), offset: 8_388_608))
        #expect(try await s.store.record(for: file)?.tempURL == newer)
        #expect(try await s.store.record(for: file)?.resumeOffset == 16_777_216)
        // Imported since.
        let imported = CatalogueRecord(identity: file, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        try await s.store.upsert(imported)
        #expect(try await !s.store.resetPartial(file, ifTempURL: newer, offset: 16_777_216))
        #expect(try await s.rows() == [imported])
    }

    @Test(arguments: StoreKind.available)
    func aCheckpointIsPerIdentityNotPerContent(_ kind: StoreKind) async throws {
        // The same file imported under another camera key: "already imported" still says imported (by content),
        // and the checkpoint row is this identity's own.
        let elsewhere = C.id("DSC00001.ARW", "20261101T143005", 44_000_000, folder: "", camera: C.mtpCamera)
        let imported = CatalogueRecord(identity: elsewhere, format: .raw, state: .imported)
        let s = try await kind.make(records: [imported])
        let url = F.partialFile("DSC00001")
        try await s.store.markPartial(file, format: .raw, tempURL: url, offset: 4096)
        #expect(try await s.store.record(for: file)?.state == .partial)
        #expect(try await s.store.record(for: elsewhere) == imported)
        #expect(try await s.store.states(of: [file]) == [file: .imported])
    }
}
