import CameraTransport
import Catalogue
import Foundation
import Observation
import PhotosBridge

/// One *Copy as JPEG* or *Share as JPEG…* in progress.
public struct JPEGWork: Sendable, Hashable {
    public var id: Int
    public var purpose: JPEGPurpose
    /// The file pressed.
    public var name: String
    public var stage: JPEGStage
    public var cancelling = false

    /// The fetch's fraction done, when the link reports bytes; nil while converting or with no size.
    public var fraction: Double? {
        guard case let .fetching(written, total) = stage, total > 0 else { return nil }
        return min(1, Double(written) / Double(total))
    }

    public var statusLine: String {
        cancelling ? JPEGWording.cancelling : JPEGWording.working(name: name, stage: stage)
    }
}

/// The action strip's state.
public enum JPEGActionState: Sendable, Hashable {
    case idle
    case working(JPEGWork)
    /// A confirmation, or the fallback note.
    case finished(String)
    case failed(String)

    public var isWorking: Bool {
        if case .working = self { true } else { false }
    }
}

/// A JPEG waiting for the share sheet. Its folder is removed when the sheet closes (`BrowseModel.shareFinished()`).
public struct JPEGShare: Sendable, Hashable, Identifiable {
    public var id: Int
    public var url: URL
    public var folder: JPEGScratch.ActionFolder
}

/// What Browse reads from the catalogue (backlog section 6): the last-known card and the already-imported badge.
public struct BrowseCatalogue: Sendable {
    public var store: any CatalogueStore
    /// The camera's key, worked out once the link is in hand (`CameraKeys`).
    public var cameraKey: CameraKeying
    /// The camera's key when it is known before the link is open (`CameraDiscovery.knownKey(for:)`: a Wi-Fi camera that
    /// has connected before), so the last-known card shows while the join and the session open. Nil, the default,
    /// shows it once the link is in hand (USB, where opening is quick).
    public var knownKey: (@Sendable () async -> CameraKey?)?

    public init(store: any CatalogueStore, cameraKey: @escaping CameraKeying,
                knownKey: (@Sendable () async -> CameraKey?)? = nil) {
        self.store = store
        self.cameraKey = cameraKey
        self.knownKey = knownKey
    }
}

/// The Browse screen's model (backlog section 6): opens the link, shows the last-known card from the catalogue at
/// once (marked as last-known) while the card is read with the measured expectations, replaces it with the live
/// listing and saves that, shows the card newest first by day with the Imported and Staged badges, filters it (new
/// only, type, date range), selects (one by one, or *Select all new*) with the sticky bar's count and size, hands the
/// selection to the import as *Import to Photos* or *Stage* (the Import button's menu; Shamil, 11 Nov), fetches
/// thumbnails through the link, and runs *Copy as JPEG* and *Share as JPEG…*.
///
/// The screen's `.task` calls `run()`, which holds the link (`LinkLeases`) until the task is cancelled (the screen
/// went away) and then lets go of it; the link closes unless an import still uses it.
///
/// **Over Wi-Fi the link can go while the screen stays** (bench 19.1, 9 Nov). Opening it is the join, so the screen says
/// it is connecting (`Phase.connecting`) until the link is in hand, and only then reads the card. When the camera's session
/// is lost with the app in front and nothing else holds the link, Browse reopens the same link and lists again, reusing
/// what it knows (`ReusingListing`). When the link is let go (the app went to the background with Browse open and no
/// import: the phone leaves the camera's network) or can't be reopened, the card stays on screen with a strip saying so
/// and Reconnect (`interruption`); only Reconnect prepares a new link, through `openLink`, and the selection and the
/// thumbnails already fetched are kept. A failed open (a join that needed the app in front among them) offers Try Again.
/// Coming back to the app reconnects nothing by itself (Shamil, 10 Nov): the strip or the failed state stays until the
/// person taps. Over USB none of this applies: Browse behaves as it always has.
@MainActor
@Observable
public final class BrowseModel {
    public enum Phase: Sendable, Hashable {
        /// Over Wi-Fi: reaching the camera (Bluetooth, the join, the session), since `since`. The card isn't being read
        /// yet; `reading` follows once the link is in hand.
        case connecting(since: Date)
        /// Opening the link and waiting for ImageCaptureCore's catalogue (over Wi-Fi: listing the card), since `since`.
        case reading(since: Date)
        case listed
        /// The catalogue completed at once with no files: Remote Shoot (PC Remote), or an empty card in MTP.
        case listsNoFiles
        case failed(String)
        /// The camera went away; the Cameras screen takes over.
        case gone
    }

    /// The link went away under a card that is still shown (Wi-Fi): what the strip above the card says.
    public enum Interruption: Sendable, Hashable {
        /// Getting the link back: the same link reopened after its session was lost, or a new one prepared.
        case reconnecting
        /// The link was let go or lost and isn't back: Reconnect prepares a new one.
        case disconnected
    }

    /// Why a file can't be selected.
    public enum SelectionBlock: Sendable, Hashable {
        case video
        case notAPhoto
        /// No capture date, so no identity: the engine can't import it yet (backlog section 3).
        case noCaptureDate
        /// The card isn't read yet (the last-known card, or still reading).
        case cardNotRead
    }

    public let camera: CameraDescriptor
    public private(set) var phase: Phase {
        didSet { if !waitsForLink { resumeThumbnailWaiters() } }
    }
    /// Set while the link has gone under a shown card (Wi-Fi only); nil when there is nothing to say.
    public private(set) var interruption: Interruption? {
        didSet { if !waitsForLink { resumeThumbnailWaiters() } }
    }
    /// Why the last reconnect failed, with its next step, under the disconnected strip (Wi-Fi: the discovery's failure
    /// text); nil when there is none.
    public private(set) var interruptionDetail: String?
    /// Goes up each time a link has listed the card, so a cell still without a thumbnail asks again on the new link (the
    /// cell's task is keyed by it, `ThumbnailTaskID`).
    public private(set) var linkGeneration = 0
    /// True after a failed open over Wi-Fi, while Try Again would prepare the link again (`retry()`).
    public private(set) var canReopen = false
    /// The card as the grid shows it: filtered, by day, newest first.
    public private(set) var sections: [CardSection] = []
    /// When the shown card was listed, while it is the catalogue's last-known card rather than the live one; nil
    /// once the live listing has replaced it (or when there was none).
    public private(set) var lastKnownListedAt: Date?
    /// The files the catalogue has as imported, for the badge: by name, capture time (to the second) and size, from
    /// either USB mode and under any camera key or folder (Shamil's rule of 8 Nov, `ObjectIdentity.ContentKey`), as
    /// the engine skips them. Read after each listing, on the last-known card, and each time the import imports more
    /// files while Browse is shown (`BrowseImporting.importedUpdates()`).
    public private(set) var imported: Set<CameraItem.ID> = []
    /// The files the catalogue has a staged copy of (Shamil, 11 Nov), for the Staged badge: matched by content, as
    /// `imported` is, and read with it.
    public private(set) var staged: Set<CameraItem.ID> = []
    /// The picked files, which the sticky bar counts and Import hands over.
    public private(set) var selection: Set<CameraItem.ID> = [] {
        didSet { if !allNewPicks.isSubset(of: selection) { allNewPicks.formIntersection(selection) } }
    }
    /// Of `selection`, the files *Select All New* picked: when every selected file is one of them, the import is
    /// told only new files were asked for, so a stage job also leaves out files imported meanwhile.
    @ObservationIgnored private var allNewPicks: Set<CameraItem.ID> = []
    /// The selecting mode of the grid: taps select instead of opening anything. Leaving it clears the selection, so
    /// the screen hides Back while selecting (a stray tap would throw a hand-built selection away).
    public var isSelecting = false {
        didSet { if !isSelecting { selection = [] } }
    }
    /// What the grid shows of the card.
    public var filter = BrowseFilter() {
        didSet { if filter != oldValue { rebuildSections() } }
    }
    /// True while Import is handing the selection over (Photos may be asking).
    public private(set) var isStartingImport = false
    /// What came of the last Import tap, for a strip at the top: a confirmation that goes by itself, or a refusal or
    /// failure that stays until it is closed (`StatusNotice.importRequest(_:id:)`); cleared with
    /// `dismissImportNotice()`.
    public private(set) var importStatus: StatusNotice?
    /// The import notice's text.
    public var importNotice: String? { importStatus?.text }
    public private(set) var action: JPEGActionState = .idle {
        didSet {
            switch action {
            case .finished, .failed: actionOutcomeCount += 1
            case .idle, .working: break
            }
        }
    }
    /// The action's confirmation (goes by itself) or error (stays until closed), for the strip at the top. Numbered,
    /// so the same error twice in a row (with no work in between) is a new notice, announced again.
    public var actionNotice: StatusNotice? { StatusNotice.jpegAction(action, id: actionOutcomeCount) }
    /// Set when a JPEG is ready to share; the screen presents the share sheet and calls `shareFinished()`.
    public private(set) var share: JPEGShare?

    @ObservationIgnored private let openLink: @Sendable () async throws(CameraLinkFailure) -> any CameraLink
    @ObservationIgnored private let services: BrowseServices
    @ObservationIgnored private let catalogue: BrowseCatalogue?
    @ObservationIgnored private weak var importer: (any BrowseImporting)?
    @ObservationIgnored private let leases: LinkLeases
    /// The card shown: the live listing, or the last-known one while the card is read.
    @ObservationIgnored private var items: [CameraItem] = []
    @ObservationIgnored private var itemsByID: [CameraItem.ID: CameraItem] = [:]
    @ObservationIgnored private var cameraKey: CameraKey?
    /// The zone identities are made in for this screen (fixed when the link opens, as the engine fixes its own per
    /// job), so Browse's badges follow the engine's rule.
    @ObservationIgnored private var zone = TimeZone.current
    @ObservationIgnored private let openFailureText: (@Sendable () async -> String?)?
    @ObservationIgnored private let openWasDeclined: (@Sendable () async -> Bool)?
    @ObservationIgnored private let onGone: @MainActor (CameraDescriptor.ID) -> Void
    @ObservationIgnored private let onDeclined: @MainActor (CameraDescriptor.ID) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var link: (any CameraLink)?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rule = JPEGSourceRule(listing: [])
    @ObservationIgnored private var thumbnails: [CameraItem.ID: Data] = [:]
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var actionCount = 0
    /// Counts the action's outcomes (`actionNotice`'s id).
    private var actionOutcomeCount = 0
    @ObservationIgnored private var importNoticeCount = 0
    /// Said instead of nothing when the action in progress ends as cancelled, because the app cancelled it.
    @ObservationIgnored private var cancelMessage: String?
    /// Badge reads started and applied, so a read that answers after a newer one is dropped.
    @ObservationIgnored private var badgeReadsStarted = 0
    @ObservationIgnored private var badgeReadsApplied = 0
    @ObservationIgnored private let keyTags: CameraKeyTags
    // The link going away (Wi-Fi).
    /// Whether the app is in front, as `scenePhaseChanged(_:)` last said: a session lost in front reopens the same link,
    /// one lost away lets it go.
    @ObservationIgnored private var inForeground = true
    /// Reconnect or Try Again was tapped while Browse waits to prepare the link again.
    @ObservationIgnored private var reopenTapped = false
    @ObservationIgnored private var reopenWaiter: CheckedContinuation<Void, Never>?
    /// Why the latest hold of a link ended, for the log.
    @ObservationIgnored private var linkEnd: LinkEnd = .eventsFinished
    /// When the card was last listed on a link, for the log.
    @ObservationIgnored private var listedAt: ContinuousClock.Instant?
    /// The last open failed (rather than a listing): the failed state's title says the camera couldn't be reached.
    @ObservationIgnored private var openFailed = false
    // Thumbnails.
    /// Over Wi-Fi, files whose thumbnail this link refused (`unreadableItem`, `itemNotFound`): not asked again until the
    /// next link lists the card (`listed(_:seconds:)` forgets them). Over USB nothing is kept: a cell asks again, as before.
    @ObservationIgnored private var thumbnailRefused: Set<CameraItem.ID> = []
    @ObservationIgnored private var thumbnailWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var nextThumbnailWaiter = 0
    @ObservationIgnored private var tally = ThumbnailTally()
    @ObservationIgnored private var undecodable: Set<CameraItem.ID> = []

    /// - Parameters:
    ///   - catalogue: The last-known card and the already-imported badge; without it Browse shows neither.
    ///   - importer: Where Import hands the selection (the app's `ImportModel`, held weakly); without it Import does
    ///     nothing.
    ///   - leases: Shared with the import, so leaving Browse doesn't close a link a job still uses. A fresh one (the
    ///     default) closes the link when Browse goes.
    ///   - openFailureText: Asked when opening the link failed: a line that says why and what to do next, for a camera
    ///     whose discovery knows more than the failure's kind (a Wi-Fi camera: `CameraDiscovery.openFailureText`).
    ///     Nil, or a nil answer, shows the kind's own wording.
    ///   - openWasDeclined: Asked when opening the link failed: true when the person chose not to continue (Not Now on the
    ///     Local Network explanation), so `onDeclined` closes the screen with no notice instead of `onGone`'s.
    public init(
        camera: CameraDescriptor,
        openLink: @escaping @Sendable () async throws(CameraLinkFailure) -> any CameraLink,
        services: BrowseServices,
        openFailureText: (@Sendable () async -> String?)? = nil,
        openWasDeclined: (@Sendable () async -> Bool)? = nil,
        onGone: @escaping @MainActor (CameraDescriptor.ID) -> Void,
        onDeclined: @escaping @MainActor (CameraDescriptor.ID) -> Void = { _ in },
        catalogue: BrowseCatalogue? = nil,
        importer: (any BrowseImporting)? = nil,
        leases: LinkLeases = LinkLeases(),
        keyTags: CameraKeyTags = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.keyTags = keyTags
        self.camera = camera
        self.openLink = openLink
        self.services = services
        self.openFailureText = openFailureText
        self.openWasDeclined = openWasDeclined
        self.onGone = onGone
        self.onDeclined = onDeclined
        self.catalogue = catalogue
        self.importer = importer
        self.leases = leases
        self.now = now
        self.calendar = calendar
        phase = camera.carrier == .wifi ? .connecting(since: now()) : .reading(since: now())
    }

    // MARK: - Lifecycle

    /// Why a hold of a link ended, for the log.
    enum LinkEnd: String, Sendable {
        /// The link's events finished: it was closed (a leave in the background, or the session let it go).
        case eventsFinished = "events finished"
        /// Its session was lost and couldn't be reopened, or was lost with the app away.
        case sessionLost
        /// Listing again on a reconnected link failed.
        case relistFailed = "relist failed"
    }

    /// How an attempt to open and hold a link ended.
    private enum Attempt {
        /// The screen went, the camera went away, or (USB) the link's events ended: nothing more to do.
        case stopped
        /// Opening failed and the failed state is shown.
        case openFailed
        /// The link ended under the screen (or a reconnect didn't get one).
        case linkEnded
    }

    /// Whether this screen's link can come back while the screen stays: Wi-Fi only (USB behaves as it always has).
    private var reconnects: Bool { camera.carrier == .wifi }

    /// Opens the link, shows the last-known card, lists the card, and follows the link's events and the import's
    /// "more files imported" (refreshing the badges on each) until the calling task is cancelled or the link's events
    /// end, then lets go of the link (closing it unless an import holds it). Over Wi-Fi it then waits, with the card
    /// still shown, for Reconnect or Try Again (never for the app's return alone), and holds the next link the same way,
    /// until the calling task is cancelled. A second call while one runs does nothing.
    public func run() async {
        guard !isRunning, phase != .gone else { return }
        isRunning = true
        defer {
            isRunning = false
            canReopen = false
            resumeThumbnailWaiters()
            logThumbnails(Task.isCancelled ? "the screen went" : "Browse stopped")
        }
        zone = TimeZone(identifier: TimeZone.current.identifier) ?? TimeZone.current
        // Where staging goes, for the Import menu's wording; not waited for (finding the iCloud folder can take a moment).
        Task { [weak self] in await self?.refreshStagingPlace() }
        var reconnecting = false
        while !Task.isCancelled, phase != .gone {
            switch await attempt(reconnecting: reconnecting) {
            case .stopped:
                return
            case .openFailed:
                guard reconnects, phase != .gone else { return }
                canReopen = true
            case .linkEnded:
                guard reconnects, !Task.isCancelled, phase != .gone else { return }
                if case .failed = phase { canReopen = true }
            }
            guard let why = await waitToReopen() else { return }
            canReopen = false
            reconnecting = showsListedCard
            if reconnecting { interruptionDetail = nil }
            services.log.note("browse: \(reconnecting ? "reconnecting" : "opening again") (\(why))")
        }
    }

    /// Whether the live card is on screen (as opposed to the last-known card, a failure or nothing).
    private var showsListedCard: Bool { phase == .listed && lastKnownListedAt == nil }

    /// One open of the link and its hold. `reconnecting`: the live card is on screen and stays while a new link is
    /// prepared and the card listed again; otherwise the screen connects (Wi-Fi) or reads (USB) from the start.
    private func attempt(reconnecting: Bool) async -> Attempt {
        let started = ContinuousClock.now
        var shownEarlyFor: CameraKey?
        if reconnecting {
            interruption = .reconnecting
        } else {
            openFailed = false
            phase = reconnects ? .connecting(since: now()) : .reading(since: now())
            // Over Wi-Fi opening the link is the join, tens of seconds: the camera's last-known card shows meanwhile
            // (B:101), under the key the catalogue already has for it.
            if let catalogue, let early = await catalogue.knownKey?() {
                cameraKey = early
                await showLastKnown(for: early, from: catalogue.store)
                if lastKnownListedAt != nil { shownEarlyFor = early }
            }
        }
        let link: any CameraLink
        do throws(CameraLinkFailure) {
            link = try await openLink()
        } catch {
            if reconnecting {
                guard !Task.isCancelled else { return .stopped }
                services.log.note("browse: reconnecting failed after \(Self.seconds(since: started)) s: \(error)")
                interruptionDetail = await openFailureText?()
                interruption = .disconnected
                return .linkEnded
            }
            if shownEarlyFor != nil { clearLastKnown() }
            guard !Task.isCancelled else { return .stopped }
            if await openWasDeclined?() == true {
                // The person chose not to continue: back to Cameras, with nothing said.
                phase = .gone
                onDeclined(camera.id)
                return .stopped
            }
            openFailed = true
            listingFailed(error, text: await openFailureText?())
            return phase == .gone ? .stopped : .openFailed
        }
        self.link = link
        leases.acquire(link)
        // The card is read from now on: the time so far starts here, not at the join (bench 19.1).
        if case .connecting = phase { phase = .reading(since: now()) }
        await adoptKey(of: link, shownEarlyFor: shownEarlyFor, reconnecting: reconnecting)
        if reconnecting {
            services.log.note("browse: reconnected: a link in \(Self.seconds(since: started)) s; listing again")
        }
        let events = link.events
        // Subscribed before the listing, so an import that finishes while the card is read is still noticed.
        let imports = importer?.importedUpdates()
        linkEnd = .eventsFinished
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // The import's updates never end by themselves: they stop with the link's events.
                await withTaskGroup(of: Bool.self) { followers in
                    followers.addTask { await self.follow(events, of: link); return true }
                    if let imports {
                        followers.addTask { await self.followImports(imports); return false }
                    }
                    while let eventsEnded = await followers.next() {
                        if eventsEnded { followers.cancelAll() }
                    }
                }
                return true
            }
            group.addTask { await self.load(link, relisting: reconnecting) }
            // A failed relist ends the hold: the card stays, and the next link is prepared afresh.
            while let keepHolding = await group.next() {
                if !keepHolding { group.cancelAll() }
            }
        }
        // The screen went away (or the link ended): nothing more is asked of this link.
        loadTask?.cancel()
        loadTask = nil
        actionTask?.cancel()
        self.link = nil
        let screenGone = Task.isCancelled
        if screenGone {
            services.log.note("browse: the screen went; letting go of the link after \(Self.seconds(since: started)) s")
        } else {
            let after = listedAt.map { "\(Self.seconds(since: $0)) s after listing" } ?? "before listing"
            services.log.note("browse: the link ended under the screen (\(linkEnd.rawValue)) \(after), phase "
                + "\(phaseWord), thumbnails ok \(tally.ok)")
            logThumbnails("the link changed")
        }
        await leases.release(link)
        guard !screenGone, reconnects, phase != .gone else { return .stopped }
        if showsListedCard, interruption != .disconnected {
            interruption = .disconnected
        }
        return .linkEnded
    }

    /// The camera's key for the link, worked out once it is in hand (and again for a reconnected link, which also tells the
    /// reminder's connection hold which camera the new link is).
    private func adoptKey(of link: any CameraLink, shownEarlyFor: CameraKey?, reconnecting: Bool) async {
        guard let catalogue else { return }
        let key = await catalogue.cameraKey(camera, link)
        if CameraKeys.isUnidentifiedWiFi(key) {
            // A Wi-Fi camera that gave no serial and has no key of its own: every one would share this key, so nothing
            // is listed, saved or imported under it.
            cameraKey = nil
            if shownEarlyFor != nil { clearLastKnown() }
            services.log.note("browse: the camera has no key of its own, so nothing is saved or imported")
        } else {
            cameraKey = key
            guard !reconnecting else { return }
            // Another camera answered than the one whose card is shown: its card is not this one's.
            if let shown = shownEarlyFor, shown != key { clearLastKnown() }
            await showLastKnown(for: key, from: catalogue.store)
        }
    }

    /// Waits, over Wi-Fi, for a reason to prepare the link again: Reconnect or Try Again, and nothing else (a return to the
    /// front reconnects nothing by itself, Shamil 10 Nov). Nil when the calling task is cancelled.
    private func waitToReopen() async -> String? {
        while true {
            if Task.isCancelled { return nil }
            if reopenTapped {
                reopenTapped = false
                return interruption == .disconnected ? "Reconnect" : "Try Again"
            }
            await nextReopenWake()
        }
    }

    /// Parks until `wakeReopen()` or the calling task's cancellation, whichever comes first.
    private func nextReopenWake() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    reopenWaiter?.resume()
                    reopenWaiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.wakeReopen() }
        }
    }

    private func wakeReopen() {
        reopenWaiter?.resume()
        reopenWaiter = nil
    }

    /// The app's scene changed (`AppModel.scenePhaseChanged(_:)`): Browse only notes whether it is in front, so a Wi-Fi
    /// session lost away lets the link go instead of reopening it. The way back to the front reconnects nothing by itself:
    /// the disconnected strip's Reconnect, or the failed state's Try Again, does (Shamil, 10 Nov).
    public func scenePhaseChanged(_ scene: AppScenePhase) {
        switch scene {
        case .background: inForeground = false
        case .active: inForeground = true
        case .inactive: break
        }
    }

    /// Lists again after a failed listing; after a failed open (Wi-Fi), prepares the link again.
    public func retry() {
        guard case .failed = phase else { return }
        if let link, loadTask == nil {
            phase = .reading(since: now())
            loadTask = Task { [weak self] in
                _ = await self?.load(link)
                self?.loadTask = nil
            }
        } else if canReopen {
            reopenTapped = true
            wakeReopen()
        }
    }

    public var canRetry: Bool { link != nil || canReopen }

    /// The disconnected strip's Reconnect: prepares a new link (Wi-Fi), keeping the card, the selection and the
    /// thumbnails.
    public func reconnect() {
        guard interruption == .disconnected else { return }
        reopenTapped = true
        wakeReopen()
    }

    /// The failed state's title: a Wi-Fi camera that couldn't be reached isn't a card that couldn't be read.
    public var failedTitle: String {
        reconnects && openFailed ? WiFiWording.failedTitle : BrowseWording.listingFailedTitle
    }

    /// Lists the card on `link`; `relisting` lists it again under the live card shown (a reconnected link), asking the
    /// camera only about files it doesn't know when the link can (`ReusingListing`). Returns false when a relist failed,
    /// which ends the link's hold.
    private func load(_ link: any CameraLink, relisting: Bool = false) async -> Bool {
        let start = ContinuousClock.now
        do throws(CameraLinkFailure) {
            try await link.open()
            let items: [CameraItem]
            if relisting, let reusing = link as? any ReusingListing {
                items = try await reusing.list(reusing: self.items)
            } else {
                items = try await link.list()
            }
            guard !Task.isCancelled, phase != .gone else { return true }
            listed(items, seconds: Self.seconds(since: start))
            await refreshImportedStates(.listing)
            await saveListing(items)
            return true
        } catch {
            guard !Task.isCancelled else { return true }
            services.log.note("browse: \(relisting ? "listing again" : "listing") ended after "
                + "\(Self.seconds(since: start)) s: \(error)")
            if relisting {
                linkEnd = .relistFailed
                return false
            }
            listingFailed(error)
            return true
        }
    }

    /// The live card from a link: shown, and the cells without a thumbnail ask again (`linkGeneration`).
    private func listed(_ items: [CameraItem], seconds: String) {
        rule = JPEGSourceRule(listing: items)
        // The last-known card's Imported badges carry over by content, so the grid, New Only and Select All New never
        // see the live card without them while the catalogue is asked again.
        show(items, carryingImported: true)
        lastKnownListedAt = nil
        interruption = nil
        interruptionDetail = nil
        phase = .listed
        listedAt = .now
        linkGeneration += 1
        // Each new link gets one fresh ask: a refusal may have been the old session's (both links map unknown answers to
        // `unreadableItem`).
        thumbnailRefused.removeAll()
        services.log.note(listingLine(items, seconds: seconds))
    }

    /// Refreshes the badges each time the import says more files were imported, so they show without leaving
    /// Browse (the 17.1 bench run: in MTP, where listing again takes 65–123 s, nothing else would show them).
    private func followImports(_ updates: AsyncStream<Int>) async {
        for await revision in updates {
            await refreshImportedStates(.importedMore(revision: revision))
        }
    }

    private func follow(_ events: AsyncStream<CameraLinkEvent>, of link: any CameraLink) async {
        for await event in events {
            switch event {
            case .removed:
                cameraGone()
            case .willSuspend:
                // The app left the foreground. Core Image renders on the GPU, which iOS refuses to a backgrounded
                // app (a failed or black render), and the fetch stops within about 2 s anyway (section 2), so the
                // action is cancelled and says why when the person comes back.
                services.log.note("browse: link event \(event)")
                cancelForSuspension()
            case .sessionLost:
                services.log.note("browse: link event sessionLost") // the line as before generations (I13)
                // Over Wi-Fi, with the live card shown and no import holding the link (its recovery has the link then):
                // in front, the same link reopens and lists again; away, the link is let go, and Reconnect gets it back.
                guard reconnects, showsListedCard, leases.holders(of: link) <= 1 else { continue }
                guard inForeground else {
                    linkEnd = .sessionLost
                    return
                }
                if await !reopen(link) {
                    linkEnd = .sessionLost
                    return
                }
            case .didSuspend, .cancelledSuspending, .resumedOperations,
                 .waitingForLocalNetwork, .storeRemoved, .storeAdded:
                // Nothing else to pause in this slice; the log helps read the bench's background runs.
                services.log.note("browse: link event \(event)")
            }
        }
    }

    /// The link's session was lost with the app in front: open it again (a reopen, `IPLink`) and list the card again,
    /// keeping the selection and the thumbnails. False when it couldn't.
    private func reopen(_ link: any CameraLink) async -> Bool {
        let start = ContinuousClock.now
        interruption = .reconnecting
        services.log.note("browse: reconnecting (the session was lost; reopening the same link)")
        do throws(CameraLinkFailure) {
            try await link.open()
            let items: [CameraItem]
            if let reusing = link as? any ReusingListing {
                items = try await reusing.list(reusing: self.items)
            } else {
                items = try await link.list()
            }
            guard !Task.isCancelled, phase != .gone else { return true }
            services.log.note("browse: reconnected: the same link reopened in \(Self.seconds(since: start)) s")
            listed(items, seconds: Self.seconds(since: start))
            await refreshImportedStates(.listing)
            return true
        } catch {
            guard !Task.isCancelled else { return true }
            services.log.note("browse: reconnecting failed after \(Self.seconds(since: start)) s: \(error)")
            interruption = .disconnected
            return false
        }
    }

    /// `text`, when there is one, is the reason with its next step (Wi-Fi): it is shown whatever the kind, so a failed join
    /// isn't taken for a camera that went away.
    private func listingFailed(_ failure: CameraLinkFailure, text: String? = nil) {
        if let text {
            phase = .failed(text)
            return
        }
        switch failure.kind {
        case .disconnected: cameraGone()
        case .modeListsNoFiles: phase = .listsNoFiles
        default: phase = .failed(BrowseWording.listingFailed(failure.kind))
        }
    }

    private func cameraGone() {
        guard phase != .gone else { return }
        phase = .gone
        actionTask?.cancel()
        onGone(camera.id)
    }

    /// The phase in a word, for the log.
    private var phaseWord: String {
        switch phase {
        case .connecting: "connecting"
        case .reading: "reading"
        case .listed: "listed"
        case .listsNoFiles: "lists no files"
        case .failed: "failed"
        case .gone: "gone"
        }
    }

    // MARK: - Thumbnails

    /// The camera's thumbnail for a file, through the link. Over USB the link keeps two in flight, newest first
    /// (`USBLink`); over Wi-Fi `IPLink` sends them one at a time, in the order asked, ahead of queued downloads (it has no
    /// cap of its own). Cancelled with the calling task, so a cell scrolled away gives up its place (a GetThumb already on
    /// the wire runs to its end). Over Wi-Fi, while the link is being reached, the card read or the link reconnected, it
    /// waits (bounded by `BrowseTiming.thumbnailWait` and the calling task) instead of giving up. Nil when it can't be had.
    /// Over Wi-Fi a file whose thumbnail the link refused (`unreadableItem`, `itemNotFound`) isn't asked again on that link,
    /// while any other failure is asked again next time; the cell asks again on each new link (`linkGeneration`), and the
    /// new link is asked once more even for a refused file. Over USB every failure is asked again next time, as before.
    public func thumbnail(for id: CameraItem.ID) async -> Data? {
        if let data = thumbnails[id] { return data }
        if thumbnailRefused.contains(id) { return nil }
        // The last-known card's files aren't the link's: nothing to ask (their cells go once the live card lists).
        if lastKnownListedAt != nil, itemsByID[id] != nil { return nil }
        if waitsForLink, !Task.isCancelled { await waitForLinkToServe() }
        if Task.isCancelled {
            tally.cancelled += 1
            return nil
        }
        if let data = thumbnails[id] { return data }
        guard phase == .listed, lastKnownListedAt == nil, itemsByID[id] != nil else {
            tally.skippedNotListed += 1
            return nil
        }
        guard let link, interruption == nil else {
            tally.skippedNoLink += 1
            return nil
        }
        tally.asked += 1
        let result: Data?
        do throws(CameraLinkFailure) {
            let data = try await link.thumbnail(of: id)
            thumbnails[id] = data
            tally.ok += 1
            result = data
        } catch {
            tally.failed[error.kind, default: 0] += 1
            if !tally.failureLogged {
                tally.failureLogged = true
                services.log.note("browse: thumbnail failed (first on this screen): \(error.kind.rawValue)"
                    + (error.detail.map { " (\($0))" } ?? ""))
            }
            if reconnects, error.kind == .unreadableItem || error.kind == .itemNotFound { thumbnailRefused.insert(id) }
            result = nil
        }
        if tally.asked % 100 == 0 { logThumbnails("every 100 asked") }
        return result
    }

    /// The cell made (or failed to make) a picture of a thumbnail: one that didn't decode is counted, and the first is
    /// logged with its size and whether it starts like a JPEG.
    public func thumbnailShown(_ data: Data, decoded: Bool, for id: CameraItem.ID) {
        guard !decoded, undecodable.insert(id).inserted else { return }
        tally.undecodable += 1
        if tally.undecodable == 1 {
            let jpeg = data.starts(with: [0xFF, 0xD8])
            services.log.note("browse: a thumbnail of \(data.count) B didn't decode (starts FFD8: \(jpeg ? "yes" : "no"))")
        }
    }

    /// Whether a thumbnail asked now waits for the link rather than giving up (Wi-Fi): it is being reached, the card read,
    /// or the link reconnected. Over USB a thumbnail never waits, as before.
    private var waitsForLink: Bool {
        guard reconnects else { return false }
        switch phase {
        case .connecting, .reading: return true
        case .listed: return interruption == .reconnecting
        case .listsNoFiles, .failed, .gone: return false
        }
    }

    /// Parks until the link can serve thumbnails (or never will), the calling task is cancelled, or
    /// `BrowseTiming.thumbnailWait` passes.
    private func waitForLinkToServe() async {
        let id = nextThumbnailWaiter
        nextThumbnailWaiter += 1
        let limit = Task { [weak self] in
            do {
                try await Task.sleep(for: BrowseTiming.thumbnailWait)
            } catch {
                return
            }
            self?.resumeThumbnailWaiter(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || !waitsForLink || !isRunning {
                    continuation.resume()
                } else {
                    thumbnailWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.resumeThumbnailWaiter(id) }
        }
        limit.cancel()
    }

    private func resumeThumbnailWaiter(_ id: Int) {
        thumbnailWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeThumbnailWaiters() {
        guard !thumbnailWaiters.isEmpty else { return }
        let waiting = thumbnailWaiters
        thumbnailWaiters = [:]
        for continuation in waiting.values { continuation.resume() }
    }

    /// The thumbnail counts so far, as one bench line (no file names, handles or identifiers), when anything was asked.
    private func logThumbnails(_ when: String) {
        guard tally.hasAnything else { return }
        services.log.note("browse: thumbnails (\(when)): \(tally.line)")
    }

    // MARK: - Copy as JPEG and Share as JPEG…

    /// Whether a file offers the two actions: a still of the live card (not the last-known one, whose files the link
    /// can't fetch by handle).
    public func offersJPEGActions(_ item: CameraItem) -> Bool {
        CardLayout.kind(of: item).offersJPEGActions && phase == .listed && interruption == nil
    }

    public var isBusy: Bool { action.isWorking || share != nil }

    public func copyAsJPEG(_ item: CameraItem) { start(.copy, item) }
    public func shareAsJPEG(_ item: CameraItem) { start(.share, item) }

    /// Cancels the action in progress; its temporary folder is removed when it stops.
    public func cancelAction() {
        guard case var .working(work) = action, !work.cancelling else { return }
        work.cancelling = true
        action = .working(work)
        actionTask?.cancel()
    }

    /// The app left the foreground during an action: cancel it, and say so once it has stopped.
    private func cancelForSuspension() {
        guard case let .working(work) = action, !work.cancelling else { return }
        services.log.note("copy-as-jpeg \(work.purpose.rawValue) cancelled: the app left the foreground")
        cancelMessage = JPEGWording.keepOpen
        cancelAction()
    }

    /// The share sheet closed, whatever was chosen: the JPEG's folder goes.
    public func shareFinished() {
        guard let share else { return }
        services.scratch.remove(share.folder)
        self.share = nil
    }

    /// The share sheet couldn't be shown.
    public func shareFailed() {
        shareFinished()
        action = .failed(JPEGWording.failed(.shareUnavailable) ?? "")
    }

    /// Clears a confirmation or an error.
    public func dismissMessage() {
        switch action {
        case .finished, .failed: action = .idle
        case .idle, .working: break
        }
    }

    private func start(_ purpose: JPEGPurpose, _ item: CameraItem) {
        guard !isBusy, phase == .listed, let link, let source = rule.source(for: item) else { return }
        let folder: JPEGScratch.ActionFolder
        do {
            folder = try services.scratch.makeActionFolder()
        } catch {
            action = .failed(JPEGWording.failed(.storage(detail: "\(type(of: error))")) ?? "")
            return
        }
        actionCount += 1
        let id = actionCount
        cancelMessage = nil
        action = .working(JPEGWork(id: id, purpose: purpose, name: item.name,
                                   stage: .fetching(written: 0, total: source.fetched.size)))
        let pipeline = JPEGPipeline(link: link, maker: services.maker)
        actionTask = Task {
            let outcome = await pipeline.run(source, purpose: purpose, in: folder) { stage in
                Task { @MainActor in self.progressed(id, stage) }
            }
            // A cancel that came after the pipeline's last check (Cancel, leaving Browse, the app leaving the
            // foreground) still wins: nothing reaches the clipboard or the share sheet, and the folder goes.
            let result: Result<JPEGOutput, JPEGActionFailure> = Task.isCancelled ? .failure(.cancelled) : outcome
            self.finish(id, purpose, source, folder, result)
        }
    }

    private func progressed(_ id: Int, _ stage: JPEGStage) {
        guard case var .working(work) = action, work.id == id else { return }
        // Bytes only move forward; a late report never takes the line back from converting to fetching.
        switch (work.stage, stage) {
        case (.converting, .fetching): return
        case let (.fetching(old, _), .fetching(new, _)) where new < old: return
        default: break
        }
        work.stage = stage
        action = .working(work)
    }

    private func finish(_ id: Int, _ purpose: JPEGPurpose, _ source: JPEGSource,
                        _ folder: JPEGScratch.ActionFolder, _ outcome: Result<JPEGOutput, JPEGActionFailure>) {
        actionTask = nil
        let cancelMessage = self.cancelMessage
        self.cancelMessage = nil
        switch outcome {
        case let .success(output):
            services.log.note(output.record.logLine)
            switch purpose {
            case .copy:
                do {
                    try services.clipboard.copyJPEG(at: output.url)
                    action = .finished(JPEGWording.copied(pressedName: source.pressed.name,
                                                          embeddedPreview: output.isEmbeddedPreview))
                } catch {
                    services.log.note("copy-as-jpeg clipboard refused the JPEG: \(type(of: error))")
                    action = .failed(JPEGWording.failed(.clipboard(detail: "\(type(of: error))")) ?? "")
                }
                services.scratch.remove(folder)
            case .share:
                guard phase != .gone else {
                    services.scratch.remove(folder)
                    action = .idle
                    return
                }
                share = JPEGShare(id: id, url: output.url, folder: folder)
                action = output.isEmbeddedPreview ? .finished(JPEGWording.sharingPreview) : .idle
            }
        case let .failure(failure):
            services.scratch.remove(folder)
            if case let .link(linkFailure) = failure, linkFailure.kind == .disconnected { cameraGone() }
            if failure != .cancelled {
                services.log.note("copy-as-jpeg \(purpose.rawValue) \(source.kind.rawValue) failed: \(failure)")
            }
            if failure == .cancelled, let cancelMessage {
                action = .failed(cancelMessage)
            } else {
                action = JPEGWording.failed(failure).map(JPEGActionState.failed) ?? .idle
            }
        }
    }

    // MARK: - The card shown, the last-known card and the catalogue

    /// Whether the card shown has any files at all (as opposed to none matching the filters). Stored, so the screen
    /// is told when it changes.
    public private(set) var hasFiles = false

    /// The first and last capture dates on the card, for the date filter's bounds; nil without dated files.
    public var dateBounds: ClosedRange<Date>? {
        let dates = items.compactMap(\.captureDate)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return first ... last
    }

    /// The date filter's pickers' range: the whole days from the card's first capture date to its last.
    public var dayBounds: ClosedRange<Date>? {
        dateBounds.map { BrowseFilter.days(from: $0.lowerBound, through: $0.upperBound, calendar: calendar) }
    }

    /// The date filter's switch: on limits the card to its whole span of days, which the pickers then narrow; off
    /// shows every date. Turning it on does nothing when no file has a capture date.
    public var limitsDates: Bool {
        get { filter.dateRange != nil }
        set {
            guard newValue != limitsDates else { return }
            if newValue, let bounds = dateBounds {
                filter.limitDates(from: bounds.lowerBound, to: bounds.upperBound, calendar: calendar)
            } else if !newValue {
                filter.dateRange = nil
            }
        }
    }

    /// The date filter's first day (its From picker), moving the last day along if it would come first.
    public var firstDay: Date {
        get { filter.dateRange?.lowerBound ?? dayBounds?.lowerBound ?? now() }
        set {
            guard let bounds = dateBounds else { return }
            filter.setFirstDay(newValue, bounds: bounds, calendar: calendar)
        }
    }

    /// The date filter's last day (its To picker), moving the first day along if it would come after.
    public var lastDay: Date {
        get { filter.dateRange?.upperBound ?? dayBounds?.upperBound ?? now() }
        set {
            guard let bounds = dateBounds else { return }
            filter.setLastDay(newValue, bounds: bounds, calendar: calendar)
        }
    }

    public func isImported(_ item: CameraItem) -> Bool { imported.contains(item.id) }

    /// Whether the catalogue has a staged copy of `item`. The cell shows Staged only when it isn't imported.
    public func isStaged(_ item: CameraItem) -> Bool { staged.contains(item.id) }

    /// Imported or staged: what *Select All New* skips and New Only hides (Shamil, 11 Nov).
    private func isDone(_ id: CameraItem.ID) -> Bool { imported.contains(id) || staged.contains(id) }

    /// Whether an import for `choice` would leave the file out as done (the engine's rule, by the badges):
    /// *Import to Photos* leaves out imported files; *Stage* staged ones, and imported ones when only new files were
    /// asked for (`newOnly`, *Select All New*).
    private func isDone(_ id: CameraItem.ID, for choice: DestinationKind, newOnly: Bool) -> Bool {
        switch choice {
        case .photos: imported.contains(id)
        case .staging: staged.contains(id) || (newOnly && imported.contains(id))
        }
    }

    /// Why the badges are read, for the bench log.
    enum BadgeRead: Sendable, Hashable, CustomStringConvertible {
        case listing
        case lastKnown
        case importedMore(revision: Int)
        case asked

        var description: String {
            switch self {
            case .listing: "after listing"
            case .lastKnown: "on the last-known card"
            case let .importedMore(revision): "after import (rev \(revision))"
            case .asked: "on request"
            }
        }
    }

    /// Reads the catalogue's states for the card shown: the Imported and Staged badges, and selected files that can no
    /// longer be selected (imported, while the Import button imports to Photos) drop out of the selection. Browse calls
    /// it itself after each listing, on the last-known card and each time the import imports or stages more files;
    /// callers may also ask.
    public func refreshImportedStates() async {
        await refreshImportedStates(.asked)
    }

    func refreshImportedStates(_ why: BadgeRead) async {
        guard let catalogue, !items.isEmpty else { return }
        guard let key = cameraKey else {
            services.log.note("browse: badges not refreshed: no key")
            return
        }
        let shown = items
        let zone = self.zone
        var byIdentity: [ObjectIdentity: CameraItem.ID] = [:]
        for item in shown {
            if let identity = item.identity(camera: key, timeZone: zone) { byIdentity[identity] = item.id }
        }
        guard !byIdentity.isEmpty else { return }
        badgeReadsStarted += 1
        let mine = badgeReadsStarted
        let states: [ObjectIdentity: ObjectState]
        let stagedIdentities: Set<ObjectIdentity>?
        do {
            states = try await catalogue.store.states(of: Array(byIdentity.keys))
        } catch {
            services.log.note("browse: badges not refreshed: catalogue error (\(type(of: error)))")
            return
        }
        do {
            stagedIdentities = try await catalogue.store.stagedStates(of: Array(byIdentity.keys))
        } catch {
            // The Imported badges still follow; the Staged ones stay as they were.
            services.log.note("browse: staged badges not refreshed: catalogue error (\(type(of: error)))")
            stagedIdentities = nil
        }
        // The card may have been replaced while the catalogue answered.
        guard shown == items else {
            services.log.note("browse: badges not refreshed: card replaced")
            return
        }
        // A newer read has answered already, and knows more.
        guard mine > badgeReadsApplied else { return }
        badgeReadsApplied = mine
        var now: Set<CameraItem.ID> = []
        for (identity, id) in byIdentity where states[identity] == .imported { now.insert(id) }
        if now != imported { imported = now }
        if let stagedIdentities {
            let nowStaged = Set(byIdentity.compactMap { identity, id in stagedIdentities.contains(identity) ? id : nil })
            if nowStaged != staged { staged = nowStaged }
        }
        dropDoneNewPicks()
        if filter.newOnly { rebuildSections() }
        services.log.note("browse: badges refreshed \(why): \(shown.count) shown, \(byIdentity.count) dated, "
            + "\(now.count) imported, \(staged.count) staged, key \(keyTags.tag(for: key))")
    }

    /// The bench log's line for a listing: how long it took, the key by its tag, how many files came without a folder
    /// and the three newest files' names, capture times and sizes (what Shamil's rule matches on), so the same file
    /// can be compared between MSC and MTP. No handle, no key.
    private func listingLine(_ listed: [CameraItem], seconds: String) -> String {
        let keyText = cameraKey.map { ", key \(keyTags.tag(for: $0))" } ?? ""
        let unfiled = listed.filter(\.folder.isEmpty).count
        let newest = listed.filter { $0.captureDate != nil }.newestFirst().prefix(3).map { item in
            let date = item.captureDate.flatMap { CaptureDate($0, in: item.captureTimeZone ?? zone) }?.rawValue
                ?? "undated"
            return "\(item.name) \(date) \(item.size) B"
        }
        return "browse: listed \(listed.count) files in \(seconds) s\(keyText), \(unfiled) with no folder "
            + "(\(CamerasWording.modeLine(camera.mode)) at discovery); newest: "
            + (newest.isEmpty ? "none" : newest.joined(separator: ", "))
    }

    /// Takes the last-known card off the screen (it was shown before the link opened, and the link didn't open, or opened
    /// to another camera).
    private func clearLastKnown() {
        show([])
        lastKnownListedAt = nil
    }

    /// Whether the link is being reached or the card read: the last-known card may still be shown.
    private var isOpening: Bool {
        switch phase {
        case .connecting, .reading: true
        case .listed, .listsNoFiles, .failed, .gone: false
        }
    }

    /// The catalogue's last listing of this camera, shown at once while the card is read (decision 7).
    private func showLastKnown(for key: CameraKey, from store: any CatalogueStore) async {
        let listing: CardListing?
        do {
            listing = try await store.lastListing(for: key)
        } catch {
            services.log.note("browse: no last-known card: \(type(of: error))")
            return
        }
        guard let listing, isOpening, items.isEmpty else { return }
        let zone = self.zone
        let known = listing.entries.map { entry in
            let identity = entry.identity
            return CameraItem(id: .init(rawValue: "last-known:\(identity.folder)/\(identity.filename)"),
                              folder: identity.folder, name: identity.filename, size: identity.size,
                              captureDate: identity.captureDate.date(in: zone), format: entry.format,
                              captureTimeZone: zone)
        }
        lastKnownListedAt = listing.listedAt
        show(known)
        services.log.note("browse: showing the last-known card (\(known.count) files)")
        await refreshImportedStates(.lastKnown)
    }

    /// Replaces the card shown, keeping only the selection that is still on it. With `carryingImported`, files of
    /// the new card whose content (name, capture time, size: the catalogue's rule) was marked imported on the old one
    /// stay marked (the last-known card and the live listing have different item IDs, and MTP may list a file in
    /// another folder), until `refreshImportedStates()` answers from the catalogue.
    private func show(_ newItems: [CameraItem], carryingImported: Bool = false) {
        let carried = carryingImported ? contentKeys(of: imported) : []
        let carriedStaged = carryingImported ? contentKeys(of: staged) : []
        items = newItems
        if hasFiles == newItems.isEmpty { hasFiles = !newItems.isEmpty }
        itemsByID = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(itemsByID.keys)
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        if !carried.isEmpty {
            let now = matching(carried, in: newItems)
            if now != imported { imported = now }
        } else if !imported.isSubset(of: ids) {
            imported.formIntersection(ids)
        }
        if !carriedStaged.isEmpty {
            let now = matching(carriedStaged, in: newItems)
            if now != staged { staged = now }
        } else if !staged.isSubset(of: ids) {
            staged.formIntersection(ids)
        }
        dropDoneNewPicks()
        rebuildSections()
    }

    /// The content keys of the files shown in `ids`.
    private func contentKeys(of ids: Set<CameraItem.ID>) -> Set<ObjectIdentity.ContentKey> {
        guard let key = cameraKey, !ids.isEmpty else { return [] }
        let zone = self.zone
        return Set(items.filter { ids.contains($0.id) }.compactMap {
            $0.identity(camera: key, timeZone: zone)?.contentKey
        })
    }

    /// The files of `newItems` whose content is one of `keys`.
    private func matching(_ keys: Set<ObjectIdentity.ContentKey>, in newItems: [CameraItem]) -> Set<CameraItem.ID> {
        guard let key = cameraKey else { return [] }
        let zone = self.zone
        return Set(newItems.filter { item in
            item.identity(camera: key, timeZone: zone).map { keys.contains($0.contentKey) } ?? false
        }.map(\.id))
    }

    private func rebuildSections() {
        let filter = self.filter
        let shown = filter.isActive ? items.filter { filter.admits($0, isDone: isDone($0.id)) } : items
        sections = CardLayout.sections(shown, calendar: calendar)
    }

    /// The live listing, saved as the camera's last-known card for next time (names, dates, sizes; files without a
    /// capture date have no identity and aren't kept).
    private func saveListing(_ listed: [CameraItem]) async {
        guard let catalogue, let key = cameraKey else { return }
        let zone = self.zone
        let entries = listed.compactMap { item in
            item.identity(camera: key, timeZone: zone).map { CardListing.Entry(identity: $0, format: item.format) }
        }
        do {
            try await catalogue.store.saveListing(CardListing(camera: key, listedAt: now(), entries: entries))
        } catch {
            services.log.note("browse: the listing couldn't be saved: \(type(of: error))")
        }
    }

    // MARK: - Selection

    /// Why `item` can't be selected; nil when it can.
    ///
    /// Staged and imported files can always be picked (Shamil, 11 Nov): a staged one so it can be imported to Photos,
    /// an imported one so it can be staged, whatever the Import button's default. What the chosen import would leave
    /// out is taken out when Import, *Import to Photos* or *Stage* is tapped (`importSelected(as:)`).
    public func selectionBlock(for item: CameraItem) -> SelectionBlock? {
        switch CardLayout.kind(of: item) {
        case .video: return .video
        case .other: return .notAPhoto
        case .photo: break
        }
        guard phase == .listed, lastKnownListedAt == nil else { return .cardNotRead }
        if item.captureDate == nil { return .noCaptureDate }
        return nil
    }

    /// What the Import button does by default: the import's remembered choice (Photos when there is no import).
    public var importChoice: DestinationKind { importer?.importChoice ?? .photos }

    /// Takes the files *Select All New* picked out of the selection once they are imported or staged meanwhile: they
    /// were picked as new. An explicit pick of a done file stays (it may be staged, or imported).
    private func dropDoneNewPicks() {
        let done = allNewPicks.filter(isDone)
        guard !done.isEmpty else { return }
        selection.subtract(done)
    }

    public func canSelect(_ item: CameraItem) -> Bool { selectionBlock(for: item) == nil }

    public func isSelected(_ item: CameraItem) -> Bool { selection.contains(item.id) }

    /// Whether `tap(_:)` would do anything with this file: select it, start selecting with it, or deselect it. A cell
    /// that doesn't isn't announced as a button.
    public func respondsToTap(_ item: CameraItem) -> Bool { isSelected(item) || canSelect(item) }

    /// Selects or deselects one file; files that can't be imported aren't selected.
    public func toggleSelection(_ item: CameraItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else if canSelect(item) {
            selection.insert(item.id)
        }
    }

    /// Selects every file the filters show that is new: stills neither imported nor staged and with a capture date,
    /// so video, other files, imported, staged and undated files are skipped (backlog section 6; Shamil, 11 Nov).
    /// Enters the selecting mode.
    public func selectAllNew() {
        var picked = selection
        let new = selectableShown
        picked.formUnion(new)
        isSelecting = true
        selection = picked
        allNewPicks.formUnion(new)
    }

    public func clearSelection() { selection = [] }

    /// A tap on a cell (and VoiceOver's default action, which does the same): while selecting it selects or
    /// deselects the file; otherwise, on a file that can be imported, it enters the selecting mode with that file
    /// selected (until Iteration 2's loupe opens it instead). A file that can't be imported does nothing outside the
    /// selecting mode; its VoiceOver value says why.
    public func tap(_ item: CameraItem) {
        if isSelecting {
            toggleSelection(item)
        } else if canSelect(item) {
            isSelecting = true
            selection = [item.id]
        }
    }

    /// The files the filters show that *Select All New* picks: those that could be selected now and are neither
    /// imported nor staged.
    private var selectableShown: [CameraItem.ID] {
        sections.flatMap { section in section.items.filter { canSelect($0) && !isDone($0.id) }.map(\.id) }
    }

    /// The stills the filters show that can't be selected only for want of a capture date (D10).
    private var undatedStillsShown: [CameraItem] {
        sections.flatMap { section in section.items.filter { selectionBlock(for: $0) == .noCaptureDate } }
    }

    /// True when every new file the filters show that could be selected is selected (and there is one): the leading
    /// button then reads *Deselect All*, as Select All does in Photos and Files.
    public var allNewSelected: Bool {
        let shown = selectableShown
        return !shown.isEmpty && selection.isSuperset(of: shown)
    }

    /// Whether the leading button does anything: something to select, or a selection to clear.
    public var canToggleSelectAllNew: Bool { !selection.isEmpty || !selectableShown.isEmpty }

    /// The leading button while selecting: *Select All New*, or *Deselect All* once all of them are selected.
    /// Deselecting keeps the selecting mode, so clearing a selection doesn't mean leaving it.
    public func toggleSelectAllNew() {
        if allNewSelected { clearSelection() } else { selectAllNew() }
    }

    // MARK: - The bar

    /// The bar's title: the camera's name, or while selecting "Select Items" and then "3 Selected" (HIG: the title
    /// reports the selection).
    public var navigationTitle: String {
        isSelecting ? BrowseWording.selectingTitle(selectionSummary) : CamerasWording.displayName(for: camera)
    }

    /// The bar's subtitle: the selection's size while selecting something, "Connecting to the camera…" or "Reading the
    /// card…" while the last-known card is shown, otherwise the mode in the camera's wording.
    public var navigationSubtitle: String {
        let summary = selectionSummary
        if isSelecting, summary.count > 0 { return ByteWording.size(summary.bytes) }
        if case .connecting = phase, lastKnownListedAt != nil { return BrowseWording.connectingSubtitle }
        if case .reading = phase, lastKnownListedAt != nil { return BrowseWording.readingSubtitle }
        return CamerasWording.modeLine(camera.mode)
    }

    /// The selected files in the card's order (newest first), as Import hands them over.
    public var selectedItems: [CameraItem] {
        guard !selection.isEmpty else { return [] }
        return items.newestFirst().filter { selection.contains($0.id) }
    }

    /// The sticky bar: how many are selected and their total size.
    public var selectionSummary: SelectionSummary {
        var bytes: UInt64 = 0
        var count = 0
        for id in selection {
            guard let item = itemsByID[id] else { continue }
            bytes += item.size
            count += 1
        }
        return SelectionSummary(count: count, bytes: bytes)
    }

    public var canImport: Bool {
        !selection.isEmpty && !isStartingImport && importer != nil && link != nil && cameraKey != nil
            && phase == .listed && interruption == nil
    }

    /// Hands the selection to the import: a new job, or the end of the running one. The selection clears once the
    /// files are in the job; Photos access may be asked for first (the first *Import to Photos*). Returns what came of
    /// it (the screen opens the Import screen when a job started), or nil when there was nothing to hand over.
    ///
    /// Files the chosen import would leave out (Shamil, 11 Nov) aren't handed over, so the notice and the Import
    /// screen count only what it copies: *Import to Photos* leaves out imported files; *Stage* leaves out staged ones,
    /// and imported ones too when the selection came from *Select All New*. When that leaves nothing, no job starts
    /// and the notice says the files are done already. The importer leaves out the rest by what the job does: with
    /// Photos access off an *Import to Photos* stages, so it also leaves out staged files, and its count and its
    /// nothing-new reason are the notice's.
    ///
    /// - Parameter choice: *Import to Photos* or *Stage*, from the Import button's menu; nil, the button itself, is
    ///   the remembered choice (`importChoice`). The import remembers what was used.
    @discardableResult
    public func importSelected(as choice: DestinationKind? = nil) async -> ImportRequestOutcome? {
        guard canImport, let importer, let link, let key = cameraKey else { return nil }
        let choice = choice ?? importer.importChoice
        let selected = selectedItems
        let newOnly = selection.isSubset(of: allNewPicks)
        let picked = selected.filter { !isDone($0.id, for: choice, newOnly: newOnly) }
        // *Select All New* hands over the stills shown without a capture date as well, never selected, for the job to
        // leave out and the Import screen to count (D10); they start nothing on their own.
        let undated = newOnly && !picked.isEmpty ? undatedStillsShown : []
        isStartingImport = true
        defer { isStartingImport = false }
        let outcome: ImportRequestOutcome = picked.isEmpty ? .nothingNew(staging: choice == .staging)
            : await importer.importItems(picked + undated, from: ImportCamera(descriptor: camera, key: key),
                                         link: link, as: choice, newOnly: newOnly)
        switch outcome {
        case .started, .appended, .nothingNew:
            selection.subtract(selected.map(\.id))
            if selection.isEmpty { isSelecting = false }
        case .busyWithAnotherCamera, .busyWithAnotherMode, .stillStarting, .failed:
            break
        }
        importNoticeCount += 1
        importStatus = StatusNotice.importRequest(outcome, id: importNoticeCount, choice: choice)
        return outcome
    }

    /// The Import button's title: "Import", or "Stage" when the remembered choice is *Stage*.
    public var importButtonTitle: String { BrowseWording.importButtonTitle(importChoice) }

    /// Reads where staging goes again, for the menu's *Stage* item.
    public func refreshStagingPlace() async { await importer?.refreshStagingPlace() }

    /// The menu's *Stage* item: "Stage in iCloud Drive", or "Stage on iPhone" when iCloud Drive isn't available.
    public var stageMenuTitle: String { BrowseWording.stageMenuTitle(importer?.stagingPlace) }

    public func dismissImportNotice() { importStatus = nil }

    /// The grid cell's VoiceOver label (`date` formatted by the screen). Whether it is selected is the cell's
    /// `.isSelected` trait.
    public func accessibilityLabel(for item: CameraItem, date: String?) -> String {
        BrowseWording.cellAccessibility(name: item.name, date: date, kind: CardLayout.kind(of: item),
                                        isImported: isImported(item), isStaged: isStaged(item))
    }

    /// The grid cell's VoiceOver value: why it can't be selected, when the label doesn't already say so.
    public func accessibilityValue(for item: CameraItem) -> String? {
        BrowseWording.cellAccessibilityValue(selectionBlock(for: item))
    }

    // MARK: - For tests

    /// Waits for the action in progress, if any, to finish.
    func waitForAction() async {
        await actionTask?.value
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        JPEGBenchRecord.format(JPEGPipeline.seconds(ContinuousClock.now - start))
    }
}

/// Browse's own waits, with what they rest on.
public enum BrowseTiming {
    /// The longest a cell's thumbnail waits for the link to be reached, the card read or the link reconnected before it
    /// gives up (the cell asks again when a link next lists the card, `BrowseModel.linkGeneration`). `unverified`: a
    /// choice, above a join with iOS's prompt (55 s on 5 Nov) and a full card's listing; the cell's own task, cancelled
    /// when it scrolls away, usually ends the wait first.
    public static let thumbnailWait: Duration = .seconds(120)
}

/// A grid cell's thumbnail task: the file and the link generation, so a cell still without a picture asks again when a
/// new link has listed the card (bench 19.1: thumbnails asked of a dead link were never asked again).
struct ThumbnailTaskID: Hashable, Sendable {
    let item: CameraItem.ID
    let generation: Int
}

/// What became of Browse's thumbnail requests, for the bench log: counts and failure kinds only, never a file name,
/// handle or identifier.
struct ThumbnailTally: Sendable, Equatable {
    /// Asked of the link.
    var asked = 0
    var ok = 0
    /// Failed, by the link's failure kind.
    var failed: [CameraLinkFailure.Kind: Int] = [:]
    /// Not asked: no link (it went, or is reconnecting and the wait ended).
    var skippedNoLink = 0
    /// Not asked: the live card isn't listed (still reading after the wait, failed, or the file isn't on the live card).
    var skippedNotListed = 0
    /// The cell went before anything was asked.
    var cancelled = 0
    /// Data came back that the cell couldn't make a picture of (counted once per file).
    var undecodable = 0
    /// The first failure has been logged.
    var failureLogged = false

    var hasAnything: Bool {
        asked > 0 || skippedNoLink > 0 || skippedNotListed > 0 || cancelled > 0 || undecodable > 0
    }

    /// "asked 12: ok 0, failed 12 (unreadableItem 12), skipped no-link 48, not-listed 0, cancelled 5, undecodable 0".
    var line: String {
        let failures = failed.values.reduce(0, +)
        let kinds = failed.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        let byKind = kinds.isEmpty ? "" : " (\(kinds.joined(separator: ", ")))"
        return "asked \(asked): ok \(ok), failed \(failures)\(byKind), skipped no-link \(skippedNoLink), not-listed "
            + "\(skippedNotListed), cancelled \(cancelled), undecodable \(undecodable)"
    }
}
