import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Testing
@testable import AppUI

/// The card the simulator serves in these suites, with stand-in bytes (`ScriptedCard.content(of:in:)`, not
/// decodable images) at sizes small enough to copy in milliseconds:
///
/// - 1 Nov: a RAW+JPEG pair (DSC00001) and a lone RAW (DSC00002), 2 s later.
/// - 2 Nov: a lone JPG (DSC00003), a video clip (C0001.MP4) and a HIF (DSC00005).
/// - A RAW with no capture date (DSC00004).
///
/// `folder` puts every file in that folder instead, as a link that reports another one would: "" for MTP when
/// ImageCaptureCore gives no parent folder (as on the bench, 1 Nov).
func standInCard(folder: String? = nil) -> ScriptedCard {
    func object(_ handle: UInt32, _ name: String, _ date: String, _ format: PTPObjectFormat, _ size: UInt64,
                folder defaultFolder: String = "DCIM/100MSDCF") -> ScriptedCard.Object {
        ScriptedCard.Object(handle: PTPObjectHandle(rawValue: handle), folder: folder ?? defaultFolder,
                            filename: name, size: size, captureDateRaw: date, format: format)
    }
    return ScriptedCard(objects: [
        object(1, "DSC00001.ARW", "20261101T090000", .sonyARW, 40_000),
        object(2, "DSC00001.JPG", "20261101T090000", .exifJPEG, 20_000),
        object(3, "DSC00002.ARW", "20261101T090002", .sonyARW, 41_000),
        object(4, "DSC00003.JPG", "20261102T100000", .exifJPEG, 22_000),
        object(5, "C0001.MP4", "20261102T100005", .mp4, 300_000, folder: "PRIVATE/M4ROOT/CLIP"),
        object(6, "DSC00004.ARW", "", .sonyARW, 39_000),
        object(7, "DSC00005.HIF", "20261102T100010", .sonyHEIF, 12_000),
    ])
}

/// The stills of `standInCard()` that can be imported: everything but the clip and the undated RAW.
let importableStills: Set<String> = ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.ARW", "DSC00003.JPG", "DSC00005.HIF"]

/// Discovery over one simulated camera: whatever link the bench last plugged in.
actor SimulatedDiscovery: CameraDiscovery {
    nonisolated let discoveries: AsyncStream<USBDiscoveryEvent>
    private let sink: AsyncStream<USBDiscoveryEvent>.Continuation
    private var link: SimulatedCameraLink

    init(link: SimulatedCameraLink) {
        self.link = link
        (discoveries, sink) = AsyncStream.makeStream()
    }

    func plug(_ link: SimulatedCameraLink) { self.link = link }
    func send(_ event: USBDiscoveryEvent) { sink.yield(event) }

    func start() throws(CameraLinkFailure) {}
    /// The plugged-in link, or `disconnected` once it has been removed and until the next `plug(_:)`, as
    /// `USBCameraBrowser.link(for:)` throws for a camera that isn't attached.
    func cameraLink(for id: CameraDescriptor.ID) async throws(CameraLinkFailure) -> any CameraLink {
        if await link.isRemoved { throw CameraLinkFailure(.disconnected, detail: "the camera has gone") }
        return link
    }
}

/// Photos as a recording fake (Photos isn't reachable on Linux or in a package test), and the real Files folder
/// (`FilesFolderDestination`) in the bench's temporary Documents folder.
final class SimulatorDestinations: ImportDestinationMaking, @unchecked Sendable {
    let documents: URL
    let photos = RecordingDestination(kind: .photos)

    init(documents: URL) { self.documents = documents }

    func destinations(for camera: ImportCamera, startedAt: Date) -> ImportDestinations {
        let files = FilesFolderDestination(documentsDirectory: documents, cameraName: camera.name)
        return ImportDestinations(photos: photos, filesFolder: files, filesFolderName: files.folderName)
    }
}

/// `FakeMaker` per file: a RAW named in `undecodable` falls back to its embedded preview, as `CoreImageJPEGMaker`
/// does when iOS can't decode it. Records each input it was given, with its bytes.
final class StandInJPEGMaker: JPEGMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var undecodable: Set<String> = []
    private var inputs: [(name: String, conversion: JPEGConversion, bytes: Data)] = []

    func makeUndecodable(_ name: String) { lock.withLock { _ = undecodable.insert(name) } }
    var made: [(name: String, conversion: JPEGConversion, bytes: Data)] { lock.withLock { inputs } }

    func makeJPEG(from input: URL, conversion: JPEGConversion, to output: URL) async throws(JPEGMakingFailure)
        -> JPEGMakingReport {
        let name = input.lastPathComponent
        let bytes = (try? Data(contentsOf: input)) ?? Data()
        let fallback = lock.withLock {
            inputs.append((name, conversion, bytes))
            return undecodable.contains(name)
        }
        return try await FakeMaker(fallback: fallback).makeJPEG(from: input, conversion: conversion, to: output)
    }

    func pixelSize(ofImageAt url: URL) -> PixelSize? { FakeMaker().pixelSize(ofImageAt: url) }
}

struct TimedOut: Error, CustomStringConvertible {
    var what: String
    var description: String { "timed out waiting for \(what)" }
}

/// The app's real models, wired by `AppModel` as the app wires them, over the simulated camera: the real
/// `ImportEngine` on the continuous clock, `InMemoryCatalogue`, the real Files folder in a temporary Documents
/// folder, and fakes only for discovery, Photos access, the Photos destination, the JPEG maker and the clipboard.
@MainActor
final class SimulatorBench {
    let root: URL
    let documents: URL
    let catalogue = InMemoryCatalogue()
    let engine: ImportEngine
    let settingsStore: InMemoryDestinationSettingStore
    let photos: FakePhotosAccess
    let destinations: SimulatorDestinations
    let discovery: SimulatedDiscovery
    let maker = StandInJPEGMaker()
    let clipboard = FakeClipboard()
    let scratch: JPEGScratch
    let log = RecordingLog()
    let app: AppModel
    /// What an MTP link gives as its key material (the device's UUID string on the bench), as the app's keying reads
    /// it; nil keys every camera from its descriptor (`CameraKeys.fromDescriptor`).
    let keyMaterial: String?
    /// The camera as it is plugged in now (`replug()` and `plug(_:)` swap it).
    private(set) var link: SimulatedCameraLink
    private var runs: [Task<Void, Never>] = []

    var camera: CameraDescriptor { link.descriptor }
    /// The key the app gives the camera plugged in now.
    var key: CameraKey { CameraKeys.key(for: camera, material: Self.material(keyMaterial, for: camera)) }
    var importer: ImportModel { app.importer }

    /// A bench with the camera connected and discovery started, as after launch.
    ///
    /// - Parameters:
    ///   - link: The camera plugged in first; an MTP link over `card` by default.
    ///   - keyMaterial: Keys cameras as the app does (`LiveRoot`): an MTP link by this material, any other mode by
    ///     its mode and name. Nil keys every camera by its descriptor.
    static func make(card: ScriptedCard = standInCard(), link: SimulatedCameraLink? = nil,
                     setting: DestinationKind = .filesFolder, photos: FakePhotosAccess = FakePhotosAccess(),
                     keyMaterial: String? = nil) async throws -> SimulatorBench {
        let bench = SimulatorBench(link: link ?? SimulatedCameraLink(card: card, chunkSize: 4096), setting: setting,
                                   photos: photos, keyMaterial: keyMaterial)
        await bench.app.scenePhaseChanged(.active)
        await bench.discovery.send(.appeared(bench.camera))
        try await bench.until("the camera to be listed") { bench.app.cameras.cameras == [bench.camera] }
        return bench
    }

    /// The material the app's keying would read from a link to `camera`: only an MTP link has any, as
    /// `USBCameraKeyMaterial.material(mode:deviceUUID:)` says.
    nonisolated static func material(_ material: String?, for camera: CameraDescriptor) -> String? {
        camera.mode == .usb(.mtp) ? material : nil
    }

    private init(link: SimulatedCameraLink, setting: DestinationKind, photos: FakePhotosAccess,
                 keyMaterial: String?) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUITests-sim-\(UUID().uuidString)", isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        scratch = JPEGScratch(root: root.appendingPathComponent(JPEGScratch.folderName, isDirectory: true))
        engine = ImportEngine(catalogue: catalogue,
                              stagingDirectory: root.appendingPathComponent("staging", isDirectory: true))
        settingsStore = InMemoryDestinationSettingStore(DestinationSetting(preferred: setting))
        self.photos = photos
        destinations = SimulatorDestinations(documents: documents)
        self.link = link
        self.keyMaterial = keyMaterial
        discovery = SimulatedDiscovery(link: link)
        // The app's keying itself (`CameraKeys.keying(material:)`), over the material a link to this camera gives.
        let keying: CameraKeying = if let keyMaterial {
            CameraKeys.keying(material: { link in SimulatorBench.material(keyMaterial, for: link.descriptor) })
        } else {
            CameraKeys.fromDescriptor
        }
        app = AppModel(discovery: discovery,
                       services: BrowseServices(maker: maker, clipboard: clipboard, scratch: scratch, log: log),
                       catalogue: catalogue, engine: engine, settingsStore: settingsStore, photos: photos,
                       destinations: destinations, cameraKey: keying)
    }

    /// Opens Browse on the camera, as navigating to it does: the screen's task runs the model until `stopBrowsing()`.
    func browse() -> BrowseModel {
        let model = app.browseModel(for: camera)
        runs.append(Task { await model.run() })
        return model
    }

    /// Leaves every Browse screen opened.
    func stopBrowsing() async {
        for run in runs { run.cancel() }
        for run in runs { await run.value }
        runs = []
    }

    /// The camera plugged in again: a new link over the card as it is now (new item IDs), or over `card` (the same
    /// camera listing its files differently, say in another folder), which discovery hands out from now on. Says
    /// nothing to the app; send `.appeared` for that.
    @discardableResult
    func replug(listing card: ScriptedCard? = nil) async -> SimulatedCameraLink {
        let again: SimulatedCameraLink
        if let card {
            again = SimulatedCameraLink(card: card, mode: camera.mode, name: camera.name,
                                        descriptorID: camera.id.rawValue, timeZone: link.timeZone,
                                        generation: link.generation + 1, chunkSize: link.chunkSize)
        } else {
            again = await link.replugged()
        }
        await discovery.plug(again)
        link = again
        return again
    }

    /// Another camera plugged in instead (the same body in another USB mode, say): discovery reports the old one gone
    /// and this one appeared, and hands out `newLink` from now on. Leave Browse first.
    func plug(_ newLink: SimulatedCameraLink) async throws {
        let old = camera
        await link.remove()
        await discovery.send(.disappeared(old.id))
        await discovery.plug(newLink)
        link = newLink
        await discovery.send(.appeared(newLink.descriptor))
        try await until("the new camera to be listed") { app.cameras.cameras == [newLink.descriptor] }
    }

    /// Cancels any job, leaves Browse and removes the temporary folders.
    func finish() async {
        await importer.cancel()
        await stopBrowsing()
        try? FileManager.default.removeItem(at: root)
    }

    /// Polls `condition` every 10 ms until it holds, for up to 5 minutes (generous: the iOS Simulator on a loaded CI
    /// runner takes tens of seconds over steps that take milliseconds on Linux); throws if it never does, so a test
    /// stops at the first missed step.
    func until(_ what: String, within limit: Duration = .seconds(300),
               sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if await condition() { return }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
        throw TimedOut(what: what)
    }

    /// Waits for the import's job to be in `state`, reading the engine as the screen does.
    func untilImport(_ state: ImportJobState, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until("the import to be \(state)", sourceLocation: sourceLocation) {
            await importer.refresh()
            return importer.state == state
        }
    }

    /// Waits for the engine's job to be in `state`, reading the engine alone: nothing here calls into `ImportModel`,
    /// so the import model learns of the job only through its own trigger (the engine's progress), as in the app.
    func untilEngine(_ state: ImportJobState, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until("the engine's job to be \(state)", sourceLocation: sourceLocation) {
            await engine.currentProgress.state == state
        }
    }

    // MARK: - Reading the results

    /// The camera's folder in Files.
    var filesFolder: URL { documents.appendingPathComponent(FilesFolderNaming.folderName(forCamera: camera.name)) }

    /// The files in the camera's Files folder, by name.
    func importedFiles() -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: filesFolder.path)) ?? []
        var out: [String: Data] = [:]
        for name in names { out[name] = try? Data(contentsOf: filesFolder.appendingPathComponent(name)) }
        return out
    }

    /// The scripted bytes of a file on the card.
    func content(of name: String) async -> Data? {
        guard let object = await link.card.objects.first(where: { $0.filename == name }) else { return nil }
        return ScriptedCard.content(of: object.handle, in: 0 ..< object.size)
    }

    /// Checks that the camera's Files folder holds exactly `names`, each with its scripted bytes.
    func expectInFiles(_ names: Set<String>, sourceLocation: SourceLocation = #_sourceLocation) async {
        let files = importedFiles()
        #expect(Set(files.keys) == names, sourceLocation: sourceLocation)
        for name in names {
            let expected = await content(of: name)
            #expect(files[name] != nil && files[name] == expected, "\(name)'s bytes", sourceLocation: sourceLocation)
        }
    }

    /// The catalogue's state for a listed file, by the engine's identity.
    func state(of item: CameraItem) async -> ObjectState? {
        guard let identity = item.identity(camera: key, timeZone: .current) else { return nil }
        return await catalogue.states(of: [identity])[identity]
    }
}

extension BrowseModel {
    /// Every file shown, in the grid's order.
    var shown: [CameraItem] { sections.flatMap(\.items) }

    /// The file shown with this name.
    func shown(_ name: String) -> CameraItem? { shown.first { $0.name == name } }
}
