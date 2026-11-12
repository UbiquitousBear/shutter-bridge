import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import Testing
@testable import AppUI

private let london = TimeZone(identifier: "Europe/London")!
private let britishEnglish = Locale(identifier: "en_GB")
private let camA = CameraKey(rawValue: "key-a")
private let camB = CameraKey(rawValue: "key-b")

private func londonCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = london
    return calendar
}

/// 14:05 on Wednesday 11 November 2026, London time: the History tests' "now".
private let now = londonCalendar().date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 14, minute: 5))!

private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
    londonCalendar().date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func identity(_ item: CameraItem, camera: CameraKey = camA) -> ObjectIdentity {
    item.identity(camera: camera, timeZone: london)!
}

private func key(_ item: CameraItem) -> ObjectIdentity.ContentKey { identity(item).contentKey }

private func job(_ id: Int, camera: CameraKey = camA, purpose: JobRecord.Purpose = .import,
                 destination: JobRecord.Destination? = .photos, carrier: JobRecord.Carrier? = .usb,
                 selection: JobRecord.Selection = .allNew, startedAt: Date, finishedAt: Date? = nil,
                 outcome: JobRecord.Outcome? = .completed, total: Int = 0, imported: Int = 0, staged: Int = 0,
                 skipped: Int = 0, failed: Int = 0, bytesTotal: UInt64 = 0, bytesDone: UInt64 = 0,
                 failedFiles: [ObjectIdentity.ContentKey] = []) -> JobRecord {
    JobRecord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!, camera: camera,
              purpose: purpose, destination: destination, carrier: carrier, selection: selection,
              startedAt: startedAt, finishedAt: finishedAt ?? (outcome == nil ? nil : startedAt.addingTimeInterval(60)),
              outcome: outcome, filesTotal: total, filesImported: imported, filesStaged: staged,
              filesSkipped: skipped, filesFailed: failed, bytesTotal: bytesTotal, bytesDone: bytesDone,
              failedFiles: failedFiles)
}

@MainActor
private final class Rig {
    let catalogue = InMemoryCatalogue()
    let importer = FakeImporter()
    let finder = FakeFinder()
    let leases = LinkLeases()
    let log = RecordingLog()
    let documents = FileManager.default.temporaryDirectory
        .appendingPathComponent("HistoryModelTests-\(UUID().uuidString)", isDirectory: true)
    var active: CameraKey?
    lazy var model = HistoryModel(catalogue: catalogue, importer: importer, finder: finder, leases: leases,
                                  onThisIPhone: documents,
                                  locator: FakeStagingLocator(.unavailable(.containerUnavailable)),
                                  activeCamera: { [unowned self] in self.active }, now: { now },
                                  calendar: londonCalendar(), locale: britishEnglish, log: log)

    init() {}

    func record(_ jobs: JobRecord...) async throws {
        for job in jobs { await catalogue.recordJob(job) }
    }

    func camera(_ key: CameraKey, name: String, model: String = "ILCE-7CM2") async {
        await catalogue.upsertCamera(CameraRecord(key: key, model: model, friendlyName: name))
    }

    func imported(_ items: CameraItem..., camera: CameraKey = camA) async throws {
        for item in items {
            await catalogue.upsert(CatalogueRecord(identity: identity(item, camera: camera), format: item.format,
                                                       state: .imported))
        }
    }

    func row(_ id: Int) -> HistoryRow? {
        let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!
        return model.sections.flatMap(\.rows).first { $0.id == uuid }
    }
}

// MARK: - Wording

@Suite("History wording")
struct HistoryWordingTests {
    @Test func countsReadAsTheImportScreenCountsThemWithoutFilesOrAFullStop() {
        #expect(HistoryWording.counts(job(1, startedAt: now, imported: 48, skipped: 2)) == "48 imported, 2 skipped")
        #expect(HistoryWording.counts(job(1, purpose: .stage, startedAt: now, staged: 12)) == "12 staged")
        #expect(HistoryWording.counts(job(1, startedAt: now, imported: 10, staged: 28, failed: 1))
            == "10 imported, 28 staged, 1 failed")
        #expect(HistoryWording.counts(job(1, startedAt: now)) == "Nothing imported")
        #expect(HistoryWording.counts(job(1, purpose: .stage, startedAt: now, skipped: 3)) == "Nothing staged, 3 skipped")
    }

    @Test func bytesAreDecimalAndAJobThatCopiedLessSaysOfWhat() {
        #expect(HistoryWording.bytes(job(1, startedAt: now, bytesTotal: 1_240_000_000, bytesDone: 1_240_000_000),
                                     locale: britishEnglish) == "1.24 GB")
        #expect(HistoryWording.bytes(job(1, startedAt: now, bytesTotal: 4_500_000_000, bytesDone: 42_300_000),
                                     locale: britishEnglish) == "42.3 MB of 4.5 GB")
    }

    @Test func durationIsWholeSecondsUnderAMinuteThenWholeMinutesAndNoneWithoutAnEnd() {
        let short = job(1, startedAt: now, finishedAt: now.addingTimeInterval(39.6))
        let long = job(1, startedAt: now, finishedAt: now.addingTimeInterval(3_900 + 20))
        #expect(HistoryWording.duration(short, locale: britishEnglish) == "40 secs")
        #expect(HistoryWording.duration(long, locale: britishEnglish) == "1 hr, 5 min")
        #expect(HistoryWording.durationSpoken(long, locale: britishEnglish) == "1 hour, 5 minutes")
        #expect(HistoryWording.duration(job(1, startedAt: now, outcome: nil), locale: britishEnglish) == nil)
    }

    @Test func outcomesAreWordedAsTheImportScreenEndsWithoutTheWordImport() {
        #expect(HistoryWording.outcome(.completed, running: false) == "Finished")
        #expect(HistoryWording.outcome(.cancelled, running: false) == "Cancelled")
        #expect(HistoryWording.outcome(.stopped(reason: CameraLinkFailure.Kind.phoneStorageFull.rawValue),
                                       running: false) == "Stopped: this iPhone is out of space")
        #expect(HistoryWording.outcome(.stopped(reason: "something-new"), running: false) == "Stopped")
        // A keepers job Photos refused (I12).
        #expect(HistoryWording.outcome(.stopped(reason: JobRecord.Outcome.photosAccessReason), running: false)
            == "Stopped: Photos access needed")
        #expect(HistoryWording.outcome(.catalogueUnavailable, running: false)
            == "Stopped: Shutter Bridge couldn't read or update its catalogue")
        #expect(HistoryWording.outcome(nil, running: false) == "Stopped early")
        #expect(HistoryWording.outcome(nil, running: true) == "In progress")
        // Every stop reason has its words.
        for kind in CameraLinkFailure.Kind.allCases {
            #expect(HistoryWording.outcome(.stopped(reason: kind.rawValue), running: false).hasPrefix("Stopped: "))
        }
    }

    @Test func thePlaceNamesTheAlbumOnlyWhenTheJobKeptItAndTellsAStagedImportApart() {
        #expect(HistoryWording.place(job(1, startedAt: now), camera: "ILCE-7CM2") == "Photos")
        var withAlbum = job(1, startedAt: now)
        withAlbum.albumIdentifier = "album-local-id"
        #expect(HistoryWording.place(withAlbum, camera: "ILCE-7CM2") == "Photos, album “ILCE-7CM2”")
        #expect(HistoryWording.place(job(1, purpose: .stage, destination: .staging, startedAt: now), camera: "A")
            == "Staging")
        #expect(HistoryWording.place(job(1, destination: .staging, startedAt: now), camera: "A")
            == "Staging instead of Photos")
        #expect(HistoryWording.place(job(1, destination: nil, startedAt: now), camera: "A") == nil)
    }

    @Test func theTitleSaysWhatTheJobWasWithTheCamerasName() {
        #expect(HistoryWording.title(.import, camera: "ILCE-7CM2") == "Import from ILCE-7CM2")
        #expect(HistoryWording.title(.stage, camera: "ILCE-7CM2") == "Stage from ILCE-7CM2")
        #expect(HistoryWording.title(.keepers, camera: "ILCE-7CM2") == "Keepers from ILCE-7CM2 to Photos")
    }

    @Test func theCamerasNameComesFromItsRowAndNeverAVolumeName() {
        #expect(HistoryWording.cameraName(CameraRecord(key: camA, model: "ILCE-7CM2", friendlyName: "Shamil's A7C"))
            == "Shamil's A7C")
        #expect(HistoryWording.cameraName(CameraRecord(key: camA, model: "ILCE-7CM2", friendlyName: "Untitled"))
            == "ILCE-7CM2")
        #expect(HistoryWording.cameraName(CameraRecord(key: camA)) == "Camera")
        #expect(HistoryWording.cameraName(nil) == "Camera")
    }

    @Test func theRowIsOneLineForVoiceOver() {
        let line = HistoryWording.rowAccessibility(title: "Import from ILCE-7CM2", time: "14:05", outcome: "Finished",
                                                   counts: "48 imported, 2 skipped", bytes: "1.24 GB",
                                                   durationSpoken: "12 minutes", place: "Photos", action: nil)
        #expect(line == "Import from ILCE-7CM2, 14:05. Finished. 48 imported, 2 skipped. 1.24 GB in 12 minutes. Photos.")
        #expect(!line.contains("\n"))
    }

    @Test func resumableAndFailedLinesCountFiles() {
        #expect(HistoryWording.resumable(filesLeft: 12) == "Resumable: 12 files left")
        #expect(HistoryWording.resumable(filesLeft: 1) == "Resumable: 1 file left")
        #expect(HistoryWording.resumable(filesLeft: nil) == "Resumable")
        #expect(HistoryWording.failedLeft(2, purpose: .import) == "2 failed files not imported yet")
        #expect(HistoryWording.failedLeft(1, purpose: .stage) == "1 failed file not staged yet")
    }

    @Test func theForgetImportsConfirmationSaysThePhotosStayAndCouldBeImportedAgain() {
        let confirmation = HistoryWording.forgetConfirmation(camera: "ILCE-7CM2")
        #expect(confirmation.title == "Forget Imports from ILCE-7CM2?")
        #expect(confirmation.message == "Shutter Bridge will forget which photos it imported from ILCE-7CM2, so they "
            + "show as new on its card and could be imported again. The photos stay in Photos, staged copies stay in "
            + "Staging, and nothing on the camera changes.")
        #expect(confirmation.footer == "A photo also imported from another camera stays imported.")
        #expect(confirmation.confirm == "Forget Imports")
        #expect(confirmation.dialogMessage == confirmation.message + "\n\n" + confirmation.footer)
        #expect(HistoryWording.forgot(48, camera: "ILCE-7CM2") == "Forgot 48 imports from ILCE-7CM2.")
        #expect(HistoryWording.forgot(1, camera: "ILCE-7CM2") == "Forgot 1 import from ILCE-7CM2.")
        #expect(HistoryWording.forgot(0, camera: "ILCE-7CM2") == "There were no imports from ILCE-7CM2 to forget.")
    }
}

// MARK: - Grouping

@Suite("History grouping")
@MainActor
struct HistoryGroupingTests {
    @Test func jobsAreNewestFirstGroupedByDayWithTheCamerasNameNeverItsKey() async throws {
        let rig = Rig()
        await rig.camera(camA, name: "ILCE-7CM2")
        try await rig.record(
            job(1, startedAt: at(day: 4, hour: 9), imported: 3),
            job(2, startedAt: at(day: 10, hour: 18), imported: 5),
            job(3, startedAt: at(day: 11, hour: 8), imported: 7),
            job(4, startedAt: at(day: 11, hour: 13, minute: 30), imported: 9))
        await rig.model.load()
        #expect(rig.model.phase == .loaded)
        #expect(rig.model.sections.map(\.title) == ["Today", "Yesterday", CullWording.dayTitle(
            "20261104", now: now, calendar: londonCalendar(), locale: britishEnglish)])
        #expect(rig.model.sections.map(\.id) == ["20261111", "20261110", "20261104"])
        #expect(rig.model.sections.map { $0.rows.map(\.counts) }
            == [["9 imported", "7 imported"], ["5 imported"], ["3 imported"]])
        let row = try #require(rig.row(4))
        #expect(row.title == "Import from ILCE-7CM2")
        #expect(row.time == "13:30")
        #expect(row.outcome == "Finished")
        #expect(row.duration == "1 min")
        for line in rig.model.sections.flatMap(\.rows).map(\.accessibilityLabel) {
            #expect(!line.contains(camA.rawValue))
        }
    }

    @Test func aDayIsTheLondonDayEvenAcrossMidnightUTC() async throws {
        let rig = Rig()
        // 00:30 BST on 1 June is 23:30 UTC on 31 May.
        var calendar = londonCalendar()
        calendar.timeZone = london
        let june = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 0, minute: 30))!
        try await rig.record(job(1, startedAt: june, imported: 1))
        await rig.model.load()
        #expect(rig.model.sections.map(\.id) == ["20260601"])
    }

    @Test func theFilterShowsOneCameraNameAndGroupsItsKeys() async throws {
        let rig = Rig()
        let camAMTP = CameraKey(rawValue: "key-a-mtp")
        await rig.camera(camA, name: "ILCE-7CM2")
        await rig.camera(camAMTP, name: "ILCE-7CM2")
        await rig.camera(camB, name: "ZV-E1", model: "ZV-E1")
        try await rig.record(
            job(1, camera: camA, startedAt: at(day: 11, hour: 9), imported: 1),
            job(2, camera: camAMTP, startedAt: at(day: 11, hour: 10), imported: 2),
            job(3, camera: camB, startedAt: at(day: 11, hour: 11), imported: 3))
        await rig.model.load()
        #expect(rig.model.cameras.map(\.name) == ["ILCE-7CM2", "ZV-E1"])
        #expect(rig.model.cameras.first?.keys == [camA, camAMTP])
        rig.model.cameraFilter = "ILCE-7CM2"
        #expect(rig.model.sections.flatMap(\.rows).map(\.counts) == ["2 imported", "1 imported"])
        rig.model.cameraFilter = nil
        #expect(rig.model.sections.flatMap(\.rows).count == 3)
    }

    @Test func stageAndKeepersJobsAreListedWithTheirPurpose() async throws {
        let rig = Rig()
        await rig.camera(camA, name: "ILCE-7CM2")
        try await rig.record(
            job(1, purpose: .stage, destination: .staging, startedAt: at(day: 11, hour: 9), staged: 4),
            job(2, purpose: .keepers, destination: .photos, carrier: .staging, startedAt: at(day: 11, hour: 10),
                imported: 2))
        await rig.model.load()
        #expect(rig.row(1)?.title == "Stage from ILCE-7CM2")
        #expect(rig.row(1)?.place == "Staging")
        #expect(rig.row(1)?.opensStagingFolder == true)
        #expect(rig.row(2)?.title == "Keepers from ILCE-7CM2 to Photos")
        #expect(rig.row(2)?.opensStagingFolder == false)
    }

    @Test func theRunningJobIsInProgressAndAnotherWithNoEndStoppedEarly() async throws {
        let rig = Rig()
        try await rig.record(
            job(1, startedAt: at(day: 10, hour: 9), outcome: nil, total: 5, imported: 2),
            job(2, startedAt: at(day: 11, hour: 9), outcome: nil, total: 5, imported: 1))
        rig.active = camA
        await rig.model.load()
        #expect(rig.row(2)?.outcome == "In progress")
        #expect(rig.row(2)?.action == nil)
        #expect(rig.row(1)?.outcome == "Stopped early")
        rig.active = nil
        await rig.model.load()
        #expect(rig.row(2)?.outcome == "Stopped early")
    }

    @Test func unreadableCameraNamesFailTheLoadRatherThanMergeEveryCameraIntoOne() async {
        // Without the names every key would read as "Camera": one entry whose Forget Imports reached both cameras.
        let catalogue = NamelessCatalogue(jobs: [job(1, camera: camA, startedAt: at(day: 11, hour: 9), imported: 1),
                                                 job(2, camera: camB, startedAt: at(day: 11, hour: 10), imported: 1)])
        let model = HistoryModel(catalogue: catalogue, importer: nil, finder: nil, leases: LinkLeases(),
                                 onThisIPhone: FileManager.default.temporaryDirectory,
                                 locator: FakeStagingLocator(.unavailable(.containerUnavailable)))
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.cameras.isEmpty)
        #expect(model.forgettableCameras.isEmpty)
        #expect(await catalogue.forgotten.isEmpty)
    }

    @Test func anUnreadableCatalogueSaysSo() async {
        let model = HistoryModel(catalogue: UnreadableJobsCatalogue(), importer: nil, finder: nil, leases: LinkLeases(),
                                 onThisIPhone: FileManager.default.temporaryDirectory,
                                 locator: FakeStagingLocator(.unavailable(.containerUnavailable)))
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.isEmpty)
    }
}

/// A catalogue that lists its jobs but can't read the cameras' rows; it counts the cameras whose imports it was asked to
/// forget.
private actor NamelessCatalogue: CatalogueStore {
    struct Broken: Error {}
    let listed: [JobRecord]
    private(set) var forgotten: [CameraKey] = []
    init(jobs: [JobRecord]) { listed = jobs }
    func record(for identity: ObjectIdentity) throws -> CatalogueRecord? { nil }
    func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] { [:] }
    func upsert(_ record: CatalogueRecord) throws {}
    func saveListing(_ listing: CardListing) throws {}
    func lastListing(for camera: CameraKey) throws -> CardListing? { nil }
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) throws {}
    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) throws {}
    func clearStaged(_ identity: ObjectIdentity) throws {}
    func stagedStates(of identities: [ObjectIdentity]) throws -> Set<ObjectIdentity> { [] }
    func camera(_ key: CameraKey) throws -> CameraRecord? { throw Broken() }
    func cameras() throws -> [CameraRecord] { throw Broken() }
    func upsertCamera(_ record: CameraRecord) throws {}
    func jobs(camera: CameraKey?) throws -> [JobRecord] { listed.filter { camera == nil || $0.camera == camera } }
    func forgetImports(camera: CameraKey) throws -> Int {
        forgotten.append(camera)
        return 0
    }
}

/// A catalogue whose every read fails, job records included (`BrokenCatalogue` keeps the protocol's empty job list).
private actor UnreadableJobsCatalogue: CatalogueStore {
    struct Broken: Error {}
    func record(for identity: ObjectIdentity) throws -> CatalogueRecord? { throw Broken() }
    func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] { throw Broken() }
    func upsert(_ record: CatalogueRecord) throws { throw Broken() }
    func saveListing(_ listing: CardListing) throws { throw Broken() }
    func lastListing(for camera: CameraKey) throws -> CardListing? { throw Broken() }
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) throws {
        throw Broken()
    }
    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) throws {
        throw Broken()
    }
    func clearStaged(_ identity: ObjectIdentity) throws { throw Broken() }
    func stagedStates(of identities: [ObjectIdentity]) throws -> Set<ObjectIdentity> { throw Broken() }
    func camera(_ key: CameraKey) throws -> CameraRecord? { throw Broken() }
    func cameras() throws -> [CameraRecord] { throw Broken() }
    func upsertCamera(_ record: CameraRecord) throws { throw Broken() }
    func jobs(camera: CameraKey?) throws -> [JobRecord] { throw Broken() }
    func forgetImports(camera: CameraKey) throws -> Int { throw Broken() }
}

// MARK: - Resumable

@Suite("History Resumable")
@MainActor
struct HistoryResumableTests {
    let a = item("DSC00001.ARW", at: 0)
    let b = item("DSC00002.ARW", at: 10)
    let c = item("DSC00003.ARW", at: 20)

    @Test func aPickedJobThatStoppedEarlyIsResumableOnlyWhileItsFilesAreLeft() async throws {
        let rig = Rig()
        try await rig.record(job(1, selection: .picked([key(a), key(b), key(c)]), startedAt: at(day: 11, hour: 9),
                                 outcome: nil, total: 3, imported: 1))
        try await rig.imported(a)
        await rig.model.load()
        #expect(rig.row(1)?.action == .resume(filesLeft: 2))
        #expect(rig.row(1)?.actionLine == "Resumable: 2 files left")
        #expect(rig.row(1)?.accessibilityLabel.hasSuffix("Resumable: 2 files left.") == true)
        // Another job imports the rest: nothing is left, so the row isn't Resumable any more.
        try await rig.imported(b, c, camera: camB)
        await rig.model.load()
        #expect(rig.row(1)?.action == nil)
    }

    @Test func anAllNewJobCountsWhatIsLeftOnTheLastKnownCard() async throws {
        let rig = Rig()
        try await rig.record(job(1, startedAt: at(day: 11, hour: 9), outcome: .stopped(reason: "disconnected"),
                                 total: 3, imported: 1))
        await rig.catalogue.saveListing(CardListing(camera: camA, listedAt: at(day: 11, hour: 8), entries: [
            .init(identity: identity(a), format: .raw), .init(identity: identity(b), format: .raw),
            .init(identity: identity(c), format: .raw),
        ]))
        try await rig.imported(a)
        await rig.model.load()
        #expect(rig.row(1)?.action == .resume(filesLeft: 2))
        #expect(rig.row(1)?.outcome == "Stopped: the camera was disconnected")
    }

    @Test func aJobKilledBeforeItsCardWasListedIsResumableWithNoCount() async throws {
        let rig = Rig()
        try await rig.record(job(1, startedAt: at(day: 11, hour: 9), outcome: nil))
        await rig.model.load()
        #expect(rig.row(1)?.action == .resume(filesLeft: nil))
        #expect(rig.row(1)?.actionLine == "Resumable")
    }

    @Test func completedCancelledAndKeepersJobsAreNeverResumable() async throws {
        let rig = Rig()
        try await rig.record(
            job(1, startedAt: at(day: 11, hour: 9), total: 3, imported: 1),
            job(2, startedAt: at(day: 11, hour: 10), outcome: .cancelled, total: 3, imported: 1),
            job(3, purpose: .keepers, carrier: .staging, startedAt: at(day: 11, hour: 11), outcome: nil, total: 3))
        await rig.model.load()
        #expect(rig.row(1)?.action == nil)
        #expect(rig.row(2)?.action == nil)
        #expect(rig.row(3)?.action == nil)
    }

    @Test func tappingWithTheCameraAwaySaysToConnectItAndQueuesNothing() async throws {
        let rig = Rig()
        await rig.camera(camA, name: "ILCE-7CM2")
        try await rig.record(
            job(1, selection: .picked([key(a)]), startedAt: at(day: 11, hour: 9), outcome: nil, total: 1),
            job(2, carrier: .wifi, selection: .picked([key(b)]), startedAt: at(day: 11, hour: 10), outcome: nil,
                total: 1))
        await rig.model.load()
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)) == false)
        #expect(rig.model.notice?.text == "Connect ILCE-7CM2 with its USB-C cable, then tap here again.")
        #expect(await rig.model.act(on: try #require(rig.row(2)?.id)) == false)
        #expect(rig.model.notice?.text == "Open ILCE-7CM2 in Cameras to connect over Wi-Fi, then tap here again.")
        #expect(rig.importer.calls.isEmpty)
    }

    @Test func resumeRebuildsAPickFromTheStoredSelectionAndQueuesOnlyWhatIsLeft() async throws {
        let rig = Rig()
        let link = FakeLink(items: [a, b, c, item("DSC00004.ARW", at: 30)])
        rig.finder.links[camA] = link
        try await rig.record(job(1, selection: .pickedNew([key(a), key(b), key(c)]), startedAt: at(day: 11, hour: 9),
                                 outcome: nil, total: 3, imported: 1))
        try await rig.imported(a)
        await rig.model.load()
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)))
        #expect(rig.importer.calls.count == 1)
        #expect(Set(rig.importer.calls[0].items.map(\.name)) == ["DSC00002.ARW", "DSC00003.ARW"])
        #expect(rig.importer.calls[0].camera.key == camA)
        #expect(rig.importer.asked[0].choice == .photos)
        #expect(rig.importer.asked[0].newOnly)
        // The link was held only while the card was read and handed over.
        #expect(rig.leases.holders(of: link) == 0)
        #expect(rig.log.lines.contains("history: queued 2 file(s) to resume a job, 0 no longer on the card"))
    }

    @Test func resumeOfAnAllNewStageJobLeavesOutStagedSkippedAndImportedFilesAsTheEngineDoes() async throws {
        let rig = Rig()
        let skippedFile = item("DSC00005.ARW", at: 40)
        let video = item("C0001.MP4", at: 50)
        let link = FakeLink(items: [a, b, c, skippedFile, video])
        rig.finder.links[camA] = link
        try await rig.record(job(1, purpose: .stage, destination: .staging, startedAt: at(day: 11, hour: 9),
                                 outcome: nil, total: 4, staged: 1))
        await rig.catalogue.markStaged(identity(a), format: .raw,
                                           at: StagedLocation(root: .onThisIPhone, relativePath: "Staging/A/1/a.ARW"))
        try await rig.imported(b)
        await rig.catalogue.upsert(CatalogueRecord(identity: identity(skippedFile), format: .raw, state: .skipped))
        await rig.model.load()
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)))
        #expect(rig.importer.calls.first?.items.map(\.name) == ["DSC00003.ARW"])
        #expect(rig.importer.asked.first?.choice == .staging)
    }

    @Test func resumeOfADateRangeTakesOnlyFilesInTheRange() async throws {
        let rig = Rig()
        rig.finder.links[camA] = FakeLink(items: [a, b, c])
        let range = try #require(b.captureDate) ... (try #require(c.captureDate))
        try await rig.record(job(1, selection: .dateRange(range), startedAt: at(day: 11, hour: 9),
                                 outcome: .catalogueUnavailable, total: 2))
        await rig.model.load()
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)))
        #expect(Set(rig.importer.calls.first?.items.map(\.name) ?? []) == ["DSC00002.ARW", "DSC00003.ARW"])
    }

    @Test func whenEverythingIsDoneByTheTimeTheCardIsReadNothingIsQueued() async throws {
        let rig = Rig()
        rig.finder.links[camA] = FakeLink(items: [a])
        // Nothing listed was left when History last looked; the card has only an imported file now.
        try await rig.record(job(1, startedAt: at(day: 11, hour: 9), outcome: nil))
        try await rig.imported(a)
        await rig.model.load()
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)) == false)
        #expect(rig.importer.calls.isEmpty)
        #expect(rig.model.notice?.text == "Nothing left to import: those files are imported already.")
    }

    @Test func aCardThatCantBeReadSaysSoAndLetsGoOfTheLink() async throws {
        let rig = Rig()
        await rig.camera(camA, name: "ILCE-7CM2")
        let link = FakeLink(items: [a])
        await link.set(listFailure: CameraLinkFailure(.noAnswer))
        rig.finder.links[camA] = link
        try await rig.record(job(1, startedAt: at(day: 11, hour: 9), outcome: nil))
        await rig.model.load()
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)) == false)
        #expect(rig.model.notice?.text == "Shutter Bridge couldn't read the card in ILCE-7CM2. Try again.")
        #expect(rig.model.notice?.tone == .problem)
        #expect(rig.leases.holders(of: link) == 0)
        #expect(rig.model.busyJob == nil)
    }

    @Test func aSecondTapWhileTheCameraIsLookedForQueuesNothing() async throws {
        let catalogue = InMemoryCatalogue()
        let importer = FakeImporter()
        let finder = GatedFinder()
        finder.found = FakeLink(items: [a])
        let model = HistoryModel(catalogue: catalogue, importer: importer, finder: finder, leases: LinkLeases(),
                                 onThisIPhone: FileManager.default.temporaryDirectory,
                                 locator: FakeStagingLocator(.unavailable(.containerUnavailable)),
                                 now: { now }, calendar: londonCalendar(), locale: britishEnglish)
        await catalogue.recordJob(job(1, selection: .picked([key(a)]), startedAt: at(day: 11, hour: 9), outcome: nil,
                                      total: 1))
        await model.load()
        let id = try #require(model.sections.first?.rows.first?.id)
        let first = Task { await model.act(on: id) }
        #expect(await eventually { finder.asked == 1 })
        var secondEnded = false
        let second = Task {
            let took = await model.act(on: id)
            secondEnded = true
            return took
        }
        // The second tap either gives up at once (busy) or waits on the finder too; neither can hang the test.
        #expect(await eventually { secondEnded || finder.asked == 2 })
        finder.answer()
        #expect(await first.value)
        #expect(await second.value == false)
        #expect(finder.asked == 1)
        #expect(importer.calls.count == 1)
    }

    @Test func theImportsRefusalIsPassedOn() async throws {
        let rig = Rig()
        rig.finder.links[camA] = FakeLink(items: [a])
        rig.importer.outcome = .busyWithAnotherCamera
        try await rig.record(job(1, startedAt: at(day: 11, hour: 9), outcome: nil))
        await rig.model.load()
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)) == false)
        #expect(rig.model.notice?.text == BrowseWording.importRequested(.busyWithAnotherCamera))
    }
}

// MARK: - Re-run

@Suite("History re-run")
@MainActor
struct HistoryRerunTests {
    let imported = item("DSC00001.ARW", at: 0)
    let skipped = item("DSC00002.ARW", at: 10)
    let failedThenImported = item("DSC00003.ARW", at: 20)
    let failedStill = item("DSC00004.ARW", at: 30)
    let failedGone = item("DSC00005.ARW", at: 40)
    let unrelated = item("DSC00006.ARW", at: 50)

    @Test func reRunQueuesOnlyTheFailedFilesStillNotImportedAndListsTheMissing() async throws {
        let rig = Rig()
        let link = FakeLink(items: [imported, skipped, failedThenImported, failedStill, unrelated])
        rig.finder.links[camA] = link
        try await rig.record(job(1, startedAt: at(day: 11, hour: 9), total: 5, imported: 1, skipped: 1, failed: 3,
                                 failedFiles: [key(failedThenImported), key(failedStill), key(failedGone)]))
        try await rig.imported(imported)
        // Imported since by another job, from another camera key.
        try await rig.imported(failedThenImported, camera: camB)
        await rig.model.load()
        #expect(rig.row(1)?.action == .rerun(failedLeft: 2))
        #expect(rig.row(1)?.actionLine == "2 failed files not imported yet")
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)))
        #expect(rig.importer.calls.first?.items.map(\.name) == ["DSC00004.ARW"])
        #expect(rig.importer.asked.first?.newOnly == false)
        #expect(rig.importer.asked.first?.choice == .photos)
        #expect(rig.model.notice?.text == "1 failed file is no longer on the card.")
        #expect(rig.log.lines.contains("history: queued 1 file(s) to re-run a job, 1 no longer on the card"))
    }

    @Test func aStageJobsReRunLeavesOutFilesStagedSinceButNotImportedOnes() async throws {
        let rig = Rig()
        rig.finder.links[camA] = FakeLink(items: [failedThenImported, failedStill])
        try await rig.record(job(1, purpose: .stage, destination: .staging, startedAt: at(day: 11, hour: 9),
                                 total: 2, failed: 2, failedFiles: [key(failedThenImported), key(failedStill)]))
        // Imported to Photos, not staged: a stage job's re-run still stages it.
        try await rig.imported(failedThenImported)
        await rig.catalogue.markStaged(identity(failedStill), format: .raw,
                                           at: StagedLocation(root: .onThisIPhone, relativePath: "Staging/A/1/b.ARW"))
        await rig.model.load()
        #expect(rig.row(1)?.action == .rerun(failedLeft: 1))
        #expect(rig.row(1)?.actionLine == "1 failed file not staged yet")
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)))
        #expect(rig.importer.calls.first?.items.map(\.name) == ["DSC00003.ARW"])
        #expect(rig.importer.asked.first?.choice == .staging)
    }

    @Test func aCancelledJobsFailuresCanBeReRunAndAllDoneOffersNothing() async throws {
        let rig = Rig()
        try await rig.record(
            job(1, startedAt: at(day: 11, hour: 9), outcome: .cancelled, total: 2, failed: 1,
                failedFiles: [key(failedStill)]),
            job(2, startedAt: at(day: 11, hour: 10), total: 1, failed: 1, failedFiles: [key(failedThenImported)]))
        try await rig.imported(failedThenImported)
        await rig.model.load()
        #expect(rig.row(1)?.action == .rerun(failedLeft: 1))
        #expect(rig.row(2)?.action == nil)
    }

    @Test func aFailedFileGoneFromTheCardIsSaidAndNothingStarts() async throws {
        let rig = Rig()
        rig.finder.links[camA] = FakeLink(items: [unrelated])
        try await rig.record(job(1, startedAt: at(day: 11, hour: 9), total: 1, failed: 1, failedFiles: [key(failedGone)]))
        await rig.model.load()
        #expect(await rig.model.act(on: try #require(rig.row(1)?.id)) == false)
        #expect(rig.importer.calls.isEmpty)
        #expect(rig.model.notice?.text == "1 failed file is no longer on the card.")
    }

    @Test func theRulesQueueEachFailedFileOnceAndNeverAnotherFile() {
        let listing = [imported, failedStill, failedStill].map {
            HistoryRules.Listed(item: $0, identity: identity($0))
        }
        let result = HistoryRules.rerunQueue(failed: [key(failedStill), key(failedStill), key(failedGone)],
                                             done: [], listing: listing)
        #expect(result.queue.map(\.name) == ["DSC00004.ARW"])
        #expect(result.missing == [key(failedGone)])
    }
}

// MARK: - Forget imports

@Suite("History Forget imports")
@MainActor
struct HistoryForgetTests {
    @Test func forgettingACameraForgetsEveryKeyWithItsNameAndKeepsTheJobs() async throws {
        let rig = Rig()
        let camAMTP = CameraKey(rawValue: "key-a-mtp")
        await rig.camera(camA, name: "ILCE-7CM2")
        await rig.camera(camAMTP, name: "ILCE-7CM2")
        await rig.camera(camB, name: "ZV-E1")
        let one = item("DSC00001.ARW", at: 0)
        let two = item("DSC00002.ARW", at: 10)
        let other = item("DSC00009.ARW", at: 90)
        try await rig.imported(one, camera: camA)
        try await rig.imported(two, camera: camAMTP)
        try await rig.imported(other, camera: camB)
        try await rig.record(job(1, camera: camA, startedAt: at(day: 11, hour: 9), imported: 1),
                             job(2, camera: camAMTP, startedAt: at(day: 11, hour: 10), imported: 1),
                             job(3, camera: camB, startedAt: at(day: 11, hour: 11), imported: 1))
        await rig.model.load()
        let camera = try #require(rig.model.cameras.first { $0.name == "ILCE-7CM2" })
        #expect(rig.model.forgetConfirmation(for: camera).title == "Forget Imports from ILCE-7CM2?")
        await rig.model.forgetImports(of: camera)
        #expect(rig.model.notice?.text == "Forgot 2 imports from ILCE-7CM2.")
        #expect(rig.model.notice?.tone == .success)
        let states = await rig.catalogue.states(of: [identity(one), identity(two, camera: camAMTP),
                                                         identity(other, camera: camB)])
        #expect(states[identity(one)] == nil || states[identity(one)] == .new)
        #expect(states[identity(two, camera: camAMTP)] == nil || states[identity(two, camera: camAMTP)] == .new)
        #expect(states[identity(other, camera: camB)] == .imported)
        // History keeps the jobs.
        #expect(rig.model.sections.flatMap(\.rows).count == 3)
        #expect(rig.log.lines.contains("history: forgot 2 imported file(s) of one camera"))
    }

    @Test func aCameraWithImportsButNoJobRecordsCanStillBeForgotten() async throws {
        // Imports made before Catalogue V4 have no job records: the camera has no History rows, but its imports are
        // still forgettable (D6), and the filter doesn't offer a camera with nothing to show.
        let rig = Rig()
        await rig.camera(camA, name: "ILCE-7CM2")
        await rig.camera(camB, name: "ZV-E1", model: "ZV-E1")
        let one = item("DSC00001.ARW", at: 0)
        let other = item("DSC00009.ARW", at: 90)
        try await rig.imported(one, camera: camA)
        try await rig.imported(other, camera: camB)
        try await rig.record(job(1, camera: camA, startedAt: at(day: 11, hour: 9), imported: 1))
        await rig.model.load()
        #expect(rig.model.cameras.map(\.name) == ["ILCE-7CM2"])
        #expect(rig.model.forgettableCameras.map(\.name) == ["ILCE-7CM2", "ZV-E1"])
        await rig.model.forgetImports(of: try #require(rig.model.forgettableCameras.last))
        #expect(rig.model.notice?.text == "Forgot 1 import from ZV-E1.")
        let states = await rig.catalogue.states(of: [identity(one), identity(other, camera: camB)])
        #expect(states[identity(one)] == .imported)
        #expect(states[identity(other, camera: camB)] != .imported)
    }

    @Test func forgettingACameraWhoseImportRunsIsRefusedAndKeepsItsMarkers() async throws {
        let rig = Rig()
        await rig.camera(camA, name: "ILCE-7CM2")
        let one = item("DSC00001.ARW", at: 0)
        let inFlight = item("DSC00002.ARW", at: 10)
        try await rig.imported(one)
        // A commit of the running job, bracketed by its marker.
        let commit = PendingCommit(id: UUID(), destination: .photos,
                                   files: [.init(identity: identity(inFlight), format: .raw, role: .single)],
                                   writtenAt: at(day: 11, hour: 9))
        try await rig.catalogue.beginCommit(commit)
        try await rig.record(job(1, startedAt: at(day: 11, hour: 9), outcome: nil, imported: 1))
        rig.active = camA
        await rig.model.load()
        await rig.model.forgetImports(of: try #require(rig.model.forgettableCameras.first))
        #expect(rig.model.notice?.text == "Wait for the import from ILCE-7CM2 to finish, then forget its imports.")
        #expect(await rig.catalogue.states(of: [identity(one)])[identity(one)] == .imported)
        #expect(await rig.catalogue.pendingCommits().map(\.id) == [commit.id])
        #expect(rig.log.lines.contains("history: didn't forget a camera's imports while its import runs"))
        // Once it has finished, the same request forgets.
        rig.active = nil
        await rig.model.forgetImports(of: try #require(rig.model.forgettableCameras.first))
        #expect(rig.model.notice?.text == "Forgot 1 import from ILCE-7CM2.")
    }

    @Test func aStagedFileStaysStagedAfterItsImportIsForgotten() async throws {
        let rig = Rig()
        let one = item("DSC00001.ARW", at: 0)
        try await rig.imported(one)
        await rig.catalogue.markStaged(identity(one), format: .raw,
                                           at: StagedLocation(root: .onThisIPhone, relativePath: "Staging/A/1/x.ARW"))
        try await rig.record(job(1, startedAt: at(day: 11, hour: 9), imported: 1))
        await rig.model.load()
        await rig.model.forgetImports(of: try #require(rig.model.cameras.first))
        #expect(await rig.catalogue.stagedRecords(camera: camA).map(\.identity) == [identity(one)])
    }
}

@Suite("History Forget imports failing")
@MainActor
struct HistoryForgetFailureTests {
    @Test func aCatalogueThatRefusesSaysSoAtErrorLevel() async {
        let log = RecordingLevelLog()
        let model = HistoryModel(catalogue: UnreadableJobsCatalogue(), importer: nil, finder: nil, leases: LinkLeases(),
                                 onThisIPhone: FileManager.default.temporaryDirectory,
                                 locator: FakeStagingLocator(.unavailable(.containerUnavailable)), log: log)
        await model.forgetImports(of: HistoryCamera(name: "ILCE-7CM2", keys: [camA]))
        #expect(model.notice?.text == HistoryWording.catalogueFailed)
        #expect(model.notice?.tone == .problem)
        #expect(log.entries.contains { $0.level == .error && $0.line.hasPrefix("history: forgetting") })
    }
}

/// Keeps each line with its level.
private final class RecordingLevelLog: BenchLog, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(line: String, level: BenchLogLevel)] = []
    var entries: [(line: String, level: BenchLogLevel)] { lock.withLock { stored } }
    func note(_ line: String) { note(line, level: .notice) }
    func note(_ line: String, level: BenchLogLevel) { lock.withLock { stored.append((line, level)) } }
}

// MARK: - Finding the camera

@Suite("History camera finder")
@MainActor
struct HistoryCameraFinderTests {
    @Test func aHeldLinkIsFoundFirstThenAUSBCameraAndAWiFiCameraIsNeverAskedFor() async {
        let leases = LinkLeases()
        let wifiDescriptor = CameraDescriptor(id: .init(rawValue: "wifi"), name: "ILCE-7CM2",
                                              mode: .wifi(.cameraNetwork))
        let usb = FakeLink(items: [], mode: .usb(.mtp), id: "usb", name: "ILCE-7CM2")
        let held = FakeLink(items: [], mode: .usb(.mtp), id: "held", name: "ZV-E1")
        let asked = Asked()
        let finder = HistoryCameraFinder(
            leases: leases, cameras: { [wifiDescriptor, usb.descriptor] },
            link: { id in
                asked.ids.append(id.rawValue)
                return id.rawValue == "usb" ? usb : nil
            },
            key: { descriptor, _ in CameraKey(rawValue: "key-" + descriptor.id.rawValue) })
        leases.acquire(held)
        #expect(await finder.link(forCameraWith: CameraKey(rawValue: "key-held")) === held)
        #expect(asked.ids.isEmpty)
        #expect(await finder.link(forCameraWith: CameraKey(rawValue: "key-usb")) === usb)
        #expect(await finder.link(forCameraWith: CameraKey(rawValue: "key-wifi")) == nil)
        #expect(!asked.ids.contains("wifi"))
    }
}

/// A finder that waits until the test lets it answer, and counts how often it was asked.
@MainActor
private final class GatedFinder: CameraFinding {
    var found: (any CameraLink)?
    private(set) var asked = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func link(forCameraWith key: CameraKey) async -> (any CameraLink)? {
        asked += 1
        await withCheckedContinuation { waiting.append($0) }
        return found
    }

    func answer() {
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
    }
}

@MainActor
private final class Asked {
    var ids: [String] = []
}

// MARK: - A stage job's folder

@Suite("History staging folder")
@MainActor
struct HistoryStagingFolderTests {
    @Test func aStageJobOpensItsCamerasFolderUnderStagingAndAPhotosJobNothing() async throws {
        let rig = Rig()
        let one = item("DSC00001.ARW", at: 0)
        let start = at(day: 11, hour: 9)
        await rig.catalogue.markStaged(identity(one), format: .raw,
                                           at: StagedLocation(root: .onThisIPhone,
                                                              relativePath: "Staging/ILCE-7CM2/2026-11-11/DSC00001.ARW",
                                                              stagedAt: start.addingTimeInterval(5)))
        try await rig.record(job(1, purpose: .stage, destination: .staging, startedAt: start, staged: 1),
                             job(2, startedAt: at(day: 11, hour: 10), imported: 1),
                             job(3, camera: camB, purpose: .stage, destination: .staging,
                                 startedAt: at(day: 11, hour: 11)))
        await rig.model.load()
        let first = try #require(rig.row(1)?.id)
        let folder = try #require(await rig.model.stagingFolder(for: first))
        #expect(folder.standardizedFileURL.path == rig.documents.appendingPathComponent("Staging/ILCE-7CM2")
            .standardizedFileURL.path)
        let second = try #require(rig.row(2)?.id)
        #expect(await rig.model.stagingFolder(for: second) == nil)
        // No staged copy of that camera's left: the Staging folder itself.
        let third = try #require(rig.row(3)?.id)
        let fallback = try #require(await rig.model.stagingFolder(for: third))
        #expect(fallback.standardizedFileURL.path == rig.documents.appendingPathComponent("Staging")
            .standardizedFileURL.path)
    }
}
