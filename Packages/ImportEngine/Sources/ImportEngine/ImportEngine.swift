import CameraTransport
import Catalogue
import Foundation
import PhotosBridge

/// Runs one import job at a time: open, enumerate and diff, download, commit (proposal, "Import engine design";
/// discovery is the app's, which hands over a link). The single writer of job state. Transport-neutral: pausing,
/// continuing, stalls and retries are its rules, not a link's, because the Wi-Fi link in Iteration 3 needs the same
/// ones (backlog section 0).
///
/// A job lists the card, leaves out what the catalogue already has as imported (by identity), and for each file
/// copies the bytes into a temporary file in the staging folder, hands it to the destination (Photos or the Files
/// folder, which moves it), records a catalogue row saying where it went, and removes the temporary file. It pauses
/// on *did suspend* and on removal without failing the file in flight (decision 4), continues when the app says so
/// or the camera is back (decision 7), and retries real errors a limited number of times. Every catalogue write goes
/// through the `CatalogueStore` actor; nothing here runs on the main actor, and nothing touches UIKit.
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
    ///   - stagingDirectory: Where downloads are written before the destination takes them. Emptied here: anything
    ///     in it is left over from a crash (resuming from it is Iteration 2's work).
    ///   - clock: What progress throttling, the rate, stall timing and retry backoff are measured on.
    ///   - timeZone: The zone a link's capture dates are read back to wall-clock time in, for identities; each job
    ///     keeps the zone it started with (an autoupdating zone is fixed at the start, so a change of zone mid-job
    ///     doesn't give Browse's items new identities).
    public init(
        catalogue: any CatalogueStore,
        settings: ImportSettings = ImportSettings(),
        stagingDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Imports", isDirectory: true),
        clock: some Clock<Duration> = ContinuousClock(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.init(catalogue: catalogue, settings: settings, stagingDirectory: stagingDirectory, clock: clock,
                  timeZone: timeZone, policy: .standard, trace: nil)
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
            for url in leftovers { try? fm.removeItem(at: url) }
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

    /// Whether a USB import is running (or paused for removal or a stall, which it gets over by itself), so the app
    /// keeps the screen on (decision 1). False while the person or the app's leaving paused it, and once a stall
    /// waits for the person after the automatic retries.
    public var isUSBImportRunning: Bool { job?.isUSBImportRunning ?? false }

    /// Changes the settings; a job already running keeps the ones it started with.
    public func updateSettings(_ settings: ImportSettings) { self.settings = settings }

    /// Starts a job: the selection from `link`'s card, into `route` (Photos or the Files folder, by the destination
    /// setting and the Photos access the caller read just before; backlog section 5).
    ///
    /// - Parameter camera: The catalogue's key for the camera, which identities are made with. The link can't give
    ///   it: how to key a camera in MSC is still open (section 2).
    public func start(
        _ selection: ImportSelection,
        from link: any CameraLink,
        camera: CameraKey,
        to route: ImportRoute
    ) throws(ImportEngineError) {
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
    }

    /// Adds files picked in Browse while a job runs; they go at the end. Files already in the job, already imported
    /// or without a capture date (no identity) aren't added, and nor are non-stills. Returns how many were added.
    @discardableResult
    public func append(_ items: [CameraItem]) async throws(ImportEngineError) -> Int {
        guard let job else { throw .noJob }
        let id = job.id
        var seen = Set<ObjectIdentity>()
        var candidates: [(item: CameraItem, identity: ObjectIdentity)] = []
        for item in items where item.format.isStill {
            guard let identity = item.identity(camera: job.camera, timeZone: job.timeZone),
                  job.entries[identity] == nil, seen.insert(identity).inserted else { continue }
            candidates.append((item, identity))
        }
        guard !candidates.isEmpty else { return 0 }
        await settleCommits(ofJobsOtherThan: id)
        let states: [ObjectIdentity: ObjectState]
        do {
            states = try await catalogue.states(of: candidates.map(\.identity))
        } catch {
            throw .catalogueUnavailable
        }
        guard let current = self.job, current.id == id else { throw .noJob }
        var added = 0
        for c in candidates where current.entries[c.identity] == nil && states[c.identity] != .imported {
            let entry = FileEntry(identity: c.identity, index: current.nextIndex, item: c.item)
            current.nextIndex += 1
            current.entries[c.identity] = entry
            current.queue.append(c.identity)
            added += 1
        }
        if added > 0 {
            current.signal.fire()
            refreshState()
        }
        return added
    }

    /// Pauses the job. Nothing new starts; a download in flight carries on and is committed if it finishes (decision
    /// 4). `.appInBackground` is the fallback for when *did suspend* doesn't reach the engine: the app calls it from
    /// its scene phase. `.cameraRemoved` acts as a removal.
    public func pause(_ reason: PauseReason = .byPerson) throws(ImportEngineError) {
        guard let job else { throw .noJob }
        switch reason {
        case .cameraRemoved: cameraRemoved(job)
        case .appInBackground, .stalled, .byPerson: addPause(reason, to: job)
        }
    }

    /// Continues a paused job in the same session, without reopening it.
    ///
    /// - Parameters:
    ///   - reason: nil (the Continue button) lifts the person's pause, the app's and a stall; `.appInBackground` (the
    ///     app coming back) lifts only that, so the app's return never undoes a pause the person made. A removal is
    ///     lifted only by `reconnect(_:to:)`.
    ///   - route: A new route for the files not yet committed, after re-reading Photos access (backlog section 5).
    public func resume(_ reason: PauseReason? = nil, to route: ImportRoute? = nil) throws(ImportEngineError) {
        guard let job else { throw .noJob }
        if let route { change(job, to: route) }
        let lifted: Set<PauseReason>
        switch reason {
        case nil: lifted = [.byPerson, .appInBackground, .stalled]
        case .appInBackground?: lifted = [.appInBackground]
        case .byPerson?: lifted = [.byPerson]
        case .stalled?: lifted = [.stalled]
        case .cameraRemoved?: lifted = []
        }
        if lifted.contains(.stalled) {
            job.stallHold = false
            job.stallResumeAt = nil
            for entry in job.entries.values { entry.stalls = 0 }
        }
        liftPauses(lifted, of: job)
    }

    /// The camera is back after a removal: a new link (or the same one), which the engine opens and lists, then
    /// finds the files left by identity and copies the interrupted one again from its start (decision 7).
    public func reconnect(_ link: any CameraLink, to route: ImportRoute? = nil) throws(ImportEngineError) {
        guard let job else { throw .noJob }
        guard job.phase == .waitingForCamera else { throw .cameraNotRemoved }
        if let route { change(job, to: route) }
        job.link = link
        job.linkGeneration += 1
        job.listRetries = 0
        ensureConsumer(for: link)
        job.phase = .listing
        liftPauses([.cameraRemoved], of: job)
        job.signal.fire()
    }

    /// Cancels the job, if there is one. Files already committed stay where they went; downloads in flight are
    /// abandoned and their temporary files removed at once.
    public func cancel() {
        guard let job else { return }
        end(job, .cancelled)
    }

    // MARK: - State

    func current(_ id: UUID) -> Job? {
        guard let job, job.id == id else { return nil }
        return job
    }

    func trace(_ event: EngineTrace) { traceHook?(event) }

    /// Derives the public state and offers a snapshot to the throttle. Called after every change.
    func refreshState() {
        if let job { state = job.state }
        offer(currentProgress)
    }

    func change(_ job: Job, to route: ImportRoute) {
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

    /// The camera went away (the `.removed` event or a `.disconnected` failure, in either order): abandon every
    /// download, delete its partial file, put it back in the queue in order, and wait for `reconnect`. Files being
    /// committed carry on. Idempotent.
    func cameraRemoved(_ job: Job) {
        guard job.phase != .waitingForCamera else { return }
        for entry in job.sortedEntries {
            guard let d = entry.download else { continue }
            d.attempt.abandon()
            entry.interrupted = true
            job.requeue(entry)
        }
        job.phase = .waitingForCamera
        addPause(.cameraRemoved, to: job)
        job.signal.fire()
        finishIfDrained(job.id) // nothing left to copy: the job is complete, camera or not
    }

    /// Ends the job: abandons downloads (a committing file finishes in its own unstructured task, which cancelling the
    /// driver doesn't reach, and records its row), wakes the driver so it drains and removes the staging folder.
    func end(_ job: Job, _ outcome: JobOutcome) {
        guard self.job === job else { return }
        for entry in job.entries.values {
            guard let d = entry.download else { continue }
            d.attempt.abandon()
            entry.phase = .queued
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
        case .removed: cameraRemoved(job)
        // No pause was made for these; *resumed operations* also fires with no suspension before it, so the job
        // continues on the app's return (`resume(.appInBackground)`), not on this.
        case .willSuspend, .cancelledSuspending, .resumedOperations: break
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
        var filesDone = 0, skipped = 0, failed = 0
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
                case .skipped: skipped += 1
                case .failed: failed += 1
                }
            case .committing:
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
            destination: job.route.decision, filesSkipped: skipped, filesFailed: failed,
            isUSBImportRunning: job.isUSBImportRunning
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

    // MARK: - Test support

    /// The current job's zone.
    func jobTimeZone() -> TimeZone? { job?.timeZone }

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
