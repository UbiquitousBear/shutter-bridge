import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import Testing
@testable import AppUI

/// One staged file: its row (state new, with a staged copy at "Staging/<cameraFolder>/<YYYY-MM-DD>/<name>" on this
/// iPhone) and the copy itself, `size` bytes, under `documents`.
private struct StagedFile {
    var record: CatalogueRecord
    var relativePath: String
    var identity: ObjectIdentity { record.identity }
    var key: ObjectIdentity.ContentKey { record.identity.contentKey }
}

private func stage(_ name: String, at date: String, size: Int = 64, camera: String, cameraFolder: String,
                   in documents: URL) -> StagedFile {
    let identity = ObjectIdentity(camera: CameraKey(rawValue: camera), folder: "DCIM/100MSDCF", filename: name,
                                  captureDate: CaptureDate(rawValue: date)!, size: UInt64(size))
    let day = String(date.prefix(4)) + "-" + String(date.dropFirst(4).prefix(2)) + "-"
        + String(date.dropFirst(6).prefix(2))
    let relative = "Staging/\(cameraFolder)/\(day)/\(name)"
    let url = documents.appendingPathComponent(relative)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: size))
    let format: PTPMediaKind = name.hasSuffix(".ARW") ? .raw : .jpeg
    return StagedFile(record: CatalogueRecord(identity: identity, format: format, state: .new,
                                              staged: StagedLocation(root: .onThisIPhone, relativePath: relative)),
                      relativePath: relative)
}

/// A reader that holds every copy until released, so a test can look at a keepers job while it runs.
private final class HoldingReader: StagedFileReading, @unchecked Sendable {
    private let plain = PlainStagedFileReader()
    private let lock = NSLock()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var open = false

    var waiting: Int { lock.withLock { held.count } }

    func presence(of source: URL, expectedSize: UInt64) -> StagedPresence {
        plain.presence(of: source, expectedSize: expectedSize)
    }

    func copy(_ source: URL, expectedSize: UInt64, to destination: URL,
              progress: @escaping @Sendable (UInt64) -> Void) async throws(CameraLinkFailure) {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                if open { return true }
                held.append(c)
                return false
            }
            if go { c.resume() }
        }
        try await plain.copy(source, expectedSize: expectedSize, to: destination, progress: progress)
    }

    func release() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { held = [] }
            return held
        }
        for w in waiters { w.resume() }
    }
}

/// The plain reader, running `before` ahead of each copy, so a test can change something as a given file is read.
private final class HookedReader: StagedFileReading, @unchecked Sendable {
    private let plain = PlainStagedFileReader()
    private let before: @Sendable (URL) async -> Void

    init(before: @escaping @Sendable (URL) async -> Void) { self.before = before }

    func presence(of source: URL, expectedSize: UInt64) -> StagedPresence {
        plain.presence(of: source, expectedSize: expectedSize)
    }

    func copy(_ source: URL, expectedSize: UInt64, to destination: URL,
              progress: @escaping @Sendable (UInt64) -> Void) async throws(CameraLinkFailure) {
        await before(source)
        try await plain.copy(source, expectedSize: expectedSize, to: destination, progress: progress)
    }
}

/// iCloud's file availability as a test scripts it: `evicted` files aren't local until downloaded; each download notes
/// what Photos had been given by then.
private final class EvictedFiles: StagedFileAvailability, @unchecked Sendable {
    private let lock = NSLock()
    private var evicted: Set<String>
    private var downloads: [String] = []
    let beforeDownload: @Sendable () async -> Void

    init(evicted: Set<String>, beforeDownload: @escaping @Sendable () async -> Void) {
        self.evicted = evicted
        self.beforeDownload = beforeDownload
    }

    var downloaded: [String] { lock.withLock { downloads } }

    func isLocal(_ file: CullFile) -> Bool { lock.withLock { !evicted.contains(file.identity.filename) } }

    func download(_ file: CullFile, progress: @Sendable (Double?) -> Void) async throws {
        await beforeDownload()
        lock.withLock {
            downloads.append(file.identity.filename)
            evicted.remove(file.identity.filename)
        }
    }
}

/// The Staging screen's model, the Import screen's model over the real engine, and *Import keepers* over both, with a
/// temporary Documents folder as On My iPhone's staging root and the fakes' Photos.
@MainActor
private final class Rig {
    let documents = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeepersImportTests-\(UUID().uuidString)", isDirectory: true)
    let catalogue: InMemoryCatalogue
    let photos: FakePhotosAccess
    let destinations = FakeDestinations()
    let engine: ImportEngine
    let importer: ImportModel
    let finder = FakeFinder()
    let cull: CullModel<String>
    let keepers: KeepersImport
    let log = RecordingLog()
    let loader = FakeLoader()

    init(_ staged: (URL) -> [StagedFile], extra: [CatalogueRecord] = [],
         photos: FakePhotosAccess = FakePhotosAccess(), files: any StagedFileAvailability = AlwaysLocalFiles(),
         reader: any StagedFileReading = PlainStagedFileReader(), leases: LinkLeases = LinkLeases(),
         engineZone: TimeZone = .autoupdatingCurrent, keepersZone: TimeZone? = nil) {
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        catalogue = InMemoryCatalogue(records: staged(documents).map(\.record) + extra)
        self.photos = photos
        engine = ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging(), timeZone: engineZone)
        importer = ImportModel(engine: engine, settings: InMemoryDestinationSettingStore(), photos: photos,
                               destinations: destinations, leases: leases, log: log)
        importer.cameraFinder = finder
        loader.autoRelease = true
        let locator = FakeStagingLocator(.unavailable(.containerUnavailable))
        cull = CullModel(catalogue: catalogue, onThisIPhone: documents, locator: locator,
                         reader: PlainStagedFileReader(), loader: loader)
        if let keepersZone {
            keepers = KeepersImport(catalogue: catalogue, importer: importer, onThisIPhone: documents,
                                    locator: locator, reader: reader, files: files, plain: PlainStagedFileRemover(),
                                    coordinated: PlainStagedFileRemover(), timeZone: keepersZone, log: log)
        } else {
            keepers = KeepersImport(catalogue: catalogue, importer: importer, onThisIPhone: documents,
                                    locator: locator, reader: reader, files: files, plain: PlainStagedFileRemover(),
                                    coordinated: PlainStagedFileRemover(), log: log)
        }
    }

    func mark(_ decision: MarkRecord.Decision, _ files: StagedFile...) async throws {
        try await catalogue.setMark(decision, for: files.map(\.key))
    }

    func exists(_ file: StagedFile) -> Bool {
        FileManager.default.fileExists(atPath: documents.appendingPathComponent(file.relativePath).path)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: documents.appendingPathComponent(relative).path)
    }

    func row(_ file: StagedFile) async -> CatalogueRecord? { await catalogue.record(for: file.identity) }

    /// Every job's record, once each has an end.
    func finishedJobs(_ count: Int) async -> [JobRecord] {
        var jobs: [JobRecord] = []
        _ = await eventually {
            jobs = await catalogue.jobs(camera: nil)
            return jobs.count == count && jobs.allSatisfy { $0.finishedAt != nil }
        }
        return jobs
    }

    func cleanup() { try? FileManager.default.removeItem(at: documents) }
}

@MainActor
@Suite("Import keepers and removal from Staging", .timeLimit(.minutes(1)))
struct KeepersImportTests {
    /// Two cameras' staged files: cam-a ("ILCE-7CM2") has a keeper, a reject and an unmarked photo on one day; cam-b
    /// ("ZV-E1") a kept RAW+JPEG pair.
    private struct TwoCameras {
        var a1, a2, a3, b1raw, b1jpg: StagedFile
        var all: [StagedFile] { [a1, a2, a3, b1raw, b1jpg] }

        init(in documents: URL) {
            a1 = stage("DSC00001.JPG", at: "20261105T140001", camera: "cam-a", cameraFolder: "ILCE-7CM2", in: documents)
            a2 = stage("DSC00002.JPG", at: "20261105T140002", camera: "cam-a", cameraFolder: "ILCE-7CM2", in: documents)
            a3 = stage("DSC00003.JPG", at: "20261105T140003", camera: "cam-a", cameraFolder: "ILCE-7CM2", in: documents)
            b1raw = stage("C0001.ARW", at: "20261106T090000", size: 96, camera: "cam-b", cameraFolder: "ZV-E1",
                          in: documents)
            b1jpg = stage("C0001.JPG", at: "20261106T090000", camera: "cam-b", cameraFolder: "ZV-E1", in: documents)
        }
    }

    private func twoCameras(photos: FakePhotosAccess = FakePhotosAccess(),
                            reader: any StagedFileReading = PlainStagedFileReader(),
                            files: any StagedFileAvailability = AlwaysLocalFiles(),
                            leases: LinkLeases = LinkLeases(), engineZone: TimeZone = .autoupdatingCurrent,
                            keepersZone: TimeZone? = nil) async throws
        -> (Rig, TwoCameras) {
        var made: TwoCameras?
        let rig = Rig({ documents in
            let two = TwoCameras(in: documents)
            made = two
            return two.all
        }, photos: photos, files: files, reader: reader, leases: leases, engineZone: engineZone,
           keepersZone: keepersZone)
        let two = try #require(made)
        try await rig.mark(.keep, two.a1, two.b1raw, two.b1jpg)
        try await rig.mark(.reject, two.a2)
        await rig.cull.load()
        try #require(rig.cull.rows.count == 2)
        return (rig, two)
    }

    // MARK: - Keepers into Photos

    @Test func stagedFilesFromTwoCameraKeysAreTwoJobsEachWithItsOwnRowsAndAlbum() async throws {
        let (rig, two) = try await twoCameras()
        defer { rig.cleanup() }
        // A camera with cam-a's key is connected: nothing of the keepers flow may reach it.
        let camera = FakeLink(items: [item("DSC00001.JPG")])
        rig.finder.links[CameraKey(rawValue: "cam-a")] = camera

        await rig.keepers.start(.all, in: rig.cull.rows)
        let plan = try #require(rig.keepers.confirmation)

        // One job per key, in the screen's order, each named for its camera's folder and read over Staging.
        let made = rig.destinations.cameras
        #expect(made.map(\.key.rawValue) == ["cam-a", "cam-b"])
        #expect(made.map(\.name) == ["ILCE-7CM2", "ZV-E1"])
        #expect(made.allSatisfy { $0.descriptor.mode == .staging })
        // Each key's rows are its own; the pair is one Photos asset.
        for file in [two.a1, two.b1raw, two.b1jpg] { #expect(await rig.row(file)?.state == .imported) }
        for file in [two.a2, two.a3] { #expect(await rig.row(file)?.state == .new) }
        #expect(await rig.destinations.photos.names.sorted() == ["C0001.ARW", "C0001.JPG", "DSC00001.JPG"])
        // Each job leaves its own History record, as a keepers job over Staging.
        let jobs = await rig.finishedJobs(2)
        #expect(Set(jobs.map(\.camera.rawValue)) == ["cam-a", "cam-b"])
        #expect(jobs.allSatisfy { $0.purpose == .keepers && $0.carrier == .staging && $0.outcome == .completed })
        // Nothing was staged by the jobs, and every staged copy is still there until the confirmation.
        #expect(await rig.destinations.files.names.isEmpty)
        for file in two.all { #expect(rig.exists(file)) }

        // The one confirmation (D2): two keepers in Photos (the pair is one), one reject; the unmarked photo stays.
        #expect(plan.keepersInPhotos == 2 && plan.rejects == 1 && plan.unmarked == 1)
        #expect(plan.keepersHeld == 0 && plan.rejectsHeld == 0)
        #expect(Set(plan.copies.map(\.identity)) == Set([two.a1, two.a2, two.b1raw, two.b1jpg].map(\.identity)))

        await rig.keepers.confirmRemoval()
        let summary = try #require(rig.keepers.summary)
        #expect(summary.removal?.removed == 4 && summary.removal?.failed == 0)
        for file in [two.a1, two.a2, two.b1raw, two.b1jpg] {
            #expect(!rig.exists(file))
            #expect(await rig.row(file)?.staged == nil)
        }
        // The unmarked photo and its row stay; the emptied day folder goes, the one still holding it stays.
        #expect(rig.exists(two.a3))
        #expect(await rig.row(two.a3)?.staged != nil)
        #expect(!rig.exists("Staging/ZV-E1/2026-11-06") && rig.exists("Staging/ZV-E1"))
        #expect(rig.exists("Staging/ILCE-7CM2/2026-11-05"))
        // The reject is remembered after its copy goes (D3).
        #expect(await rig.catalogue.marks(of: [two.a2.key])[two.a2.key]?.decision == .reject)

        // No camera link was used: the connected camera was never opened, listed or read.
        #expect(await camera.isOpen == false)
        #expect(await camera.bytesStarted == 0)
        #expect(await camera.fetched.isEmpty)
        #expect(!CameraLinkCapabilities.defaults(for: .staging).deletes)

        // Reloaded, Staging shows only what stayed.
        await rig.cull.load()
        #expect(rig.cull.rows.flatMap(\.units).flatMap(\.files).map(\.identity) == [two.a3.identity])
        #expect(rig.cull.unavailable.total == 0)
    }

    @Test func keepingTheCopiesRemovesNothing() async throws {
        let (rig, two) = try await twoCameras()
        defer { rig.cleanup() }
        await rig.keepers.start(.all, in: rig.cull.rows)
        #expect(rig.keepers.confirmation != nil)
        rig.keepers.keepStaged()
        let summary = try #require(rig.keepers.summary)
        #expect(summary.removal == nil && summary.plan != nil)
        #expect(rig.keepers.notice?.tone == .success)
        #expect(rig.keepers.notice?.systemImage == "checkmark.circle")
        #expect(rig.keepers.notice?.text == KeepersWording.finished(summary))
        for file in two.all {
            #expect(rig.exists(file))
            #expect(await rig.row(file)?.staged != nil)
        }
        rig.keepers.dismiss()
        #expect(rig.keepers.phase == .idle)
    }

    /// The plan is made when the jobs end, but the confirmation can wait (the loupe stays open over the screen): a mark
    /// changed meanwhile is read again at removal, so a reject changed to a keeper (not in Photos) isn't removed on its
    /// old mark, and the keeper now holds its day's other rejects back.
    @Test func aMarkChangedWhileTheConfirmationWaitsIsReadAgainAtRemoval() async throws {
        let (rig, two) = try await twoCameras()
        defer { rig.cleanup() }
        await rig.keepers.start(.all, in: rig.cull.rows)
        let plan = try #require(rig.keepers.confirmation)
        #expect(plan.copies.map(\.identity).contains(two.a2.identity))
        // The person changes their mind about the reject before confirming.
        try await rig.mark(.keep, two.a2)

        await rig.keepers.confirmRemoval()
        let summary = try #require(rig.keepers.summary)
        #expect(rig.exists(two.a2))
        #expect(await rig.row(two.a2)?.staged != nil)
        // What the rules still allow, and the person confirmed, goes: the keepers in Photos.
        for file in [two.a1, two.b1raw, two.b1jpg] { #expect(!rig.exists(file)) }
        #expect(summary.removal?.removed == 3 && summary.removal?.failed == 0)
        #expect(rig.exists(two.a3))
    }

    /// If the catalogue can't be read when the person confirms, the plan can't be checked again: nothing is removed,
    /// and the strip says the copies stay staged.
    @Test func aCatalogueUnreadableAtRemovalRemovesNothing() async throws {
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepersImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        let reject = stage("DSC00001.JPG", at: "20261105T140001", camera: "cam-a", cameraFolder: "ILCE-7CM2",
                           in: documents)
        let catalogue = SwitchableCatalogue(records: [reject.record])
        try await catalogue.setMark(.reject, rating: 0, for: [reject.key], at: Date())
        let locator = FakeStagingLocator(.unavailable(.containerUnavailable))
        let engine = ImportEngine(catalogue: InMemoryCatalogue(), stagingDirectory: temporaryStaging())
        let importer = ImportModel(engine: engine, settings: InMemoryDestinationSettingStore(),
                                   photos: FakePhotosAccess(), destinations: FakeDestinations())
        let loader = FakeLoader()
        loader.autoRelease = true
        let cull = CullModel<String>(catalogue: catalogue, onThisIPhone: documents, locator: locator,
                                     reader: PlainStagedFileReader(), loader: loader)
        await cull.load()
        let keepers = KeepersImport(catalogue: catalogue, importer: importer, onThisIPhone: documents,
                                    locator: locator, reader: PlainStagedFileReader(), plain: PlainStagedFileRemover(),
                                    coordinated: PlainStagedFileRemover())
        await keepers.start(.all, in: cull.rows)
        #expect(keepers.confirmation?.rejects == 1)

        await catalogue.setFailsListing(true)
        await keepers.confirmRemoval()
        let summary = try #require(keepers.summary)
        #expect(summary.removal?.removed == 0 && summary.removal?.failed == 1)
        #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent(reject.relativePath).path))
        #expect(await catalogue.record(for: reject.identity)?.staged != nil)
    }

    /// The zone the flow planned the jobs in isn't the zone the engine reads capture times in when a job starts (the
    /// Staging screen was opened in London, the phone has since landed in Tokyo): each keeper's row is still its staged
    /// row, so it reads as imported, its copy can go, and nothing is written under a capture time 9 hours away (which
    /// would leave the staged file new, to be imported again).
    @Test func theKeepersRowsAreTheStagedRowsWhateverZoneTheJobsWerePlannedIn() async throws {
        let (rig, two) = try await twoCameras(engineZone: TimeZone(identifier: "Asia/Tokyo")!,
                                              keepersZone: TimeZone(identifier: "Europe/London")!)
        defer { rig.cleanup() }
        let before = await rig.catalogue.stagedRecords(camera: nil).count
        await rig.keepers.start(.all, in: rig.cull.rows)
        let plan = try #require(rig.keepers.confirmation)
        for file in [two.a1, two.b1raw, two.b1jpg] { #expect(await rig.row(file)?.state == .imported) }
        #expect(plan.keepersInPhotos == 2 && plan.keepersHeld == 0)
        // No row of its own for any keeper: every row is a staged one.
        let all = await rig.catalogue.states(of: two.all.map(\.identity))
        #expect(all.values.filter { $0 == .imported }.count == 3)
        #expect(await rig.catalogue.stagedRecords(camera: nil).count == before)
        #expect(await rig.catalogue.record(for: ObjectIdentity(
            camera: two.a1.identity.camera, folder: two.a1.identity.folder, filename: two.a1.identity.filename,
            captureDate: CaptureDate(rawValue: "20261105T230001")!, size: two.a1.identity.size)) == nil)
    }

    @Test func aDayScopeImportsOnlyThatDaysKeepers() async throws {
        let (rig, two) = try await twoCameras()
        defer { rig.cleanup() }
        let day = try #require(rig.cull.rows.first { $0.cameraName == "ZV-E1" })
        await rig.keepers.start(.day(day.id), in: rig.cull.rows)
        let plan = try #require(rig.keepers.confirmation)
        #expect(rig.destinations.cameras.map(\.key.rawValue) == ["cam-b"])
        #expect(Set(plan.copies.map(\.identity)) == [two.b1raw.identity, two.b1jpg.identity])
        #expect(await rig.row(two.a1)?.state == .new)
    }

    // MARK: - Photos access

    /// A 3311 mid-job: the first camera's job stops for Photos access, writes nothing to Staging, the second camera's job
    /// never starts, and nothing is removed.
    @Test(arguments: [PhotosAuthorisation.denied, .restricted])
    func aRefusedSaveStopsTheKeepersStagesNothingAndStartsNoLaterJob(_ access: PhotosAuthorisation) async throws {
        let photos = FakePhotosAccess()
        // Read once before the job (full access), then as refused after the save.
        photos.change(afterNextReadTo: access)
        let (rig, two) = try await twoCameras(photos: photos)
        defer { rig.cleanup() }
        await rig.destinations.photos.setDenies(true)

        await rig.keepers.start(.all, in: rig.cull.rows)
        let summary = try #require(rig.keepers.summary)
        #expect(summary.run?.end == .photosAccessNeeded(access))
        #expect(summary.run?.jobsStarted == 1 && summary.run?.jobCount == 2)
        #expect(rig.destinations.cameras.map(\.key.rawValue) == ["cam-a"])
        #expect(await rig.destinations.files.names.isEmpty)
        #expect(await rig.destinations.iCloud.names.isEmpty)
        #expect(summary.plan == nil && summary.removal == nil)
        for file in two.all {
            #expect(rig.exists(file))
            #expect(await rig.row(file)?.staged != nil)
            #expect(await rig.row(file)?.state == .new)
        }
        // The Import screen says so, with Open Settings only for a denial.
        #expect(rig.importer.state == .finished(.photosAccessNeeded(access)))
        #expect(rig.importer.statusLine == ImportWording.photosAccessNeeded(access))
        #expect(rig.importer.offersPhotosSettingsLink == (access == .denied))
        #expect(await rig.finishedJobs(1).first?.outcome == .stopped(reason: "photosAccess"))
        #expect(KeepersWording.finished(summary).contains("Nothing was removed from Staging"))
    }

    /// The first camera's job completes, the second's is refused (Photos access turned off as it reads its files): the
    /// keepers stopped, so nothing is offered or removed, not even the first camera's copies that the rules alone would
    /// let go (section 7.5: "nothing is removed from Staging").
    @Test func aLaterJobRefusedRemovesNothingEvenWhereAnEarlierJobCompleted() async throws {
        let box = DestinationsBox()
        let photos = FakePhotosAccess()
        let reader = HookedReader { source in
            guard source.path.contains("/ZV-E1/") else { return }
            photos.set(.denied)
            await box.destinations?.photos.setDenies(true)
        }
        let (rig, two) = try await twoCameras(photos: photos, reader: reader)
        defer { rig.cleanup() }
        box.destinations = rig.destinations

        await rig.keepers.start(.all, in: rig.cull.rows)
        let summary = try #require(rig.keepers.summary)
        #expect(summary.run?.end == .photosAccessNeeded(.denied))
        #expect(summary.run?.jobsStarted == 2)
        #expect(await rig.row(two.a1)?.state == .imported)
        #expect(summary.plan == nil && summary.removal == nil)
        for file in two.all {
            #expect(rig.exists(file))
            #expect(await rig.row(file)?.staged != nil)
        }
    }

    @Test func photosAccessOffBeforehandStartsNoJob() async throws {
        let (rig, two) = try await twoCameras(photos: FakePhotosAccess(.denied))
        defer { rig.cleanup() }
        await rig.keepers.start(.all, in: rig.cull.rows)
        let summary = try #require(rig.keepers.summary)
        #expect(summary.run?.end == .photosAccessNeeded(.denied) && summary.run?.jobsStarted == 0)
        #expect(rig.destinations.cameras.isEmpty)
        #expect(rig.keepers.notice?.tone == .problem)
        #expect(rig.keepers.notice?.systemImage == "exclamationmark.triangle")
        #expect(await rig.destinations.photos.names.isEmpty)
        #expect(await rig.destinations.files.names.isEmpty)
        for file in two.all { #expect(rig.exists(file)) }
    }

    @Test func photosAccessIsAskedForOnceWhenNobodyHasAsked() async throws {
        let photos = FakePhotosAccess(.notDetermined, answer: .limited)
        let (rig, _) = try await twoCameras(photos: photos)
        defer { rig.cleanup() }
        await rig.keepers.start(.all, in: rig.cull.rows)
        #expect(rig.keepers.confirmation != nil)
        #expect(photos.askCount == 1)
    }

    // MARK: - What is held back

    /// A keeper imported separately before isn't saved again, and counts as in Photos; a keeper whose staged copy
    /// changed is skipped, stays with its mark, and holds back the reject of its day.
    @Test func anAlreadyImportedKeeperIsLeftOutAndASkippedOneHoldsItsDayBack() async throws {
        var files: [String: StagedFile] = [:]
        let earlier = ObjectIdentity(camera: CameraKey(rawValue: "cam-z"), folder: "DCIM/100MSDCF",
                                     filename: "DSC00001.JPG", captureDate: CaptureDate(rawValue: "20261105T140001")!,
                                     size: 64)
        let rig = Rig({ documents in
            for (name, time) in [("DSC00001.JPG", "20261105T140001"), ("DSC00002.JPG", "20261105T140002"),
                                 ("DSC00003.JPG", "20261105T140003")] {
                files[name] = stage(name, at: time, camera: "cam-a", cameraFolder: "ILCE-7CM2", in: documents)
            }
            return Array(files.values)
        }, extra: [CatalogueRecord(identity: earlier, format: .jpeg, state: .imported,
                                   location: .photosAsset(localIdentifier: "earlier"))])
        defer { rig.cleanup() }
        let (imported, changed, reject) = try (#require(files["DSC00001.JPG"]), #require(files["DSC00002.JPG"]),
                                               #require(files["DSC00003.JPG"]))
        try await rig.mark(.keep, imported, changed)
        try await rig.mark(.reject, reject)
        await rig.cull.load()
        // Changed in Files after the screen listed it.
        _ = FileManager.default.createFile(atPath: rig.documents.appendingPathComponent(changed.relativePath).path,
                                           contents: Data(count: 10))

        await rig.keepers.start(.all, in: rig.cull.rows)
        let plan = try #require(rig.keepers.confirmation)
        #expect(await rig.destinations.photos.names.isEmpty)
        #expect(plan.keepersInPhotos == 1 && plan.keepersHeld == 1 && plan.rejectsHeld == 1 && plan.rejects == 0)
        #expect(plan.copies.map(\.identity) == [imported.identity])
        await rig.keepers.confirmRemoval()
        let summary = try #require(rig.keepers.summary)
        #expect(summary.run?.alreadyImported == 1 && summary.run?.filesSkipped == 1)
        #expect(!rig.exists(imported))
        #expect(rig.exists(changed) && rig.exists(reject))
        #expect(await rig.catalogue.marks(of: [changed.key])[changed.key]?.decision == .keep)
    }

    @Test func nothingMarkedIsNothingToDo() async throws {
        var made: StagedFile?
        let rig = Rig { documents in
            let file = stage("DSC00001.JPG", at: "20261105T140001", camera: "cam-a", cameraFolder: "A", in: documents)
            made = file
            return [file]
        }
        defer { rig.cleanup() }
        await rig.cull.load()
        await rig.keepers.start(.all, in: rig.cull.rows)
        #expect(rig.keepers.summary?.problem == .nothingToDo)
        #expect(rig.exists(try #require(made)))
        #expect(rig.destinations.cameras.isEmpty)
    }

    // MARK: - Evicted keepers

    @Test func evictedKeepersAreDownloadedBeforeTheJobStarts() async throws {
        let box = DestinationsBox()
        let files = EvictedFiles(evicted: ["DSC00001.JPG"]) {
            // Nothing has reached Photos, and no job has started, when the download runs.
            let started = await box.photosNames()
            box.note(started)
        }
        let (rig, _) = try await twoCameras(files: files)
        defer { rig.cleanup() }
        box.destinations = rig.destinations
        await rig.keepers.start(.all, in: rig.cull.rows)
        #expect(rig.keepers.confirmation != nil)
        #expect(files.downloaded == ["DSC00001.JPG"])
        #expect(box.seen == [[]])
        #expect(rig.keepers.phase != .idle)
        await rig.keepers.confirmRemoval()
        #expect(rig.keepers.summary?.downloadedFirst == 1)
    }

    // MARK: - While a keepers job runs

    @Test func aKeepersJobGoesOnWhenTheAppLeavesAndTakesNoPicksFromBrowse() async throws {
        let reader = HoldingReader()
        let (rig, _) = try await twoCameras(reader: reader)
        defer { rig.cleanup() }
        let keepers = rig.keepers
        let rows = rig.cull.rows
        let run = Task { @MainActor in await keepers.start(.all, in: rows) }
        #expect(await eventually { reader.waiting > 0 })
        #expect(rig.importer.keepersLine == "Keepers, 1 of 2 cameras")
        #expect(rig.keepers.notice?.text.hasPrefix("Keepers, 1 of 2 cameras") == true)
        #expect(rig.keepers.confirmation == nil && !rig.keepers.acceptRemoval())
        #expect(rig.importer.camera?.descriptor.carrier == .staging)

        // Leaving the app doesn't pause it: its files are local.
        await rig.importer.scenePhaseChanged(.background)
        #expect(await rig.engine.state == .running)
        // A pick from a camera with the same key doesn't join it.
        let link = FakeLink(items: [item("DSC09999.JPG")])
        let outcome = await rig.importer.importItems(
            [item("DSC09999.JPG")], from: ImportCamera(descriptor: link.descriptor, key: CameraKey(rawValue: "cam-a")),
            link: link, as: .photos, newOnly: false)
        #expect(outcome == .busyWithKeepers)
        await rig.importer.scenePhaseChanged(.active)

        reader.release()
        await run.value
        #expect(rig.keepers.confirmation != nil)
        #expect(await link.bytesStarted == 0)
    }

    /// The person closes the Import screen just as a keepers job ends (LiveRoot dismisses a finished job when its sheet
    /// closes): the sequence still reads that job's end, goes on to the next camera and offers the removal, rather than
    /// waiting for ever on a job no longer shown, which would also refuse every later import as busy with keepers.
    @Test func closingTheImportScreenAsAKeepersJobEndsDoesntStallTheSequence() async throws {
        let leases = LinkLeases()
        let (rig, _) = try await twoCameras(leases: leases)
        defer { rig.cleanup() }
        let importer = rig.importer
        let closes = Counter()
        // Staging's link is let go once its job has ended and that end is on the screen, before the sequence reads it.
        leases.onClosed = { link in
            guard link is StagingFolderLink, importer.isFinished else { return }
            closes.count += 1
            importer.dismiss()
        }
        let keepers = rig.keepers
        let rows = rig.cull.rows
        let run = Task { @MainActor in await keepers.start(.all, in: rows) }
        // Bounded, so a sequence stalled on the dismissed job fails here instead of hanging (and isn't awaited).
        guard await eventually({ keepers.confirmation != nil }) else {
            Issue.record("the keepers sequence stalled after the Import screen was dismissed")
            return
        }
        #expect(closes.count == 2)
        #expect(rig.destinations.cameras.map(\.key.rawValue) == ["cam-a", "cam-b"])
        keepers.keepStaged()
        _ = await run.value
        // Once the sequence is over, closing the Import screen clears the finished job as before.
        importer.dismiss()
        #expect(!importer.hasJob)
    }

    /// The keepers line belongs to a keepers job: a camera's import started after *Import keepers* (with its last job
    /// never dismissed) doesn't say "Keepers, 2 of 2 cameras".
    @Test func aCameraImportAfterTheKeepersHasNoKeepersLine() async throws {
        let (rig, _) = try await twoCameras()
        defer { rig.cleanup() }
        await rig.keepers.start(.all, in: rig.cull.rows)
        rig.keepers.keepStaged()
        #expect(rig.importer.keepersLine == "Keepers, 2 of 2 cameras")
        let link = FakeLink(items: [item("DSC09999.JPG")])
        let outcome = await rig.importer.importItems(
            [item("DSC09999.JPG")], from: ImportCamera(descriptor: link.descriptor, key: CameraKey(rawValue: "cam-z")),
            link: link, as: .photos, newOnly: false)
        #expect(outcome == .started(1))
        #expect(rig.importer.camera?.descriptor.carrier != .staging)
        #expect(rig.importer.keepersLine == nil)
    }

    /// iOS ended the continued task and the person taps Continue: a keepers job carries on over its own Staging link;
    /// the camera with the staged files' key, though connected, isn't even looked up.
    @Test func aKeepersJobContinuedAfterAnExpiryNeverTakesACamerasLink() async throws {
        let reader = HoldingReader()
        let (rig, _) = try await twoCameras(reader: reader)
        defer { rig.cleanup() }
        let camera = FakeLink(items: [item("DSC00001.JPG")])
        rig.finder.links[CameraKey(rawValue: "cam-a")] = camera
        let keepers = rig.keepers
        let rows = rig.cull.rows
        let run = Task { @MainActor in await keepers.start(.all, in: rows) }
        #expect(await eventually { reader.waiting > 0 })

        try await rig.engine.pause(.taskExpired)
        await rig.importer.resume()
        #expect(rig.finder.asked.isEmpty)
        reader.release()
        guard await eventually({ keepers.confirmation != nil }) else {
            Issue.record("the keepers didn't finish after Continue")
            return
        }
        _ = await run.value
        #expect(rig.finder.asked.isEmpty)
        #expect(await camera.isOpen == false)
        #expect(await camera.bytesStarted == 0)
        #expect(await camera.fetched.isEmpty)
    }

    /// A keepers job left waiting for its link (as a removal would leave a camera's job) is never handed a connected
    /// camera's link, even one with the staged files' key: the camera isn't looked up, and the job stays waiting.
    @Test func aKeepersJobWaitingForItsLinkIsNeverHandedACamerasLink() async throws {
        let reader = HoldingReader()
        let (rig, _) = try await twoCameras(reader: reader)
        defer { rig.cleanup() }
        let camera = FakeLink(items: [item("DSC00001.JPG")])
        rig.finder.links[CameraKey(rawValue: "cam-a")] = camera
        let keepers = rig.keepers
        let rows = rig.cull.rows
        let run = Task { @MainActor in await keepers.start(.all, in: rows) }
        #expect(await eventually { reader.waiting > 0 })

        try await rig.engine.pause(.cameraRemoved)
        await rig.importer.cameraConnected()
        await rig.importer.refresh()
        #expect(rig.finder.asked.isEmpty)
        #expect(await rig.engine.state == .paused(.cameraRemoved))

        await rig.importer.cancel()
        reader.release()
        _ = await run.value
        #expect(keepers.summary?.run?.end == .ended(.cancelled))
        #expect(keepers.summary?.plan == nil)
        #expect(await camera.isOpen == false)
        #expect(await camera.bytesStarted == 0)
    }

    @Test func aSecondStartWhileOneRunsIsIgnored() async throws {
        let reader = HoldingReader()
        let (rig, _) = try await twoCameras(reader: reader)
        defer { rig.cleanup() }
        let keepers = rig.keepers
        let rows = rig.cull.rows
        let run = Task { @MainActor in await keepers.start(.all, in: rows) }
        #expect(await eventually { reader.waiting > 0 })
        #expect(rig.keepers.isBusy)
        await rig.keepers.start(.all, in: rows)
        #expect(rig.keepers.phase == .importing)
        reader.release()
        await run.value
        #expect(rig.destinations.cameras.count == 2)
    }

    // MARK: - Grouping

    @Test func keptUnitsAreGroupedByStagedCameraKeyInTheScreensOrder() {
        let a1 = cullFile("DSC00001.JPG", at: "20261105T140001", camera: "cam-a")
        let b1 = cullFile("DSC00002.JPG", at: "20261105T140002", camera: "cam-b")
        let a2 = cullFile("DSC00003.JPG", at: "20261104T100000", camera: "cam-a")
        let rejected = cullFile("DSC00004.JPG", at: "20261105T140004", camera: "cam-c")
        let today = CullDayRow(cameraName: "ILCE-7CM2", day: "20261105",
                               units: [a1, b1, rejected].map { CullUnit(.single($0)) })
        let yesterday = CullDayRow(cameraName: "ILCE-7CM2", day: "20261104", units: [CullUnit(.single(a2))])
        var marks: [ObjectIdentity.ContentKey: CullMark] = [:]
        for file in [a1, b1, a2] { marks[file.contentKey] = CullMark(decision: .keep) }
        marks[rejected.contentKey] = CullMark(decision: .reject)
        let jobs = KeepersImport.jobs(days: [today, yesterday], marks: marks, timeZone: TimeZone(identifier: "UTC")!)
        #expect(jobs.map(\.job.camera.rawValue) == ["cam-a", "cam-b"])
        #expect(jobs.map(\.job.cameraName) == ["ILCE-7CM2", "ILCE-7CM2"])
        #expect(jobs[0].job.entries.map(\.name) == ["DSC00001.JPG", "DSC00003.JPG"])
        // Each entry carries the file's original identity and its staged copy.
        let entry = jobs[0].job.entries[0]
        #expect(entry.folder == a1.identity.folder && entry.size == a1.identity.size && entry.url == a1.url)
        #expect(entry.captureDate.flatMap { CaptureDate($0, in: TimeZone(identifier: "UTC")!) }
            == a1.identity.captureDate)
    }
}

/// A count a main-actor closure can change.
@MainActor
private final class Counter {
    var count = 0
}

/// Lets a download check what Photos had been given, from a closure made before the rig.
private final class DestinationsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FakeDestinations?
    private var notes: [[String]] = []

    var destinations: FakeDestinations? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var seen: [[String]] { lock.withLock { notes } }

    func photosNames() async -> [String] { await destinations?.photos.names ?? ["no rig"] }
    func note(_ names: [String]) { lock.withLock { notes.append(names) } }
}
