import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

/// D11's second half (Shamil, 12 Nov): a USB job paused by a pulled cable continues on the same body in the other Image
/// Transfer mode, found by content, and a job on a name-hash key (MSC's "Untitled") isn't taken over by another card.
@MainActor
@Suite("Continuing a paused USB job by content (D11)")
struct ContinueByContentTests {
    let card = [
        item("DSC00001.ARW", at: 10, size: 4_000),
        item("DSC00001.JPG", at: 10, size: 2_000),
        item("DSC00002.JPG", at: 20, size: 3_000),
    ]
    let otherKey = CameraKey(rawValue: "usb-device:other")

    /// `items` as the other mode lists them: new handles, no folder, lower-case names (as an MTP listing might).
    func inTheOtherMode(_ items: [CameraItem]) -> [CameraItem] {
        items.map { CameraItem(id: .init(rawValue: "mtp-\($0.id.rawValue)"), folder: "", name: $0.name.lowercased(),
                               size: $0.size, captureDate: $0.captureDate) }
    }

    @MainActor
    struct Rig {
        let model: ImportModel
        let engine: ImportEngine
        let catalogue: InMemoryCatalogue
        let destinations: FakeDestinations
        let finder: FakeFinder
        let link: FakeLink
        let camera: ImportCamera
        let log: RecordingLog

        func finished() async -> Bool {
            await eventually {
                await model.refresh()
                if case .finished = model.state { return true }
                return false
            }
        }

        func paused() async -> Bool {
            await eventually {
                await model.refresh()
                return model.state == .paused(.cameraRemoved)
            }
        }

        /// The job's camera link: a download in flight, then the cable pulled.
        func pullTheCable() async -> Bool {
            guard await eventually({ await link.bytesStarted == 1 }) else { return false }
            await link.remove()
            return await paused()
        }

        /// A camera in the other mode, under another key.
        func attach(_ other: FakeLink, key: CameraKey) {
            finder.others = [AttachedCamera(descriptor: other.descriptor, key: key, link: other)]
        }

        /// Tells the model a camera was connected, and waits for its content probe to end.
        func connected() async {
            await model.cameraConnected()
            await model.contentProbeFinished()
        }
    }

    /// A job from the MSC camera (key `usb-msc-name:`, from its descriptor), or with `inMTP` from the MTP camera (key
    /// `usb-device:job`), whose downloads hang until it is removed.
    func rig(listHangs: Bool = false, inMTP: Bool = false) async -> Rig {
        let link = inMTP ? FakeLink(items: card, mode: .usb(.mtp), id: "fake-camera", name: "ILCE-7CM2")
            : FakeLink(items: card)
        await link.set(writesListedSize: true)
        await link.set(bytesHangs: true)
        if listHangs { await link.set(listHangs: true) }
        let catalogue = InMemoryCatalogue()
        let engine = ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging(), clock: FrozenClock())
        let destinations = FakeDestinations()
        let finder = FakeFinder()
        let log = RecordingLog()
        let model = ImportModel(engine: engine, settings: InMemoryDestinationSettingStore(DestinationSetting(preferred: .photos)),
                                photos: FakePhotosAccess(), destinations: destinations, log: log)
        model.cameraFinder = finder
        let key = inMTP ? CameraKey(rawValue: "usb-device:job") : CameraKeys.key(for: link.descriptor, material: nil)
        let camera = ImportCamera(descriptor: link.descriptor, key: key)
        return Rig(model: model, engine: engine, catalogue: catalogue, destinations: destinations, finder: finder,
                   link: link, camera: camera, log: log)
    }

    func mtpLink(_ items: [CameraItem], id: String = "mtp") async -> FakeLink {
        let link = FakeLink(items: items, mode: .usb(.mtp), id: id, name: "ILCE-7CM2")
        await link.set(writesListedSize: true)
        return link
    }

    @Test func aJobPausedInOneModeCarriesOnInTheOtherWhenTheCardHoldsEveryFileLeft() async throws {
        let r = await rig()
        #expect(await r.model.importItems(card, from: r.camera, link: r.link) == .started(3))
        #expect(await r.pullTheCable())
        let otherCard = inTheOtherMode(card)
        let mtp = await mtpLink(otherCard)
        r.attach(mtp, key: otherKey)
        await r.connected()
        #expect(await r.finished())
        #expect(r.model.state == .finished(.completed))
        #expect(r.model.countsLine == "3 files imported.")
        // The same-key lookup ran first.
        #expect(r.finder.asked.first == r.camera.key)
        // The new handles were fetched, each once.
        #expect(Set(await mtp.fetched) == Set(otherCard.map(\.id)))
        #expect(await mtp.fetched.count == 3)
        #expect(await r.link.fetched.isEmpty)
        // One row per file, under the job's own key and the first listing's folder: the identity was kept.
        let rows = await r.catalogue.allRecords
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.state == .imported && $0.identity.camera == r.camera.key })
        #expect(rows.allSatisfy { $0.identity.folder == "DCIM/100MSDCF" })
        // No new destinations (the album and Staging folder are the job's), and one job record.
        #expect(r.destinations.cameras.count == 1)
        #expect(await r.catalogue.jobs(camera: r.camera.key).count == 1)
        #expect(await r.catalogue.jobs(camera: otherKey).isEmpty)
        // The other camera's link was let go once the job ended.
        #expect(await eventually { await mtp.closed })
    }

    @Test func theContinuationIsLoggedWithCountsAndTagsOnly() async {
        let r = await rig()
        _ = await r.model.importItems(card, from: r.camera, link: r.link)
        #expect(await r.pullTheCable())
        r.attach(await mtpLink(inTheOtherMode(card)), key: otherKey)
        await r.connected()
        #expect(await r.finished())
        let lines = r.log.lines.filter { $0.contains("file(s) left of key") }
        #expect(lines.count == 1)
        let line = lines.first ?? ""
        #expect(line.contains("holds 3 of 3 file(s) left") && line.hasSuffix("; continuing there"))
        #expect(!line.contains("usb-device:other") && !line.contains(r.camera.key.rawValue))
        #expect(!line.contains("ILCE-7CM2") && !line.contains("Untitled"))
    }

    @Test func aDifferentCardInTheOtherModeLeavesTheJobWaitingAndIsNotListedAgainUntilItGoes() async {
        let r = await rig()
        _ = await r.model.importItems(card, from: r.camera, link: r.link)
        #expect(await r.pullTheCable())
        let other = await mtpLink([item("DSC00007.JPG", folder: "", at: 70, size: 7_000, id: "o7"),
                                   item("DSC00008.JPG", folder: "", at: 80, size: 8_000, id: "o8"),
                                   item("DSC00009.JPG", folder: "", at: 90, size: 9_000, id: "o9")])
        r.attach(other, key: otherKey)
        await r.connected()
        #expect(r.model.state == .paused(.cameraRemoved))
        #expect(r.model.isWaitingForCamera)
        #expect(await other.fetched.isEmpty)
        // The probe let go of its only lease.
        #expect(await eventually { await other.closed })
        #expect(await other.listCount == 1)
        // Asked again (the app coming back, another camera appearing): the refused card isn't listed again...
        await r.connected()
        await r.connected()
        #expect(await other.listCount == 1)
        // ... until that camera has gone and come back (a replug, or another card).
        r.model.cameraDisappeared(other.descriptor.id)
        await r.connected()
        #expect(await other.listCount == 2)
        #expect(r.model.state == .paused(.cameraRemoved))
        // The job's own camera coming back still carries it on.
        let back = FakeLink(items: card, id: "fake-camera-2")
        await back.set(writesListedSize: true)
        r.finder.links[r.camera.key] = back
        await r.connected()
        #expect(await r.finished())
        #expect(r.model.state == .finished(.completed))
        #expect(await back.fetched.count == 3)
        #expect(await other.fetched.isEmpty)
    }

    @Test func aCardHoldingOnlySomeOfTheFilesLeftLeavesTheJobWaiting() async {
        let r = await rig()
        _ = await r.model.importItems(card, from: r.camera, link: r.link)
        #expect(await r.pullTheCable())
        let other = await mtpLink(inTheOtherMode(Array(card.prefix(2))))
        r.attach(other, key: otherKey)
        await r.connected()
        #expect(r.model.state == .paused(.cameraRemoved))
        #expect(await other.fetched.isEmpty)
        #expect(r.log.lines.contains { $0.contains("holds 2 of 3 file(s) left") && $0.hasSuffix("; not continuing") })
        await r.model.cancel()
    }

    @Test func aSwappedCardUnderTheSameMSCKeyLeavesTheJobWaiting() async {
        let r = await rig()
        _ = await r.model.importItems(card, from: r.camera, link: r.link)
        #expect(await r.pullTheCable())
        let before = r.model.countsLine
        // Another "Untitled" card (or another body in MSC): the same name-hash key, none of the job's files.
        let swapped = FakeLink(items: [item("DSC00007.JPG", at: 70, size: 7_000, id: "s7"),
                                       item("DSC00008.JPG", at: 80, size: 8_000, id: "s8")], id: "fake-camera-2")
        await swapped.set(writesListedSize: true)
        r.finder.links[r.camera.key] = swapped
        await r.connected()
        #expect(r.model.state == .paused(.cameraRemoved))
        #expect(await swapped.fetched.isEmpty)
        #expect(r.model.progress.filesSkipped == 0)
        #expect(r.model.countsLine == before)
        #expect(await eventually { await swapped.closed })
        await r.model.cancel()
    }

    @Test func itsOwnCardUnderTheSameMSCKeyWithAPhotoDeletedStillCarriesOn() async {
        let r = await rig()
        _ = await r.model.importItems(card, from: r.camera, link: r.link)
        #expect(await r.pullTheCable())
        let back = FakeLink(items: Array(card.prefix(2)), id: "fake-camera-2")
        await back.set(writesListedSize: true)
        r.finder.links[r.camera.key] = back
        await r.connected()
        #expect(await r.finished())
        #expect(await back.fetched.count == 2)
        #expect(r.model.progress.filesSkipped == 1)   // no longer on the card, as before
    }

    @Test func aPickFromTheCameraTheJobContinuedOnJoinsIt() async {
        let r = await rig()
        _ = await r.model.importItems(card, from: r.camera, link: r.link)
        #expect(await r.pullTheCable())
        let fourth = item("DSC00003.JPG", folder: "", at: 30, size: 5_000, id: "mtp-4")
        let mtp = await mtpLink(inTheOtherMode(card) + [fourth])
        await mtp.set(bytesHangs: true)
        r.attach(mtp, key: otherKey)
        await r.connected()
        #expect(await eventually {
            await r.model.refresh()
            return r.model.state == .running
        })
        let atMTP = ImportCamera(descriptor: mtp.descriptor, key: otherKey)
        #expect(await r.model.importItems([fourth], from: atMTP, link: mtp) == .appended(1))
        let third = FakeLink(items: [fourth], mode: .usb(.mtp), id: "third", name: "ILCE-7M4")
        let atThird = ImportCamera(descriptor: third.descriptor, key: CameraKey(rawValue: "usb-device:third"))
        #expect(await r.model.importItems([fourth], from: atThird, link: third) == .busyWithAnotherCamera)
        await r.model.cancel()
    }

    @Test func aContentProbeNeverHoldsUpCameraConnected() async {
        let r = await rig()
        _ = await r.model.importItems(card, from: r.camera, link: r.link)
        #expect(await r.pullTheCable())
        let mtp = await mtpLink(inTheOtherMode(card))
        await mtp.set(listHangs: true)   // ImageCaptureCore's catalogue, a minute or two in MTP
        r.attach(mtp, key: otherKey)
        await r.model.cameraConnected()   // returns while the listing hangs
        #expect(await eventually { await mtp.listCount == 1 })
        #expect(r.model.state == .paused(.cameraRemoved))
        await r.model.cameraConnected()   // nor does a second call wait for it
        await mtp.set(listHangs: false)
        await r.model.contentProbeFinished()
        #expect(await r.finished())
        #expect(await mtp.fetched.count == 3)
    }

    @Test func theJobsOwnCameraComingBackDuringAProbeStillContinuesIt() async {
        // An MTP job (its key names the device): its own camera is found by key at once, with no listing.
        let r = await rig(inMTP: true)
        _ = await r.model.importItems(card, from: r.camera, link: r.link)
        #expect(await r.pullTheCable())
        let msc = FakeLink(items: inTheOtherMode(card), id: "msc")
        await msc.set(writesListedSize: true)
        await msc.set(listHangs: true)
        r.attach(msc, key: CameraKeys.key(for: msc.descriptor, material: nil))
        await r.model.cameraConnected()
        #expect(await eventually { await msc.listCount == 1 })
        // The job's own camera is back while the other card is still being read.
        let back = FakeLink(items: card, mode: .usb(.mtp), id: "fake-camera-2", name: "ILCE-7CM2")
        await back.set(writesListedSize: true)
        r.finder.links[r.camera.key] = back
        await r.model.cameraConnected()
        #expect(await r.finished())
        #expect(r.model.state == .finished(.completed))
        #expect(await back.fetched.count == 3)
        // The probe, once its listing ends, finds the job carried on and lets the other camera go untouched.
        await msc.set(listHangs: false)
        await r.model.contentProbeFinished()
        #expect(await msc.fetched.isEmpty)
        #expect(await eventually { await msc.closed })
    }

    @Test func aCallDuringAProbeIsAnsweredWhenItEnds() async {
        // An MSC job: its own key is a name hash, so its own camera's card is checked by content too, after the probe
        // under way.
        let r = await rig()
        _ = await r.model.importItems(card, from: r.camera, link: r.link)
        #expect(await r.pullTheCable())
        let other = await mtpLink([item("DSC00007.JPG", folder: "", at: 70, size: 7_000, id: "o7")])
        await other.set(listHangs: true)
        r.attach(other, key: otherKey)
        await r.model.cameraConnected()
        #expect(await eventually { await other.listCount == 1 })
        let back = FakeLink(items: card, id: "fake-camera-2")
        await back.set(writesListedSize: true)
        r.finder.links[r.camera.key] = back
        await r.model.cameraConnected()   // answered once the probe under way has ended
        await other.set(listHangs: false)
        await r.model.contentProbeFinished()
        #expect(await r.finished())
        #expect(await back.fetched.count == 3)
        #expect(await other.fetched.isEmpty)
    }

    @Test func aJobPausedBeforeItsFirstListingWaitsForItsOwnCamera() async {
        let r = await rig(listHangs: true)
        #expect(await r.model.importItems(card, from: r.camera, link: r.link) == .started(3))
        #expect(await eventually { await r.link.listCount == 1 })
        await r.link.remove()
        #expect(await r.paused())
        let other = await mtpLink(inTheOtherMode(card))
        r.attach(other, key: otherKey)
        await r.connected()
        // No file left is known before the first listing, so no card is opened to look for them.
        #expect(r.model.state == .paused(.cameraRemoved))
        #expect(await other.listCount == 0)
        #expect(await !other.isOpen)
        await r.model.cancel()
    }

    @Test func neverOverWiFiNorWhileNothingIsPaused() async {
        let r = await rig()
        let mtp = await mtpLink(inTheOtherMode(card))
        r.attach(mtp, key: otherKey)
        // Nothing is paused: nothing is asked.
        await r.connected()
        #expect(r.finder.othersAsked == 0)
        // A Wi-Fi job paused by a removal waits for its own key: no other camera is asked for.
        let wifi = FakeLink(items: card, mode: .wifi(.cameraNetwork), id: "wifi", name: "ILCE-7CM2")
        await wifi.set(writesListedSize: true)
        await wifi.set(bytesHangs: true)
        let atWiFi = ImportCamera(descriptor: wifi.descriptor, key: CameraKey(rawValue: "wifi-serial:x"))
        _ = await r.model.importItems(card, from: atWiFi, link: wifi)
        #expect(await eventually { await wifi.bytesStarted == 1 })
        await wifi.remove()
        #expect(await r.paused())
        await r.connected()
        #expect(r.finder.othersAsked == 0)
        #expect(await mtp.listCount == 0)
        await r.model.cancel()
    }
}
