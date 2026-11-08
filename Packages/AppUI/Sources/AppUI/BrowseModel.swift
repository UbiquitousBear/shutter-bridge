import CameraTransport
import Catalogue
import Foundation
import Observation

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

    public init(store: any CatalogueStore, cameraKey: @escaping CameraKeying) {
        self.store = store
        self.cameraKey = cameraKey
    }
}

/// The Browse screen's model (backlog section 6): opens the link, shows the last-known card from the catalogue at
/// once (marked as last-known) while the card is read with the measured expectations, replaces it with the live
/// listing and saves that, shows the card newest first by day with the already-imported badge, filters it (new only,
/// type, date range), selects (one by one, or *Select all new*) with the sticky bar's count and size, hands the
/// selection to the import, fetches thumbnails through the link, and runs *Copy as JPEG* and *Share as JPEG…*.
///
/// The screen's `.task` calls `run()`, which holds the link (`LinkLeases`) until the task is cancelled (the screen
/// went away) and then lets go of it; the link closes unless an import still uses it.
@MainActor
@Observable
public final class BrowseModel {
    public enum Phase: Sendable, Hashable {
        /// Opening the link and waiting for ImageCaptureCore's catalogue, since `since`.
        case reading(since: Date)
        case listed
        /// The catalogue completed at once with no files: Remote Shoot (PC Remote), or an empty card in MTP.
        case listsNoFiles
        case failed(String)
        /// The camera went away; the Cameras screen takes over.
        case gone
    }

    /// Why a file can't be selected.
    public enum SelectionBlock: Sendable, Hashable {
        case video
        case notAPhoto
        case imported
        /// No capture date, so no identity: the engine can't import it yet (backlog section 3).
        case noCaptureDate
        /// The card isn't read yet (the last-known card, or still reading).
        case cardNotRead
    }

    public let camera: CameraDescriptor
    public private(set) var phase: Phase
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
    /// The picked files, which the sticky bar counts and Import hands over.
    public private(set) var selection: Set<CameraItem.ID> = []
    /// The selecting mode of the grid: taps select instead of opening anything. Leaving it clears the selection.
    public var isSelecting = false {
        didSet { if !isSelecting { selection = [] } }
    }
    /// What the grid shows of the card.
    public var filter = BrowseFilter() {
        didSet { if filter != oldValue { rebuildSections() } }
    }
    /// True while Import is handing the selection over (Photos may be asking).
    public private(set) var isStartingImport = false
    /// What came of the last Import tap, for a strip at the top; cleared with `dismissImportNotice()`.
    public private(set) var importNotice: String?
    public private(set) var action: JPEGActionState = .idle
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
    @ObservationIgnored private let onGone: @MainActor (CameraDescriptor.ID) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var link: (any CameraLink)?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rule = JPEGSourceRule(listing: [])
    @ObservationIgnored private var thumbnails: [CameraItem.ID: Data] = [:]
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var actionCount = 0
    /// Said instead of nothing when the action in progress ends as cancelled, because the app cancelled it.
    @ObservationIgnored private var cancelMessage: String?
    /// Badge reads started and applied, so a read that answers after a newer one is dropped.
    @ObservationIgnored private var badgeReadsStarted = 0
    @ObservationIgnored private var badgeReadsApplied = 0
    @ObservationIgnored private let keyTags: CameraKeyTags

    /// - Parameters:
    ///   - catalogue: The last-known card and the already-imported badge; without it Browse shows neither.
    ///   - importer: Where Import hands the selection (the app's `ImportModel`, held weakly); without it Import does
    ///     nothing.
    ///   - leases: Shared with the import, so leaving Browse doesn't close a link a job still uses. A fresh one (the
    ///     default) closes the link when Browse goes.
    public init(
        camera: CameraDescriptor,
        openLink: @escaping @Sendable () async throws(CameraLinkFailure) -> any CameraLink,
        services: BrowseServices,
        onGone: @escaping @MainActor (CameraDescriptor.ID) -> Void,
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
        self.onGone = onGone
        self.catalogue = catalogue
        self.importer = importer
        self.leases = leases
        self.now = now
        self.calendar = calendar
        phase = .reading(since: now())
    }

    // MARK: - Lifecycle

    /// Opens the link, shows the last-known card, lists the card, and follows the link's events and the import's
    /// "more files imported" (refreshing the badges on each) until the calling task is cancelled or the link's events
    /// end, then lets go of the link (closing it unless an import holds it). A second call while one runs does
    /// nothing.
    public func run() async {
        guard !isRunning, phase != .gone else { return }
        isRunning = true
        defer { isRunning = false }
        phase = .reading(since: now())
        let link: any CameraLink
        do throws(CameraLinkFailure) {
            link = try await openLink()
        } catch {
            if !Task.isCancelled { listingFailed(error) }
            return
        }
        self.link = link
        leases.acquire(link)
        zone = TimeZone(identifier: TimeZone.current.identifier) ?? TimeZone.current
        if let catalogue {
            let key = await catalogue.cameraKey(camera, link)
            cameraKey = key
            await showLastKnown(for: key, from: catalogue.store)
        }
        let events = link.events
        // Subscribed before the listing, so an import that finishes while the card is read is still noticed.
        let imports = importer?.importedUpdates()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // The import's updates never end by themselves: they stop with the link's events.
                await withTaskGroup(of: Bool.self) { followers in
                    followers.addTask { await self.follow(events); return true }
                    if let imports {
                        followers.addTask { await self.followImports(imports); return false }
                    }
                    while let eventsEnded = await followers.next() {
                        if eventsEnded { followers.cancelAll() }
                    }
                }
            }
            group.addTask { await self.load(link) }
            await group.waitForAll()
        }
        // The screen went away (or the link's events ended): nothing more is asked of this link.
        loadTask?.cancel()
        loadTask = nil
        actionTask?.cancel()
        self.link = nil
        await leases.release(link)
    }

    /// Lists again after a failure.
    public func retry() {
        guard case .failed = phase, let link, loadTask == nil else { return }
        phase = .reading(since: now())
        loadTask = Task { [weak self] in
            await self?.load(link)
            self?.loadTask = nil
        }
    }

    public var canRetry: Bool { link != nil }

    private func load(_ link: any CameraLink) async {
        let start = ContinuousClock.now
        do throws(CameraLinkFailure) {
            try await link.open()
            let items = try await link.list()
            guard !Task.isCancelled, phase != .gone else { return }
            rule = JPEGSourceRule(listing: items)
            // The last-known card's Imported badges carry over by content, so the grid, New Only and Select All
            // New never see the live card without them while the catalogue is asked again.
            show(items, carryingImported: true)
            lastKnownListedAt = nil
            phase = .listed
            services.log.note(listingLine(items, seconds: Self.seconds(since: start)))
            await refreshImportedStates(.listing)
            await saveListing(items)
        } catch {
            guard !Task.isCancelled else { return }
            services.log.note("browse: listing ended after \(Self.seconds(since: start)) s: \(error)")
            listingFailed(error)
        }
    }

    /// Refreshes the badges each time the import says more files were imported, so they show without leaving
    /// Browse (the 17.1 bench run: in MTP, where listing again takes 65–123 s, nothing else would show them).
    private func followImports(_ updates: AsyncStream<Int>) async {
        for await revision in updates {
            await refreshImportedStates(.importedMore(revision: revision))
        }
    }

    private func follow(_ events: AsyncStream<CameraLinkEvent>) async {
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
            case .didSuspend, .cancelledSuspending, .resumedOperations:
                // Nothing else to pause in this slice; the log helps read the bench's background runs.
                services.log.note("browse: link event \(event)")
            }
        }
    }

    private func listingFailed(_ failure: CameraLinkFailure) {
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

    // MARK: - Thumbnails

    /// The camera's thumbnail for a file, through the link (which keeps two in flight, newest first). Cancelled with
    /// the calling task, so a cell scrolled away gives up its place. Nil when it can't be had.
    public func thumbnail(for id: CameraItem.ID) async -> Data? {
        if let data = thumbnails[id] { return data }
        guard let link, phase == .listed else { return nil }
        guard let data = try? await link.thumbnail(of: id) else { return nil }
        thumbnails[id] = data
        return data
    }

    // MARK: - Copy as JPEG and Share as JPEG…

    /// Whether a file offers the two actions: a still of the live card (not the last-known one, whose files the link
    /// can't fetch by handle).
    public func offersJPEGActions(_ item: CameraItem) -> Bool {
        CardLayout.kind(of: item).offersJPEGActions && phase == .listed
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

    /// Reads the catalogue's states for the card shown: the badge, and selected files that are now imported drop out
    /// of the selection. Browse calls it itself after each listing, on the last-known card and each time the import
    /// imports more files; callers may also ask.
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
        do {
            states = try await catalogue.store.states(of: Array(byIdentity.keys))
        } catch {
            services.log.note("browse: badges not refreshed: catalogue error (\(type(of: error)))")
            return
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
        if !selection.isDisjoint(with: now) { selection.subtract(now) }
        if filter.newOnly { rebuildSections() }
        services.log.note("browse: badges refreshed \(why): \(shown.count) shown, \(byIdentity.count) dated, "
            + "\(now.count) imported, key \(keyTags.tag(for: key))")
    }

    /// The bench log's line for a listing: how long it took, the key by its tag, how many files came without a folder
    /// and the three newest files' names, capture times and sizes (what Shamil's rule matches on), so the same file
    /// can be compared between MSC and MTP. No handle, no key.
    private func listingLine(_ listed: [CameraItem], seconds: String) -> String {
        let keyText = cameraKey.map { ", key \(keyTags.tag(for: $0))" } ?? ""
        let unfiled = listed.filter(\.folder.isEmpty).count
        let newest = listed.filter { $0.captureDate != nil }.newestFirst().prefix(3).map { item in
            let date = item.captureDate.flatMap { CaptureDate($0, in: zone) }?.rawValue ?? "undated"
            return "\(item.name) \(date) \(item.size) B"
        }
        return "browse: listed \(listed.count) files in \(seconds) s\(keyText), \(unfiled) with no folder "
            + "(\(CamerasWording.modeLine(camera.mode)) at discovery); newest: "
            + (newest.isEmpty ? "none" : newest.joined(separator: ", "))
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
        guard let listing, case .reading = phase, items.isEmpty else { return }
        let zone = self.zone
        let known = listing.entries.map { entry in
            let identity = entry.identity
            return CameraItem(id: .init(rawValue: "last-known:\(identity.folder)/\(identity.filename)"),
                              folder: identity.folder, name: identity.filename, size: identity.size,
                              captureDate: identity.captureDate.date(in: zone), format: entry.format)
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
        let carried = carryingImported ? importedIdentities() : []
        items = newItems
        if hasFiles == newItems.isEmpty { hasFiles = !newItems.isEmpty }
        itemsByID = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(itemsByID.keys)
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        if let key = cameraKey, !carried.isEmpty {
            let zone = self.zone
            let now = Set(newItems.filter { item in
                item.identity(camera: key, timeZone: zone).map { carried.contains($0.contentKey) } ?? false
            }.map(\.id))
            if now != imported { imported = now }
            if !selection.isDisjoint(with: now) { selection.subtract(now) }
        } else if !imported.isSubset(of: ids) {
            imported.formIntersection(ids)
        }
        rebuildSections()
    }

    /// The content keys of the files shown as imported.
    private func importedIdentities() -> Set<ObjectIdentity.ContentKey> {
        guard let key = cameraKey, !imported.isEmpty else { return [] }
        let zone = self.zone
        return Set(items.filter { imported.contains($0.id) }.compactMap {
            $0.identity(camera: key, timeZone: zone)?.contentKey
        })
    }

    private func rebuildSections() {
        let filter = self.filter
        let shown = filter.isActive ? items.filter { filter.admits($0, isImported: imported.contains($0.id)) } : items
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
    public func selectionBlock(for item: CameraItem) -> SelectionBlock? {
        switch CardLayout.kind(of: item) {
        case .video: return .video
        case .other: return .notAPhoto
        case .photo: break
        }
        guard phase == .listed, lastKnownListedAt == nil else { return .cardNotRead }
        if imported.contains(item.id) { return .imported }
        if item.captureDate == nil { return .noCaptureDate }
        return nil
    }

    public func canSelect(_ item: CameraItem) -> Bool { selectionBlock(for: item) == nil }

    public func isSelected(_ item: CameraItem) -> Bool { selection.contains(item.id) }

    /// Selects or deselects one file; files that can't be imported aren't selected.
    public func toggleSelection(_ item: CameraItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else if canSelect(item) {
            selection.insert(item.id)
        }
    }

    /// Selects every file the filters show that can be imported: stills not yet imported and with a capture date,
    /// so video, other files, imported and undated files are skipped (backlog section 6). Enters the selecting mode.
    public func selectAllNew() {
        var picked = selection
        for section in sections {
            for item in section.items where canSelect(item) { picked.insert(item.id) }
        }
        isSelecting = true
        selection = picked
    }

    public func clearSelection() { selection = [] }

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
            && phase == .listed
    }

    /// Hands the selection to the import: a new job, or the end of the running one. The selection clears once the
    /// files are in the job; Photos access may be asked for first (the first Import). Returns what came of it (the
    /// screen opens the Import screen when a job started), or nil when there was nothing to hand over.
    @discardableResult
    public func importSelected() async -> ImportRequestOutcome? {
        guard canImport, let importer, let link, let key = cameraKey else { return nil }
        let picked = selectedItems
        isStartingImport = true
        defer { isStartingImport = false }
        let outcome = await importer.importItems(picked, from: ImportCamera(descriptor: camera, key: key), link: link)
        switch outcome {
        case .started, .appended, .nothingNew:
            selection.subtract(picked.map(\.id))
            if selection.isEmpty { isSelecting = false }
        case .busyWithAnotherCamera, .stillStarting, .failed:
            break
        }
        importNotice = BrowseWording.importRequested(outcome)
        return outcome
    }

    public func dismissImportNotice() { importNotice = nil }

    /// The grid cell's VoiceOver label (`date` formatted by the screen).
    public func accessibilityLabel(for item: CameraItem, date: String?) -> String {
        BrowseWording.cellAccessibility(name: item.name, date: date, kind: CardLayout.kind(of: item),
                                        isImported: isImported(item), isSelected: isSelected(item),
                                        selectable: isSelecting && canSelect(item))
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
