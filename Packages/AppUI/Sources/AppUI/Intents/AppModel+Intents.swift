import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Observation
import PhotosBridge

// What the App Intents reach in the app (I16; backlog section 5, D7 (a)), plain Swift so it is tested on Linux:
//
// - "Import new photos from <camera>" opens the app (the intent asks to run in front) and calls
//   `AppModel.importNewPhotos(cameraWith:waitingForCamera:waitingForImport:)`, which opens Browse on the camera and, once
//   its card is read, does what *Select All New* and *Import* do there, with the remembered Import-button choice
//   (Photos or Stage). Browse reaches the camera, so a Wi-Fi join only ever happens with the app in front.
// - "How many new photos" calls `AppModel.newPhotoCount(cameraWith:)`, which answers from the live card while a USB
//   camera is connected and listed in Browse, and otherwise from the catalogue's last listing, with its age. It never
//   opens a link.
// - The camera picker lists `AppModel.intentCameras()`.

/// Where the intents find the app's model (I16). The live launch sets `launcher` before launch finishes, so an intent
/// that launched the app waits for the catalogue to open rather than finding nothing.
@MainActor
public enum IntentHost {
    /// The app's launcher (`LiveLaunch.launcher`); nil until the app sets it, and in tests that don't.
    public static var launcher: AppLauncher?

    /// The app's model once its catalogue is open, waiting up to `limit` for a launch in progress; nil when there is no
    /// launcher, the catalogue didn't open, or the wait ran out.
    public static func model(waitingUpTo limit: Duration = .seconds(10)) async -> AppModel? {
        await launcher?.readyModel(waitingUpTo: limit)
    }
}

extension AppLauncher {
    /// The model once the catalogue is open: launches the app if nothing has (a failed launch is tried again once), and
    /// waits up to `limit` for a launch in progress. Nil when the catalogue didn't open or the wait ran out.
    public func readyModel(waitingUpTo limit: Duration) async -> AppModel? {
        if let model { return model }
        if case .failed = state {
            await launch()
            return model
        }
        // `launch()` does nothing while a launch runs, so this only starts one when none has begun.
        Task { await self.launch() }
        _ = await ObservedWait.until(limit) { [weak self] in
            guard let self else { return true }
            if case .opening = self.state { return false }
            return true
        }
        return model
    }
}

/// What the App Intents asked the app to do (I16), for `AppModel` and the screens.
@MainActor
@Observable
public final class AppIntentRequests {
    /// What an intent asked the screens to show, numbered so the same request twice is acted on twice: the live app
    /// shows the Cameras tab (Browse is pushed onto it when the camera is connected), closes Settings, and opens the
    /// Import sheet when `showsImport`.
    public private(set) var navigation: IntentNavigation?
    /// Goes up each time a card is listed (a camera the picker doesn't list yet may now have a catalogue row): the live
    /// app tells App Shortcuts the cameras may have changed.
    public private(set) var camerasRevision = 0

    /// The "Import new photos" waiting for its camera's card; one at a time, a newer request replacing it.
    @ObservationIgnored var pending: PendingNewPhotosImport?
    @ObservationIgnored private var navigations = 0

    public init() {}

    func navigate(showsImport: Bool) {
        navigations += 1
        navigation = IntentNavigation(id: navigations, showsImport: showsImport)
    }

    func cardListed() { camerasRevision += 1 }
}

/// What an intent asked the screens to show (`AppIntentRequests.navigation`).
public struct IntentNavigation: Sendable, Hashable {
    public let id: Int
    /// Open the Import sheet: the import started or files were added to it.
    public let showsImport: Bool
}

/// An "Import new photos" waiting for Browse to read its camera's card.
@MainActor
final class PendingNewPhotosImport {
    let camera: CameraDescriptor.ID
    let choice: DestinationKind
    /// Past it, a listing no longer starts the import: the card wasn't read in time (an MTP listing takes up to about
    /// 2 minutes, a Wi-Fi join with iOS's prompt about 1 more), and a later listing is the person's own visit.
    let expires: ContinuousClock.Instant
    private(set) var result: NewPhotosImportStart?
    /// The new files are being handed to the import.
    var isStarting = false
    private let gate = OnceGate()

    init(camera: CameraDescriptor.ID, choice: DestinationKind, expires: ContinuousClock.Instant) {
        self.camera = camera
        self.choice = choice
        self.expires = expires
    }

    func finish(_ result: NewPhotosImportStart) {
        guard self.result == nil else { return }
        self.result = result
        gate.open()
    }

    /// The result once there is one, or what is happening when `limit` has passed: starting, waiting for the card to be
    /// read, or (`notReading`, asked then) waiting for the person because Browse isn't reading it.
    func outcome(waitingUpTo limit: Duration,
                 notReading: @MainActor () -> NewPhotosCardWait? = { nil }) async -> NewPhotosImportStart {
        let gate = self.gate
        let timer = Task { @MainActor in
            try? await Task.sleep(for: limit)
            gate.open()
        }
        await gate.wait()
        timer.cancel()
        if let result { return result }
        if isStarting { return .starting(choice: choice) }
        if let why = notReading() { return .waitingForPerson(choice: choice, why: why) }
        return .waitingForCard(choice: choice)
    }
}

extension AppModel {
    /// How long an "Import new photos" waits for its camera's card before Browse stops starting it.
    static let newPhotosImportLifetime: Duration = .seconds(300)

    // MARK: - The camera picker

    /// The cameras the intents' picker lists (D7 (a)): every camera in the catalogue, most recently connected first, by
    /// its catalogue name, or by the connected camera's own name when the catalogue has none; and a connected camera the
    /// catalogue doesn't know yet. Two cameras with one name are told apart by when each was last connected.
    public func intentCameras() async -> [IntentCamera] {
        let records = (try? await catalogue.cameras()) ?? []
        var connectedNames: [CameraKey: String] = [:]
        var connectedOrder: [CameraKey] = []
        for (camera, key) in await connectedKeys() where connectedNames[key] == nil {
            connectedNames[key] = CamerasWording.displayName(for: camera)
            connectedOrder.append(key)
        }
        var listed = records.map { record in
            let stored = HistoryWording.cameraName(record)
            let name = stored == CamerasWording.genericName ? connectedNames[record.key] ?? stored : stored
            return IntentCamera(key: record.key, name: name,
                                lastConnected: record.lastSeen == .distantPast ? nil : record.lastSeen)
        }
        let known = Set(records.map(\.key))
        for key in connectedOrder where !known.contains(key) {
            listed.append(IntentCamera(key: key, name: connectedNames[key] ?? CamerasWording.genericName,
                                       lastConnected: nil))
        }
        return listed
    }

    /// The listed cameras whose key is known without opening anything: by discovery for a Wi-Fi camera that has
    /// connected before, from the link over USB (nothing is opened). A Wi-Fi camera with no key yet has never connected.
    private func connectedKeys() async -> [(CameraDescriptor, CameraKey)] {
        var keys: [(CameraDescriptor, CameraKey)] = []
        for camera in cameras.cameras {
            if let known = await discovery.knownKey(for: camera.id) {
                keys.append((camera, known))
            } else if camera.carrier != .wifi, let link = try? await discovery.cameraLink(for: camera.id) {
                keys.append((camera, await cameraKeying(camera, link)))
            }
        }
        return keys
    }

    // MARK: - How many new photos

    /// "How many new photos" (D7 (a)): from the live card while a USB camera with this key is connected and its card
    /// listed in Browse (the badges read again first), otherwise from the catalogue's last listing with its age. Opens
    /// nothing. It counts after the launch pass (`runLaunchPass()`, I15), which the app starts as it launches and this
    /// joins: an intent that launched the app after a kill between a commit and its catalogue write would otherwise
    /// count the photo the pass is about to find in Photos as new, one more than *Import new photos* then picks.
    public func newPhotoCount(cameraWith key: CameraKey) async -> NewPhotoCountAnswer {
        await runLaunchPass()
        for browse in cameras.liveBrowses().reversed() where browse.camera.carrier == .usb && browse.liveCardKey == key {
            await browse.refreshImportedStates()
            guard let count = browse.liveNewPhotoCount else { continue }
            log.note("intents: new photo count from the live card: \(count)")
            return .live(count)
        }
        do {
            let answer = try await NewPhotoCount.lastKnown(for: key, in: catalogue)
            switch answer {
            case let .lastKnown(count, _): log.note("intents: new photo count from the last-known card: \(count)")
            case .neverRead: log.note("intents: new photo count: the card was never read")
            case .live, .unavailable: break
            }
            return answer
        } catch {
            log.note("intents: new photo count: catalogue error (\(type(of: error)))")
            return .unavailable
        }
    }

    // MARK: - Import new photos

    /// "Import new photos from <camera>" (D7 (a)), with the app in front: finds the camera among those listed (waiting up
    /// to `waitingForCamera` for discovery, which starts as the app becomes active), opens Browse on it, and once its
    /// card is read does what *Select All New* then *Import* do there, with the remembered Import-button choice: Photos
    /// access is asked for in the app as *Import* asks it. Answers once that has started, or after `waitingForImport`
    /// with what is still happening (the import then starts when the card is read, unless the person leaves Browse or
    /// the app first, or `newPhotosImportLifetime` passes). A camera that isn't listed is answered at once as not
    /// connected, with the Cameras tab shown.
    public func importNewPhotos(cameraWith key: CameraKey, waitingForCamera: Duration = .seconds(10),
                                waitingForImport: Duration = .seconds(20)) async -> NewPhotosImportStart {
        guard let camera = await listedCamera(withKey: key, waitingUpTo: waitingForCamera) else {
            log.note("intents: import new photos: the camera isn't connected")
            intents.navigate(showsImport: false)
            return .notConnected
        }
        let request = PendingNewPhotosImport(camera: camera.id, choice: importer.importChoice,
                                             expires: .now.advanced(by: Self.newPhotosImportLifetime))
        if let replaced = intents.pending {
            log.note("intents: import new photos dropped: a newer request replaced it")
            replaced.finish(.couldNotStart)
        }
        intents.pending = request
        let shown = cameras.path.last == camera
        if !shown { cameras.path = [camera] }
        intents.navigate(showsImport: false)
        // Browse already shows the live card: nothing more will be listed, so the import starts now.
        if shown, let browse = cameras.liveBrowses().last(where: { $0.camera.id == camera.id }) {
            browseListed(browse)
        } else {
            log.note("intents: import new photos: waiting for the card")
        }
        return await request.outcome(waitingUpTo: waitingForImport) { [weak self] in
            self?.cameras.browses(of: camera.id).last?.newPhotosCardWait
        }
    }

    /// The listed camera whose catalogue key is `key`, waiting up to `limit` for it to be listed.
    private func listedCamera(withKey key: CameraKey, waitingUpTo limit: Duration) async -> CameraDescriptor? {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while true {
            let shown = cameras.cameras
            for camera in shown where await isCamera(camera, withKey: key) { return camera }
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { return nil }
            let cameras = self.cameras
            guard await ObservedWait.until(left, { cameras.cameras != shown }) else { return nil }
        }
    }

    /// The navigation stack changed: a waiting "Import new photos" whose camera is no longer shown is dropped now, not
    /// at the next listing, so coming back to the camera later is the person's own visit and starts nothing.
    func browsePathChanged(_ path: [CameraDescriptor]) {
        guard let request = intents.pending, path.last?.id != request.camera else { return }
        dropPendingNewPhotosImport(because: "Browse was left")
    }

    /// Drops the waiting "Import new photos", if any: its answer is that it couldn't start.
    func dropPendingNewPhotosImport(because reason: String) {
        guard let request = intents.pending else { return }
        intents.pending = nil
        log.note("intents: import new photos dropped: \(reason)")
        request.finish(.couldNotStart)
    }

    /// A Browse model listed its camera's live card (`CamerasModel.onBrowseListed`): the waiting "Import new photos"
    /// for that camera starts, if it still applies.
    func browseListed(_ browse: BrowseModel) {
        intents.cardListed()
        guard let request = intents.pending, request.camera == browse.camera.id else { return }
        intents.pending = nil
        let reason: String? = if importer.isAway {
            "the app is in the background"
        } else if cameras.path.last?.id != browse.camera.id {
            "Browse was left"
        } else if ContinuousClock.now >= request.expires {
            "the card took too long to read"
        } else {
            nil
        }
        if let reason {
            log.note("intents: import new photos dropped: \(reason)")
            request.finish(.couldNotStart)
            return
        }
        request.isStarting = true
        Task { @MainActor [weak self] in
            let remembered = self?.importer.importChoice ?? request.choice
            let outcome = await browse.importAllNew()
            guard let self else {
                request.finish(outcome.map { .requested($0, choice: remembered) } ?? .couldNotStart)
                return
            }
            let result: NewPhotosImportStart = outcome.map {
                .requested($0, choice: self.destinationUsed(by: $0, remembered: remembered))
            } ?? .couldNotStart
            request.finish(result)
            self.log.note("intents: import new photos: \(Self.logWords(for: result))")
            switch outcome {
            case .started?, .appended?: intents.navigate(showsImport: true)
            default: break
            }
        }
    }

    /// Where the files of an import request actually go, for the answer: an *Import to Photos* stages when Photos access
    /// is off (decision 9), and then it says "Staging", not "to Photos".
    private func destinationUsed(by outcome: ImportRequestOutcome, remembered: DestinationKind) -> DestinationKind {
        switch outcome {
        case .started, .appended:
            if case .staging? = importer.progress.destination { return .staging }
            return remembered
        case let .nothingNew(staging):
            return staging ? .staging : remembered
        case .busyWithAnotherCamera, .busyWithAnotherMode, .busyWithKeepers, .stillStarting, .failed:
            return remembered
        }
    }

    /// The log's words for a result: counts and kinds only.
    nonisolated static func logWords(for result: NewPhotosImportStart) -> String {
        switch result {
        case let .requested(outcome, choice):
            let to = choice == .staging ? "to stage" : "to Photos"
            return switch outcome {
            case let .started(n): "started with \(n) file\(n == 1 ? "" : "s") \(to)"
            case let .appended(n): "added \(n) file\(n == 1 ? "" : "s") to the job \(to)"
            case .nothingNew: "nothing new \(to)"
            case .busyWithAnotherCamera: "refused: another camera's job runs"
            case .busyWithAnotherMode: "refused: a job of the other kind runs"
            case .busyWithKeepers: "refused: Import keepers runs"
            case .stillStarting: "refused: a job is starting"
            case .failed: "refused by the engine"
            }
        case .waitingForCard: return "waiting for the card"
        case let .waitingForPerson(_, why):
            return switch why {
            case .reaching: "waiting: still reaching the camera"
            case .listingFailed: "waiting: the card couldn't be read"
            case .couldNotReach: "waiting: the camera couldn't be reached"
            case .disconnected: "waiting: the camera is disconnected"
            }
        case .starting: return "starting"
        case .notConnected: return "the camera isn't connected"
        case .couldNotStart: return "Browse couldn't hand the files over"
        case .appNotReady: return "the catalogue isn't open"
        }
    }
}

extension BrowseModel {
    /// What *Select All New* then *Import* do, for "Import new photos" (I16): the filters cleared, so every new file on
    /// the card is picked rather than those shown, and any selection the person had made replaced. With nothing new it
    /// leaves the selecting mode and answers *nothing new* for the remembered choice; nil when Browse couldn't hand the
    /// files over (its link went, or an Import was being handed over).
    func importAllNew() async -> ImportRequestOutcome? {
        if filter.isActive { filter = .none }
        clearSelection()
        selectAllNew()
        guard !selection.isEmpty else {
            isSelecting = false
            return .nothingNew(staging: importChoice == .staging)
        }
        return await importSelected()
    }
}

/// Waits on the main actor for an observable condition, with a bound.
@MainActor
enum ObservedWait {
    /// Waits until `condition` holds, checking it again each time an observable value it read changes, for up to
    /// `limit`. Returns whether it held.
    static func until(_ limit: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while true {
            let gate = OnceGate()
            let holds = withObservationTracking {
                condition()
            } onChange: {
                Task { @MainActor in gate.open() }
            }
            if holds { return true }
            guard ContinuousClock.now < deadline else { return false }
            let timer = Task { @MainActor in
                try? await Task.sleep(until: deadline, clock: .continuous)
                gate.open()
            }
            await gate.wait()
            timer.cancel()
        }
    }
}

/// Opens once; every wait before or after returns once it has.
@MainActor
final class OnceGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
