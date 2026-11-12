import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import Testing
@testable import AppUI

// The App Intents' plain half (I16; backlog section 5, D7 (a)): the count "How many new photos" answers with (what
// *Select All New* would pick: stills with a date, neither imported, staged nor rejected), its wording with the
// listing's age, and the import's answers. The intents themselves compile only in CI.

private let britishEnglish = Locale(identifier: "en_GB")

private var london: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    london.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite("New photo count: what Select All New would pick")
struct NewPhotoCountRuleTests {
    let camera = CameraKey(rawValue: "usb-msc-name:untitled")

    /// A card with one file in each state.
    let card = [
        item("DSC00001.JPG", at: 10),
        item("DSC00002.ARW", at: 20),
        item("DSC00003.JPG", at: 30),   // imported
        item("DSC00004.JPG", at: 40),   // staged
        item("DSC00005.JPG", at: 50),   // rejected
        item("DSC00006.JPG", at: nil),  // no capture date (D10)
        item("C0001.MP4", at: 60),      // video
        item("DSC00001.XMP", at: 10),   // sidecar
    ]

    func identity(_ name: String) -> ObjectIdentity {
        card.first { $0.name == name }!.identity(camera: camera, timeZone: .current)!
    }

    func entries(_ names: [String]) -> [CardListing.Entry] {
        names.map { name in
            CardListing.Entry(identity: identity(name), format: card.first { $0.name == name }!.format)
        }
    }

    @Test func aLiveCardCountsDatedStillsThatArentDone() {
        let done: Set<String> = ["DSC00003.JPG", "DSC00004.JPG", "DSC00005.JPG"]
        #expect(NewPhotoCount.count(card) { done.contains($0.name) } == 2)
        // Nothing done: every dated still, never the undated one, the video or the sidecar.
        #expect(NewPhotoCount.count(card) { _ in false } == 5)
        #expect(!NewPhotoCount.counts(item("DSC00006.JPG", at: nil)) { _ in false })
        #expect(NewPhotoCount.count([]) { _ in false } == 0)
    }

    /// The catalogue: DSC00003 imported (under another camera key and folder: "already imported" is by content),
    /// DSC00004 staged, DSC00005 rejected, DSC00002 kept (a Keep isn't done), and a Reject on a file not on the card.
    func seeded() async throws -> InMemoryCatalogue {
        var elsewhere = identity("DSC00003.JPG")
        elsewhere.camera = CameraKey(rawValue: "usb-mtp-name:other")
        elsewhere.folder = ""
        let catalogue = InMemoryCatalogue(records: [CatalogueRecord(identity: elsewhere, format: .jpeg, state: .imported)])
        await catalogue.markStaged(identity("DSC00004.JPG"), format: .jpeg,
                                   at: StagedLocation(root: .iCloudDrive, relativePath: "Staging/Camera/DSC00004.JPG"))
        let marked = Date(timeIntervalSince1970: 1_793_000_000)
        try await catalogue.setMark(.reject, rating: 0, for: [identity("DSC00005.JPG").contentKey], at: marked)
        try await catalogue.setMark(.keep, rating: 3, for: [identity("DSC00002.ARW").contentKey], at: marked)
        return catalogue
    }

    @Test func theLastKnownCardLeavesOutImportedStagedAndRejectedFiles() async throws {
        let catalogue = try await seeded()
        let listedAt = date(2026, 11, 12, 14, 5)
        // A saved listing keeps only dated files; the video is kept, and isn't counted.
        await catalogue.saveListing(CardListing(camera: camera, listedAt: listedAt, entries: entries([
            "DSC00001.JPG", "DSC00002.ARW", "DSC00003.JPG", "DSC00004.JPG", "DSC00005.JPG", "C0001.MP4",
        ])))
        let answer = try await NewPhotoCount.lastKnown(for: camera, in: catalogue)
        #expect(answer == .lastKnown(2, listedAt: listedAt))
        #expect(answer.count == 2)
    }

    @Test func doneKeysAreReadByContent() async throws {
        let catalogue = try await seeded()
        let identities = ["DSC00001.JPG", "DSC00002.ARW", "DSC00003.JPG", "DSC00004.JPG", "DSC00005.JPG"].map(identity)
        let done = try await NewPhotoCount.doneKeys(of: identities, in: catalogue)
        #expect(done == Set(["DSC00003.JPG", "DSC00004.JPG", "DSC00005.JPG"].map { identity($0).contentKey }))
        #expect(try await NewPhotoCount.doneKeys(of: [], in: catalogue).isEmpty)
    }

    @Test func liftingARejectMakesItNewAgain() async throws {
        let catalogue = try await seeded()
        await catalogue.saveListing(CardListing(camera: camera, listedAt: date(2026, 11, 12, 9, 0),
                                                entries: entries(["DSC00001.JPG", "DSC00005.JPG"])))
        #expect(try await NewPhotoCount.lastKnown(for: camera, in: catalogue).count == 1)
        await catalogue.clearMarks(of: [identity("DSC00005.JPG").contentKey])
        #expect(try await NewPhotoCount.lastKnown(for: camera, in: catalogue).count == 2)
    }

    @Test func aCardNeverReadSaysSo() async throws {
        #expect(try await NewPhotoCount.lastKnown(for: camera, in: InMemoryCatalogue()) == .neverRead)
        #expect(NewPhotoCountAnswer.neverRead.count == 0)
        #expect(NewPhotoCountAnswer.unavailable.count == 0)
        #expect(NewPhotoCountAnswer.live(7).count == 7)
    }

    @Test func aCatalogueThatCantBeReadThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await NewPhotoCount.lastKnown(for: camera, in: BrokenCatalogue())
        }
    }
}

@Suite("New photo count and import: what the intents say")
struct NewPhotosWordingTests {
    let now = date(2026, 11, 12, 15, 30)

    func clock(_ date: Date) -> String { HistoryWording.time(date, locale: britishEnglish, calendar: london) }

    func count(_ answer: NewPhotoCountAnswer, camera: String = "ILCE-7CM2") -> String {
        NewPhotosWording.countAnswer(answer, camera: camera, now: now, calendar: london, locale: britishEnglish)
    }

    @Test func theLastKnownCountSaysTheListingsAge() {
        #expect(count(.lastKnown(12, listedAt: date(2026, 11, 12, 14, 5)))
            == "12 new photos when the card was last read, today at 14:05.")
        // A time before 10:00 is written as the platform's clock style has it ("09:12" or "9:12").
        let morning = date(2026, 11, 11, 9, 12)
        #expect(count(.lastKnown(1, listedAt: morning))
            == "1 new photo when the card was last read, yesterday at \(clock(morning)).")
        #expect(count(.lastKnown(0, listedAt: date(2026, 11, 3, 18, 40)))
            == "No new photos when the card was last read, on 3 Nov 2026 at 18:40.")
    }

    @Test func theLiveCountNamesTheCamera() {
        #expect(count(.live(12)) == "ILCE-7CM2 has 12 new photos on its card.")
        #expect(count(.live(1)) == "ILCE-7CM2 has 1 new photo on its card.")
        #expect(count(.live(0)) == "ILCE-7CM2 has no new photos on its card.")
        #expect(count(.live(3), camera: CamerasWording.genericName) == "The camera has 3 new photos on its card.")
    }

    @Test func aCardNeverReadOrACatalogueThatCantBeReadIsSaid() {
        #expect(count(.neverRead)
            == "Shutter Bridge hasn't read the card in ILCE-7CM2 yet. Connect the camera and open it in Shutter Bridge.")
        #expect(count(.neverRead, camera: CamerasWording.genericName)
            == "Shutter Bridge hasn't read the card in this camera yet. Connect the camera and open it in Shutter Bridge.")
        #expect(count(.unavailable)
            == "Shutter Bridge couldn't read its catalogue, so it can't say how many photos are new.")
    }

    @Test func thePickerTellsTwoCamerasWithOneNameApartByLastConnected() {
        func line(_ date: Date?) -> String {
            NewPhotosWording.lastConnected(date, now: now, calendar: london, locale: britishEnglish)
        }
        #expect(line(date(2026, 11, 12, 14, 5)) == "Last connected today at 14:05")
        #expect(line(date(2026, 11, 11, 20, 0)) == "Last connected yesterday at 20:00")
        let morning = date(2026, 10, 30, 8, 15)
        #expect(line(morning) == "Last connected on 30 Oct 2026 at \(clock(morning))")
        #expect(line(nil) == "Connected now")
    }

    @Test func theImportSaysWhatStartedWithTheRememberedChoice() {
        func say(_ start: NewPhotosImportStart, camera: String = "ILCE-7CM2") -> String {
            NewPhotosWording.importAnswer(start, camera: camera)
        }
        #expect(say(.requested(.started(48), choice: .photos)) == "Importing 48 new photos to Photos.")
        #expect(say(.requested(.started(1), choice: .photos)) == "Importing 1 new photo to Photos.")
        #expect(say(.requested(.started(48), choice: .staging)) == "Staging 48 new photos.")
        #expect(say(.requested(.appended(3), choice: .photos)) == "Added 3 new photos to the import.")
        #expect(say(.requested(.appended(3), choice: .staging)) == "Added 3 new photos to staging.")
        #expect(say(.requested(.nothingNew(staging: false), choice: .photos)) == "ILCE-7CM2 has no new photos to import.")
        #expect(say(.requested(.nothingNew(staging: true), choice: .staging), camera: CamerasWording.genericName)
            == "The camera has no new photos to stage.")
        // A refusal says what Browse's notice says.
        #expect(say(.requested(.busyWithAnotherCamera, choice: .photos))
            == BrowseWording.importRequested(.busyWithAnotherCamera, choice: .photos))
        #expect(say(.waitingForCard(choice: .photos))
            == "Reading the card in ILCE-7CM2. Its new photos will be imported to Photos once it's read.")
        #expect(say(.waitingForCard(choice: .staging), camera: CamerasWording.genericName)
            == "Reading the card in the camera. Its new photos will be staged once it's read.")
        // Browse isn't reading the card: what is actually true in each case.
        #expect(say(.waitingForPerson(choice: .photos, why: .reaching))
            == "Reaching ILCE-7CM2. Its new photos will be imported to Photos once the card is read.")
        #expect(say(.waitingForPerson(choice: .staging, why: .listingFailed))
            == "Shutter Bridge couldn't read the card in ILCE-7CM2. Open Browse and tap Try Again. "
            + "Its new photos will be staged once the card is read.")
        #expect(say(.waitingForPerson(choice: .photos, why: .couldNotReach), camera: CamerasWording.genericName)
            == "Shutter Bridge couldn't reach the camera. Open Browse and tap Try Again. "
            + "Its new photos will be imported to Photos once the card is read.")
        #expect(say(.waitingForPerson(choice: .staging, why: .failedWithNoRetry))
            == "Shutter Bridge couldn't read the card in ILCE-7CM2, so its new photos won't be staged. "
            + "Open Browse to see why.")
        #expect(say(.waitingForPerson(choice: .photos, why: .failedWithNoRetry), camera: CamerasWording.genericName)
            == "Shutter Bridge couldn't read the card in the camera, so its new photos won't be imported to Photos. "
            + "Open Browse to see why.")
        #expect(say(.waitingForPerson(choice: .photos, why: .disconnected))
            == "ILCE-7CM2 is disconnected. Open Browse and tap Reconnect. "
            + "Its new photos will be imported to Photos once the card is read.")
        #expect(say(.waitingForPerson(choice: .photos, why: .disconnected), camera: CamerasWording.genericName)
            == "The camera is disconnected. Open Browse and tap Reconnect. "
            + "Its new photos will be imported to Photos once the card is read.")
        #expect(say(.starting(choice: .photos)) == "Starting to import the new photos to Photos.")
        #expect(say(.notConnected) == "ILCE-7CM2 isn't connected. Connect it, then try again.")
        #expect(say(.notConnected, camera: CamerasWording.genericName)
            == "The camera isn't connected. Connect it, then try again.")
        #expect(say(.couldNotStart) == "The import from ILCE-7CM2 didn't start. Open Browse and tap Import.")
        #expect(say(.appNotReady) == "Shutter Bridge couldn't open its catalogue. Open the app to see why.")
    }

    @Test func theLogSaysCountsAndKindsOnly() {
        #expect(AppModel.logWords(for: .requested(.started(48), choice: .photos)) == "started with 48 files to Photos")
        #expect(AppModel.logWords(for: .requested(.appended(1), choice: .staging))
            == "added 1 file to the job to stage")
        #expect(AppModel.logWords(for: .requested(.failed("serial 1234567"), choice: .photos)) == "refused by the engine")
        #expect(AppModel.logWords(for: .notConnected) == "the camera isn't connected")
        #expect(AppModel.logWords(for: .waitingForPerson(choice: .photos, why: .listingFailed))
            == "waiting: the card couldn't be read")
        #expect(AppModel.logWords(for: .waitingForPerson(choice: .photos, why: .failedWithNoRetry))
            == "waiting: the card couldn't be read, with nothing to retry")
    }
}
