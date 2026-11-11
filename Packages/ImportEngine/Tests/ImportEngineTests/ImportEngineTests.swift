import CameraTransport
import Catalogue
import Foundation
import PhotosBridge
import Testing
@testable import ImportEngine

@Suite("Import progress")
struct ImportProgressTests {
    @Test func fractionAndRemainingAreInBytes() {
        let p = ImportProgress(filesDone: 1, filesTotal: 4, bytesDone: 25, bytesTotal: 100)
        #expect(p.fractionCompleted == 0.25)
        #expect(p.bytesRemaining == 75)
        #expect(ImportProgress.none.fractionCompleted == 0)
        let over = ImportProgress(filesDone: 1, filesTotal: 1, bytesDone: 120, bytesTotal: 100)
        #expect(over.fractionCompleted == 1)
        #expect(over.bytesRemaining == 0)
    }

    @Test func etaNeedsAPositiveRate() {
        // 100 files as 50 RAW+JPEG pairs, about 3.2 GB (backlog, exit criteria), at MSC's 40 MB/s: 80 s.
        var p = ImportProgress(filesDone: 0, filesTotal: 100, bytesDone: 0, bytesTotal: 3_200_000_000)
        #expect(p.estimatedTimeRemaining == nil)
        p.bytesPerSecond = 0
        #expect(p.estimatedTimeRemaining == nil)
        p.bytesPerSecond = .infinity
        #expect(p.estimatedTimeRemaining == nil)
        p.bytesPerSecond = 40_000_000
        #expect(p.estimatedTimeRemaining == .seconds(80))
        #expect(p.megabytesPerSecond == 40)
    }
}

@Suite("Selection and settings")
struct ImportSelectionTests {
    @Test func onlyAnExplicitPickOfNothingIsEmpty() {
        #expect(ImportSelection.items([]).isEmpty)
        #expect(!ImportSelection.allNew.isEmpty)
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(!ImportSelection.dateRange(now ... now).isEmpty)
    }

    @Test func downloadsInFlightIsOneOrTwo() {
        #expect(ImportSettings().downloadsInFlight == 1)
        #expect(ImportSettings(downloadsInFlight: 2).downloadsInFlight == 2)
        #expect(ImportSettings(downloadsInFlight: 0).downloadsInFlight == 1)
        var s = ImportSettings()
        s.downloadsInFlight = 5
        #expect(s.downloadsInFlight == 2)
    }

    @Test func decodingClampsDownloadsInFlight() throws {
        let decode = { (json: String) in try JSONDecoder().decode(ImportSettings.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"downloadsInFlight":5}"#).downloadsInFlight == 2)
        #expect(try decode(#"{"downloadsInFlight":0}"#).downloadsInFlight == 1)
        #expect(try decode(#"{"downloadsInFlight":-1}"#).downloadsInFlight == 1)
        #expect(try decode(#"{}"#).downloadsInFlight == 1)
        let round = try JSONEncoder().encode(ImportSettings(downloadsInFlight: 2))
        #expect(try JSONDecoder().decode(ImportSettings.self, from: round).downloadsInFlight == 2)
    }
}

actor NoLink: CameraLink {
    nonisolated let descriptor = CameraDescriptor(id: .init(rawValue: "none"), name: "None", mode: .usb(.massStorage))
    nonisolated let capabilities = CameraLinkCapabilities.usb
    nonisolated let events = AsyncStream<CameraLinkEvent> { $0.finish() }
    func open() throws(CameraLinkFailure) {}
    func list() throws(CameraLinkFailure) -> [CameraItem] { [] }
    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem { throw CameraLinkFailure(.itemNotFound) }
    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data() }
    func bytes(of item: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) throws(CameraLinkFailure) -> URL {
        throw CameraLinkFailure(.itemNotFound)
    }
    func close() {}
}

struct NoDestination: ImportDestination {
    let kind: DestinationKind = .photos
    func commit(_ unit: CommitUnit) throws(ImportDestinationFailure) -> ImportResult {
        throw .rejected(detail: "test")
    }
}

@Suite("The engine's surface", .timeLimit(.minutes(1)))
struct ImportEngineSurfaceTests {
    let camera = CameraKey(rawValue: "test-camera")
    var route: ImportRoute {
        .photos(NoDestination(), staging: NoDestination(), onThisIPhone: NoDestination(),
                stagingPlace: Harness.onThisIPhone, authorisation: { .authorised })
    }

    @Test func startsIdleWithDefaultSettings() async {
        let engine = ImportEngine(catalogue: InMemoryCatalogue())
        #expect(await engine.state == .idle)
        #expect(await engine.settings.downloadsInFlight == 1)
        #expect(await engine.currentProgress == ImportProgress.none)
        #expect(await !engine.isUSBImportRunning)
    }

    @Test func refusesAnEmptySelection() async {
        let engine = ImportEngine(catalogue: InMemoryCatalogue())
        await #expect(throws: ImportEngineError.emptySelection) {
            try await engine.start(.items([]), from: NoLink(), camera: camera, to: route)
        }
        #expect(await engine.state == .idle)
    }

    @Test func oneJobAtATime() async throws {
        let h = Harness()
        let link = h.link(h.singles(["A.JPG"]))
        await link.setDefaultStep(.hold)
        try await h.start(.allNew, from: link)
        await #expect(throws: ImportEngineError.jobInProgress) {
            try await h.engine.start(.allNew, from: link, camera: h.camera, to: h.photosRoute)
        }
        await h.cleanup()
    }

    @Test func controlsNeedAJob() async {
        let engine = ImportEngine(catalogue: InMemoryCatalogue())
        await #expect(throws: ImportEngineError.noJob) { try await engine.pause() }
        await #expect(throws: ImportEngineError.noJob) { try await engine.resume() }
        await #expect(throws: ImportEngineError.noJob) { try await engine.append([]) }
        await #expect(throws: ImportEngineError.noJob) { try await engine.reconnect(NoLink()) }
        await engine.cancel()
        #expect(await engine.state == .idle)
    }

    @Test func activeStates() {
        #expect(ImportJobState.running.isActive)
        #expect(ImportJobState.paused(.appInBackground).isActive)
        #expect(!ImportJobState.idle.isActive)
        #expect(!ImportJobState.finished(.stopped(.phoneStorageFull)).isActive)
        #expect(!ImportJobState.finished(.catalogueUnavailable).isActive)
    }

    @Test func settingsApplyFromTheNextJob() async throws {
        let h = Harness(downloadsInFlight: 1)
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        await link.setDefaultStep(.hold)
        try await h.start(.items(card), from: link)
        let a = await link.nextHeldCall()
        await h.engine.updateSettings(ImportSettings(downloadsInFlight: 2))
        #expect(await h.engine.settings.downloadsInFlight == 2)
        _ = try await h.engine.append([])
        a.release()
        let b = await link.nextHeldCall()
        b.release()
        let c = await link.nextHeldCall()
        c.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.maxConcurrentBytes == 1)

        let mark = h.trace.count
        let card2 = h.singles(["D.JPG", "E.JPG"], prefix: "s2")
        let link2 = h.link(card2)
        await link2.setDefaultStep(.hold)
        try await h.start(.items(card2), from: link2)
        let d = await link2.nextHeldCall()
        let e = await link2.nextHeldCall()
        #expect(await link2.maxConcurrentBytes == 2)
        d.release()
        e.release()
        #expect(await h.waitFinished(after: mark) == .completed)
        await h.cleanup()
    }

    @Test func routeFollowsTheDecision() throws {
        let folder = URL(fileURLWithPath: "/nonexistent")
        let photos = FakeDestination(kind: .photos, folder: folder)
        let files = FakeDestination(kind: .staging, folder: folder)
        let iCloud = FakeDestination(kind: .staging, folder: folder, place: .iCloudDrive)
        let access: @Sendable () async -> PhotosAuthorisation = { .authorised }
        let forced = try ImportRoute(.stagedHere(.photosRestricted), photos: photos, staging: files,
                                     onThisIPhone: files, stagingPlace: .iCloudDrive, authorisation: access)
        #expect(forced.decision == .stagedHere(.photosRestricted))
        #expect(forced.destination.kind == .staging)
        #expect(forced.purpose == .staging)
        // A staging decision's own place wins over the one given for a Photos route's fallback.
        #expect(forced.stagingPlace == Harness.onThisIPhone)
        let chosen = try ImportRoute(.photos, photos: photos, staging: iCloud, onThisIPhone: files,
                                     stagingPlace: .iCloudDrive, authorisation: access)
        #expect(chosen.decision == .photos)
        #expect(chosen.destination.kind == .photos)
        #expect(chosen.staging.kind == .staging)
        #expect(chosen.stagingPlace == .iCloudDrive)
        #expect(chosen.purpose == .photos)
        let made = ImportRoute.photos(photos, staging: files, onThisIPhone: files, stagingPlace: Harness.onThisIPhone,
                                      authorisation: access)
        #expect(made.decision == chosen.decision)
        let staged = ImportRoute.staging(files, reason: .photosDenied, place: Harness.onThisIPhone,
                                         onThisIPhone: files)
        #expect(staged.decision == .stagedHere(.photosDenied))
        #expect(staged.purpose == .staging)
        let inICloud = try ImportRoute(.staging(.chosen, .iCloudDrive), photos: photos, staging: iCloud,
                                       onThisIPhone: files, stagingPlace: .iCloudDrive, authorisation: access)
        #expect(inICloud.decision == .staging(.chosen, .iCloudDrive))
        #expect(inICloud.stagingPlace == .iCloudDrive)
    }

    /// The app asks for Photos access before a job starts; a route can't be built from "ask first", and saying so is
    /// an error the app can handle, not a trap.
    @Test func aRouteNeedsPhotosAccessAskedFirst() {
        let folder = URL(fileURLWithPath: "/nonexistent")
        #expect(throws: ImportEngineError.photosAccessNotAsked) {
            let files = FakeDestination(kind: .staging, folder: folder)
            return try ImportRoute(.askForPhotosAccess, photos: FakeDestination(kind: .photos, folder: folder),
                                   staging: files, onThisIPhone: files, stagingPlace: Harness.onThisIPhone,
                                   authorisation: { .notDetermined })
        }
    }

    /// After a refused save the reason comes from the access read then: a restriction gets no Settings link.
    @Test func afterADeniedSaveTheReasonFollowsTheAccess() {
        let folder = URL(fileURLWithPath: "/nonexistent")
        let files = FakeDestination(kind: .staging, folder: folder)
        let route = ImportRoute.photos(FakeDestination(kind: .photos, folder: folder), staging: files,
                                       onThisIPhone: files, stagingPlace: Harness.onThisIPhone,
                                       authorisation: { .denied })
        for access in PhotosAuthorisation.allCases {
            let after = route.afterDeniedSave(access)
            #expect(after.decision == .afterDeniedSave(authorisation: access, staging: Harness.onThisIPhone))
            #expect(after.destination.kind == .staging)
        }
        #expect(route.afterDeniedSave(.restricted).decision == .stagedHere(.photosRestricted))
        #expect(route.afterDeniedSave(.denied).decision == .stagedHere(.photosDenied))
    }

    /// A copy of `.autoupdatingCurrent` keeps following the system zone; the job's zone is fixed at the start, so a
    /// change of zone mid-job can't give Browse's items new identities (and import them twice).
    @Test func anAutoupdatingZoneIsFixedForTheJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zone-\(UUID().uuidString)")
        let engine = ImportEngine(catalogue: InMemoryCatalogue(), settings: ImportSettings(),
                                  stagingDirectory: root, clock: ManualClock(), timeZone: .autoupdatingCurrent,
                                  policy: .standard, trace: nil)
        let item = CameraItem(id: .init(rawValue: "a"), folder: "DCIM", name: "A.JPG", size: 10, captureDate: Harness.t0)
        let link = FakeCameraLink(card: [item])
        await link.setDefaultStep(.hold)
        let files = FakeDestination(kind: .staging, folder: root)
        try await engine.start(.items([item]), from: link, camera: camera, to: .staging(files, reason: .chosen, place: Harness.onThisIPhone, onThisIPhone: files))
        let zone = try #require(await engine.jobTimeZone())
        #expect(zone != TimeZone.autoupdatingCurrent) // an autoupdating zone equals only another autoupdating one
        #expect(zone == TimeZone(identifier: TimeZone.current.identifier))
        await engine.cancel()
        await link.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    @Test func identityIsWallClockInTheJobsZone() {
        let item = CameraItem(id: .init(rawValue: "x"), folder: "DCIM/100MSDCF", name: "DSC00001.ARW", size: 10,
                              captureDate: Harness.t0)
        let utc = item.identity(camera: camera, timeZone: TimeZone(identifier: "UTC")!)
        #expect(utc?.captureDate.rawValue == "20261026T073320")
        #expect(utc?.folder == "DCIM/100MSDCF")
        #expect(utc?.size == 10)
        let tokyo = item.identity(camera: camera, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(tokyo?.captureDate.rawValue == "20261026T163320")
        var undated = item
        undated.captureDate = nil
        #expect(undated.identity(camera: camera, timeZone: TimeZone(identifier: "UTC")!) == nil)
    }
}
