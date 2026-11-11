import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPSimulator
import SimulatedLink
import Testing
@testable import AppUI

// The app's models end to end against the simulated camera (backlog sections 6 and 7): Browse, Import, the scene's
// phase, a pulled cable, Copy as JPEG and the destination, through `AppModel`'s wiring, with the real engine, the
// in-memory catalogue and the real Files folder. See `SimulatorBench` for what is real and what is faked.

@MainActor
@Suite("Browse and Import against the simulated camera", .serialized, .timeLimit(.minutes(5)))
struct BrowseAndImportAgainstSimulatorTests {
    @Test func browseListsTheCardNewestFirstByDayAndTheLastKnownCardGivesWayToTheLiveOne() async throws {
        let bench = try await SimulatorBench.make()
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        #expect(browse.lastKnownListedAt == nil)
        #expect(browse.sections.map(\.id) == ["2026-11-02", "2026-11-01", "undated"])
        #expect(browse.sections.map { $0.items.map(\.name) } == [
            ["DSC00005.HIF", "C0001.MP4", "DSC00003.JPG"],
            ["DSC00002.ARW", "DSC00001.ARW", "DSC00001.JPG"],
            ["DSC00004.ARW"],
        ])
        // Thumbnails come through the link: the camera's for a still, none for the clip.
        let raw = try #require(browse.shown("DSC00001.ARW"))
        let thumbnail = try #require(await browse.thumbnail(for: raw.id))
        #expect(thumbnail.prefix(2) == Data([0xFF, 0xD8]))
        let clip = try #require(browse.shown("C0001.MP4"))
        #expect(await browse.thumbnail(for: clip.id) == nil)
        // The live listing is saved as the last-known card: every dated file, by identity.
        try await bench.until("the listing to be saved") { await bench.catalogue.lastListing(for: bench.key) != nil }
        let first = try #require(await bench.catalogue.lastListing(for: bench.key))
        #expect(Set(first.entries.map(\.identity.filename)) == importableStills.union(["C0001.MP4"]))
        await bench.stopBrowsing()
        #expect(await !bench.link.isOpen)   // nobody else held it, so leaving Browse closed it

        // Next connection: the camera has shot another frame and its catalogue takes a while.
        let again = await bench.replug()
        await again.shoot([.jpeg])
        await again.holdCatalogue()
        let second = bench.browse()
        try await bench.until("the last-known card") { second.lastKnownListedAt == first.listedAt }
        if case .reading = second.phase {} else { Issue.record("expected the card to be read still, got \(second.phase)") }
        #expect(second.sections.map(\.id) == ["2026-11-02", "2026-11-01"])
        #expect(Set(second.shown.map(\.name)) == importableStills.union(["C0001.MP4"]))
        #expect(second.shown.allSatisfy { $0.id.rawValue.hasPrefix("last-known:") })
        let known = try #require(second.shown("DSC00003.JPG"))
        #expect(second.selectionBlock(for: known) == .cardNotRead)
        #expect(!second.offersJPEGActions(known))
        second.selectAllNew()
        #expect(second.selection.isEmpty)

        await again.releaseCatalogue()
        try await bench.until("the live card") { second.phase == .listed }
        #expect(second.lastKnownListedAt == nil)
        #expect(second.shown.first?.name == "DSC00006.JPG")
        #expect(second.shown.count == 8)
        #expect(second.shown.allSatisfy { $0.id.rawValue.hasPrefix("g2-") })
        // The live card replaces the saved one, new frame included.
        try await bench.until("the new listing to be saved") {
            await bench.catalogue.lastListing(for: bench.key)?.entries.count == 7
        }
        let saved = try #require(await bench.catalogue.lastListing(for: bench.key))
        #expect(saved.entries.contains { $0.identity.filename == "DSC00006.JPG" })
        #expect(saved.listedAt >= first.listedAt)
        await bench.finish()
    }

    @Test func selectAllNewPicksStillsOnlyAndAnImportedFileIsNeverPickedAgain() async throws {
        let bench = try await SimulatorBench.make()
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        browse.selectAllNew()
        #expect(browse.isSelecting)
        #expect(Set(browse.selectedItems.map(\.name)) == importableStills)
        #expect(browse.selectedItems.map(\.name).first == "DSC00005.HIF")   // newest first, as Import hands them
        #expect(browse.selectionBlock(for: try #require(browse.shown("C0001.MP4"))) == .video)
        #expect(browse.selectionBlock(for: try #require(browse.shown("DSC00004.ARW"))) == .noCaptureDate)
        #expect(browse.selectionSummary == SelectionSummary(count: 5, bytes: 40_000 + 20_000 + 41_000 + 22_000 + 12_000))
        #expect(browse.canImport)

        let outcome = await browse.importSelected()
        #expect(outcome == .started(5))
        #expect(browse.importNotice == "Importing 5 files.")
        #expect(browse.selection.isEmpty && !browse.isSelecting)
        #expect(bench.importer.hasJob)
        #expect(bench.importer.camera?.key == bench.key)
        try await bench.untilImport(.finished(.completed))
        #expect(bench.importer.countsLine == "5 files imported.")
        #expect(bench.importer.rows.allSatisfy { $0.stateText == "Imported to Files" })
        await bench.expectInFiles(importableStills)
        #expect(await bench.link.bytesCalls.sorted() == importableStills.sorted())   // each file fetched once

        // The badge: Browse follows the import's "more files imported" by itself, with nobody asking it to.
        #expect(bench.importer.importedRevision > 0)
        try await bench.until("the badges after the import") { browse.imported.count == importableStills.count }
        #expect(Set(browse.shown.filter(browse.isImported).map(\.name)) == importableStills)
        #expect(browse.selectionBlock(for: try #require(browse.shown("DSC00002.ARW"))) == .imported)
        for item in browse.shown where importableStills.contains(item.name) {
            #expect(await bench.state(of: item) == .imported, "\(item.name)")
        }
        browse.filter.newOnly = true
        #expect(Set(browse.shown.map(\.name)) == ["C0001.MP4", "DSC00004.ARW"])
        browse.filter.newOnly = false

        // A second Select All New picks nothing, so there is nothing to import.
        browse.selectAllNew()
        #expect(browse.selection.isEmpty)
        #expect(!browse.canImport)
        #expect(await browse.importSelected() == nil)
        #expect(await bench.link.bytesCalls.count == 5)

        // Next connection: the badges show on the last-known card at once, and stay on the live one.
        await bench.stopBrowsing()
        let again = await bench.replug()
        await again.holdCatalogue()
        let next = bench.browse()
        try await bench.until("the badges on the last-known card") {
            next.lastKnownListedAt != nil && next.imported.count == 5
        }
        #expect(Set(next.shown.filter(next.isImported).map(\.name)) == importableStills)
        await again.releaseCatalogue()
        try await bench.until("the live card") { next.phase == .listed }
        #expect(Set(next.shown.filter(next.isImported).map(\.name)) == importableStills)
        #expect(next.shown.allSatisfy { $0.id.rawValue.hasPrefix("g2-") })
        next.selectAllNew()
        #expect(next.selection.isEmpty)
        #expect(await again.bytesCalls.isEmpty)
        await bench.finish()
    }

    @Test func filesPickedWhileAJobRunsAreAppendedAndLandAtTheEnd() async throws {
        let bench = try await SimulatorBench.make()
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        await bench.link.script("DSC00003.JPG", .holdAfter(4096))
        browse.isSelecting = true
        browse.toggleSelection(try #require(browse.shown("DSC00003.JPG")))
        #expect(await browse.importSelected() == .started(1))
        await bench.link.waitUntilHeld("DSC00003.JPG")

        // Two more picked while the first is still copying.
        browse.isSelecting = true
        browse.toggleSelection(try #require(browse.shown("DSC00001.ARW")))
        browse.toggleSelection(try #require(browse.shown("DSC00002.ARW")))
        #expect(await browse.importSelected() == .appended(2))
        #expect(browse.importNotice == "Added 2 files to the import.")
        await bench.importer.refresh()
        #expect(bench.importer.rows.map(\.name) == ["DSC00003.JPG", "DSC00002.ARW", "DSC00001.ARW"])
        #expect(bench.importer.rows.first?.stateText == "Copying from the camera")
        #expect(bench.importer.statusLine == "0 of 3 files done")
        // Picking a file already in the job adds nothing.
        browse.isSelecting = true
        browse.toggleSelection(try #require(browse.shown("DSC00001.ARW")))
        #expect(await browse.importSelected() == .nothingNew)

        await bench.link.release("DSC00003.JPG")
        try await bench.untilImport(.finished(.completed))
        #expect(await bench.link.bytesCalls == ["DSC00003.JPG", "DSC00002.ARW", "DSC00001.ARW"])
        #expect(bench.importer.countsLine == "3 files imported.")
        await bench.expectInFiles(["DSC00003.JPG", "DSC00002.ARW", "DSC00001.ARW"])
        await bench.finish()
    }
}

@MainActor
@Suite("Leaving the app and the cable, against the simulated camera", .serialized, .timeLimit(.minutes(5)))
struct SceneAndCableAgainstSimulatorTests {
    /// Starts an import of every new still, with the newest (the HIF) held part-way, and returns the Browse model.
    func importAllHoldingTheNewest(_ bench: SimulatorBench, holding name: String = "DSC00005.HIF") async throws
        -> BrowseModel {
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        await bench.link.script(name, .holdAfter(4096))
        browse.selectAllNew()
        #expect(await browse.importSelected() == .started(5))
        await bench.link.waitUntilHeld(name)
        return browse
    }

    @Test func backgroundPausesTheJobAndComingBackCompletesIt() async throws {
        let bench = try await SimulatorBench.make()
        _ = try await importAllHoldingTheNewest(bench)
        #expect(bench.app.keepsScreenOn)

        // The app leaves the foreground: the scene's phase reaches the import first, then ImageCaptureCore suspends.
        await bench.app.scenePhaseChanged(.inactive)
        #expect(bench.importer.state == .running)
        await bench.app.scenePhaseChanged(.background)
        #expect(bench.importer.state == .paused(.appInBackground))
        #expect(bench.importer.statusLine == "Paused: open Shutter Bridge to continue.")
        #expect(!bench.app.keepsScreenOn)
        await bench.link.appLeavesForeground()
        await bench.link.suspend()
        let removed = await bench.link.isRemoved
        let open = await bench.link.isOpen
        #expect(!removed && open)   // the same session carries on

        // The download in flight finishes once the session resumes and is committed; nothing new starts while the
        // app's pause holds.
        await bench.link.release("DSC00005.HIF")
        await bench.link.resumeOperations()
        try await bench.until("the file in flight to be committed") { bench.importedFiles()["DSC00005.HIF"] != nil }
        await bench.importer.refresh()
        #expect(bench.importer.state == .paused(.appInBackground))
        #expect(await bench.link.bytesCalls == ["DSC00005.HIF"])

        await bench.app.scenePhaseChanged(.active)
        try await bench.untilImport(.finished(.completed))
        await bench.expectInFiles(importableStills)
        #expect(await bench.link.bytesCalls.sorted() == importableStills.sorted())
        await bench.finish()
    }

    @Test func comingBackNeverLiftsThePersonsPause() async throws {
        let bench = try await SimulatorBench.make()
        _ = try await importAllHoldingTheNewest(bench)
        await bench.importer.pause()
        #expect(bench.importer.state == .paused(.byPerson))

        await bench.app.scenePhaseChanged(.background)
        await bench.link.appLeavesForeground()
        await bench.link.suspend()
        await bench.link.resumeOperations()
        await bench.app.scenePhaseChanged(.active)
        await bench.importer.refresh()
        #expect(bench.importer.state == .paused(.byPerson))
        #expect(bench.importer.canResume)
        #expect(bench.importer.statusLine == "Paused. Tap Continue to resume.")

        await bench.importer.resume()
        #expect(bench.importer.state == .running)
        await bench.link.release("DSC00005.HIF")
        try await bench.untilImport(.finished(.completed))
        await bench.expectInFiles(importableStills)
        await bench.finish()
    }

    @Test func aPulledCablePausesTheJobAndTheReconnectedCameraFinishesItWithoutImportingTwice() async throws {
        let bench = try await SimulatorBench.make()
        // Newest first: the HIF and DSC00003.JPG are in Files before DSC00002.ARW is cut off part-way.
        let browse = try await importAllHoldingTheNewest(bench, holding: "DSC00002.ARW")
        let first = bench.link
        await first.remove()
        await bench.discovery.send(.disappeared(bench.camera.id))
        try await bench.untilImport(.paused(.cameraRemoved))
        #expect(bench.importer.isWaitingForCamera)
        #expect(!bench.importer.canResume)
        #expect(bench.importer.keepsScreenOn)
        #expect(bench.importer.statusLine == ImportWording.paused(.cameraRemoved, mode: .mtp))
        try await bench.until("Browse to give way") { browse.phase == .gone }
        try await bench.until("the camera to go from the list") { bench.app.cameras.cameras.isEmpty }
        await bench.expectInFiles(["DSC00005.HIF", "DSC00003.JPG"])
        #expect(await first.delivered == ["DSC00005.HIF", "DSC00003.JPG"])

        // The cable goes back in: discovery reports the camera, and the import carries on through the new link.
        let again = await bench.replug()
        await bench.discovery.send(.appeared(bench.camera))
        try await bench.untilImport(.finished(.completed))
        #expect(bench.importer.countsLine == "5 files imported.")
        await bench.expectInFiles(importableStills)   // no second copy of anything ("DSC00005 (1).HIF" and so on)
        let refetched = await again.bytesCalls
        #expect(refetched.first == "DSC00002.ARW")   // the interrupted file again, from its start
        #expect(Set(refetched) == ["DSC00002.ARW", "DSC00001.ARW", "DSC00001.JPG"])
        #expect(refetched.count == 3)
        #expect(await again.openCount == 1)
        for name in importableStills {
            let item = try #require(await again.item(named: name))
            #expect(await bench.state(of: item) == .imported, "\(name)")
        }
        await bench.finish()
    }
}

extension SceneAndCableAgainstSimulatorTests {
    /// The cable pulled and put back while the app is in the background: nothing moves until the app is back, then
    /// the job carries on through the new link.
    @Test func aCablePulledWhileInTheBackgroundWaitsForTheAppAndTheCamera() async throws {
        let bench = try await SimulatorBench.make()
        _ = try await importAllHoldingTheNewest(bench, holding: "DSC00003.JPG")
        await bench.app.scenePhaseChanged(.background)
        await bench.link.appLeavesForeground()
        await bench.link.suspend()
        await bench.link.remove()
        try await bench.untilImport(.paused(.cameraRemoved))
        await bench.discovery.send(.disappeared(bench.camera.id))
        try await bench.until("the camera to go from the list") { bench.app.cameras.cameras.isEmpty }
        let again = await bench.replug()
        await bench.discovery.send(.appeared(bench.camera))
        try await bench.until("the camera to be listed again") { bench.app.cameras.cameras == [bench.camera] }
        // Reconnected (the engine lists the new link even while paused), with only the background pause left.
        await again.waitForListCall()
        try await bench.untilImport(.paused(.appInBackground))
        #expect(await again.bytesCalls.isEmpty)   // nothing is fetched while the app is away

        await bench.app.scenePhaseChanged(.active)
        try await bench.untilImport(.finished(.completed))
        await bench.expectInFiles(importableStills)
        let refetched = await again.bytesCalls
        #expect(refetched.first == "DSC00003.JPG")
        #expect(!refetched.contains("DSC00005.HIF"))
        await bench.finish()
    }
}

@MainActor
@Suite("Copy as JPEG against the simulated camera", .serialized, .timeLimit(.minutes(5)))
struct CopyAsJPEGAgainstSimulatorTests {
    @Test func theSourceFollowsTheRuleAndNothingIsImportedOrLeftBehind() async throws {
        let bench = try await SimulatorBench.make()
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        let pairRAW = try #require(browse.shown("DSC00001.ARW"))
        let loneJPG = try #require(browse.shown("DSC00003.JPG"))
        let loneRAW = try #require(browse.shown("DSC00002.ARW"))
        #expect(browse.offersJPEGActions(pairRAW))
        #expect(!browse.offersJPEGActions(try #require(browse.shown("C0001.MP4"))))

        // A RAW with its pair's JPG on the card: that JPG, as the camera made it.
        browse.copyAsJPEG(pairRAW)
        await browse.waitForAction()
        #expect(browse.action == .finished("Copied DSC00001 as a JPEG."))
        #expect(await bench.link.bytesCalls.last == "DSC00001.JPG")
        #expect(bench.clipboard.copied.last == (await bench.content(of: "DSC00001.JPG")))
        #expect(actionFolders(in: bench.scratch).isEmpty)

        // A lone JPG: itself, as it is.
        browse.copyAsJPEG(loneJPG)
        await browse.waitForAction()
        #expect(browse.action == .finished("Copied DSC00003 as a JPEG."))
        #expect(bench.clipboard.copied.last == (await bench.content(of: "DSC00003.JPG")))
        #expect(actionFolders(in: bench.scratch).isEmpty)
        #expect(bench.maker.made.isEmpty)   // neither was rendered

        // A lone RAW: fetched whole and rendered.
        browse.copyAsJPEG(loneRAW)
        await browse.waitForAction()
        #expect(browse.action == .finished("Copied DSC00002 as a JPEG."))
        #expect(bench.maker.made.map(\.name) == ["DSC00002.ARW"])
        #expect(bench.maker.made.first?.conversion == .renderRAW)
        #expect(bench.maker.made.first?.bytes == (await bench.content(of: "DSC00002.ARW")))
        #expect(bench.clipboard.copied.last == Data("JPEG from DSC00002.ARW by renderRAW".utf8))
        #expect(actionFolders(in: bench.scratch).isEmpty)

        // The same RAW when iOS can't decode it: the embedded preview, and the message says so.
        bench.maker.makeUndecodable("DSC00002.ARW")
        browse.copyAsJPEG(loneRAW)
        await browse.waitForAction()
        #expect(browse.action == .finished(JPEGWording.copiedPreview))
        #expect(bench.clipboard.copied.count == 4)
        #expect(actionFolders(in: bench.scratch).isEmpty)

        // The bench log names each path.
        let paths = bench.log.lines.filter { $0.hasPrefix("copy-as-jpeg path=") }
            .compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
        #expect(paths == ["path=pair-jpg", "path=jpg-as-is", "path=raw-render", "path=preview-fallback"])

        // None of it is an import: no catalogue row, no job, nothing in Files, no badge.
        #expect(await bench.catalogue.allRecords.isEmpty)
        #expect(!bench.importer.hasJob)
        #expect(bench.importedFiles().isEmpty)
        await browse.refreshImportedStates()
        #expect(browse.imported.isEmpty)
        await bench.finish()
    }

    @Test func aCancelledOrFailedCopyLeavesNothingBehind() async throws {
        let bench = try await SimulatorBench.make()
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        await bench.link.script("DSC00003.JPG", .holdAfter(4096))
        browse.copyAsJPEG(try #require(browse.shown("DSC00003.JPG")))
        await bench.link.waitUntilHeld("DSC00003.JPG")
        #expect(actionFolders(in: bench.scratch).count == 1)
        guard case let .working(work) = browse.action else {
            Issue.record("expected the copy to be working, got \(browse.action)")
            return
        }
        #expect(work.name == "DSC00003.JPG")

        browse.cancelAction()
        #expect(browse.statusLineIsCancelling)
        // ImageCaptureCore ignores the cancel and the fetch runs on; once it returns, the copy ends as cancelled.
        await bench.link.release("DSC00003.JPG")
        await browse.waitForAction()
        #expect(browse.action == .idle)
        #expect(bench.clipboard.copied.isEmpty)
        #expect(actionFolders(in: bench.scratch).isEmpty)

        // A fetch the camera fails: the message, and the folder goes too.
        await bench.link.script("DSC00001.JPG", .fail(.unreadableItem))
        browse.copyAsJPEG(try #require(browse.shown("DSC00001.JPG")))
        await browse.waitForAction()
        let failure = CameraLinkFailure(.unreadableItem, detail: "bytes: scripted")
        #expect(browse.action == JPEGWording.failed(.link(failure)).map(JPEGActionState.failed))
        #expect(bench.clipboard.copied.isEmpty)
        #expect(actionFolders(in: bench.scratch).isEmpty)
        #expect(await bench.catalogue.allRecords.isEmpty)
        await bench.finish()
    }

    @Test func leavingTheAppCancelsACopyAndSaysWhyOnceItHasStopped() async throws {
        let bench = try await SimulatorBench.make()
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        await bench.link.script("DSC00002.ARW", .holdAfter(4096))
        browse.copyAsJPEG(try #require(browse.shown("DSC00002.ARW")))
        await bench.link.waitUntilHeld("DSC00002.ARW")

        // *Will suspend* cancels the copy (no render in the background); the fetch stops with the session.
        await bench.link.appLeavesForeground()
        try await bench.until("the copy to be cancelling") { browse.statusLineIsCancelling }
        await bench.link.suspend()
        await bench.link.release("DSC00002.ARW")
        await bench.link.resumeOperations()
        await browse.waitForAction()
        #expect(browse.action == .failed(JPEGWording.keepOpen))
        #expect(bench.maker.made.isEmpty)
        #expect(bench.clipboard.copied.isEmpty)
        #expect(actionFolders(in: bench.scratch).isEmpty)
        await bench.finish()
    }
}

extension BrowseModel {
    fileprivate var statusLineIsCancelling: Bool {
        if case let .working(work) = action { work.cancelling && work.statusLine == JPEGWording.cancelling } else { false }
    }
}

@MainActor
@Suite("The destination against the simulated camera", .serialized, .timeLimit(.minutes(5)))
struct DestinationAgainstSimulatorTests {
    /// Lists the card and imports `names` (every new still if nil).
    func importFromBrowse(_ bench: SimulatorBench, _ browse: BrowseModel, _ names: [String]? = nil) async throws
        -> ImportRequestOutcome? {
        if let names {
            browse.isSelecting = true
            for name in names { browse.toggleSelection(try #require(browse.shown(name))) }
        } else {
            browse.selectAllNew()
        }
        return await browse.importSelected()
    }

    @Test func settingFilesSendsTheFilesToTheCamerasFolderAndNeverAsksForPhotos() async throws {
        let photos = FakePhotosAccess(.notDetermined)
        let bench = try await SimulatorBench.make(setting: .photos, photos: photos)
        bench.app.settings.destination = .staging   // the Settings screen's picker
        #expect(bench.settingsStore.load() == DestinationSetting(preferred: .staging))
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        #expect(try await importFromBrowse(bench, browse) == .started(5))
        try await bench.untilImport(.finished(.completed))
        #expect(photos.askCount == 0)
        #expect(bench.importer.progress.destination == .stagedHere(.chosen))
        #expect(bench.importer.destinationLine
            == "Imported to Files: On My iPhone › Shutter Bridge › Staging › ILCE-7CM2.")
        #expect(bench.importer.filesReasonLine == "You chose Files in Settings.")
        #expect(!bench.importer.offersPhotosSettingsLink)
        await bench.expectInFiles(importableStills)
        #expect(await bench.destinations.photos.names.isEmpty)
        // Dated by the camera's capture date, so Files sorts them by it.
        let jpg = try #require(await bench.link.item(named: "DSC00003.JPG"))
        let staged = try #require(bench.stagedFile(named: "DSC00003.JPG"))
        let modified = try FileManager.default.attributesOfItem(atPath: staged.path)[.modificationDate]
        #expect(modified as? Date == jpg.captureDate)
        await bench.finish()
    }

    @Test func photosDeniedForcesFilesAndSaysWhy() async throws {
        let photos = FakePhotosAccess(.denied)
        let bench = try await SimulatorBench.make(setting: .photos, photos: photos)
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        #expect(try await importFromBrowse(bench, browse) == .started(5))
        try await bench.untilImport(.finished(.completed))
        #expect(photos.askCount == 0)   // denied isn't asked again; iOS wouldn't show the prompt
        #expect(bench.importer.progress.destination == .stagedHere(.photosDenied))
        #expect(bench.importer.filesReasonLine == ImportWording.filesReason(.photosDenied))
        #expect(bench.importer.offersPhotosSettingsLink)
        #expect(bench.importer.destinationLine
            == "Imported to Files: On My iPhone › Shutter Bridge › Staging › ILCE-7CM2.")
        await bench.expectInFiles(importableStills)
        #expect(await bench.destinations.photos.names.isEmpty)
        await bench.finish()
    }

    @Test func photosIsAskedForOnlyAtTheFirstImport() async throws {
        let photos = FakePhotosAccess(.notDetermined, answer: .authorised)
        let bench = try await SimulatorBench.make(setting: .photos, photos: photos)
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        // Launching, listing, thumbnails, selecting and Copy as JPEG never ask.
        let jpg = try #require(browse.shown("DSC00003.JPG"))
        _ = await browse.thumbnail(for: jpg.id)
        browse.copyAsJPEG(try #require(browse.shown("DSC00003.JPG")))
        await browse.waitForAction()
        browse.selectAllNew()
        browse.clearSelection()
        #expect(photos.askCount == 0)

        #expect(try await importFromBrowse(bench, browse, ["DSC00003.JPG"]) == .started(1))
        #expect(photos.askCount == 1)
        try await bench.untilImport(.finished(.completed))
        #expect(bench.importer.progress.destination == .photos)
        #expect(bench.importer.destinationLine == "Imported to Photos.")
        #expect(await bench.destinations.photos.names == ["DSC00003.JPG"])

        // The next import goes straight to Photos.
        #expect(try await importFromBrowse(bench, browse, ["DSC00002.ARW"]) == .started(1))
        try await bench.untilImport(.finished(.completed))
        #expect(photos.askCount == 1)
        #expect(await bench.destinations.photos.names == ["DSC00003.JPG", "DSC00002.ARW"])
        #expect(bench.importedFiles().isEmpty)
        await bench.finish()
    }
}
