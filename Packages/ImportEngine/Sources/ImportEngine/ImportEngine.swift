import CameraTransport
import Catalogue
import Foundation
import PhotosBridge

/// Runs one import job at a time: open, enumerate and diff, download, commit (proposal, "Import engine design";
/// discovery is the app's, which hands over a link). The single writer of job state. Transport-neutral: pausing,
/// continuing, stalls and retries are its rules, not a link's, because the Wi-Fi link in Iteration 3 needs the same
/// ones (backlog section 0).
///
/// A job lists the card, leaves out what the catalogue already has as done for the job's purpose (by content: an
/// import job what is imported, a stage job what is staged), and for each file copies the bytes into a temporary
/// file in the engine's own folder, hands it to the destination (Photos, or the staging folder, which moves it),
/// records in the catalogue where it went (`upsert` for Photos, `markStaged` for staging), and removes the temporary
/// file. It pauses
/// on *did suspend* and on removal without failing the file in flight (decision 4), continues when the app says so
/// or the camera is back (decision 7), and retries real errors a limited number of times. Every catalogue write goes
/// through the `CatalogueStore` actor; nothing here runs on the main actor, and nothing touches UIKit.
///
/// **What differs between links comes from their capabilities** (wireless plan, decision 5), never their carrier:
/// - Downloads in flight are `min(settings.downloadsInFlight, link.capabilities.maxDownloadsInFlight)`.
/// - On a link that resumes (`resumesPartialFiles`, Wi-Fi), an interrupted file is continued from the link's
///   latest checkpoint after its name and size are checked against the camera's (`DownloadAttempt`), and its
///   checkpoint is written to the catalogue (`markPartial`) every 16 MiB, when it is interrupted and on
///   `flushCheckpoints()`, so a later job continues it too. On one that doesn't (USB) the partial file is deleted
///   and the file copied again from 0, as before.
///
/// **The Wi-Fi link's events pause, never fail** (backlog Iteration 3, section 9): `.storeRemoved` (and a
/// `cardUnavailable` failure) pauses with `.cardUnavailable` and `.storeAdded` lists the card again;
/// `.sessionLost` pauses with `.cameraUnreachable` until `reconnect`; `.waitingForLocalNetwork` only informs.
public actor ImportEngine {
    /// Progress of the current job, at most four updates a second. One consumer, the Import screen's view model;
    /// only the newest value is kept.
    public nonisolated let progress: AsyncStream<ImportProgress>
    let progressContinuation: AsyncStream<ImportProgress>.Continuation

    public private(set) var state: ImportJobState = .idle
    /// Read at the start of each job; `updateSettings(_:)` changes them for the next one.
    public private(set) var settings: ImportSettings

    let catalogue: any CatalogueStore
    let stagingDirectory: URL
    let clock: EngineClock
    let timeZone: TimeZone
    let policy: ImportPolicy
    let traceHook: (@Sendable (EngineTrace) -> Void)?

    var job: Job?
    /// The last job that finished, for its outcomes and final progress.
    var lastJob: Job?
    var throttle: ProgressThrottle
    var tickerTask: Task<Void, Never>?
    /// One events consumer per link, never cancelled: cancelling an `AsyncStream` consumer ends the stream, and a
    /// link's events must outlive a job. Removed when the stream finishes.
    var consumers: [ObjectIdentifier: (link: any CameraLink, task: Task<Void, Never>)] = [:]
    /// Commits in flight, each in its own unstructured task so that ending a job never cancels one, keyed by a token
    /// and tagged with their job. A new job's diff and `append` wait for those of ended jobs, so a file still being
    /// committed when its job ended has its row before it can be queued again.
    var commitsInFlight: [UUID: (job: UUID, task: Task<CommitResult, Never>)] = [:]

    /// - Parameters:
    ///   - stagingDirectory: Where downloads are written before the destination takes them. Emptied here (anything
    ///     in it is left over from a crash), except its `Partials` folder, which holds resumable partial files a
    ///     catalogue row may point to; of those, any not written for `ImportPolicy.partialRetention` (7 days) are
    ///     deleted.
    ///   - clock: What progress throttling, the rate, stall timing and retry backoff are measured on.
    ///   - timeZone: The zone a link's capture dates are read back to wall-clock time in, for identities; each job
    ///     keeps the zone it started with (an autoupdating zone is fixed at the start, so a change of zone mid-job
    ///     doesn't give Browse's items new identities).
    ///   - trace: Where the engine's own decisions go (the app's log); `.none` records nothing.
    public init(
        catalogue: any CatalogueStore,
        settings: ImportSettings = ImportSettings(),
        stagingDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Imports", isDirectory: true),
        clock: some Clock<Duration> = ContinuousClock(),
        timeZone: TimeZone = .autoupdatingCurrent,
        trace: EngineTraceSink = .none
    ) {
        self.init(catalogue: catalogue, settings: settings, stagingDirectory: stagingDirectory, clock: clock,
                  timeZone: timeZone, policy: .standard, trace: trace.sink)
    }

    init(
        catalogue: any CatalogueStore,
        settings: ImportSettings,
        stagingDirectory: URL,
        clock: some Clock<Duration>,
        timeZone: TimeZone,
        policy: ImportPolicy,
        trace: (@Sendable (EngineTrace) -> Void)?
    ) {
        self.catalogue = catalogue
        self.settings = settings
        self.stagingDirectory = stagingDirectory
        self.clock = EngineClock(clock)
        self.timeZone = timeZone
        self.policy = policy
        self.traceHook = trace
        self.throttle = ProgressThrottle(interval: policy.progressInterval)
        (progress, progressContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let fm = FileManager.default
        if let leftovers = try? fm.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
            for url in leftovers where url.lastPathComponent != Self.partialsFolderName { try? fm.removeItem(at: url) }
        }
        Self.prunePartials(in: stagingDirectory.appendingPathComponent(Self.partialsFolderName, isDirectory: true),
                           olderThan: Date().addingTimeInterval(-policy.partialRetention))
    }

    /// The staging folder's subfolder for resumable partial files, one folder per file.
    static let partialsFolderName = "Partials"

    var partialsDirectory: URL { stagingDirectory.appendingPathComponent(Self.partialsFolderName, isDirectory: true) }

    /// Deletes every partial file's folder whose newest write is before `cutoff`.
    static func prunePartials(in partials: URL, olderThan cutoff: Date) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        for folder in (try? fm.contentsOfDirectory(at: partials, includingPropertiesForKeys: keys)) ?? [] {
            var newest = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [] {
                if let date = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate, date > newest {
                    newest = date
                }
            }
            if newest < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    deinit {
        progressContinuation.finish()
        tickerTask?.cancel()
    }

    // MARK: - Public surface

    /// The current job's progress, or the last job's final progress, unthrottled.
    public var currentProgress: ImportProgress {
        if let job { return snapshot(of: job) }
        if let lastJob { return snapshot(of: lastJob) }
        return ImportProgress(filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0, state: state)
    }

    /// The current job, for `reconnect(_:to:knownItems:route:)`; nil when there is none.
    public var currentJobID: ImportJobID? { job.map { ImportJobID($0.id) } }

    /// What the current job is for: `.staging` for a stage job, `.photos` for an import job (`ImportRoute.purpose`);
    /// nil when there is none. A pick for the other purpose can't be appended to it.
    public var currentPurpose: DestinationKind? { job?.route.purpose }

    /// Whether an import over `carrier` is running, or paused only for what it gets over without the person (a
    /// removal, a lost card or session, a stall it retries by itself). False while the person, the app's leaving,
    /// an expiry or a needed join paused it, and once a stall waits for the person after the automatic retries.
    public func importRunning(carrier: CameraCarrier) -> Bool { job?.importRunning(carrier: carrier) ?? false }

    /// `importRunning(carrier: .usb)`: the app keeps the screen on meanwhile (decision 1). The screen-on rule stays
    /// USB-only.
    public var isUSBImportRunning: Bool { importRunning(carrier: .usb) }

    /// Changes the settings; a job already running keeps the ones it started with.
    public func updateSettings(_ settings: ImportSettings) { self.settings = settings }

    /// Starts a job: the selection from `link`'s card, into `route` (Photos or the staging folder, by the choice made
    /// for this import and the Photos access the caller read just before; backlog section 5; Shamil, 11 Nov). The
    /// route's purpose makes it an import job or a stage job (`ImportRoute.purpose`).
    ///
    /// - Parameter camera: The catalogue's key for the camera, which identities are made with. The link can't give
    ///   it: how to key a camera in MSC is still open (section 2).
    /// - Returns: The job's ID, which `reconnect(_:to:knownItems:route:)` names.
    @discardableResult
    public func start(
        _ selection: ImportSelection,
        from link: any CameraLink,
        camera: CameraKey,
        to route: ImportRoute
    ) throws(ImportEngineError) -> ImportJobID {
        guard job == nil else { throw .jobInProgress }
        guard !selection.isEmpty else { throw .emptySelection }
        // A copy of `.autoupdatingCurrent` keeps following the system zone; the job's must not change.
        let zone = TimeZone(identifier: timeZone.identifier) ?? timeZone
        let job = Job(camera: camera, timeZone: zone, selection: selection, limit: settings.downloadsInFlight,
                      staging: stagingDirectory, link: link, route: route, rateSamples: policy.rateSampleFiles)
        self.job = job
        ensureConsumer(for: link)
        ensureTicker()
        refreshState()
        let id = job.id
        job.driver = Task { await self.runJob(id) }
        return ImportJobID(id)
    }

    /// The picks of `selection` that a new job for `route` would hold, in their order: those the catalogue doesn't
    /// already have done for the route's purpose (`DoneRule`, by content, as the first listing's diff reads it), each
    /// file once. Picks without a capture date are kept: the job shows them as skipped rows. So the app can start a
    /// job with these and say how many it holds, and start none when nothing is left (Photos access denied makes an
    /// *Import to Photos* a stage job, which also leaves out staged files). The job's own diff applies the same rule
    /// again when the card is listed. `.allNew` and `.dateRange` need the card's listing, so they come back empty.
    ///
    /// - Parameter camera: The catalogue's key for the camera, as `start(_:from:camera:to:)` takes it.
    /// - Throws: `.catalogueUnavailable` when the catalogue can't be read.
    public func picksToDo(_ selection: ImportSelection, camera: CameraKey, for route: ImportRoute) async
        throws(ImportEngineError) -> [CameraItem] {
        let picked: [CameraItem]
        switch selection {
        case let .items(items), let .newItems(items): picked = items
        case .allNew, .dateRange: return []
        }
        let zone = TimeZone(identifier: timeZone.identifier) ?? timeZone
        let identities = picked.map { $0.identity(camera: camera, timeZone: zone) }
        let keyed = identities.compactMap(\.self)
        let purpose = route.purpose
        // An ended job may still be committing one of these files: its row has to land first.
        await settleCommits(ofJobsOtherThan: UUID())
        let states: [ObjectIdentity: ObjectState]
        let staged: Set<ObjectIdentity>
        do {
            states = keyed.isEmpty ? [:] : try await catalogue.states(of: keyed)
            staged = purpose == .staging && !keyed.isEmpty ? try await catalogue.stagedStates(of: keyed) : []
        } catch {
            throw .catalogueUnavailable
        }
        var seen = Set<ObjectIdentity.ContentKey>()
        var out: [CameraItem] = []
        for (item, identity) in zip(picked, identities) {
            guard let identity else {
                out.append(item)
                continue
            }
            guard DoneRule.isWanted(state: states[identity] ?? .new, staged: staged.contains(identity),
                                    purpose: purpose, newOnly: selection.newOnly, wholeCard: false),
                  seen.insert(identity.contentKey).inserted else { continue }
            out.append(item)
        }
        return out
    }

    /// Adds files picked in Browse while a job runs; they go at the end. Files already in the job or already done for
    /// the job's purpose (both by content: name, capture time and size, whatever the folder or camera key), files
    /// without a capture date (no identity) and non-stills aren't added. Returns how many were added.
    ///
    /// Done follows the job's purpose (`DoneRule`; Shamil, 11 Nov): an import job leaves out imported files and
    /// ignores staging; a stage job leaves out staged files, and imported ones too when `newOnly` is set.
    ///
    /// - Parameter newOnly: The files come from *Select all new* rather than an explicit pick, so a stage job leaves
    ///   out imported files as well as staged ones. An explicit pick of an imported file may still be staged.
    @discardableResult
    public func append(_ items: [CameraItem], newOnly: Bool = false) async throws(ImportEngineError) -> Int {
        guard let job else { throw .noJob }
        let id = job.id
        // "Already in this job" and "already imported" are by content (name, capture time, size; Shamil, 8 Nov), so a
        // file Browse lists in another folder than the job's listing did is never added twice.
        var seen = Set<ObjectIdentity.ContentKey>()
        var candidates: [(item: CameraItem, identity: ObjectIdentity)] = []
        for item in items where item.format.isStill {
            guard let identity = item.identity(camera: job.camera, timeZone: job.timeZone),
                  job.entry(sameContentAs: identity) == nil, seen.insert(identity.contentKey).inserted else { continue }
            candidates.append((item, identity))
        }
        guard !candidates.isEmpty else { return 0 }
        await settleCommits(ofJobsOtherThan: id)
        let facts: DoneFacts?
        do {
            facts = try await doneFacts(of: candidates.map(\.identity), job: id)
        } catch {
            throw .catalogueUnavailable
        }
        guard let facts, let current = self.job, current.id == id else { throw .noJob }
        var wanted: [(item: CameraItem, identity: ObjectIdentity)] = []
        for c in candidates where current.entry(sameContentAs: c.identity) == nil {
            let staged = facts.staged.contains(c.identity)
            guard DoneRule.isWanted(state: facts.states[c.identity] ?? .new, staged: staged, purpose: facts.purpose,
                                    newOnly: newOnly, wholeCard: false) else {
                if staged && facts.purpose == .staging { trace(.alreadyStaged(c.item.name)) }
                continue
            }
            wanted.append(c)
        }
        // RAW+JPEG pairs among the added files, or between an added file and a lone one of the job still to download
        // (section 7.1). The added files' partners among themselves go next to each other at the end of the queue.
        let lone = current.sortedEntries.filter { $0.partner == nil && $0.isToDownload }
        let pairs = Self.pairs(among: lone.map(\.item) + wanted.map(\.item))
            .filter { $0.0 >= lone.count || $0.1 >= lone.count }
        let newPairs = pairs.filter { $0.0 >= lone.count && $0.1 >= lone.count }
            .map { ($0.0 - lone.count, $0.1 - lone.count) }
        var created: [Int: FileEntry] = [:]
        for i in Self.pairAwareOrder(count: wanted.count, pairs: newPairs) {
            let c = wanted[i]
            let entry = FileEntry(identity: c.identity, index: current.nextIndex, item: c.item)
            entry.queuedUnderStagingRule = facts.purpose == .staging
            current.nextIndex += 1
            current.add(entry)
            current.queue.append(c.identity)
            created[i] = entry
        }
        let added = created.count
        for (a, b) in pairs {
            let first = a < lone.count ? lone[a] : created[a - lone.count]
            let second = b < lone.count ? lone[b] : created[b - lone.count]
            if let first, let second { current.pair(first, second) }
        }
        if added > 0 {
            current.signal.fire()
            refreshState()
        }
        return added
    }

    /// Pauses the job. Nothing new starts; a download in flight carries on and is committed if it finishes (decision
    /// 4). `.appInBackground` is the fallback for when *did suspend* doesn't reach the engine: the app calls it from
    /// its scene phase. `.cameraRemoved` and `.cameraUnreachable` act as the camera going away (`.removed`,
    /// `.sessionLost`), and `.cardUnavailable` as the card going (`.storeRemoved`).
    ///
    /// On the continued task's expiry the app calls `flushCheckpoints()` first, then `pause(.taskExpired)`, then
    /// stops the link's transfer (W13); `.needsJoin` is the app's, when getting the camera back needs a join it can't
    /// make from the background (W14).
    public func pause(_ reason: PauseReason = .byPerson) throws(ImportEngineError) {
        guard let job else { throw .noJob }
        switch reason {
        case .cameraRemoved: cameraLost(job, .cameraRemoved)
        case .cameraUnreachable:
            job.cameraLossReason = .cameraUnreachable
            cameraLost(job, .cameraUnreachable)
        case .cardUnavailable: cardLost(job)
        case .appInBackground, .stalled, .byPerson, .taskExpired, .needsJoin: addPause(reason, to: job)
        }
    }

    /// Whether the job is paused for `reason`, whichever pause `state` shows (`PauseReason.precedence`): an expiry
    /// stays hidden behind a needed join, for one (W14).
    public func isPaused(for reason: PauseReason) -> Bool { job?.pauses.contains(reason) ?? false }

    /// Continues a paused job in the same session, without reopening it.
    ///
    /// - Parameters:
    ///   - reason: nil (the Continue button) lifts the person's pause, the app's, a stall and an expiry;
    ///     `.appInBackground` (the app coming back) lifts only that, so the app's return never undoes a pause the
    ///     person made. A removal, a lost card or session and a needed join are lifted only by `reconnect`.
    ///   - route: A new route for the files not yet committed, after re-reading Photos access (backlog section 5).
    ///     Refused, keeping the job's own, where it would turn a stage job into an import job or move staging from
    ///     this iPhone to iCloud Drive (`ImportRoute.mayChange(to:)`).
    public func resume(_ reason: PauseReason? = nil, to route: ImportRoute? = nil) throws(ImportEngineError) {
        guard let job else { throw .noJob }
        if let route { change(job, to: route) }
        let lifted: Set<PauseReason>
        switch reason {
        case nil: lifted = [.byPerson, .appInBackground, .stalled, .taskExpired]
        case .appInBackground?: lifted = [.appInBackground]
        case .byPerson?: lifted = [.byPerson]
        case .stalled?: lifted = [.stalled]
        case .taskExpired?: lifted = [.taskExpired]
        case .cameraRemoved?, .cameraUnreachable?, .cardUnavailable?, .needsJoin?: lifted = []
        }
        if lifted.contains(.stalled) {
            job.stallHold = false
            job.stallResumeAt = nil
            for entry in job.entries.values { entry.stalls = 0 }
        }
        liftPauses(lifted, of: job)
    }

    /// The camera is back after a removal: `reconnect(_:to:knownItems:route:)` for the current job, listing the
    /// card through the link.
    public func reconnect(_ link: any CameraLink, to route: ImportRoute? = nil) throws(ImportEngineError) {
        guard let job else { throw .noJob }
        try reconnect(ImportJobID(job.id), to: link, route: route)
    }

    /// The camera is back, or a new session is up: the job carries on through `link` (a new link, or the same one
    /// opened again). The engine opens it, lists the card (or takes `knownItems`), finds the files left by content
    /// (name, capture time, size) and goes on. On a link that resumes, the file that was in flight continues from
    /// its latest checkpoint once the camera confirms its name and size; on one that doesn't, it is copied again
    /// from its start (decision 7).
    ///
    /// Lifts every pause that waits for the camera or a session (`.cameraRemoved`, `.cameraUnreachable`,
    /// `.cardUnavailable`, `.needsJoin`) and the continued task's expiry (`.taskExpired`): Continue after an
    /// expiry is a new continued task, a reopen, then this (W13). A download still in flight on the old session is
    /// walked away from, its partial file kept where the link resumes.
    ///
    /// - Parameters:
    ///   - job: The job to carry on; a job that has since ended (or another) throws `.noJob`.
    ///   - knownItems: The card as the app has just listed it (`IPLink.list(reusing:)`, which asks GetObjectInfo
    ///     only for handles it hasn't seen, W8); empty to have the engine call `list()`. Each file's name and size
    ///     are still checked against the camera before a partial file is continued.
    ///   - route: A new route for the files not yet committed, after re-reading Photos access (backlog section 5).
    ///     Refused, keeping the job's own, where it would turn a stage job into an import job or move staging from
    ///     this iPhone to iCloud Drive (`ImportRoute.mayChange(to:)`).
    ///   - keepingExpiry: true leaves `.taskExpired` in place: the new link is the job's and the card is listed, but
    ///     nothing is copied until Continue lifts the expiry (W14: a Wi-Fi recovery that ends after iOS ended the
    ///     continued task).
    /// - Throws: `.cameraNotRemoved` when the job is neither waiting for the camera nor paused for a reason this
    ///   lifts.
    public func reconnect(_ job: ImportJobID, to link: any CameraLink, knownItems: [CameraItem] = [],
                          route: ImportRoute? = nil, keepingExpiry: Bool = false) throws(ImportEngineError) {
        guard let current = self.job, current.id == job.rawValue else { throw .noJob }
        guard current.phase == .waitingForCamera || !current.pauses.isDisjoint(with: PauseReason.liftedByReconnect)
        else { throw .cameraNotRemoved }
        if let route { change(current, to: route) }
        for entry in current.sortedEntries {
            guard let d = entry.download else { continue }
            d.attempt.abandon()
            entry.interrupted = true
            current.requeue(entry)
        }
        current.link = link
        current.linkGeneration += 1
        current.listRetries = 0
        current.pendingListing = knownItems.isEmpty ? nil : knownItems
        ensureConsumer(for: link)
        current.phase = .listing
        liftPauses(PauseReason.liftedByReconnect.subtracting(keepingExpiry ? [.taskExpired] : []), of: current)
        current.signal.fire()
        scheduleCheckpointFlush()
    }

    /// Writes every resumable file's latest checkpoint to the catalogue (`markPartial`) where it is newer than the
    /// one written, so a job the app loses (iOS ends it after an expiry) leaves rows a later job resumes from. The
    /// app calls it before `pause(.taskExpired)` (backlog Iteration 3, section 9, *Expiry is normal*). Returns once
    /// the catalogue has them; a catalogue that refuses one is left as it was (the in-memory resume point holds).
    public func flushCheckpoints() async {
        guard let job else { return }
        let id = job.id
        for entry in job.sortedEntries {
            guard let resumable = entry.resumable, let seed = resumable.best else { continue }
            await saveCheckpoint(seed, of: entry.identity, in: id)
        }
    }

    /// Cancels the job, if there is one. Files already committed stay where they went; downloads in flight are
    /// abandoned and their temporary files removed at once, except a resumable partial file whose checkpoint the
    /// catalogue has (a later job continues it; `ImportPolicy.partialRetention` cleans up one that never does).
    public func cancel() {
        guard let job else { return }
        end(job, .cancelled)
    }

    // MARK: - State

    func current(_ id: UUID) -> Job? {
        guard let job, job.id == id else { return nil }
        return job
    }

    /// The job `id` once it has ended, while it is still the last job.
    func endedJob(_ id: UUID) -> Job? {
        guard let lastJob, lastJob.id == id, lastJob.finished != nil else { return nil }
        return lastJob
    }

    func trace(_ event: EngineTrace) { traceHook?(event) }

    /// Derives the public state and offers a snapshot to the throttle. Called after every change.
    func refreshState() {
        if let job { state = job.state }
        offer(currentProgress)
    }

    /// Gives the job a new route for the files not yet committed, unless the job may not take it
    /// (`ImportRoute.mayChange(to:)`: a stage job never becomes an import job, and staging on this iPhone never moves
    /// to iCloud Drive mid-job), when it keeps its route and the refusal is traced.
    func change(_ job: Job, to route: ImportRoute) {
        guard job.route.mayChange(to: route) else {
            trace(.routeRefused(route.decision))
            return
        }
        let before = job.route.decision
        job.route = route
        if route.decision != before { trace(.destinationChanged(route.decision)) }
    }

    func addPause(_ reason: PauseReason, to job: Job) {
        if job.pauses.isEmpty {
            for entry in job.entries.values {
                guard let d = entry.download else { continue }
                entry.interrupted = true
                d.pausedDuring = true
            }
        }
        if job.pauses.insert(reason).inserted { trace(.paused(reason)) }
        refreshState()
    }

    func liftPauses(_ reasons: Set<PauseReason>, of job: Job) {
        guard !job.pauses.isEmpty else { return }
        job.pauses.subtract(reasons)
        if job.pauses.isEmpty {
            let now = clock.now
            for entry in job.entries.values { entry.download?.lastProgressAt = now }
            trace(.resumed)
            job.signal.fire()
        }
        refreshState()
    }

    /// The camera went away (`reason` `.cameraRemoved`: the `.removed` event or a `.disconnected` failure, in either
    /// order; `.cameraUnreachable`: `.sessionLost`): walk away from every download, put it back in the queue in
    /// order, and wait for `reconnect`. A partial file is deleted, or kept for the resume on a link that resumes.
    /// Files being committed carry on. Idempotent; a lost session names a removal already recorded more exactly
    /// (the failure and the event race), never the other way round.
    func cameraLost(_ job: Job, _ reason: PauseReason) {
        noteLost(job)
        guard job.phase != .waitingForCamera else {
            if reason == .cameraUnreachable {
                job.pauses.remove(.cameraRemoved) // the session was lost: the camera wasn't removed
            } else if job.pauses.contains(.cameraUnreachable) {
                return
            }
            addPause(reason, to: job)
            return
        }
        stopDownloads(of: job)
        addPause(reason, to: job)
        job.signal.fire()
        finishIfDrained(job.id) // nothing left to copy: the job is complete, camera or not
    }

    /// The camera dropped its card (`.storeRemoved`, or a `cardUnavailable` failure): like a lost camera, with the
    /// session still up, so nothing counts as failed (the spike's 82-files bug) and `.storeAdded` lists the card
    /// again. Idempotent.
    func cardLost(_ job: Job) {
        noteLost(job)
        if job.phase != .waitingForCamera { stopDownloads(of: job) }
        addPause(.cardUnavailable, to: job)
        job.signal.fire()
        finishIfDrained(job.id)
    }

    /// The card is back (`.storeAdded`) and the session never went: list it again on the same link, find the files
    /// left by content (handles may have changed) and go on.
    func cardBack(_ job: Job) {
        guard job.pauses.contains(.cardUnavailable), job.phase == .waitingForCamera,
              job.pauses.isDisjoint(with: [.cameraRemoved, .cameraUnreachable]) else { return }
        relist(job)
        liftPauses([.cardUnavailable], of: job)
    }

    /// Lists the card again on the job's link, before anything else starts.
    func relist(_ job: Job) {
        job.linkGeneration += 1
        job.listRetries = 0
        job.pendingListing = nil
        job.phase = .listing
        job.signal.fire()
    }

    /// Walks away from every download (each is put back in the queue in order) and waits for the camera; the
    /// latest checkpoints of resumable files are written to the catalogue.
    func stopDownloads(of job: Job) {
        for entry in job.sortedEntries {
            guard let d = entry.download else { continue }
            d.attempt.abandon()
            entry.interrupted = true
            job.requeue(entry)
        }
        job.phase = .waitingForCamera
        scheduleCheckpointFlush()
    }

    /// `flushCheckpoints()` in its own task, from a synchronous step.
    func scheduleCheckpointFlush() {
        guard job?.entries.values.contains(where: { $0.resumable != nil }) == true else { return }
        Task { await self.flushCheckpoints() }
    }

    /// Ends the job: abandons downloads (a committing file finishes in its own unstructured task, which cancelling the
    /// driver doesn't reach, and records its row), wakes the driver so it drains and removes the job's folder (or
    /// leaves it to the last commit still reading from it: `removeFolderIfUnused(of:)`).
    func end(_ job: Job, _ outcome: JobOutcome) {
        guard self.job === job else { return }
        for entry in job.entries.values {
            if let d = entry.download {
                d.attempt.abandon()
                entry.phase = .queued
            }
            // A half kept for its partner isn't committed by a job that ends before the pair is complete: it stays
            // on the card, and the next import offers the pair again. Its file is deleted now, as an abandoned
            // download's is, not left for the job's folder, which the driver removes only once its lanes have
            // returned (after the job reads as finished); on a link that resumes it is kept or deleted as any
            // partial copy is, below.
            if let held = entry.held {
                entry.phase = .queued
                if !held.download.attempt.keepsFiles {
                    try? FileManager.default.removeItem(at: held.url)
                    try? FileManager.default.removeItem(at: held.download.attempt.directory)
                }
            }
            // A resumable partial stays only where the catalogue points to it. A committing file's folder holds
            // the staged file; `commitAndRecord` removes it once the commit is done.
            if case .committing = entry.phase { continue }
            if let r = entry.resumable, entry.outcome == nil, r.persistedOffset == 0 {
                try? FileManager.default.removeItem(at: r.folder)
                entry.resumable = nil
            }
        }
        job.finished = outcome
        job.signal.finish()
        job.driver?.cancel()
        lastJob = job
        self.job = nil
        state = .finished(outcome)
        trace(.finished(outcome))
        refreshState()
    }

    // MARK: - Events

    func ensureConsumer(for link: any CameraLink) {
        let key = ObjectIdentifier(link)
        guard consumers[key] == nil else { return }
        let events = link.events
        let task = Task { [weak self] in
            for await event in events { await self?.handle(event, from: key) }
            await self?.consumerEnded(key)
        }
        consumers[key] = (link, task)
    }

    func consumerEnded(_ key: ObjectIdentifier) { consumers[key] = nil }

    func handle(_ event: CameraLinkEvent, from key: ObjectIdentifier) {
        guard let job, ObjectIdentifier(job.link) == key else { return }
        trace(.linkEvent(event))
        switch event {
        case .didSuspend: addPause(.appInBackground, to: job)
        case .removed: cameraLost(job, .cameraRemoved)
        // No pause was made for these; *resumed operations* also fires with no suspension before it, so the job
        // continues on the app's return (`resume(.appInBackground)`), not on this.
        case .willSuspend, .cancelledSuspending, .resumedOperations: break
        // Wi-Fi's events (`IPLink`); a USB link never sends them. Waiting for the Local Network prompt only informs
        // (the link keeps waiting, the app explains the prompt); it is traced above.
        case .waitingForLocalNetwork: break
        case .storeRemoved: cardLost(job)
        case .storeAdded: cardBack(job)
        case .sessionLost:
            job.cameraLossReason = .cameraUnreachable
            cameraLost(job, .cameraUnreachable)
        }
    }

    // MARK: - Ticker, stalls and progress

    /// Runs while a job is active or a snapshot waits to be published. Each deadline is the last tick plus the
    /// interval, so a clock that jumped is ticked once, not caught up.
    func ensureTicker() {
        guard tickerTask == nil else { return }
        let clock = self.clock
        let first = clock.now + policy.progressInterval
        tickerTask = Task { [weak self] in
            var deadline = first
            while true {
                do { try await clock.sleep(until: deadline) } catch { return }
                guard let self, let next = await self.tick() else { return }
                deadline = next
            }
        }
    }

    /// Stall detection and lifting, then progress. Returns the next deadline, or nil when the ticker stops.
    func tick() -> Duration? {
        let now = clock.now
        trace(.tick(now))
        if let job {
            if job.pauses.isEmpty {
                var stalled: [FileEntry] = []
                for entry in job.sortedEntries {
                    guard let d = entry.download else { continue }
                    let reading = d.attempt.meter.reading
                    // Progress restarts the stall clock but not the stall count, which is per file (3 automatic
                    // retries) and reset only by the person continuing.
                    if reading.bytes > d.lastBytes { d.lastBytes = reading.bytes }
                    noteFirstByte(of: entry, in: job, reading: reading)
                    let last = max(d.lastProgressAt, reading.grewAt ?? d.lastProgressAt)
                    if now - last >= policy.stallTimeout { stalled.append(entry) }
                }
                if !stalled.isEmpty { stall(stalled, of: job, at: now) }
            } else if job.pauses.contains(.stalled), !job.stallHold, let at = job.stallResumeAt, now >= at {
                job.stallResumeAt = nil
                liftPauses([.stalled], of: job)
            }
        }
        if let due = throttle.due(at: now) { publish(due, at: now) }
        if job != nil { offer(currentProgress) }
        if job == nil && !throttle.hasPending {
            tickerTask = nil
            return nil
        }
        return now + policy.progressInterval
    }

    /// A stall pauses the job and retries the file with a fresh call (decision 4): the attempt is abandoned (a late
    /// file is discarded) and the file goes back to the front of the queue.
    func stall(_ entries: [FileEntry], of job: Job, at now: Duration) {
        for entry in entries {
            guard let d = entry.download else { continue }
            d.attempt.abandon()
            entry.stalls += 1
            entry.interrupted = true
            job.requeue(entry)
            trace(.stalled(entry.item.name, count: entry.stalls))
            if entry.stalls > policy.automaticStallRetries { job.stallHold = true }
        }
        job.stallResumeAt = job.stallHold ? nil : now + policy.stallRetryDelay
        addPause(.stalled, to: job)
        scheduleCheckpointFlush()
    }

    func offer(_ p: ImportProgress) {
        let now = clock.now
        if let out = throttle.offer(p, at: now) { publish(out, at: now) }
        if throttle.hasPending { ensureTicker() }
    }

    func publish(_ p: ImportProgress, at now: Duration) {
        progressContinuation.yield(p)
        trace(.published(now))
    }

    func snapshot(of job: Job) -> ImportProgress {
        var filesDone = 0, skipped = 0, failed = 0, staged = 0
        var bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0
        for entry in job.entries.values {
            let size = entry.item.size
            bytesTotal += size
            switch entry.phase {
            case let .done(outcome):
                filesDone += 1
                bytesDone += size
                switch outcome {
                case .imported: break
                case .staged: staged += 1
                case .skipped: skipped += 1
                case .failed: failed += 1
                }
            case .held, .committing:
                bytesDone += size
            case let .downloading(d):
                // A high-water mark: a restarted download holds its place until the new attempt passes it, so
                // published progress never goes backwards.
                entry.shownBytes = max(entry.shownBytes, min(d.attempt.meter.reading.bytes, size))
                bytesDone += entry.shownBytes
            case .queued, .waitingToRetry:
                bytesDone += entry.shownBytes
            }
        }
        for item in job.unkeyed {
            bytesTotal += item.size
            bytesDone += item.size
            filesDone += 1
            skipped += 1
        }
        return ImportProgress(
            filesDone: filesDone, filesTotal: job.entries.count + job.unkeyed.count, bytesDone: bytesDone,
            bytesTotal: bytesTotal, bytesPerSecond: job.rate.bytesPerSecond, state: job.state,
            destination: job.route.decision, filesSkipped: skipped, filesFailed: failed, filesStaged: staged,
            runningCarrier: job.runningCarrier,
            stallWaitsForPerson: job.finished == nil && job.stallHold && job.pauses.contains(.stalled)
        )
    }

    // MARK: - Commits of ended jobs

    /// Waits for every commit in flight that belongs to a job other than `id` (only ended jobs can have one), so its
    /// row is written before the catalogue is asked what to queue.
    func settleCommits(ofJobsOtherThan id: UUID) async {
        for commit in commitsInFlight.values where commit.job != id {
            _ = await commit.task.value
        }
    }

    /// Removes an ended job's staging folder once nothing reads from it any more: its driver has returned (so every
    /// lane has, with the commits the lanes wait for) and none of its commits is in flight. Called by the driver as
    /// it returns and by each commit no lane waits for once it is done, so whichever is last removes the folder, and
    /// nobody waits for anybody: a destination that never answers keeps only that folder, which the next launch
    /// empties with the rest of the staging folder. Each job has its own folder, so a job started meanwhile keeps
    /// its own.
    func removeFolderIfUnused(of job: Job) {
        guard job.finished != nil, job.driverReturned,
              !commitsInFlight.values.contains(where: { $0.job == job.id }) else { return }
        try? FileManager.default.removeItem(at: job.jobDirectory)
    }

    // MARK: - Test support

    /// The current job's zone.
    func jobTimeZone() -> TimeZone? { job?.timeZone }

    /// The last finished job's driver, to wait until it has returned.
    func lastJobDriver() -> Task<Void, Never>? { lastJob?.driver }

    /// The latest attempt at a resumable file of the current job: the one whose checkpoint crossings are written.
    func latestAttempt(of identity: ObjectIdentity) -> DownloadAttempt? {
        job?.entries[identity]?.resumable?.previous
    }

    /// The outcome of every resolved file of the current or last job.
    func outcomes() -> [ObjectIdentity: FileOutcome] {
        guard let j = job ?? lastJob else { return [:] }
        var out: [ObjectIdentity: FileOutcome] = [:]
        for (identity, entry) in j.entries {
            if let o = entry.outcome { out[identity] = o }
        }
        return out
    }
}
