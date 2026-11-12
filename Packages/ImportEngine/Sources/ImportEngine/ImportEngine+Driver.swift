import CameraTransport
import Catalogue
import Foundation
import PhotosBridge

extension ImportEngine {
    /// One job from start to finish: list and diff, download, and on a removal wait for the camera, relist and find
    /// the files left by content (name, capture time, size). Removes the job's staging folder when it ends, unless a
    /// commit no lane waits for is still reading from it (`removeFolderIfUnused(of:)`).
    func runJob(_ id: UUID) async {
        guard let job = current(id) else { return }
        defer {
            job.driverReturned = true
            removeFolderIfUnused(of: job)
        }
        while let job = current(id) {
            switch job.phase {
            case .listing:
                await listPhase(id)
            case .downloading:
                await downloadPhase(id)
            case .waitingForCamera:
                trace(.idle(queued: job.queue.count, inFlight: 0))
                await job.signal.wait()
            }
            finishIfDrained(id)
        }
    }

    /// Completes the job when nothing is left: the check and the finish are one synchronous step, so an `append`
    /// can't land in between. Also while waiting for the camera once the card has been listed: a removal during the
    /// last commit leaves nothing to copy, and the job mustn't wait (screen on) for a camera it no longer needs.
    ///
    /// Held halves of pairs whose partner won't come are committed first (`commitLoneHalves(of:)`), so the job
    /// finishes once those commits are done.
    func finishIfDrained(_ id: UUID) {
        guard let job = current(id) else { return }
        commitLoneHalves(of: job)
        guard job.queue.isEmpty, !job.hasActiveFiles else { return }
        switch job.phase {
        case .downloading: break
        case .waitingForCamera: guard job.hasListed else { return }
        case .listing: return
        }
        end(job, .completed)
    }

    func currentListing(_ id: UUID, _ generation: Int) -> Job? {
        guard let job = current(id), job.linkGeneration == generation, job.phase == .listing else { return nil }
        return job
    }

    // MARK: - Listing

    func listPhase(_ id: UUID) async {
        guard let job = current(id) else { return }
        let link = job.link
        let generation = job.linkGeneration
        // The card as the app just listed it, handed over by `reconnect` (taken once: a relist asks the link).
        let known = job.pendingListing
        job.pendingListing = nil
        let listed: [CameraItem]
        do throws(CameraLinkFailure) {
            try await link.open()
            // Which session the job now uses, so a late loss of the one it replaced is told apart (I13).
            let session = await link.sessionGeneration
            currentListing(id, generation)?.useSession(session)
            if let known { listed = known } else { listed = try await link.list() }
        } catch {
            await listingFailed(error, id: id, generation: generation)
            return
        }
        guard let job = currentListing(id, generation) else { return }
        job.listRetries = 0
        if job.hasListed {
            remap(job, listed)
        } else {
            await diff(listed, id: id, generation: generation)
        }
    }

    func listingFailed(_ failure: CameraLinkFailure, id: UUID, generation: Int) async {
        guard let job = currentListing(id, generation) else { return }
        switch failure.outcome {
        case .retryNow where job.listRetries < policy.retryDelays.count:
            job.listRetries += 1
            let until = clock.now + policy.retryDelays[job.listRetries - 1]
            trace(.retrying(EngineTrace.listingName, retry: job.listRetries, until: until))
            try? await clock.sleep(until: until)
        case .retryOnReconnect:
            if failure.kind == .cardUnavailable { cardLost(job) } else { cameraLost(job, job.cameraLossReason) }
        case .retryNow, .skipFile, .stopJob:
            end(job, .stopped(failure.kind))
        }
    }

    /// The first listing: what to copy, against the catalogue (stage 3), which answers by content (Shamil, 8 Nov).
    /// A picked file is found on this listing by content too, since Browse's catalogue and this one may report its
    /// folder differently; its row keeps the pick's identity. What counts as done follows the job's purpose
    /// (`DoneRule`; Shamil, 11 Nov): an import job leaves out imported files, a stage job staged ones (and imported
    /// ones where only new files were asked for).
    func diff(_ listed: [CameraItem], id: UUID, generation: Int) async {
        guard let job = currentListing(id, generation) else { return }
        let camera = job.camera
        let zone = job.timeZone

        enum Plan { case queue, skip(SkipReason) }
        var planned: [(item: CameraItem, identity: ObjectIdentity, plan: Plan)] = []
        var unkeyed: [CameraItem] = []
        let keepSkippedRows: Bool
        switch job.selection {
        case .allNew, .dateRange:
            keepSkippedRows = false
            var range: ClosedRange<Date>?
            if case let .dateRange(r) = job.selection { range = r }
            var listedContent = Set<ObjectIdentity.ContentKey>()
            for item in listed.newestFirst() where item.format.isStill {
                guard let identity = item.identity(camera: camera, timeZone: zone) else {
                    // No capture date, so no identity: left out and counted, for the Import screen to say how many
                    // (D10). A date range can't hold a file with no date, so it leaves such files out unsaid.
                    if range == nil { unkeyed.append(item) }
                    continue
                }
                if let range, let date = item.captureDate, !range.contains(date) { continue }
                // One file listed in two folders is one file.
                guard listedContent.insert(identity.contentKey).inserted else {
                    trace(.sameFileListedTwice(item.name))
                    continue
                }
                planned.append((item, identity, .queue))
            }
        case let .items(picked), let .newItems(picked), let .requeued(picked):
            // A pick: in the order picked, matched by content against this listing for current handles.
            keepSkippedRows = true
            let onCard = Self.byContent(listed, camera: camera, timeZone: zone)
            for item in picked {
                guard let identity = item.identity(camera: camera, timeZone: zone) else {
                    unkeyed.append(item)
                    continue
                }
                if !item.format.isStill {
                    planned.append((item, identity, .skip(.notAStill)))
                } else if let current = onCard[identity.contentKey] {
                    planned.append((current, identity, .queue))
                } else {
                    planned.append((item, identity, .skip(.link(.itemNotFound))))
                }
            }
        }

        // A job that ended (cancel, stop) may still be committing one of these files: its row has to land first, or
        // the file would be queued, copied and saved again.
        await settleCommits(ofJobsOtherThan: id)
        // A partial file iOS emptied from Caches, or the prune deleted, sends its row back to offset 0 first (I13).
        await reconcilePartials()
        guard currentListing(id, generation) != nil else { return }
        let facts: DoneFacts
        do {
            guard let read = try await doneFacts(of: planned.map(\.identity), job: id,
                                                 readingRejects: job.selection.leavesOutRejects) else { return }
            facts = read
        } catch {
            if let job = currentListing(id, generation) { end(job, .catalogueUnavailable) }
            return
        }
        let states = facts.states
        // Partial files an earlier job left (its checkpoints, `markPartial`), for the files about to be queued.
        var partials: [ObjectIdentity: CatalogueRecord] = [:]
        for p in planned where states[p.identity] == .partial {
            if case .queue = p.plan, let record = try? await catalogue.record(for: p.identity),
               record.state == .partial, record.tempURL != nil {
                partials[p.identity] = record
            }
        }
        guard let job = currentListing(id, generation) else { return }

        var kept: [(item: CameraItem, identity: ObjectIdentity, plan: Plan)] = []
        var seen = Set<ObjectIdentity.ContentKey>()
        for p in planned {
            let state = states[p.identity] ?? .new
            let staged = facts.staged.contains(p.identity)
            guard DoneRule.isWanted(state: state, staged: staged, purpose: facts.purpose,
                                    newOnly: job.selection.newOnly, wholeCard: !keepSkippedRows) else {
                if staged && facts.purpose == .staging { trace(.alreadyStaged(p.item.name)) }
                continue
            }
            // Picked twice (one file in two folders): one file, imported once.
            guard seen.insert(p.identity.contentKey).inserted else {
                trace(.sameFileListedTwice(p.item.name))
                continue
            }
            // A reject stays rejected (D3): left out unless picked explicitly, and counted for the outcome.
            guard !facts.rejected.contains(p.identity.contentKey) else {
                if job.rejectsLeftOut.insert(p.identity.contentKey).inserted { trace(.rejectedLeftOut(p.item.name)) }
                continue
            }
            kept.append(p)
        }

        // A RAW and its JPEG or HEIF among the files to copy are one unit (section 7.1), committed together once both
        // are downloaded; they are queued next to each other, so the pair's files download close together. A file
        // whose partner is already done for the job's purpose, or isn't to be copied, is a lone file.
        let toQueue = kept.indices.filter { if case .queue = kept[$0].plan { true } else { false } }
        let pairs = Self.pairs(among: toQueue.map { kept[$0].item }).map { (toQueue[$0.0], toQueue[$0.1]) }

        // Listed files go before anything appended during the listing; a duplicate of an appended file takes the
        // listing's place.
        var index = -kept.count
        var queued: [ObjectIdentity] = []
        var created: [Int: FileEntry] = [:]
        for i in Self.pairAwareOrder(count: kept.count, pairs: pairs) {
            defer { index += 1 }
            let p = kept[i]
            let entry = FileEntry(identity: p.identity, index: index, item: p.item)
            created[i] = entry
            entry.queuedUnderStagingRule = facts.purpose == .staging
            job.add(entry)   // replaces a file of the same content appended during the listing
            switch p.plan {
            case .queue:
                if let record = partials[p.identity] { adopt(record, into: entry, of: job) }
                queued.append(p.identity)
            case let .skip(reason):
                entry.phase = .done(.skipped(reason))
                trace(.skipped(p.item.name, reason))
            }
        }
        for (a, b) in pairs {
            if let first = created[a], let second = created[b] { job.pair(first, second) }
        }
        for item in unkeyed where job.leaveOut(undated: item) {
            trace(.skipped(item.name, .noCaptureDate))
        }
        job.queue = queued + job.queue
        job.phase = .downloading
        job.hasListed = true
        trace(.listed(onCard: listed.count, queued: queued.count))
        noteReconnected(job)
        refreshState()
    }

    /// What the catalogue says about some files, as the done rule needs it for a job's purpose.
    struct DoneFacts {
        var states: [ObjectIdentity: ObjectState]
        /// The files with a staged copy; read only for a stage job (empty for an import job).
        var staged: Set<ObjectIdentity>
        /// The job's purpose the answers were read for.
        var purpose: DestinationKind
        /// The files with a Reject mark (D3), by content key; read only when asked for (empty otherwise).
        var rejected: Set<ObjectIdentity.ContentKey> = []
    }

    /// The states of `identities` and, for a stage job, which are staged, both by content. Read again when the job's
    /// purpose changed meanwhile (a continue that stages an import job), so the answers match the purpose they are
    /// used with; a purpose only ever changes from import to stage, so that happens at most once. Nil once the job
    /// has gone. With `readingRejects`, also which have a Reject mark (`marks(of:)`, D3), whatever the purpose.
    func doneFacts(of identities: [ObjectIdentity], job id: UUID, readingRejects: Bool = false) async throws
        -> DoneFacts? {
        guard var purpose = current(id)?.route.purpose else { return nil }
        let rejected = readingRejects && !identities.isEmpty
            ? RejectRule.rejected(in: try await catalogue.marks(of: identities.map(\.contentKey))) : []
        while true {
            let states = try await catalogue.states(of: identities)
            let staged = purpose == .staging ? try await catalogue.stagedStates(of: identities) : []
            guard let job = current(id) else { return nil }
            if job.route.purpose == purpose {
                return DoneFacts(states: states, staged: staged, purpose: purpose, rejected: rejected)
            }
            purpose = job.route.purpose
        }
    }

    /// A listing after a replug: every file left is found again by content (name, capture time, size, so a listing
    /// that reports another folder still finds it) and takes its new handle; one that isn't on the card any more is
    /// skipped. Files on the card that aren't in the job are ignored (decision 7).
    func remap(_ job: Job, _ listed: [CameraItem]) {
        let onCard = Self.byContent(listed, camera: job.camera, timeZone: job.timeZone)
        for entry in job.sortedEntries {
            guard case .queued = entry.phase else { continue }
            if let item = onCard[entry.identity.contentKey] {
                entry.item = item
            } else {
                job.queue.removeAll { $0 == entry.identity }
                entry.phase = .done(.skipped(.link(.itemNotFound)))
                trace(.skipped(entry.item.name, .link(.itemNotFound)))
            }
        }
        job.phase = .downloading
        trace(.listed(onCard: listed.count, queued: job.queue.count))
        commitLoneHalves(of: job) // a half kept for a file that is no longer on the card goes alone
        noteReconnected(job)
        refreshState()
    }

    // MARK: - Pairs

    /// A file as the pairing rule sees it: the listing's folder, name and capture date.
    private struct PairCandidate: PairableFile {
        let index: Int
        let item: CameraItem
        var pairingFolder: String { item.folder }
        var pairingFilename: String { item.name }
        var pairingCaptureDate: Date? { item.captureDate }
    }

    /// The RAW+JPEG pairs among `items` by `RawPairingRule` (same folder, same stem, within 1 s; no pair without a
    /// date), as index pairs, in the order of each pair's first file.
    static func pairs(among items: [CameraItem]) -> [(Int, Int)] {
        let candidates = items.enumerated().map { PairCandidate(index: $0.offset, item: $0.element) }
        return RawPairingRule().units(candidates).compactMap { unit in
            guard case let .pair(raw, processed) = unit else { return nil }
            return (min(raw.index, processed.index), max(raw.index, processed.index))
        }
    }

    /// The order to queue `count` files in: as given, except that each pair's second file follows its first at once.
    static func pairAwareOrder(count: Int, pairs: [(Int, Int)]) -> [Int] {
        var partner: [Int: Int] = [:]
        for (a, b) in pairs {
            partner[a] = b
            partner[b] = a
        }
        var out: [Int] = []
        out.reserveCapacity(count)
        var placed = Set<Int>()
        for i in 0 ..< count where placed.insert(i).inserted {
            out.append(i)
            if let j = partner[i], placed.insert(j).inserted { out.append(j) }
        }
        return out
    }

    /// An earlier job's partial file for `entry`, from its catalogue row: continued on a link that resumes (once the
    /// attempt has checked it), deleted on one that doesn't, which copies the file from its start (USB, as before).
    /// Only a file inside the staging folder's `Partials` folder is touched.
    func adopt(_ record: CatalogueRecord, into entry: FileEntry, of job: Job) {
        guard case let .inside(file, folder) = partialLocation(of: record) else { return }
        guard job.link.capabilities.resumesPartialFiles else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        let seed = PartialSeed(download: PartialDownload(file: file, bytesWritten: record.resumeOffset),
                               name: record.identity.filename, size: record.identity.size)
        entry.resumable = ResumableFile(folder: folder, adopted: seed, persistedOffset: record.resumeOffset)
    }

    /// A listing's dated files by content key; the first listed wins when one file is listed twice.
    static func byContent(_ listed: [CameraItem], camera: CameraKey, timeZone: TimeZone)
        -> [ObjectIdentity.ContentKey: CameraItem] {
        var out: [ObjectIdentity.ContentKey: CameraItem] = [:]
        for item in listed {
            guard let key = item.identity(camera: camera, timeZone: timeZone)?.contentKey, out[key] == nil
            else { continue }
            out[key] = item
        }
        return out
    }

    // MARK: - Downloading

    private enum Lane: Sendable { case file, waker }

    /// Downloads with at most `limit` files in flight. Leaves when the job is drained, has gone, or needs a listing
    /// or the camera, once its files in flight have returned.
    func downloadPhase(_ id: UUID) async {
        guard let signal = current(id)?.signal else { return }
        await withTaskGroup(of: Lane.self) { group in
            var inFlight = 0
            var waker = false
            while true {
                guard let job = current(id) else {
                    group.cancelAll()
                    break
                }
                while inFlight < job.limit, let identity = claimNext(job) {
                    inFlight += 1
                    group.addTask { await self.runFile(identity, of: id); return .file }
                }
                if job.phase != .downloading {
                    if inFlight == 0 { break }
                } else if job.queue.isEmpty && inFlight == 0 {
                    finishIfDrained(id)
                    // A held half or a commit no lane waits for still belongs to the job: wait for it to settle.
                    guard current(id) != nil, job.hasActiveFiles else { break }
                }
                if inFlight < job.limit && job.phase == .downloading {
                    trace(.idle(queued: job.queue.count, inFlight: inFlight))
                }
                if !waker {
                    waker = true
                    group.addTask { await signal.wait(); return .waker }
                }
                switch await group.next() {
                case .file?: inFlight -= 1
                case .waker?: waker = false
                case nil: waker = false
                }
            }
            // The waker must be released, or the group never ends.
            if waker { signal.fire() }
        }
    }

    /// Takes the next file and starts its download; nil when paused, not downloading, or nothing is queued.
    func claimNext(_ job: Job) -> ObjectIdentity? {
        guard job.pauses.isEmpty, job.phase == .downloading, !job.queue.isEmpty else { return nil }
        let identity = job.queue.removeFirst()
        guard let entry = job.entries[identity] else { return nil }
        beginAttempt(entry, of: job)
        return identity
    }

    /// A new `bytes` call. On a link that can't resume, into a new folder: an interrupted file is always copied
    /// again from its start. On one that can, into the file's own folder, continuing from the latest checkpoint
    /// once the camera confirms the file's name and size (`DownloadAttempt`).
    func beginAttempt(_ entry: FileEntry, of job: Job) {
        var onDiscard: (@Sendable () -> Void)?
        if let hook = traceHook { onDiscard = { hook(.discardedLateFile) } }
        let origin = (name: entry.item.name, size: entry.item.size)
        let attempt: DownloadAttempt
        var resume: DownloadAttempt.Resume?
        if job.link.capabilities.resumesPartialFiles {
            let resumable = entry.resumable
                ?? ResumableFile(folder: partialsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
            entry.resumable = resumable
            try? FileManager.default.createDirectory(at: resumable.folder, withIntermediateDirectories: true)
            let id = job.id
            let identity = entry.identity
            attempt = DownloadAttempt(
                directory: resumable.folder, clock: clock, origin: origin, keepsFiles: true,
                checkpointInterval: policy.checkpointInterval, onDiscard: onDiscard,
                onCheckpoint: { [weak self] attempt, seed in
                    await self?.checkpointCrossed(seed, by: attempt, of: identity, in: id)
                })
            resume = DownloadAttempt.Resume(previous: resumable.previous, adopted: resumable.adopted)
            resumable.previous = attempt
            resumable.adopted = nil
        } else {
            let directory = job.jobDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            attempt = DownloadAttempt(directory: directory, clock: clock, origin: origin, onDiscard: onDiscard)
        }
        entry.attempts += 1
        entry.phase = .downloading(Download(attempt: attempt, startedAt: clock.now))
        trace(.started(entry.item.name, attempt: entry.attempts))
        attempt.start(link: job.link, item: entry.item.id, resume: resume)
        refreshState()
    }
}
