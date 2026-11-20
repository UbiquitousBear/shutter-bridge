import Catalogue
import Foundation
import PTPKit
import Testing
@testable import AppUI

// Settings › Import When Connected (backlog section 14): one switch per body name, written on every one-body key of the
// name with `updateCamera`, never on a shared key.

/// A catalogue whose Camera rows read from a fixed list and whose writes all fail.
actor RefusingCameraCatalogue: CatalogueStore {
    struct Refused: Error {}
    let rows: [CameraRecord]
    init(rows: [CameraRecord]) { self.rows = rows }
    func record(for identity: ObjectIdentity) throws -> CatalogueRecord? { nil }
    func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] { [:] }
    func upsert(_ record: CatalogueRecord) throws { throw Refused() }
    func saveListing(_ listing: CardListing) throws { throw Refused() }
    func lastListing(for camera: CameraKey) throws -> CardListing? { nil }
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) throws {
        throw Refused()
    }
    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) throws {
        throw Refused()
    }
    func clearStaged(_ identity: ObjectIdentity) throws { throw Refused() }
    func stagedStates(of identities: [ObjectIdentity]) throws -> Set<ObjectIdentity> { [] }
    func camera(_ key: CameraKey) throws -> CameraRecord? { rows.first { $0.key == key } }
    func cameras() throws -> [CameraRecord] { rows }
    func upsertCamera(_ record: CameraRecord) throws { throw Refused() }
}

@MainActor
@Suite("Auto-import: the Settings switches")
struct AutoImportSettingsTests {
    let otherKey = CameraKey(rawValue: "usb-device:other")

    func seeded() async -> InMemoryCatalogue {
        let catalogue = InMemoryCatalogue()
        await catalogue.upsertCamera(bodyRow(bodyMTPKey, seen: 10))
        var wifi = bodyRow(bodyWiFiKey, seen: 20, carrier: .wifi)
        wifi.ptpipGUID = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")
        wifi.bluetoothPeripheralID = UUID(uuidString: "00000000-0000-4000-8000-0000000000BB")
        await catalogue.upsertCamera(wifi)
        await catalogue.upsertCamera(bodyRow(mscSharedKey, seen: 5))
        await catalogue.upsertCamera(bodyRow(otherKey, "ILCE-7M4", seen: 30))
        return catalogue
    }

    @Test func listsEachBodyOffByDefault() async {
        let model = AutoImportSettings(catalogue: await seeded())
        #expect(model.choices.isEmpty)
        await model.load()
        #expect(model.choices == [AutoImportChoice(name: "ILCE-7M4", isOn: false),
                                  AutoImportChoice(name: autoImportModel, isOn: false)])
        #expect(model.listsSeveralCameras)
        #expect(!model.saveFailed)
    }

    @Test func turningOnWritesEveryOneBodyKeyOfTheNameAndNoSharedKey() async {
        let catalogue = await seeded()
        let before = await catalogue.cameras()
        let log = RecordingLog()
        let model = AutoImportSettings(catalogue: catalogue, log: log)
        await model.load()
        await model.set(true, for: autoImportModel)
        #expect(await catalogue.camera(bodyMTPKey)?.autoImport == true)
        #expect(await catalogue.camera(bodyWiFiKey)?.autoImport == true)
        #expect(await catalogue.camera(mscSharedKey)?.autoImport == false)
        #expect(await catalogue.camera(otherKey)?.autoImport == false)
        // Nothing else of the rows changes.
        for old in before {
            var expected = old
            if old.key == bodyMTPKey || old.key == bodyWiFiKey { expected.autoImport = true }
            #expect(await catalogue.camera(old.key) == expected)
        }
        #expect(model.choices == [AutoImportChoice(name: "ILCE-7M4", isOn: false),
                                  AutoImportChoice(name: autoImportModel, isOn: true)])
        #expect(log.lines == ["settings: auto-import turned on for a camera (2 key(s))"])
    }

    @Test func turningOffClearsThem() async {
        let catalogue = await seeded()
        let model = AutoImportSettings(catalogue: catalogue)
        await model.set(true, for: autoImportModel)
        await model.set(false, for: autoImportModel)
        #expect(await catalogue.camera(bodyMTPKey)?.autoImport == false)
        #expect(await catalogue.camera(bodyWiFiKey)?.autoImport == false)
        #expect(model.choices.allSatisfy { !$0.isOn })
    }

    @Test func aSwitchShowsItsNewValueAtOnceAndIsWritten() async {
        let catalogue = await seeded()
        let model = AutoImportSettings(catalogue: catalogue)
        await model.load()
        var bindings = model.choiceBindings
        bindings[1].isOn = true
        model.choiceBindings = bindings
        #expect(model.choices[1] == AutoImportChoice(name: autoImportModel, isOn: true))
        #expect(await eventually { await catalogue.camera(bodyWiFiKey)?.autoImport == true })
        #expect(await eventually { await catalogue.camera(bodyMTPKey)?.autoImport == true })
        // An unchanged list writes nothing.
        model.choiceBindings = model.choiceBindings
        #expect(await catalogue.camera(otherKey)?.autoImport == false)
    }

    @Test func aRefusedWriteSaysSoAndReadsBack() async {
        let log = RecordingLog()
        let model = AutoImportSettings(catalogue: RefusingCameraCatalogue(rows: [bodyRow(bodyMTPKey)]), log: log)
        await model.load()
        var bindings = model.choiceBindings
        bindings[0].isOn = true
        model.choiceBindings = bindings
        #expect(model.choices == [AutoImportChoice(name: autoImportModel, isOn: true)])
        #expect(await eventually { model.saveFailed })
        // The switch reads back what is stored.
        #expect(await eventually { model.choices == [AutoImportChoice(name: autoImportModel, isOn: false)] })
        #expect(log.lines.contains("settings: auto-import wasn't saved: Refused"))
        #expect(!model.listsSeveralCameras)
    }

    @Test func anUnreadableCatalogueListsNothingAndLogs() async {
        let log = RecordingLog()
        let model = AutoImportSettings(catalogue: BrokenCatalogue(), log: log)
        await model.load()
        #expect(model.choices.isEmpty)
        #expect(log.lines == ["settings: auto-import: the catalogue couldn't be read (Broken)"])
        await model.set(true, for: autoImportModel)
        #expect(model.saveFailed)
        #expect(log.lines.contains("settings: auto-import wasn't saved: Broken"))
    }
}
