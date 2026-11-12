import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit

// The App Intents' plain half (I16; backlog section 5, D7 (a)): the count "How many new photos" answers with, the
// cameras the camera picker lists, and every sentence both intents say, in British English. Pure, so it is tested on
// Linux; the intents themselves (CameraEntity.swift, ImportNewPhotosIntent.swift, NewPhotoCountIntent.swift,
// AppShortcuts.swift) sit behind `#if canImport(AppIntents)` and only CI's Xcode job compiles them.

/// What *Select all new* would pick from a card, counted for "How many new photos" (D7 (a)).
///
/// The rule is Browse's (`BrowseModel.selectAllNew()` with no filter): stills (RAW, HEIF, JPEG) with a capture date
/// that are neither imported, staged nor rejected. Staged files are left out whatever the remembered Import-button
/// choice, as *Select all new* leaves them out for either choice (decision pack, *Choices decided by Shamil on
/// 11 Nov*): the count is what "Import new photos" then hands to the import, which the engine's done rule
/// (`DoneRule`) and `ImportSelection.leavesOutRejects` apply again. Video, sidecars and files without a capture date
/// (D10) are never counted. Files, not RAW+JPEG pairs, are counted, as Browse's selection and the Import screen count
/// them.
public enum NewPhotoCount {
    /// Whether a file of a live listing counts: a still with a capture date that `isDone` (imported, staged or
    /// rejected) doesn't rule out.
    public static func counts(_ item: CameraItem, isDone: (CameraItem) -> Bool) -> Bool {
        item.format.isStill && item.captureDate != nil && !isDone(item)
    }

    /// The files of a live listing *Select all new* would pick.
    public static func count(_ items: [CameraItem], isDone: (CameraItem) -> Bool) -> Int {
        items.reduce(0) { $0 + (counts($1, isDone: isDone) ? 1 : 0) }
    }

    /// The files of a last-known listing *Select all new* would pick, given the content keys the catalogue has as
    /// imported, staged or rejected (`doneKeys(of:in:)`). A listing keeps only files with a capture date
    /// (`BrowseModel`'s `saveListing`), so none is left out for want of one.
    public static func count(_ entries: [CardListing.Entry], done: Set<ObjectIdentity.ContentKey>) -> Int {
        entries.reduce(0) { $0 + ($1.format.isStill && !done.contains($1.identity.contentKey) ? 1 : 0) }
    }

    /// The content keys among `identities` the catalogue has as imported, staged or rejected, read as Browse reads its
    /// badges: `states(of:)`, `stagedStates(of:)` and `marks(of:)` (D3's Reject rule, `RejectRule`), all by content.
    public static func doneKeys(of identities: [ObjectIdentity],
                                in store: any CatalogueStore) async throws -> Set<ObjectIdentity.ContentKey> {
        guard !identities.isEmpty else { return [] }
        let states = try await store.states(of: identities)
        let staged = try await store.stagedStates(of: identities)
        var done = RejectRule.rejected(in: try await store.marks(of: identities.map(\.contentKey)))
        for identity in identities where states[identity] == .imported || staged.contains(identity) {
            done.insert(identity.contentKey)
        }
        return done
    }

    /// The answer from the catalogue's last listing of `camera`: `.neverRead` when it has none.
    public static func lastKnown(for camera: CameraKey, in store: any CatalogueStore) async throws -> NewPhotoCountAnswer {
        guard let listing = try await store.lastListing(for: camera) else { return .neverRead }
        let stills = listing.entries.filter(\.format.isStill)
        let done = try await doneKeys(of: stills.map(\.identity), in: store)
        return .lastKnown(count(stills, done: done), listedAt: listing.listedAt)
    }
}

/// What "How many new photos" answers with (D7 (a)).
public enum NewPhotoCountAnswer: Sendable, Hashable {
    /// Counted on the live listing: a USB camera that is connected, with its card listed in Browse.
    case live(Int)
    /// Counted on the catalogue's last listing of the camera, read at `listedAt`.
    case lastKnown(Int, listedAt: Date)
    /// The camera's card has never been listed.
    case neverRead
    /// The catalogue couldn't be read (or the app couldn't open it).
    case unavailable

    /// The number for Shortcuts: 0 when there is nothing to count.
    public var count: Int {
        switch self {
        case let .live(n), let .lastKnown(n, _): n
        case .neverRead, .unavailable: 0
        }
    }
}

/// Why Browse isn't reading the card while an "Import new photos" waits for it: what the answer then says, instead of
/// "reading the card".
public enum NewPhotosCardWait: Sendable, Hashable {
    /// Over Wi-Fi: still reaching the camera (Bluetooth, the join, the session); the card isn't being read yet.
    case reaching
    /// The card couldn't be read: Browse offers Try Again.
    case listingFailed
    /// Over Wi-Fi: the camera couldn't be reached: Browse offers Try Again.
    case couldNotReach
    /// The card couldn't be read and Browse offers nothing to tap (a USB camera that couldn't be opened, whose failed
    /// state has no Try Again): the import won't start from this Browse.
    case failedWithNoRetry
    /// Over Wi-Fi: the link was lost or let go: Browse waits for the person to tap Reconnect (Shamil, 10 Nov).
    case disconnected
}

extension BrowseModel {
    /// Why this Browse isn't reading its card, when it isn't; nil while it is reading (or about to), when the card has
    /// been read, or when there is nothing to say. For "Import new photos"'s answer after its wait.
    var newPhotosCardWait: NewPhotosCardWait? {
        if interruption == .disconnected { return .disconnected }
        switch phase {
        case .connecting: return .reaching
        case .failed:
            // Try Again is only shown when it can do something (`canRetry`); without it nothing will read the card.
            guard canRetry else { return .failedWithNoRetry }
            return failedToReachCamera ? .couldNotReach : .listingFailed
        // An offline Browse (W6-absent) waits for the camera, which `waitingForConnection` says instead.
        case .reading, .listed, .listsNoFiles, .gone, .notConnected: return nil
        }
    }
}

/// What came of "Import new photos" (D7 (a)): `AppModel.importNewPhotos(cameraWith:waitingForCamera:waitingForImport:
/// answeringBy:)`.
public enum NewPhotosImportStart: Sendable, Hashable {
    /// Browse's *Import* for *Select all new* answered, for the remembered choice.
    case requested(ImportRequestOutcome, choice: DestinationKind)
    /// Browse is open on the camera, still reaching it or reading its card when the wait ended: the import starts once
    /// the card has been read.
    case waitingForCard(choice: DestinationKind)
    /// Browse is open on the camera but isn't reading its card (`why`): the import starts once the person has dealt with
    /// that (Try Again, Reconnect) and the card has been read, unless the person leaves Browse or the app first; with
    /// nothing to tap (`NewPhotosCardWait.failedWithNoRetry`) it doesn't start.
    case waitingForPerson(choice: DestinationKind, why: NewPhotosCardWait)
    /// The new files were picked and the import is being started (Photos access may be being asked for).
    case starting(choice: DestinationKind)
    /// No connected camera has this key. (Since W6-absent the app answers a camera that isn't listed with
    /// `waitingForConnection`, having opened its offline Browse.)
    case notConnected
    /// No listed camera has this key (W6-absent): its offline Browse is open, showing the last-known card when
    /// `cardRead` (otherwise saying the card hasn't been read yet), and the import starts once the camera is listed and
    /// its card read, unless the person leaves Browse or the app first.
    case waitingForConnection(choice: DestinationKind, cardRead: Bool)
    /// Browse couldn't hand the files over (its link went while the card was shown), or the request was dropped (the
    /// person left Browse or the app before the card was read).
    case couldNotStart
    /// The app's catalogue isn't open.
    case appNotReady
}

/// A camera as the intents' camera picker lists it (D7 (a)): its name and when it was last connected, keyed by its
/// catalogue key. Never the serial, which the key is a hash of where it comes from one (`CameraKey`).
public struct IntentCamera: Sendable, Hashable, Identifiable {
    public var key: CameraKey
    /// The camera's name: its catalogue name (`HistoryWording.cameraName(_:)`), or the connected camera's own name when
    /// the catalogue has none.
    public var name: String
    /// When it was last connected or listed; nil when it never was (connected now for the first time).
    public var lastConnected: Date?

    public var id: String { key.rawValue }

    public init(key: CameraKey, name: String, lastConnected: Date?) {
        self.key = key
        self.name = name
        self.lastConnected = lastConnected
    }
}

/// Everything the two intents say (D7 (a)). Counted words stay plain until the String Catalog (I17).
public enum NewPhotosWording {
    /// The intents' titles. The intents write them as literals, which the App Intents metadata is read from at build
    /// time; `AppIntentsTests` (CI) checks they match.
    public static let importTitle = "Import New Photos"
    public static let countTitle = "How Many New Photos"

    /// "12 new photos", "1 new photo", "No new photos".
    public static func newPhotos(_ n: Int) -> String {
        switch n {
        case 0: "No new photos"
        case 1: "1 new photo"
        default: "\(n) new photos"
        }
    }

    /// The camera as a sentence's subject: its name, or "The camera" for the generic name.
    static func subject(_ camera: String) -> String {
        camera == CamerasWording.genericName ? "The camera" : camera
    }

    /// When a listing was read or a camera last connected: "today at 14:05", "yesterday at 09:12", "on 3 Nov 2026 at
    /// 18:40", in the person's clock style.
    public static func age(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                           locale: Locale = .autoupdatingCurrent) -> String {
        let time = HistoryWording.time(date, locale: locale, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(date, inSameDayAs: today) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        return "on \(date.formatted(style)) at \(time)"
    }

    /// The camera picker's second line, which tells two cameras with one name apart: "Last connected today at 14:05";
    /// "Connected now" for a camera connected for the first time.
    public static func lastConnected(_ date: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent,
                                     locale: Locale = .autoupdatingCurrent) -> String {
        guard let date else { return "Connected now" }
        return "Last connected " + age(date, now: now, calendar: calendar, locale: locale)
    }

    /// "How many new photos"'s answer: "12 new photos when the card was last read, today at 14:05." from the
    /// last-known card, "ILCE-7CM2 has 12 new photos on its card." from the live one.
    public static func countAnswer(_ answer: NewPhotoCountAnswer, camera: String, now: Date,
                                   calendar: Calendar = .autoupdatingCurrent,
                                   locale: Locale = .autoupdatingCurrent) -> String {
        switch answer {
        case let .live(n):
            let photos = n == 0 ? "no new photos" : newPhotos(n)
            return "\(subject(camera)) has \(photos) on its card."
        case let .lastKnown(n, listedAt):
            return "\(newPhotos(n)) when the card was last read, "
                + "\(age(listedAt, now: now, calendar: calendar, locale: locale))."
        case .neverRead:
            return "Shutter Bridge hasn't read the card in \(camera == CamerasWording.genericName ? "this camera" : camera) "
                + "yet. Connect the camera and open it in Shutter Bridge."
        case .unavailable:
            return "Shutter Bridge couldn't read its catalogue, so it can't say how many photos are new."
        }
    }

    /// "Import new photos"'s answer: "Importing 48 new photos to Photos.", "Staging 48 new photos.", or why nothing
    /// started.
    public static func importAnswer(_ start: NewPhotosImportStart, camera: String) -> String {
        let subject = subject(camera)
        switch start {
        case let .requested(outcome, choice):
            let staging = choice == .staging
            switch outcome {
            case let .started(n):
                return staging ? "Staging \(newPhotosLower(n))." : "Importing \(newPhotosLower(n)) to Photos."
            case let .appended(n):
                return "Added \(newPhotosLower(n)) to " + (staging ? "staging." : "the import.")
            case .nothingNew:
                return "\(subject) has no new photos to " + (staging ? "stage." : "import.")
            case .busyWithAnotherCamera, .busyWithAnotherMode, .busyWithKeepers, .stillStarting, .failed:
                return BrowseWording.importRequested(outcome, choice: choice) ?? couldNotStart(subject)
            }
        case let .waitingForCard(choice):
            return "Reading the card in \(camera == CamerasWording.genericName ? "the camera" : camera). Its new photos "
                + (choice == .staging ? "will be staged" : "will be imported to Photos") + " once it's read."
        case let .waitingForPerson(choice, why):
            let name = camera == CamerasWording.genericName ? "the camera" : camera
            let then = "Its new photos " + (choice == .staging ? "will be staged" : "will be imported to Photos")
                + " once the card is read."
            switch why {
            case .reaching:
                return "Reaching \(name). \(then)"
            case .listingFailed:
                return "Shutter Bridge couldn't read the card in \(name). Open Browse and tap \(BrowseWording.tryAgain). \(then)"
            case .couldNotReach:
                return "Shutter Bridge couldn't reach \(name). Open Browse and tap \(BrowseWording.tryAgain). \(then)"
            case .failedWithNoRetry:
                return "Shutter Bridge couldn't read the card in \(name), so its new photos won't be "
                    + (choice == .staging ? "staged" : "imported to Photos") + ". Open Browse to see why."
            case .disconnected:
                return "\(subject) is disconnected. Open Browse and tap \(BrowseWording.reconnect). \(then)"
            }
        case let .starting(choice):
            return choice == .staging ? "Starting to stage the new photos." : "Starting to import the new photos to Photos."
        case .notConnected:
            return "\(subject) isn't connected. Connect it, then try again."
        case let .waitingForConnection(choice, cardRead):
            let photos = choice == .staging ? "its new photos will be staged" : "its new photos will be imported to Photos"
            return cardRead
                ? "\(subject) isn't connected. Connect it while Shutter Bridge shows its card, and \(photos)."
                : "\(subject) isn't connected, and Shutter Bridge hasn't read its card yet. Connect it while Shutter "
                    + "Bridge is open, and \(photos)."
        case .couldNotStart:
            return couldNotStart(subject)
        case .appNotReady:
            return "Shutter Bridge couldn't open its catalogue. Open the app to see why."
        }
    }

    /// "48 new photos", "1 new photo", in the middle of a sentence.
    private static func newPhotosLower(_ n: Int) -> String { n == 1 ? "1 new photo" : "\(n) new photos" }

    private static func couldNotStart(_ subject: String) -> String {
        let possessive = subject == "The camera" ? "the camera" : subject
        return "The import from \(possessive) didn't start. Open Browse and tap Import."
    }
}
