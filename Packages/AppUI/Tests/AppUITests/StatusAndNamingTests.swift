import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

// The HIG fixes of 9 Nov (docs/iteration-1-backlog.md, section 6): the camera's display name, the status notices
// (which stay, which go, what VoiceOver hears) and the Import rows' colours.

private func camera(_ name: String, _ mode: CameraMode) -> CameraDescriptor {
    CameraDescriptor(id: .init(rawValue: "c"), name: name, mode: mode)
}

@Suite("The camera's display name")
struct CameraDisplayNameTests {
    @Test func imageTransferMSCIsAlwaysCamera() {
        // In MSC discovery names the device after the card's volume, whatever it is called.
        #expect(CamerasWording.displayName(for: camera("Untitled", .usb(.massStorage))) == "Camera")
        #expect(CamerasWording.displayName(for: camera("HOLIDAY", .usb(.massStorage))) == "Camera")
        #expect(CamerasWording.displayName(for: camera("ILCE-7CM2", .usb(.massStorage))) == "Camera")
    }

    @Test func volumeDefaultsAndEmptyNamesAreCameraInAnyMode() {
        for name in ["Untitled", "untitled", "UNTITLED", "NO NAME", "No Name", "no name", "", "   ", " Untitled "] {
            #expect(CamerasWording.displayName(for: camera(name, .usb(.mtp))) == "Camera", "\(name)")
            #expect(CamerasWording.displayName(for: camera(name, .wifi(.cameraNetwork))) == "Camera", "\(name)")
        }
    }

    @Test func otherwiseTheCamerasOwnName() {
        #expect(CamerasWording.displayName(for: camera("ILCE-7CM2", .usb(.mtp))) == "ILCE-7CM2")
        #expect(CamerasWording.displayName(for: camera("ILCE-7CM2", .usb(.remoteShoot))) == "ILCE-7CM2")
        #expect(CamerasWording.displayName(for: camera(" ILCE-7CM2 ", .wifi(.cameraNetwork))) == "ILCE-7CM2")
        #expect(CamerasWording.displayName(for: camera("Untitled 2", .usb(.mtp))) == "Untitled 2")
    }

    @Test func theDisconnectNoticeUsesIt() {
        #expect(CamerasWording.disconnected(camera("Untitled", .usb(.massStorage)))
            == "The camera was disconnected. Connect it again to see its card.")
        #expect(CamerasWording.disconnected(camera("ILCE-7CM2", .usb(.mtp)))
            == "ILCE-7CM2 was disconnected. Connect it again to see its card.")
        #expect(!CamerasWording.disconnected(camera("Untitled", .usb(.massStorage))).contains("Untitled"))
    }

    @Test func newAlbumsAndFoldersAreNamedWithIt() async throws {
        let msc = ImportCamera(descriptor: camera("Untitled", .usb(.massStorage)), key: CameraKey(rawValue: "k1"))
        let mtp = ImportCamera(descriptor: camera("ILCE-7CM2", .usb(.mtp)), key: CameraKey(rawValue: "k2"))
        #expect(msc.name == "Camera")
        #expect(mtp.name == "ILCE-7CM2")

        let made = StandardImportDestinations(library: UnusedPhotoLibrary(), albumStore: InMemoryAlbumIdentifierStore(),
                                              options: PhotosImportOptions(albums: .both),
                                              documentsDirectory: URL(fileURLWithPath: "/nonexistent/Documents"),
                                              stagingLocator: FakeStagingLocator(.unavailable(.iCloudDriveOff)),
                                              iCloudDriveMover: PlainFileMover())
        let start = Date(timeIntervalSince1970: 1_762_700_000)
        let inMSC = made.destinations(for: msc, startedAt: start, staging: await made.locate())
        #expect(inMSC.stagingFolderName == "Camera")
        #expect(inMSC.stagingPlace == .onThisIPhone(.iCloudDriveOff))
        let photos = try #require(inMSC.photos as? PhotosLibraryDestination)
        let albums = photos.albumPlan.albums
        // Named and keyed by the camera's name (D11); the album an earlier build stored under the key is adopted.
        #expect(albums.first?.key == "camera-name:Camera")
        #expect(albums.first?.legacyKeys == ["camera:k1"])
        #expect(albums.first?.title == "Camera")
        #expect(albums.last?.title.hasPrefix("Camera, ") == true)
        #expect(albums.allSatisfy { !$0.title.contains("Untitled") })

        let inMTP = made.destinations(for: mtp, startedAt: start, staging: await made.locate())
        #expect(inMTP.stagingFolderName == "ILCE-7CM2")
        let mtpPhotos = try #require(inMTP.photos as? PhotosLibraryDestination)
        #expect(mtpPhotos.albumPlan.albums.first?.title == "ILCE-7CM2")
        #expect(mtpPhotos.albumPlan.albums.first?.key == "camera-name:ILCE-7CM2")
    }
}

/// A Photos library that is never reached: making destinations touches no library.
private struct UnusedPhotoLibrary: PhotoLibraryClient {
    func authorisation() async -> PhotosAuthorisation { .authorised }
    func requestReadWriteAuthorisation() async -> PhotosAuthorisation { .authorised }
    func album(withIdentifier identifier: String) async -> AlbumLookup { .missing }
    func createAlbum(titled title: String) async throws(PhotoLibraryFailure) -> String { "album" }
    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) async throws(PhotoLibraryFailure)
        -> String { "asset" }
}

@Suite("Status notices: which stay, which go, what VoiceOver hears")
struct StatusNoticeTests {
    @Test func importConfirmationsGoByThemselves() {
        for outcome in [ImportRequestOutcome.started(2), .appended(1), .nothingNew(staging: false)] {
            let notice = StatusNotice.importRequest(outcome)
            #expect(notice.tone == .info, "\(outcome)")
            #expect(notice.dismissesItself, "\(outcome)")
            #expect(notice.systemImage == "square.and.arrow.down", "\(outcome)")
            #expect(notice.text == BrowseWording.importRequested(outcome))
            #expect(notice.announcement == StatusAnnouncement(notice.text, priority: .normal))
        }
    }

    @Test func importRefusalsAndFailuresStayUntilClosed() {
        for outcome in [ImportRequestOutcome.busyWithAnotherCamera, .stillStarting, .failed("The engine said no.")] {
            let notice = StatusNotice.importRequest(outcome)
            #expect(notice.tone == .problem, "\(outcome)")
            #expect(!notice.dismissesItself, "\(outcome)")
            #expect(notice.systemImage == "exclamationmark.triangle", "\(outcome)")
            #expect(notice.dismissDelay(voiceOverRunning: false) == nil, "\(outcome)")
            #expect(notice.announcement.priority == .high, "\(outcome)")
        }
        #expect(StatusNotice.importRequest(.failed("The engine said no.")).text == "The engine said no.")
    }

    @Test func nothingGoesByItselfWhileVoiceOverRuns() {
        let confirmation = StatusNotice.importRequest(.started(3))
        #expect(confirmation.dismissDelay(voiceOverRunning: false) == .seconds(5))
        #expect(confirmation.dismissDelay(voiceOverRunning: true) == nil)
        let problem = StatusNotice.importRequest(.busyWithAnotherCamera)
        #expect(problem.dismissDelay(voiceOverRunning: false) == nil)
        #expect(problem.dismissDelay(voiceOverRunning: true) == nil)
        #expect(StatusNotice.autoDismissDelay == .seconds(5))
    }

    @Test func aProblemCanNeverGoByItself() {
        let notice = StatusNotice(text: "x", tone: .problem, systemImage: "info.circle", dismissesItself: true)
        #expect(!notice.dismissesItself)
        #expect(notice.systemImage == "exclamationmark.triangle")
    }

    @Test func copyAndShareOutcomes() throws {
        #expect(StatusNotice.jpegAction(.idle) == nil)
        let work = JPEGWork(id: 1, purpose: .copy, name: "DSC00001.ARW", stage: .fetching(written: 0, total: 10))
        #expect(StatusNotice.jpegAction(.working(work)) == nil)

        let copied = try #require(StatusNotice.jpegAction(.finished("Copied DSC00001 as a JPEG.")))
        #expect(copied.tone == .success)
        #expect(copied.dismissesItself)
        #expect(copied.systemImage == "checkmark.circle")
        #expect(copied.announcement == StatusAnnouncement("Copied DSC00001 as a JPEG."))

        let failed = try #require(StatusNotice.jpegAction(.failed("The camera didn't answer. Try again.")))
        #expect(failed.tone == .problem)
        #expect(!failed.dismissesItself)
        #expect(failed.announcement == StatusAnnouncement("The camera didn't answer. Try again.", priority: .high))

        // The share sheet opens as this appears, so it is said urgently or VoiceOver reads the sheet over it.
        let preview = try #require(StatusNotice.jpegAction(.finished(JPEGWording.sharingPreview)))
        #expect(preview.tone == .success)
        #expect(preview.announcement == StatusAnnouncement(JPEGWording.sharingPreview, priority: .high))

        // Numbered, so the same outcome twice is two notices.
        #expect(StatusNotice.jpegAction(.failed("x"), id: 1) != StatusNotice.jpegAction(.failed("x"), id: 2))
    }

    @Test func theCamerasNoticeStaysUntilTheCameraIsBackOrClosed() {
        let text = CamerasWording.disconnected(camera("Untitled", .usb(.massStorage)))
        let notice = StatusNotice.cameras(text)
        #expect(notice.tone == .info)
        #expect(!notice.dismissesItself)
        #expect(notice.systemImage == "info.circle")
        // Browse closes as this appears, so it is said urgently or VoiceOver reads the Cameras screen over it.
        #expect(notice.announcement == StatusAnnouncement(text, priority: .high))
        #expect(StatusNotice.cameras(text, id: 1) != StatusNotice.cameras(text, id: 2))
    }

    @Test func announcementPriorityDefaultsByTone() {
        #expect(StatusNotice(text: "x", tone: .info, systemImage: "info.circle", dismissesItself: true)
            .announcement.priority == .normal)
        #expect(StatusNotice(text: "x", tone: .success, systemImage: "checkmark.circle", dismissesItself: true)
            .announcement.priority == .normal)
        // A problem is always urgent, whatever is asked.
        #expect(StatusNotice(text: "x", tone: .problem, systemImage: "", dismissesItself: false,
                             announcementPriority: .normal).announcement.priority == .high)
    }
}

@Suite("Import screen announcements")
struct ImportAnnouncementTests {
    let status = "Paused: the camera was disconnected. Connect it again and the import carries on."

    func say(_ old: ImportJobState, _ new: ImportJobState, status: String? = "line",
             counts: String? = nil) -> StatusAnnouncement? {
        ImportWording.stateAnnouncement(from: old, to: new, statusLine: status, counts: counts)
    }

    @Test func theSameStateIsSaidOnce() {
        // Byte and file progress doesn't change the state, so nothing is said for it.
        #expect(say(.running, .running) == nil)
        #expect(say(.paused(.cameraRemoved), .paused(.cameraRemoved)) == nil)
        #expect(say(.finished(.completed), .finished(.completed)) == nil)
    }

    @Test func aStartingJobIsLeftToBrowsesNotice() {
        #expect(say(.idle, .running) == nil)
        #expect(say(.finished(.completed), .idle) == nil)
        #expect(say(.running, .idle) == nil)
    }

    @Test func pausesAreUrgent() {
        #expect(say(.running, .paused(.cameraRemoved), status: status) == StatusAnnouncement(status, priority: .high))
        // Every pause that needs the person, including a stall the engine has stopped retrying.
        for reason in PauseReason.allCases {
            #expect(say(.running, .paused(reason))?.priority == .high, "\(reason)")
        }
        let held = ImportProgress(filesDone: 0, filesTotal: 3, bytesDone: 0, bytesTotal: 0, state: .paused(.stalled),
                                  stallWaitsForPerson: true)
        #expect(ImportWording.stateAnnouncement(from: .init(state: .running), to: .init(held), statusLine: "line",
                                                counts: nil) == StatusAnnouncement("line", priority: .high))
        // A different pause is a different kind.
        #expect(say(.paused(.stalled), .paused(.byPerson)) == StatusAnnouncement("line", priority: .high))
    }

    @Test func anAutomaticStallRetryIsSaidPlainlyAndItsEndNotAtAll() {
        let running = ImportWording.AnnouncedState(state: .running)
        let retrying = ImportWording.AnnouncedState(ImportProgress(filesDone: 0, filesTotal: 3, bytesDone: 0,
                                                                  bytesTotal: 0, state: .paused(.stalled)))
        #expect(retrying.isAutomaticRetry)
        func say(_ old: ImportWording.AnnouncedState, _ new: ImportWording.AnnouncedState) -> StatusAnnouncement? {
            ImportWording.stateAnnouncement(from: old, to: new, statusLine: "line", counts: nil)
        }
        #expect(say(running, retrying) == StatusAnnouncement("line", priority: .normal))
        #expect(say(retrying, running) == nil)
        #expect(say(retrying, retrying) == nil)
        // The engine gives up retrying: the same pause now waits for the person, and is urgent.
        let held = ImportWording.AnnouncedState(state: .paused(.stalled), isAutomaticRetry: false)
        #expect(say(retrying, held) == StatusAnnouncement("line", priority: .high))
        #expect(say(held, running) == StatusAnnouncement("line"))
        // Only a stall is ever an automatic retry.
        func progress(_ state: ImportJobState) -> ImportProgress {
            ImportProgress(filesDone: 0, filesTotal: 1, bytesDone: 0, bytesTotal: 0, state: state)
        }
        #expect(!ImportWording.AnnouncedState(progress(.paused(.byPerson))).isAutomaticRetry)
        #expect(!ImportWording.AnnouncedState(progress(.running)).isAutomaticRetry)
        #expect(!ImportWording.AnnouncedState(state: .running, isAutomaticRetry: true).isAutomaticRetry)
    }

    @Test func carryingOnIsSaidPlainly() {
        #expect(say(.paused(.cameraRemoved), .running, status: "3 of 10 files done")
            == StatusAnnouncement("3 of 10 files done"))
    }

    @Test func finishingSaysTheCountsAndAStopIsUrgent() {
        #expect(say(.running, .finished(.completed), status: "Import finished.", counts: "3 files imported.")
            == StatusAnnouncement("Import finished. 3 files imported."))
        #expect(say(.paused(.byPerson), .finished(.cancelled), status: "Import cancelled.", counts: nil)
            == StatusAnnouncement("Import cancelled."))
        #expect(say(.running, .finished(.stopped(.phoneStorageFull)))?.priority == .high)
        #expect(say(.running, .finished(.catalogueUnavailable))?.priority == .high)
    }

    @Test func nothingToSayWithoutAStatusLine() {
        #expect(say(.running, .paused(.byPerson), status: nil) == nil)
        #expect(say(.running, .paused(.byPerson), status: "") == nil)
    }

    @Test func theLinesComeFromTheScreensWording() {
        let progress = ImportProgress(filesDone: 1, filesTotal: 3, bytesDone: 10, bytesTotal: 30,
                                      state: .paused(.cameraRemoved))
        let line = ImportWording.status(progress, mode: .massStorage)
        let said = say(.running, .paused(.cameraRemoved), status: line)
        #expect(said?.text.contains("Image Transfer (MSC)") == true)
        #expect(said?.priority == .high)
    }
}

@Suite("Import rows: the symbol carries the colour")
struct ImportRowToneTests {
    @Test func tones() {
        let raw = item("DSC00001.ARW", size: 45_600_000)
        func row(_ phase: ImportFileStatus.Phase) -> ImportRow {
            ImportRow(ImportFileStatus(id: .undated(0), item: raw, phase: phase, bytesDone: 0), going: .photos)
        }
        #expect(row(.queued).tone == .neutral)
        #expect(row(.downloading).tone == .neutral)
        #expect(row(.waitingToRetry).tone == .neutral)
        #expect(row(.committing).tone == .neutral)
        #expect(row(.notImported).tone == .neutral)
        #expect(row(.imported(nil)).tone == .done)
        #expect(row(.skipped(.noCaptureDate)).tone == .skipped)
        #expect(row(.failed(.destination(.notEnoughSpace))).tone == .failed)
        #expect(row(.skipped(.noCaptureDate)).isProblem && row(.failed(.destination(.rejected(detail: "")))).isProblem)
        #expect(!row(.imported(nil)).isProblem && !row(.queued).isProblem)
    }
}
