import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

/// D11 (Shamil, 12 Nov): one name per body. A camera's album, Staging folder, Cameras row and History name are the
/// model it reports in MTP and over Wi-Fi, and in MSC the one named body's the catalogue knows.
@MainActor
@Suite("One name per body (D11)")
struct OneNamePerBodyTests {
    let msc = CameraDescriptor(id: .init(rawValue: "msc"), name: "Untitled", mode: .usb(.massStorage))
    let mtp = CameraDescriptor(id: .init(rawValue: "mtp"), name: "ILCE-7CM2", mode: .usb(.mtp))
    let wifi = CameraDescriptor(id: .init(rawValue: "wifi"), name: "Camera", mode: .wifi(.cameraNetwork))
    let mscKey = CameraKey(rawValue: "usb-msc-name:volume")
    let mtpKey = CameraKey(rawValue: "usb-device:body-1")
    let wifiKey = CameraKey(rawValue: "wifi-serial:body-1")

    // MARK: The rule

    @Test func theOneBodyIsCountedByNameAmongBodyKeysOnly() {
        let mtpRow = CameraRecord(key: mtpKey, friendlyName: "ILCE-7CM2")
        let wifiRow = CameraRecord(key: wifiKey, model: "ILCE-7CM2", preferredCarrier: .wifi)
        #expect(CameraNaming.onlyBodyName(among: [mtpRow, wifiRow]) == "ILCE-7CM2")
        // A name-hash key's row (MSC's, which this rule names) never counts as a body.
        let mscRow = CameraRecord(key: mscKey, friendlyName: "Something Else")
        #expect(CameraNaming.onlyBodyName(among: [mtpRow, wifiRow, mscRow]) == "ILCE-7CM2")
        // Unnamed rows and volume names don't count either.
        let unnamed = CameraRecord(key: CameraKey(rawValue: "usb-device:body-2"))
        let untitled = CameraRecord(key: CameraKey(rawValue: "usb-device:body-3"), friendlyName: "Untitled")
        #expect(CameraNaming.onlyBodyName(among: [wifiRow, unnamed, untitled]) == "ILCE-7CM2")
        // A second named body: none.
        let other = CameraRecord(key: CameraKey(rawValue: "wifi-serial:body-2"), model: "ILCE-7M4")
        #expect(CameraNaming.onlyBodyName(among: [mtpRow, wifiRow, other]) == nil)
        #expect(CameraNaming.onlyBodyName(among: []) == nil)
        #expect(CameraNaming.onlyBodyName(among: [unnamed]) == nil)
    }

    @Test func mscTakesTheOneBodysNameElseCamera() {
        let one = [CameraRecord(key: wifiKey, model: "ILCE-7CM2")]
        #expect(CameraNaming.name(for: msc, key: mscKey, records: one) == "ILCE-7CM2")
        let two = one + [CameraRecord(key: mtpKey, friendlyName: "ILCE-7M4")]
        #expect(CameraNaming.name(for: msc, key: mscKey, records: two) == "Camera")
        #expect(CameraNaming.name(for: msc, key: mscKey, records: []) == "Camera")
        #expect(CameraNaming.displayName(for: msc, onlyBodyName: "ILCE-7CM2") == "ILCE-7CM2")
        #expect(CameraNaming.displayName(for: msc, onlyBodyName: nil) == "Camera")
    }

    @Test func mtpAndWiFiAreNamedByTheModelTheyReport() {
        let rows = [CameraRecord(key: wifiKey, model: "ILCE-7CM2", preferredCarrier: .wifi),
                    CameraRecord(key: CameraKey(rawValue: "wifi-serial:body-2"), model: "ILCE-7M4")]
        #expect(CameraNaming.name(for: mtp, key: mtpKey, records: rows) == "ILCE-7CM2")
        // A Wi-Fi descriptor listed before the camera's first connection still says "Camera": its row has the model.
        #expect(CameraNaming.name(for: wifi, key: wifiKey, records: rows) == "ILCE-7CM2")
        #expect(CameraNaming.name(for: wifi, key: wifiKey, records: []) == "Camera")
        // In MTP and over Wi-Fi the camera's own name, never another body's.
        #expect(CameraNaming.displayName(for: mtp, onlyBodyName: "ILCE-7M4") == "ILCE-7CM2")
    }

    @Test func theNameIsWrittenToTheRowOnlyWhenItReadsOtherwise() async throws {
        let catalogue = InMemoryCatalogue(cameras: [CameraRecord(key: wifiKey, model: "ILCE-7CM2", preferredCarrier: .wifi)])
        #expect(await CameraNaming.learn("ILCE-7CM2", for: mscKey, in: catalogue))
        #expect(await catalogue.camera(mscKey)?.friendlyName == "ILCE-7CM2")
        #expect(HistoryWording.cameraName(await catalogue.camera(mscKey)) == "ILCE-7CM2")
        #expect(await !CameraNaming.learn("ILCE-7CM2", for: mscKey, in: catalogue))   // already reads so
        // Back to "Camera" (a second body came along): the friendly name is cleared.
        #expect(await CameraNaming.learn("Camera", for: mscKey, in: catalogue))
        #expect(await catalogue.camera(mscKey)?.friendlyName == "")
        // A Wi-Fi row named by its model isn't written; nor is a Wi-Fi name-hash key, nor without a catalogue.
        #expect(await !CameraNaming.learn("ILCE-7CM2", for: wifiKey, in: catalogue))
        #expect(await catalogue.camera(wifiKey)?.friendlyName == "")
        #expect(await !CameraNaming.learn("ILCE-7CM2", for: CameraKey(rawValue: "wifi-name:x"), in: catalogue))
        #expect(await !CameraNaming.learn("ILCE-7CM2", for: mscKey, in: nil))
        // The Camera row's other fields are left alone.
        #expect(await catalogue.camera(wifiKey)?.preferredCarrier == .wifi)
    }

    // MARK: The import

    @MainActor
    struct Rig {
        let model: ImportModel
        let catalogue: InMemoryCatalogue
        let destinations: FakeDestinations
    }

    func rig(_ catalogue: InMemoryCatalogue) -> Rig {
        let destinations = FakeDestinations()
        let engine = ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging())
        let model = ImportModel(engine: engine, settings: InMemoryDestinationSettingStore(),
                                photos: FakePhotosAccess(), destinations: destinations, catalogue: catalogue)
        return Rig(model: model, catalogue: catalogue, destinations: destinations)
    }

    func finish(_ model: ImportModel) async -> Bool {
        await eventually {
            await model.refresh()
            if case .finished = model.state { return true }
            return false
        }
    }

    @Test func aOneBodyOwnerGetsOneNameAcrossMTPAndMSC() async throws {
        let r = rig(InMemoryCatalogue())
        // An MTP import names the body: its row says so.
        let mtpLink = FakeLink(items: [item("DSC00001.JPG", folder: "", at: 10)], mode: .usb(.mtp), id: "mtp",
                               name: "ILCE-7CM2")
        await mtpLink.set(writesListedSize: true)
        let atMTP = ImportCamera(descriptor: mtpLink.descriptor, key: mtpKey)
        #expect(await r.model.importItems(await mtpLink.items, from: atMTP, link: mtpLink) == .started(1))
        #expect(await finish(r.model))
        #expect(r.destinations.cameras.last?.name == "ILCE-7CM2")
        #expect(await r.catalogue.camera(mtpKey)?.friendlyName == "ILCE-7CM2")
        r.model.dismiss()

        // Then an MSC import: the same album and Staging folder, and its own row reads the same name for History.
        let mscLink = FakeLink(items: [item("DSC00002.JPG", at: 20)], id: "msc")
        await mscLink.set(writesListedSize: true)
        let atMSC = ImportCamera(descriptor: mscLink.descriptor, key: mscKey)
        #expect(atMSC.name == "Camera")   // discovery's name
        #expect(await r.model.importItems(await mscLink.items, from: atMSC, link: mscLink) == .started(1))
        #expect(await finish(r.model))
        #expect(r.destinations.cameras.last?.name == "ILCE-7CM2")
        #expect(r.model.stagingFolderName == FilesFolderNaming.folderName(forCamera: "ILCE-7CM2"))
        #expect(r.model.camera?.name == "ILCE-7CM2")
        #expect(HistoryWording.cameraName(await r.catalogue.camera(mscKey)) == "ILCE-7CM2")
    }

    @Test func withTwoNamedBodiesAnMSCImportStaysCamera() async throws {
        let catalogue = InMemoryCatalogue(cameras: [
            CameraRecord(key: wifiKey, model: "ILCE-7CM2", preferredCarrier: .wifi),
            CameraRecord(key: CameraKey(rawValue: "wifi-serial:body-2"), model: "ILCE-7M4", preferredCarrier: .wifi),
            // Named when only one body was known.
            CameraRecord(key: mscKey, friendlyName: "ILCE-7CM2"),
        ])
        let r = rig(catalogue)
        let link = FakeLink(items: [item("DSC00002.JPG", at: 20)], id: "msc")
        await link.set(writesListedSize: true)
        let camera = ImportCamera(descriptor: link.descriptor, key: mscKey)
        #expect(await r.model.importItems(await link.items, from: camera, link: link) == .started(1))
        #expect(await finish(r.model))
        #expect(r.destinations.cameras.last?.name == "Camera")
        // The row now reads as the album and folder were named.
        #expect(await catalogue.camera(mscKey)?.friendlyName == "")
    }

    @Test func theAlbumIsKeyedByTheNameTheJobGivesIt() async throws {
        let made = StandardImportDestinations(library: NoLibrary(), albumStore: InMemoryAlbumIdentifierStore(),
                                              documentsDirectory: URL(fileURLWithPath: "/nonexistent/Documents"),
                                              stagingLocator: FakeStagingLocator(.unavailable(.iCloudDriveOff)),
                                              iCloudDriveMover: PlainFileMover())
        let camera = ImportCamera(descriptor: msc, key: mscKey, name: "ILCE-7CM2")
        let destinations = made.destinations(for: camera, startedAt: Date(), staging: await made.locate())
        #expect(destinations.stagingFolderName == "ILCE-7CM2")
        let photos = try #require(destinations.photos as? PhotosLibraryDestination)
        #expect(photos.albumPlan.albums == [.init(key: "camera-name:ILCE-7CM2", title: "ILCE-7CM2",
                                                  legacyKeys: ["camera:" + mscKey.rawValue], legacyKeyPrefix: "camera:")])
    }

    // MARK: The Cameras screen

    @Test func otherUSBCamerasListsAttachedImageTransferCamerasWithAnotherKeyOnly() async {
        let mscLink = FakeLink(items: [], mode: .usb(.massStorage), id: "msc", name: "Untitled")
        let mtpLink = FakeLink(items: [], mode: .usb(.mtp), id: "mtp", name: "ILCE-7CM2")
        let remote = FakeLink(items: [], mode: .usb(.remoteShoot), id: "remote", name: "ILCE-7CM2")
        let wifiLink = FakeLink(items: [], mode: .wifi(.cameraNetwork), id: "wifi", name: "ILCE-7CM2")
        let discovery = MultiCameraDiscovery(links: [mscLink, mtpLink, remote, wifiLink],
                                             knownKeys: [wifiLink.descriptor.id: wifiKey])
        let model = CamerasModel(discovery: discovery, services: services())
        for link in [mscLink, mtpLink, remote, wifiLink] { model.apply(.appeared(link.descriptor)) }
        let mscKey = CameraKeys.key(for: mscLink.descriptor, material: nil)
        let others = await model.otherUSBCameras(than: mscKey)
        #expect(others.map(\.descriptor) == [mtpLink.descriptor])
        #expect(others.first?.key == CameraKeys.key(for: mtpLink.descriptor, material: nil))
        #expect(others.first.map { ObjectIdentifier($0.link) == ObjectIdentifier(mtpLink) } == true)
        let asked = await discovery.linksAsked
        // Never the Wi-Fi camera (a join) nor Remote Shoot (no files); the camera asked about is left out.
        #expect(asked[wifiLink.descriptor.id] == nil)
        #expect(asked[remote.descriptor.id] == nil)
        #expect(await model.otherUSBCameras(than: CameraKeys.key(for: mtpLink.descriptor, material: nil))
            .map(\.descriptor) == [mscLink.descriptor])
    }

    @Test func anMSCRowIsNamedAfterTheOneBody() async {
        let catalogue = InMemoryCatalogue(cameras: [CameraRecord(key: wifiKey, model: "ILCE-7CM2")])
        let discovery = MultiCameraDiscovery(links: [])
        let model = CamerasModel(discovery: discovery, services: services(), catalogue: catalogue)
        #expect(model.displayName(for: msc) == "Camera")
        await model.refreshOnlyBodyName()
        #expect(model.onlyBodyName == "ILCE-7CM2")
        #expect(model.displayName(for: msc) == "ILCE-7CM2")
        #expect(model.displayName(for: mtp) == "ILCE-7CM2")
        #expect(model.browseModel(for: msc).navigationTitle == "ILCE-7CM2")
        await catalogue.upsertCamera(CameraRecord(key: mtpKey, friendlyName: "ILCE-7M4"))
        await model.refreshOnlyBodyName()
        #expect(model.onlyBodyName == nil)
        #expect(model.displayName(for: msc) == "Camera")
    }
}

/// A Photos library that is never reached.
private struct NoLibrary: PhotoLibraryClient {
    func authorisation() async -> PhotosAuthorisation { .authorised }
    func requestReadWriteAuthorisation() async -> PhotosAuthorisation { .authorised }
    func album(withIdentifier identifier: String) async -> AlbumLookup { .missing }
    func createAlbum(titled title: String) async throws(PhotoLibraryFailure) -> String { "album" }
    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) async throws(PhotoLibraryFailure)
        -> String { "asset" }
}

/// The rule for continuing a paused job on another card by content (D11).
@Suite("Continuing across camera keys (D11)")
struct CrossKeyContinuationTests {
    let job = CameraKey(rawValue: "usb-msc-name:volume")
    let zone = TimeZone(identifier: "Europe/London")!
    let card = [item("DSC00001.ARW", at: 10, size: 4_000), item("DSC00001.JPG", at: 10, size: 2_000),
                item("DSC00002.JPG", at: 20, size: 3_000)]

    func left(_ items: [CameraItem]) -> Set<ObjectIdentity.ContentKey> {
        Set(items.compactMap { $0.identity(camera: job, timeZone: zone)?.contentKey })
    }

    /// `items` as another mode lists them: other handles, another folder.
    func elsewhere(_ items: [CameraItem], folder: String = "DCIM/100MTP") -> [CameraItem] {
        items.map { CameraItem(id: .init(rawValue: "other-\($0.id.rawValue)"), folder: folder, name: $0.name,
                               size: $0.size, captureDate: $0.captureDate) }
    }

    @Test func everyFileLeftOnTheCardContinues() {
        let listing = elsewhere(card) + [item("DSC00009.JPG", at: 90)]
        let verdict = CrossKeyContinuation(left: left(card), listing: listing, camera: job, timeZone: zone)
        #expect(verdict.found == 3 && verdict.left == 3)
        #expect(verdict.continues && verdict.holdsAny)
    }

    @Test func aDifferentCardOrBodyDoesNotContinue() {
        let otherSeconds = card.map { item($0.name, at: 500, size: $0.size) }
        let otherSizes = card.map { item($0.name, at: 10, size: $0.size + 1) }
        for listing in [otherSeconds, otherSizes] {
            let verdict = CrossKeyContinuation(left: left(card), listing: listing, camera: job, timeZone: zone)
            #expect(verdict.found == 0 && !verdict.continues && !verdict.holdsAny)
        }
    }

    @Test func aPartialMatchDoesNotContinueAcrossKeysButHoldsAny() {
        let verdict = CrossKeyContinuation(left: left(card), listing: elsewhere(Array(card.prefix(2))), camera: job,
                                           timeZone: zone)
        #expect(verdict.found == 2 && verdict.left == 3)
        #expect(!verdict.continues)
        #expect(verdict.holdsAny)   // enough on the job's own name-hash key
    }

    @Test func nothingLeftNeverContinues() {
        let verdict = CrossKeyContinuation(left: [], listing: card, camera: job, timeZone: zone)
        #expect(!verdict.continues && !verdict.holdsAny)
    }

    @Test func namesMatchIgnoringASCIICase() {
        let lower = card.map { CameraItem(id: .init(rawValue: "l-\($0.id.rawValue)"), folder: "", name: $0.name.lowercased(),
                                          size: $0.size, captureDate: $0.captureDate) }
        let verdict = CrossKeyContinuation(left: left(card), listing: lower, camera: job, timeZone: zone)
        #expect(verdict.continues)
    }

    @Test func filesLeftAreTheQueuedDownloadingAndRetryingFilesOnly() throws {
        let phases: [ImportFileStatus.Phase] = [.queued, .downloading, .waitingToRetry, .committing, .imported(nil),
                                                .staged(nil), .skipped(.notAStill), .failed(.link(.busy)),
                                                .notImported]
        let items = phases.indices.map { item("DSC0\(1000 + $0).JPG", at: TimeInterval($0), size: 1_000) }
        var files = zip(items, phases).map { item, phase in
            ImportFileStatus(id: .file(item.identity(camera: job, timeZone: zone)!), item: item, phase: phase,
                             bytesDone: 0)
        }
        files.append(ImportFileStatus(id: .undated(0), item: item("DSC09999.JPG", at: nil), phase: .queued,
                                      bytesDone: 0))
        #expect(CrossKeyContinuation.filesLeft(in: files) == left(Array(items.prefix(3))))
    }

    @Test func onlyMSCAndMTPNameHashesAreSharedKeys() {
        #expect(CrossKeyContinuation.isSharedKey(CameraKey(rawValue: "usb-msc-name:x")))
        #expect(CrossKeyContinuation.isSharedKey(CameraKey(rawValue: "usb-mtp-name:x")))
        #expect(!CrossKeyContinuation.isSharedKey(CameraKey(rawValue: "usb-device:x")))
        #expect(!CrossKeyContinuation.isSharedKey(CameraKey(rawValue: "wifi-serial:x")))
    }
}
