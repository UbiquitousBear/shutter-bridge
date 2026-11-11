import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

// Staging in the app (Shamil, 11 Nov): the choice is made at each import (Import to Photos or Stage), the last one is
// remembered app-wide, staging goes to iCloud Drive or, when it isn't available, to this iPhone, and Browse shows its
// own Staged badge.

private let iCloudDocuments = URL(fileURLWithPath: "/nonexistent/iCloud/Documents")

// MARK: - The Import screen's model

extension ImportModelTests {
    @Test func aStageJobNeverAsksForPhotosAccessAndReadsWhereStagingGoes() async {
        let photos = FakePhotosAccess(.notDetermined)
        let h = await harness(photos: photos)
        #expect(await h.model.importItems(card, from: h.camera, link: h.link, as: .staging, newOnly: false)
            == .started(3))
        #expect(await h.finished())
        #expect(photos.askCount == 0)
        #expect(await h.destinations.locator.locateCount == 1)
        #expect(h.model.stagingPlace == testStagingPlace)
        #expect(await h.destinations.photos.names.isEmpty)
        #expect(await h.destinations.files.names.count == 3)
        #expect(h.model.importChoice == .staging)
        #expect(h.settings.load() == DestinationSetting(preferred: .staging))
        #expect(h.model.rows.allSatisfy { $0.stateText == "Staged on this iPhone" && $0.tone == .done })
    }

    @Test func stagingInICloudDriveGoesThereAndSaysSo() async {
        let h = await harness(setting: .staging, staging: .iCloudDrive(documents: iCloudDocuments))
        #expect(await h.importAll(card) == .started(3))
        #expect(await h.finished())
        #expect(await h.destinations.iCloud.names.count == 3)
        #expect(await h.destinations.files.names.isEmpty)
        #expect(h.model.progress.destination == .staging(.chosen, .iCloudDrive))
        #expect(h.model.destinationLine == "Staged in iCloud Drive › Shutter Bridge › Staging › Camera.")
        #expect(h.model.stagingReasonLine == "Not added to Photos. iCloud Drive uploads the files in the background.")
        #expect(h.model.countsLine == "3 files staged.")
        #expect(h.model.rows.allSatisfy { $0.stateText == "Staged in iCloud Drive" })
    }

    @Test func iCloudDriveLostMidJobStagesTheRestOnThisIPhoneAndSaysSo() async {
        let h = await harness(setting: .staging, staging: .iCloudDrive(documents: iCloudDocuments))
        await h.destinations.iCloud.setUnavailable(true)
        #expect(await h.importAll(card) == .started(3))
        #expect(await h.finished())
        #expect(h.model.state == .finished(.completed))
        #expect(await h.destinations.files.names.count == 3)
        #expect(h.model.progress.filesFailed == 0)
        #expect(h.model.progress.destination == .staging(.chosen, .onThisIPhone(.lostDuringImport)))
        #expect(h.model.stagingReasonLine
            == "Not added to Photos. iCloud Drive became unavailable, so the rest are staged on this iPhone.")
        #expect(h.model.destinationLine == "Staged in On My iPhone › Shutter Bridge › Staging › Camera.")
    }

    @Test func aContinueMovesStagingFromICloudDriveToThisIPhoneButNeverBack() async {
        let h = await harness(setting: .staging, hangs: true, staging: .iCloudDrive(documents: iCloudDocuments))
        #expect(await h.importAll(card) == .started(3))
        #expect(await eventually { await h.link.bytesStarted == 1 })
        await h.model.refresh()
        #expect(h.model.progress.destination == .staging(.chosen, .iCloudDrive))
        // Nothing changed: nothing to switch to.
        #expect(await h.model.continuingRoute() == nil)
        await h.model.pause()
        await h.destinations.locator.set(.unavailable(.iCloudDriveOff))   // signed out while paused
        await h.model.resume()
        #expect(h.model.progress.destination == .staging(.chosen, .onThisIPhone(.lostDuringImport)))
        await h.model.pause()
        await h.destinations.locator.set(.iCloudDrive(documents: iCloudDocuments))   // back again
        await h.model.resume()
        #expect(h.model.progress.destination == .staging(.chosen, .onThisIPhone(.lostDuringImport)))
        #expect(await h.model.continuingRoute() == nil)
        await h.model.cancel()
    }

    @Test func aPickForTheOtherChoiceWhileAJobRunsIsRefused() async {
        let h = await harness(setting: .staging, hangs: true)
        #expect(await h.importAll([card[0]]) == .started(1))
        let outcome = await h.model.importItems([card[1]], from: h.camera, link: h.link, as: .photos, newOnly: false)
        #expect(outcome == .busyWithAnotherMode(.staging))
        #expect(h.model.message == "Staging is running. Import these when it's done.")
        // Refused, so the remembered choice stays.
        #expect(h.model.importChoice == .staging)
        // The same choice is added to the job.
        #expect(await h.model.importItems([card[1]], from: h.camera, link: h.link, as: .staging, newOnly: false)
            == .appended(1))
        await h.model.cancel()
    }

    @Test func anImportJobStagedBecauseOfPhotosStillTakesImportPicks() async {
        let h = await harness(photos: FakePhotosAccess(.denied), hangs: true)
        #expect(await h.importAll([card[0]]) == .started(1))
        await h.model.refresh()
        #expect(h.model.progress.destination == .stagedHere(.photosDenied))
        #expect(await h.importAll([card[1]]) == .appended(1))
        #expect(await h.model.importItems([card[2]], from: h.camera, link: h.link, as: .staging, newOnly: false)
            == .busyWithAnotherMode(.photos))
        #expect(h.model.message == "An import is running. Stage these when it's done.")
        await h.model.cancel()
    }

    /// Select All New's picks leave out files already imported from a Stage job; an explicit pick of one stages it
    /// (Shamil, 11 Nov).
    @Test func selectAllNewLeavesImportedFilesOutOfStagingAndAnExplicitPickStagesThem() async throws {
        let h = await harness()
        let imported = try #require(card[0].identity(camera: h.camera.key, timeZone: .current))
        await h.catalogue.upsert(CatalogueRecord(identity: imported, format: .raw, state: .imported))
        #expect(await h.model.importItems(card, from: h.camera, link: h.link, as: .staging, newOnly: true)
            == .started(3))
        #expect(await h.finished())
        #expect(await h.destinations.files.names.sorted() == ["DSC00001.JPG", "DSC00002.JPG"])
        #expect(await h.model.importItems([card[0]], from: h.camera, link: await freshLink(), as: .staging,
                                          newOnly: false) == .started(1))
        #expect(await h.state(.finished(.completed)))
        #expect(await h.destinations.files.names.sorted() == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
        // Still imported, and staged too.
        #expect(await h.catalogue.record(for: imported)?.state == .imported)
        #expect(await h.catalogue.stagedStates(of: [imported]) == [imported])
    }

    @Test func theStagingPlaceIsReadForTheImportMenu() async {
        let h = await harness(staging: .iCloudDrive(documents: iCloudDocuments))
        #expect(h.model.stagingPlace == nil)
        await h.model.refreshStagingPlace()
        #expect(h.model.stagingPlace == .iCloudDrive)
        await h.destinations.locator.set(.unavailable(.containerUnavailable))
        await h.model.refreshStagingPlace()
        #expect(h.model.stagingPlace == .onThisIPhone(.containerUnavailable))
    }
}

// MARK: - Browse

@MainActor
@Suite("Browse: the Staged badge, the Import menu, and what Select All New picks")
struct BrowseStagingTests {
    let card = [
        item("DSC00001.ARW", at: 10, size: 40_000_000),
        item("DSC00002.ARW", at: 20, size: 41_000_000),
        item("DSC00003.JPG", at: 30, size: 22_000_000),
        item("DSC00004.JPG", at: 40, size: 21_000_000),
    ]

    struct Harness {
        let model: BrowseModel
        let catalogue: InMemoryCatalogue
        let importer: FakeImporter
        let run: Task<Void, Never>

        func stop() async {
            run.cancel()
            await run.value
        }
    }

    var descriptor: CameraDescriptor { FakeLink(items: []).descriptor }

    func named(_ name: String) -> CameraItem { card.first { $0.name == name }! }

    func identity(_ name: String) -> ObjectIdentity {
        named(name).identity(camera: CameraKeys.key(for: descriptor, material: nil), timeZone: .current)!
    }

    func staged(_ name: String, at root: StagingRoot = .onThisIPhone) -> StagedLocation {
        StagedLocation(root: root, relativePath: "Staging/Camera/2026-10-26/\(name)")
    }

    /// DSC00001.ARW imported, DSC00002.ARW staged, DSC00003.JPG both, DSC00004.JPG new.
    func start(choice: DestinationKind = .photos) async -> Harness {
        let catalogue = InMemoryCatalogue(records: [
            CatalogueRecord(identity: identity("DSC00001.ARW"), format: .raw, state: .imported),
            CatalogueRecord(identity: identity("DSC00002.ARW"), format: .raw, state: .new,
                            staged: staged("DSC00002.ARW")),
            CatalogueRecord(identity: identity("DSC00003.JPG"), format: .jpeg, state: .imported,
                            staged: staged("DSC00003.JPG", at: .iCloudDrive)),
        ])
        let link = FakeLink(items: card)
        let importer = FakeImporter()
        importer.importChoice = choice
        let model = BrowseModel(
            camera: link.descriptor,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in link },
            services: services(),
            onGone: { _ in },
            catalogue: BrowseCatalogue(store: catalogue, cameraKey: CameraKeys.fromDescriptor),
            importer: importer
        )
        let run = Task { await model.run() }
        return Harness(model: model, catalogue: catalogue, importer: importer, run: run)
    }

    func listed(_ h: Harness) async -> Bool {
        await eventually { h.model.phase == .listed && !h.model.staged.isEmpty }
    }

    @Test func stagedFilesHaveTheirOwnBadgeAndImportedTakesPrecedence() async {
        let h = await start()
        #expect(await listed(h))
        #expect(h.model.isStaged(named("DSC00002.ARW")) && !h.model.isImported(named("DSC00002.ARW")))
        #expect(h.model.isStaged(named("DSC00003.JPG")) && h.model.isImported(named("DSC00003.JPG")))
        #expect(!h.model.isStaged(named("DSC00001.ARW")) && !h.model.isStaged(named("DSC00004.JPG")))
        // VoiceOver reads both when both apply; the cell shows Imported.
        #expect(h.model.accessibilityLabel(for: named("DSC00002.ARW"), date: "d") == "DSC00002.ARW, d, RAW, Staged")
        #expect(h.model.accessibilityLabel(for: named("DSC00003.JPG"), date: "d")
            == "DSC00003.JPG, d, JPEG, Imported, staged")
        #expect(h.model.accessibilityLabel(for: named("DSC00001.ARW"), date: "d") == "DSC00001.ARW, d, RAW, Imported")
        #expect(h.model.accessibilityLabel(for: named("DSC00004.JPG"), date: "d") == "DSC00004.JPG, d, JPEG, New")
        await h.stop()
    }

    @Test func selectAllNewAndNewOnlySkipStagedAndImportedFiles() async {
        let h = await start()
        #expect(await listed(h))
        h.model.selectAllNew()
        #expect(h.model.selectedItems.map(\.name) == ["DSC00004.JPG"])
        #expect(h.model.allNewSelected)
        h.model.filter.newOnly = true
        #expect(h.model.sections.flatMap(\.items).map(\.name) == ["DSC00004.JPG"])
        await h.stop()
    }

    @Test func stagedAndImportedPhotosCanBePickedWhateverTheDefault() async {
        let h = await start()
        #expect(await listed(h))
        // Import to Photos is the default, and every photo can be picked: a staged one to import, an imported one
        // to stage (Shamil, 11 Nov).
        #expect(h.model.importButtonTitle == "Import")
        for name in ["DSC00001.ARW", "DSC00002.ARW", "DSC00003.JPG", "DSC00004.JPG"] {
            #expect(h.model.selectionBlock(for: named(name)) == nil)
        }
        h.model.tap(named("DSC00002.ARW"))
        #expect(h.model.selectedItems.map(\.name) == ["DSC00002.ARW"])
        #expect(await h.model.importSelected() == .started(1))
        #expect(h.importer.asked.last?.choice == .photos)
        #expect(h.importer.asked.last?.newOnly == false)
        #expect(h.model.importNotice == "Importing 1 file.")
        await h.stop()
    }

    /// The menu's *Stage* stages an imported photo picked while Import to Photos is the default.
    @Test func anImportedPhotoCanBeStagedWhileImportToPhotosIsTheDefault() async {
        let h = await start()
        #expect(await listed(h))
        h.model.tap(named("DSC00001.ARW"))
        #expect(await h.model.importSelected(as: .staging) == .started(1))
        #expect(h.importer.calls.last?.items.map(\.name) == ["DSC00001.ARW"])
        #expect(h.importer.asked.last?.choice == .staging)
        #expect(h.importer.asked.last?.newOnly == false)
        #expect(h.model.importNotice == "Staging 1 file.")
        // Select All New still skips it.
        h.model.selectAllNew()
        #expect(h.model.selectedItems.map(\.name) == ["DSC00004.JPG"])
        await h.stop()
    }

    /// What the chosen import would leave out isn't handed over, so the notice counts only what it copies; when
    /// nothing is left, no job starts and the notice says the files are done.
    @Test func whatTheChosenImportLeavesOutIsNotHandedOver() async {
        let h = await start()
        #expect(await listed(h))
        // Import to Photos leaves out imported photos.
        h.model.tap(named("DSC00001.ARW"))
        h.model.toggleSelection(named("DSC00004.JPG"))
        #expect(await h.model.importSelected() == .started(1))
        #expect(h.importer.calls.last?.items.map(\.name) == ["DSC00004.JPG"])
        #expect(h.model.importNotice == "Importing 1 file.")
        #expect(h.model.selectedItems.isEmpty)
        // Only imported ones: nothing to hand over.
        let calls = h.importer.calls.count
        h.model.tap(named("DSC00003.JPG"))
        #expect(await h.model.importSelected(as: .photos) == .nothingNew)
        #expect(h.importer.calls.count == calls)
        #expect(h.model.importNotice == "These files are already imported or in the import.")
        #expect(h.model.selectedItems.isEmpty && !h.model.isSelecting)
        // Stage leaves out staged photos, imported or not.
        h.model.tap(named("DSC00002.ARW"))
        h.model.toggleSelection(named("DSC00003.JPG"))
        #expect(await h.model.importSelected(as: .staging) == .nothingNew)
        #expect(h.importer.calls.count == calls)
        #expect(h.model.importNotice == "These files are already staged or being staged.")
        #expect(h.importer.importChoice == .photos) // nothing was handed over, so nothing was remembered
        await h.stop()
    }

    @Test func whileStageIsTheDefaultAnImportedPhotoCanBePickedToStage() async {
        let h = await start(choice: .staging)
        #expect(await listed(h))
        #expect(h.model.importButtonTitle == "Stage")
        #expect(h.model.selectionBlock(for: named("DSC00001.ARW")) == nil)
        h.model.tap(named("DSC00001.ARW"))
        #expect(await h.model.importSelected() == .started(1))
        #expect(h.importer.asked.last?.choice == .staging)
        #expect(h.importer.asked.last?.newOnly == false)
        #expect(h.model.importNotice == "Staging 1 file.")
        // Select All New still skips it.
        h.model.selectAllNew()
        #expect(h.model.selectedItems.map(\.name) == ["DSC00004.JPG"])
        await h.stop()
    }

    @Test func theMenuHandsOverTheChoiceAndTheButtonRemembersIt() async {
        let h = await start()
        #expect(await listed(h))
        #expect(h.model.importButtonTitle == "Import")
        h.model.selectAllNew()
        #expect(await h.model.importSelected(as: .staging) == .started(1))
        // Only new files were asked for, so a stage job also leaves out files imported meanwhile.
        #expect(h.importer.asked.last?.choice == .staging)
        #expect(h.importer.asked.last?.newOnly == true)
        #expect(h.model.importButtonTitle == "Stage")
        // An explicit pick added to Select All New's picks is no longer "new only": an imported photo picked with
        // it is staged too.
        h.model.selectAllNew()
        h.model.tap(named("DSC00001.ARW"))
        #expect(await h.model.importSelected() == .started(2))
        #expect(h.importer.asked.last?.newOnly == false)
        await h.stop()
    }

    @Test func aRefusalForTheOtherChoiceKeepsTheSelection() async {
        let h = await start()
        #expect(await listed(h))
        h.importer.outcome = .busyWithAnotherMode(.photos)
        h.model.selectAllNew()
        #expect(await h.model.importSelected(as: .staging) == .busyWithAnotherMode(.photos))
        #expect(h.model.selectedItems.map(\.name) == ["DSC00004.JPG"])
        #expect(h.model.importNotice == "An import is running. Stage these when it's done.")
        #expect(h.model.importStatus?.tone == .problem)
        #expect(h.model.importButtonTitle == "Import")
        await h.stop()
    }

    @Test func theStageItemSaysWhereStagingGoes() async {
        let h = await start()
        h.importer.locatedPlace = .iCloudDrive
        #expect(await listed(h))
        // Browse reads it when it opens.
        #expect(await eventually { h.importer.stagingReads >= 1 })
        #expect(h.model.stageMenuTitle == "Stage in iCloud Drive")
        h.importer.locatedPlace = .onThisIPhone(.iCloudDriveOff)
        await h.model.refreshStagingPlace()
        #expect(h.model.stageMenuTitle == "Stage on iPhone")
        await h.stop()
    }

    @Test func theStagedBadgeFollowsTheImport() async {
        let h = await start()
        #expect(await listed(h))
        #expect(!h.model.isStaged(named("DSC00004.JPG")))
        await h.catalogue.markStaged(identity("DSC00004.JPG"), format: .jpeg, at: staged("DSC00004.JPG"))
        h.importer.announceImported()
        #expect(await eventually { h.model.isStaged(named("DSC00004.JPG")) })
        await h.stop()
    }

    @Test func wording() {
        #expect(BrowseWording.importButtonTitle(.photos) == "Import")
        #expect(BrowseWording.importButtonTitle(.staging) == "Stage")
        #expect(BrowseWording.importToPhotos == "Import to Photos")
        #expect(BrowseWording.stageMenuTitle(.iCloudDrive) == "Stage in iCloud Drive")
        #expect(BrowseWording.stageMenuTitle(.onThisIPhone(.lostDuringImport)) == "Stage on iPhone")
        #expect(BrowseWording.stageMenuTitle(nil) == "Stage on iPhone")
        #expect(BrowseWording.stagedBadge == "Staged")
        #expect(BrowseWording.importRequested(.started(3), choice: .staging) == "Staging 3 files.")
        #expect(BrowseWording.importRequested(.appended(2), choice: .staging) == "Added 2 files to staging.")
        #expect(BrowseWording.importRequested(.nothingNew, choice: .staging)
            == "These files are already staged or being staged.")
        #expect(ImportBackgroundWording.title(staging: true) == "Staging photos")
        #expect(ImportBackgroundWording.title(staging: false) == "Importing photos")
        #expect(ImportWording.stagingReason(.chosen, place: .iCloudDrive)
            == "Not added to Photos. iCloud Drive uploads the files in the background.")
        #expect(ImportWording.stagingReason(.photosDenied, place: .onThisIPhone(.iCloudDriveOff))
            == "Photos access is off, so photos are being staged instead. Allow access in Settings to import to "
            + "Photos next time. iCloud Drive is off or you're not signed in to iCloud, so they stay on this iPhone.")
        // Culling isn't built yet: nothing promises it.
        for reason in StagingReason.allCases {
            for place in [StagingPlace.iCloudDrive, .onThisIPhone(.containerUnavailable)] {
                #expect(!ImportWording.stagingReason(reason, place: place).lowercased().contains("cull"))
            }
        }
    }
}
