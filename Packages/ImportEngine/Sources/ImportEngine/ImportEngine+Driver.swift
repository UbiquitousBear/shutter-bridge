import CameraTransport
import Catalogue
import Foundation

extension ImportEngine {
    /// One job from start to finish: list and diff, download, and on a removal wait for the camera, relist and find
    /// the files left by identity. Removes the job's staging folder when it ends.
    func runJob(_ id: UUID) async {
        guard let directory = current(id)?.jobDirectory else { return }
        defer { try? FileManager.default.removeItem(at: directory) }
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
    func finishIfDrained(_ id: UUID) {
        guard let job = current(id), job.queue.isEmpty, !job.hasActiveFiles else { return }
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
        let listed: [CameraItem]
        do throws(CameraLinkFailure) {
            try await link.open()
            listed = try await link.list()
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
            cameraRemoved(job)
        case .retryNow, .skipFile, .stopJob:
            end(job, .stopped(failure.kind))
        }
    }

    /// The first listing: what to import, by identity against the catalogue (stage 3).
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
            for item in listed.newestFirst() where item.format.isStill {
                guard let identity = item.identity(camera: camera, timeZone: zone) else { continue }
                if let range, let date = item.captureDate, !range.contains(date) { continue }
                planned.append((item, identity, .queue))
            }
        case let .items(picked):
            // An explicit pick: in the order picked, matched by identity against this listing for current handles.
            keepSkippedRows = true
            var onCard: [ObjectIdentity: CameraItem] = [:]
            for item in listed {
                if let identity = item.identity(camera: camera, timeZone: zone) { onCard[identity] = item }
            }
            for item in picked {
                guard let identity = item.identity(camera: camera, timeZone: zone) else {
                    unkeyed.append(item)
                    continue
                }
                if !item.format.isStill {
                    planned.append((item, identity, .skip(.notAStill)))
                } else if let current = onCard[identity] {
                    planned.append((current, identity, .queue))
                } else {
                    planned.append((item, identity, .skip(.link(.itemNotFound))))
                }
            }
        }

        // A job that ended (cancel, stop) may still be committing one of these files: its row has to land first, or
        // the file would be queued, copied and saved again.
        await settleCommits(ofJobsOtherThan: id)
        guard currentListing(id, generation) != nil else { return }
        let states: [ObjectIdentity: ObjectState]
        do {
            states = try await catalogue.states(of: planned.map(\.identity))
        } catch {
            if let job = currentListing(id, generation) { end(job, .catalogueUnavailable) }
            return
        }
        guard let job = currentListing(id, generation) else { return }

        // Listed files go before anything appended during the listing; a duplicate of an appended file takes the
        // listing's place.
        var index = -planned.count
        var queued: [ObjectIdentity] = []
        var seen = Set<ObjectIdentity>()
        for p in planned {
            defer { index += 1 }
            let state = states[p.identity] ?? .new
            let wanted = keepSkippedRows ? state != .imported : (state == .new || state == .partial)
            guard wanted, seen.insert(p.identity).inserted else { continue }
            if job.entries[p.identity] != nil {
                job.queue.removeAll { $0 == p.identity }
            }
            let entry = FileEntry(identity: p.identity, index: index, item: p.item)
            job.entries[p.identity] = entry
            switch p.plan {
            case .queue:
                queued.append(p.identity)
            case let .skip(reason):
                entry.phase = .done(.skipped(reason))
                trace(.skipped(p.item.name, reason))
            }
        }
        for item in unkeyed {
            job.unkeyed.append(item)
            trace(.skipped(item.name, .noCaptureDate))
        }
        job.queue = queued + job.queue
        job.phase = .downloading
        job.hasListed = true
        trace(.listed(onCard: listed.count, queued: queued.count))
        refreshState()
    }

    /// A listing after a replug: every file left is found again by identity and takes its new handle; one that
    /// isn't on the card any more is skipped. Files on the card that aren't in the job are ignored (decision 7).
    func remap(_ job: Job, _ listed: [CameraItem]) {
        var onCard: [ObjectIdentity: CameraItem] = [:]
        for item in listed {
            if let identity = item.identity(camera: job.camera, timeZone: job.timeZone) { onCard[identity] = item }
        }
        for entry in job.sortedEntries {
            guard case .queued = entry.phase else { continue }
            if let item = onCard[entry.identity] {
                entry.item = item
            } else {
                job.queue.removeAll { $0 == entry.identity }
                entry.phase = .done(.skipped(.link(.itemNotFound)))
                trace(.skipped(entry.item.name, .link(.itemNotFound)))
            }
        }
        job.phase = .downloading
        trace(.listed(onCard: listed.count, queued: job.queue.count))
        refreshState()
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
                    break
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

    /// A fresh `bytes` call into a new folder: an interrupted file is always copied again from its start.
    func beginAttempt(_ entry: FileEntry, of job: Job) {
        let directory = job.jobDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var onDiscard: (@Sendable () -> Void)?
        if let hook = traceHook { onDiscard = { hook(.discardedLateFile) } }
        let attempt = DownloadAttempt(directory: directory, clock: clock, onDiscard: onDiscard)
        entry.attempts += 1
        entry.phase = .downloading(Download(attempt: attempt, startedAt: clock.now))
        trace(.started(entry.item.name, attempt: entry.attempts))
        attempt.start(link: job.link, item: entry.item.id)
        refreshState()
    }
}
