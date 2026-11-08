import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

/// The Import screen's model over the real engine (its public API), with fake links, destinations and Photos access.
@MainActor
@Suite("Import screen model")
struct ImportModelTests {
    let card = [
        item("DSC00001.ARW", at: 10, size: 4_000),
        item("DSC00001.JPG", at: 10, size: 2_000),
        item("DSC00002.JPG", at: 20, size: 3_000),
    ]

    struct Harness {
        let model: ImportModel
        let engine: ImportEngine
        let catalogue: InMemoryCatalogue
        let settings: InMemoryDestinationSettingStore
        let photos: FakePhotosAccess
        let destinations: FakeDestinations
        let leases: LinkLeases
        let finder: FakeFinder
        let link: FakeLink
        let camera: ImportCamera

        func importAll(_ items: [CameraItem]) async -> ImportRequestOutcome {
            await model.importItems(items, from: camera, link: link)
        }

        func finished() async -> Bool {
            await eventually {
                await model.refresh()
                if case .finished = model.state { return true }
                return false
            }
        }

        func state(_ expected: ImportJobState) async -> Bool {
            await eventually {
                await model.refresh()
                return model.state == expected
            }
        }
    }

    func freshLink(id: String = "fake-camera") async -> FakeLink {
        let link = FakeLink(items: card, id: id)
        await link.set(writesListedSize: true)
        return link
    }

    func harness(setting: DestinationKind = .photos, photos: FakePhotosAccess = FakePhotosAccess(),
                 hangs: Bool = false, catalogue: InMemoryCatalogue = InMemoryCatalogue(),
                 log: any BenchLog = SilentBenchLog()) async -> Harness {
        let link = FakeLink(items: card)
        await link.set(writesListedSize: true)
        await link.set(bytesHangs: hangs)
        let engine = ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging())
        let settings = InMemoryDestinationSettingStore(DestinationSetting(preferred: setting))
        let destinations = FakeDestinations()
        let leases = LinkLeases()
        let finder = FakeFinder()
        let model = ImportModel(engine: engine, settings: settings, photos: photos, destinations: destinations,
                                leases: leases, log: log)
        model.cameraFinder = finder
        let camera = ImportCamera(descriptor: link.descriptor, key: CameraKeys.key(for: link.descriptor, material: nil))
        return Harness(model: model, engine: engine, catalogue: catalogue, settings: settings, photos: photos,
                       destinations: destinations, leases: leases, finder: finder, link: link, camera: camera)
    }

    // MARK: - More files imported

    @Test func importedUpdatesFireOncePerIncrease() async {
        final class Seen: @unchecked Sendable {
            var revisions: [Int] = []
        }
        let h = await harness(setting: .filesFolder)
        let seen = Seen()
        let updates = h.model.importedUpdates()
        let reader = Task { @MainActor in
            for await revision in updates { seen.revisions.append(revision) }
        }
        #expect(await h.importAll(card) == .started(3))
        #expect(await h.finished())
        #expect(h.model.importedRevision > 0)
        #expect(await eventually { seen.revisions.last == h.model.importedRevision })
        // Never more than once per increase, in order; a slow reader may skip to the newest.
        #expect(seen.revisions == seen.revisions.sorted() && Set(seen.revisions).count == seen.revisions.count)
        // Reading the engine again with nothing new imported says nothing.
        let count = seen.revisions.count
        await h.model.refresh()
        await h.model.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(seen.revisions.count == count)
        reader.cancel()
        await reader.value
    }

    @Test func eachImportedFileIsLoggedWithItsIdentityAndNoKey() async {
        let log = RecordingLog()
        let h = await harness(setting: .filesFolder, log: log)
        #expect(await h.importAll(card) == .started(3))
        #expect(await h.finished())
        let tag = CameraKeyTags.shared.tag(for: h.camera.key)
        let imported = log.lines.filter { $0.hasPrefix("import: imported ") }
        #expect(imported.count == 3)
        let date = CaptureDate(card[2].captureDate!, in: .current)!.rawValue
        #expect(imported.contains(
            "import: imported DSC00002.JPG \(date) 3000 B folder \"DCIM/100MSDCF\" key \(tag) → Files"))
        #expect(log.lines.filter { $0.hasPrefix("import: job ended ") }
            == ["import: job ended completed: 3 imported, key \(tag)"])
        for line in log.lines { #expect(!line.contains(h.camera.key.rawValue.suffix(16)), "\(line)") }
    }

    // MARK: - Destination and the Photos ask

    @Test func theFirstImportAsksForPhotosAccessThenImportsToPhotos() async {
        let photos = FakePhotosAccess(.notDetermined, answer: .authorised)
        let h = await harness(photos: photos)
        #expect(await h.importAll(card) == .started(3))
        #expect(photos.askCount == 1)
        #expect(await h.finished())
        #expect(h.model.state == .finished(.completed))
        #expect(await h.destinations.photos.names.sorted() == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
        #expect(h.model.destinationLine == "Imported to Photos.")
        #expect(h.model.filesReasonLine == nil)
        #expect(!h.model.offersPhotosSettingsLink)
        #expect(h.model.statusLine == "Import finished.")
        #expect(h.model.countsLine == "3 files imported.")
        #expect(h.model.rows.map(\.stateText) == ["Imported to Photos", "Imported to Photos", "Imported to Photos"])
        #expect(!h.model.keepsScreenOn)
        #expect(h.model.importedRevision > 0)
        // The job let go of the link when it ended; nobody else held it.
        #expect(await eventually { await h.link.closed })
        #expect(h.destinations.cameras.map(\.key) == [h.camera.key])

        // The next import doesn't ask again.
        let again = await h.model.importItems([card[0]], from: h.camera, link: await freshLink())
        #expect(again == .started(1))
        #expect(photos.askCount == 1)
        #expect(await h.finished())
    }

    @Test func deniedAtThePromptGoesToFilesWithTheSettingsLink() async {
        let h = await harness(photos: FakePhotosAccess(.notDetermined, answer: .denied))
        #expect(await h.importAll(card) == .started(3))
        #expect(await h.finished())
        #expect(await h.destinations.files.names.count == 3)
        #expect(await h.destinations.photos.names.isEmpty)
        #expect(h.model.destinationLine == "Imported to Files: On My iPhone › Shutter Bridge › Untitled.")
        #expect(h.model.filesReasonLine == ImportWording.filesReason(.photosDenied))
        #expect(h.model.offersPhotosSettingsLink)
        #expect(h.model.rows.allSatisfy { $0.stateText == "Saved to Files" })
    }

    @Test func restrictedGoesToFilesWithoutTheSettingsLink() async {
        let photos = FakePhotosAccess(.restricted)
        let h = await harness(photos: photos)
        #expect(await h.importAll(card) == .started(3))
        #expect(await h.finished())
        #expect(photos.askCount == 0)
        #expect(h.model.filesReasonLine == ImportWording.filesReason(.photosRestricted))
        #expect(!h.model.offersPhotosSettingsLink)
    }

    @Test func limitedAccessImportsToPhotos() async {
        let h = await harness(photos: FakePhotosAccess(.limited))
        _ = await h.importAll(card)
        #expect(await h.finished())
        #expect(h.model.progress.destination == .photos)
        #expect(await h.destinations.photos.names.count == 3)
    }

    @Test func choosingFilesNeverAsksAndSaysItWasChosen() async {
        let photos = FakePhotosAccess(.notDetermined)
        let h = await harness(setting: .filesFolder, photos: photos)
        _ = await h.importAll(card)
        #expect(await h.finished())
        #expect(photos.askCount == 0)
        #expect(h.model.progress.destination == .files(.chosen))
        #expect(h.model.filesReasonLine == "You chose Files in Settings.")
        #expect(!h.model.offersPhotosSettingsLink)
    }

    @Test func theNextImportFollowsTheSetting() async {
        let h = await harness(setting: .filesFolder)
        _ = await h.importAll([card[0]])
        #expect(await h.finished())
        #expect(h.model.progress.destination == .files(.chosen))
        h.settings.save(DestinationSetting(preferred: .photos))
        _ = await h.model.importItems([card[2]], from: h.camera, link: await freshLink())
        #expect(await h.state(.finished(.completed)))
        #expect(h.model.progress.destination == .photos)
    }

    @Test func aDenialMidImportSendsTheRestToFiles() async {
        let photos = FakePhotosAccess(.authorised)
        let h = await harness(photos: photos)
        await h.destinations.photos.setDenies(true)
        photos.change(afterNextReadTo: .denied)   // read as allowed at the start, denied after the refused save
        _ = await h.importAll(card)
        #expect(await h.finished())
        #expect(h.model.progress.destination == .files(.photosDenied))
        #expect(h.model.offersPhotosSettingsLink)
        #expect(await h.destinations.files.names.count == 3)
        #expect(h.model.progress.filesFailed == 0)
    }

    // MARK: - Rows, appending, pause, continue, cancel

    @Test func rowsShowEachFileAndAppendedFilesLandAtTheEnd() async {
        let h = await harness(hangs: true)
        #expect(await h.importAll([card[2]]) == .started(1))
        #expect(await eventually { await h.link.bytesStarted == 1 })
        #expect(await h.importAll([card[0], card[1], card[2]]) == .appended(2))
        await h.model.refresh()
        #expect(h.model.rows.map(\.name) == ["DSC00002.JPG", "DSC00001.ARW", "DSC00001.JPG"])
        #expect(h.model.rows.first?.stateText == "Copying from the camera")
        #expect(h.model.rows.first?.isInFlight == true)
        #expect(h.model.rows.dropFirst().allSatisfy { $0.stateText == "Waiting" && !$0.isInFlight })
        #expect(h.model.rows[1].accessibilityLabel == "DSC00001.ARW, Waiting, 4 KB")
        #expect(h.model.statusLine == "0 of 3 files done")
        #expect(h.model.bytesLine == "0 bytes of 9 KB")
        #expect(await h.importAll([card[0]]) == .nothingNew)
        #expect(h.model.keepsScreenOn)
        await h.model.cancel()
        #expect(h.model.state == .finished(.cancelled))
        #expect(h.model.statusLine == "Import cancelled.")
        #expect(h.model.countsLine == "0 files imported.")
        // The finished job's rows say the files weren't imported: no "Waiting", no bar that never ends.
        #expect(h.model.rows.allSatisfy { $0.stateText == "Not imported: still on the card" && !$0.isInFlight })
        // Nothing was imported, so nothing says "Imported to Photos.".
        #expect(h.model.destinationLine == nil)
    }

    @Test func anotherCamerasImportIsRefusedWhileOneRuns() async {
        let h = await harness(hangs: true)
        _ = await h.importAll([card[0]])
        let other = FakeLink(items: card, id: "other", name: "Second")
        let otherCamera = ImportCamera(descriptor: other.descriptor, key: CameraKey(rawValue: "other-key"))
        #expect(await h.model.importItems([card[1]], from: otherCamera, link: other) == .busyWithAnotherCamera)
        #expect(h.model.message == BrowseWording.importRequested(.busyWithAnotherCamera))
        await h.model.cancel()
    }

    @Test func pauseAndContinue() async {
        let h = await harness(hangs: true)
        _ = await h.importAll(card)
        #expect(await eventually { await h.link.bytesStarted == 1 })
        #expect(h.model.canPause)
        await h.model.pause()
        #expect(h.model.state == .paused(.byPerson))
        #expect(h.model.statusLine == "Paused. Tap Continue to carry on.")
        #expect(h.model.canResume)
        #expect(!h.model.canPause)
        #expect(!h.model.keepsScreenOn)   // the person paused it: the screen may sleep
        #expect(h.model.rateLine == nil && h.model.timeLeftLine == nil)
        await h.model.resume()
        #expect(h.model.state == .running)
        #expect(h.model.keepsScreenOn)
        await h.link.set(bytesHangs: false)
        await h.model.cancel()
    }

    @Test func continuingReadsPhotosAccessAgain() async {
        let photos = FakePhotosAccess(.authorised)
        let h = await harness(photos: photos, hangs: true)
        _ = await h.importAll(card)
        await h.model.pause()
        photos.set(.denied)   // turned off in Settings while the app was away
        await h.model.resume()
        #expect(h.model.progress.destination == .files(.photosDenied))
        #expect(h.model.offersPhotosSettingsLink)
        await h.model.cancel()
    }

    /// Access granted mid-job applies from the next import (decision 9): a job going to Files stays there, on
    /// Continue and on a return to the foreground.
    @Test func grantingPhotosAccessMidJobKeepsTheJobOnFiles() async {
        let photos = FakePhotosAccess(.denied)
        let h = await harness(photos: photos, hangs: true)
        _ = await h.importAll(card)
        #expect(await eventually { await h.link.bytesStarted == 1 })
        await h.model.refresh()
        #expect(h.model.progress.destination == .files(.photosDenied))
        await h.model.pause()
        photos.set(.authorised)   // allowed in Settings while the app was away
        await h.model.resume()
        #expect(h.model.progress.destination == .files(.photosDenied))
        #expect(h.model.offersPhotosSettingsLink)
        await h.model.scenePhaseChanged(.background)
        await h.model.scenePhaseChanged(.active)
        #expect(h.model.progress.destination == .files(.photosDenied))
        #expect(h.model.filesReasonLine == ImportWording.filesReason(.photosDenied))
        await h.model.cancel()
    }

    @Test func aFinishedJobCanBeDismissed() async {
        let h = await harness()
        _ = await h.importAll([card[2]])
        #expect(await h.finished())
        #expect(h.model.isFinished)
        h.model.dismiss()
        #expect(!h.model.hasJob)
        #expect(h.model.rows.isEmpty)
        #expect(h.model.statusLine == nil)
        await h.model.refresh()   // the engine's last job stays off the screen
        #expect(h.model.rows.isEmpty)
    }

    // MARK: - Scene phase, the screen and the camera coming back

    @Test func leavingTheForegroundPausesAndComingBackContinues() async {
        let h = await harness(hangs: true)
        _ = await h.importAll(card)
        #expect(await eventually { await h.link.bytesStarted == 1 })
        #expect(h.model.keepsScreenOn)
        await h.model.scenePhaseChanged(.inactive)
        #expect(h.model.state == .running)
        await h.model.scenePhaseChanged(.background)
        #expect(h.model.state == .paused(.appInBackground))
        #expect(h.model.statusLine == "Paused: open Shutter Bridge to continue.")
        #expect(!h.model.keepsScreenOn)
        #expect(await !h.link.closed)   // the same session carries on
        await h.model.scenePhaseChanged(.active)
        #expect(h.model.state == .running)
        #expect(h.model.keepsScreenOn)
        await h.model.cancel()
    }

    @Test func comingBackNeverLiftsThePersonsPause() async {
        let h = await harness(hangs: true)
        _ = await h.importAll(card)
        await h.model.pause()
        await h.model.scenePhaseChanged(.background)
        await h.model.scenePhaseChanged(.active)
        #expect(h.model.state == .paused(.byPerson))
        await h.model.cancel()
    }

    @Test func aRemovedCablePausesAndTheJobCarriesOnWhenTheCameraIsBack() async {
        let h = await harness(hangs: true)
        _ = await h.importAll(card)
        #expect(await eventually { await h.link.bytesStarted == 1 })
        await h.link.remove()
        #expect(await h.state(.paused(.cameraRemoved)))
        #expect(h.model.isWaitingForCamera)
        #expect(!h.model.canResume)
        #expect(h.model.keepsScreenOn)   // waiting for the camera it gets over by itself
        #expect(h.model.statusLine == ImportWording.paused(.cameraRemoved, mode: .massStorage))
        #expect(h.model.statusLine == "Paused: the camera was disconnected. Connect it again in Image Transfer (MSC) "
            + "and the import carries on.")

        let back = await freshLink(id: "fake-camera-2")
        h.finder.links[h.camera.key] = back
        await h.model.cameraConnected()
        #expect(await h.finished())
        #expect(h.model.state == .finished(.completed))
        #expect(await back.fetched.count == 3)
        #expect(h.model.countsLine == "3 files imported.")
        // The job let go of the new link when it ended.
        #expect(await eventually { await back.closed })
    }

    @Test func aStallThatWaitsForThePersonSaysSo() {
        #expect(ImportWording.status(ImportProgress(filesDone: 0, filesTotal: 1, bytesDone: 0, bytesTotal: 1,
                                                    state: .paused(.stalled), stallWaitsForPerson: true))
            == "Paused: the camera stopped sending. Check the cable and the camera, then tap Continue.")
        #expect(ImportWording.status(ImportProgress(filesDone: 0, filesTotal: 1, bytesDone: 0, bytesTotal: 1,
                                                    state: .paused(.stalled)))
            == "The camera stopped sending, so the file is being copied again.")
    }

    @Test func aCatalogueThatCantBeReadStopsTheJobAndSaysWhy() async {
        let link = FakeLink(items: card)
        await link.set(writesListedSize: true)
        let engine = ImportEngine(catalogue: BrokenCatalogue(), stagingDirectory: temporaryStaging())
        let model = ImportModel(engine: engine, settings: InMemoryDestinationSettingStore(),
                                photos: FakePhotosAccess(), destinations: FakeDestinations())
        let camera = ImportCamera(descriptor: link.descriptor, key: CameraKey(rawValue: "k"))
        _ = await model.importItems(card, from: camera, link: link)
        #expect(await eventually {
            await model.refresh()
            return model.state == .finished(.catalogueUnavailable)
        })
        #expect(model.statusLine == ImportWording.finished(.catalogueUnavailable))
    }
}
