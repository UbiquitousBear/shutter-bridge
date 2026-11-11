import CameraTransport
import Catalogue
import Foundation
import PhotosBridge

extension ImportEngine {
    /// One file, from its claimed download to its catalogue row: download, size check, commit, row, cleanup, with
    /// retries in the same lane. Everything is looked up again after every await; a file whose job has gone does
    /// only cleanup (or, once committed, records its row and cleans up).
    func runFile(_ identity: ObjectIdentity, of id: UUID) async {
        while let attempt = current(id)?.entries[identity]?.download?.attempt {
            let outcome = await attempt.outcome()
            guard let job = current(id), let entry = job.entries[identity], let download = entry.download,
                  download.attempt === attempt else { return } // whoever abandoned it requeued and cleaned up
            switch outcome {
            case .abandoned:
                job.requeue(entry)
                refreshState()
                return
            case let .failed(failure):
                guard await linkFailed(failure, entry: entry, download: download, job: job) else { return }
            case .identityChanged:
                // The handle now names another file: the partial can't be continued, and where the job's file is
                // now (if it is still on the card) is for the listing to say. It is copied from its start.
                trace(.identityChanged(entry.item.name))
                discardPartial(of: entry, download: download)
                job.requeue(entry)
                relist(job)
                refreshState()
                return
            case let .written(url):
                let expected = entry.item.size
                let actual = Self.fileSize(at: url)
                // Every file is checked against the listing; it costs a stat, and it is how a file that finished
                // suspiciously fast after a continue (the spike's 35.4 MB in 0.02 s) gets checked.
                if actual != expected {
                    trace(.sizeMismatch(entry.item.name, expected: expected, actual: actual))
                    // Bytes that came out the wrong size are never continued from: the retry starts at 0.
                    discardPartial(of: entry, download: download)
                    guard await retry(identity, of: id,
                                      after: .sizeMismatch(expected: expected, actual: actual)) else { return }
                } else {
                    guard await commitOrHold(url, identity: identity, of: id, download: download) else { return }
                }
            }
        }
    }

    static func fileSize(at url: URL) -> UInt64 {
        let path = url.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    /// Follows the failure's outcome. Returns true when a new attempt has begun in this lane.
    ///
    /// A partial file is deleted, except on a link that resumes while the file is still to be copied (a retry, or
    /// waiting for the camera or the card), where its latest checkpoint is written to the catalogue instead.
    func linkFailed(_ failure: CameraLinkFailure, entry: FileEntry, download: Download, job: Job) async -> Bool {
        let id = job.id
        if !download.attempt.keepsFiles { try? FileManager.default.removeItem(at: download.attempt.directory) }
        switch failure.outcome {
        case .retryNow:
            // A call that was in flight across a pause doesn't fail the file (decision 4): no retry is counted.
            if download.pausedDuring {
                job.requeue(entry)
                refreshState()
                await saveLatestCheckpoint(of: entry, in: id)
                return false
            }
            return await retry(entry.identity, of: id, after: .link(failure.kind))
        case .retryOnReconnect:
            // Puts this file back in the queue too, with no retry counted. A lost card is not a lost camera: the
            // session is up, and nothing may count as failed (the spike's 82-files bug).
            if failure.kind == .cardUnavailable { cardLost(job) } else { cameraLost(job, job.cameraLossReason) }
            return false
        case .skipFile:
            resolve(entry, .skipped(.link(failure.kind)))
            commitLoneHalves(of: job) // a partner kept for this file goes alone
            refreshState()
            return false
        case .stopJob:
            resolve(entry, .failed(.link(failure.kind)))
            end(job, .stopped(failure.kind))
            return false
        }
    }

    // MARK: - Partial files on a link that resumes

    /// A download's checkpoint crossed the catalogue interval (16 MiB): written if the attempt is still the file's
    /// latest in this job.
    func checkpointCrossed(_ seed: PartialSeed, by attempt: DownloadAttempt, of identity: ObjectIdentity,
                           in id: UUID) async {
        guard let entry = current(id)?.entries[identity], entry.resumable?.previous === attempt else { return }
        await saveCheckpoint(seed, of: identity, in: id)
    }

    /// The file's latest checkpoint, written to the catalogue if it is newer than the one there.
    func saveLatestCheckpoint(of entry: FileEntry, in id: UUID) async {
        guard let seed = entry.resumable?.best else { return }
        await saveCheckpoint(seed, of: entry.identity, in: id)
    }

    /// Writes `seed` as the file's `.partial` row (`markPartial`) with its offset and its path relative to the
    /// staging folder, if it is newer than the last one written and still the file's partial copy. A catalogue
    /// that refuses it is left as it was: the resume point in memory holds, and the next checkpoint tries again.
    ///
    /// Never once the file's commit has begun (`FileEntry.takesCheckpoints`): a crossing handed over late (its task
    /// ran after the download finished) or a flush would otherwise write `.partial` after the commit's row, and a
    /// staged row would read as partial again. The check and the count of writes in flight
    /// (`FileEntry.checkpointWrites`) happen together on the actor, before any await, so a write either starts
    /// before the commit begins (and the commit waits for it) or not at all.
    func saveCheckpoint(_ seed: PartialSeed, of identity: ObjectIdentity, in id: UUID) async {
        guard let entry = current(id)?.entries[identity], entry.takesCheckpoints, let resumable = entry.resumable,
              seed.offset > resumable.persistedOffset, seed.offset <= entry.identity.size,
              let relative = relativeToStaging(seed.download.file, in: resumable.folder) else { return }
        resumable.persistedOffset = seed.offset
        let writes = entry.checkpointWrites
        writes.begin()
        defer { writes.end() }
        do {
            try await catalogue.markPartial(identity, format: entry.item.format, tempURL: relative,
                                            offset: seed.offset)
            trace(.checkpointSaved(entry.item.name, offset: seed.offset))
        } catch {
            // Let the next checkpoint (or flush) try again.
            if let r = current(id)?.entries[identity]?.resumable, r === resumable, r.persistedOffset == seed.offset {
                r.persistedOffset = 0
            }
        }
    }

    /// `file` relative to the staging folder (`Partials/<folder>/<name>`), the form the catalogue keeps (the
    /// container's path changes on an app update); nil for a file outside the file's own folder.
    func relativeToStaging(_ file: URL, in folder: URL) -> URL? {
        guard file.deletingLastPathComponent().standardizedFileURL.pathComponents
            == folder.standardizedFileURL.pathComponents else { return nil }
        let path = "\(Self.partialsFolderName)/\(folder.lastPathComponent)/\(file.lastPathComponent)"
        return URL(fileURLWithPath: path, relativeTo: stagingDirectory)
    }

    /// Drops the file's partial copy: the folder is deleted and the next attempt starts from 0 in a new one. Nothing
    /// is written to the catalogue: a row left pointing to the deleted file is restarted by whoever reads it (the
    /// file isn't there), and the new copy's first checkpoint replaces it.
    func discardPartial(of entry: FileEntry, download: Download) {
        try? FileManager.default.removeItem(at: download.attempt.directory)
        if let resumable = entry.resumable {
            try? FileManager.default.removeItem(at: resumable.folder)
            entry.resumable = nil
        }
    }

    /// Backs off and tries the file again with a fresh call, or fails it once the retries are used up. Returns true
    /// when a new attempt has begun in this lane; false when the file failed, was put back in the queue (the job is
    /// paused, relisting or waiting for the camera) or the job has gone.
    func retry(_ identity: ObjectIdentity, of id: UUID, after reason: FailureReason) async -> Bool {
        guard let job = current(id), let entry = job.entries[identity] else { return false }
        guard entry.retries < policy.retryDelays.count else {
            resolve(entry, .failed(reason))
            refreshState()
            return false
        }
        entry.retries += 1
        let until = clock.now + policy.retryDelays[entry.retries - 1]
        entry.phase = .waitingToRetry
        trace(.retrying(entry.item.name, retry: entry.retries, until: until))
        refreshState()
        // A resumable file's retry continues from its latest checkpoint: written first, so an app iOS ends during
        // the backoff leaves a row that holds it. (A file whose partial was discarded has none.)
        await saveLatestCheckpoint(of: entry, in: id)
        let slept: Bool
        do {
            try await clock.sleep(until: until)
            slept = true
        } catch {
            slept = false
        }
        guard let job = current(id), let entry = job.entries[identity], case .waitingToRetry = entry.phase else {
            return false
        }
        guard slept, job.pauses.isEmpty, job.phase == .downloading else {
            job.requeue(entry)
            refreshState()
            return false
        }
        beginAttempt(entry, of: job) // `entry.item` may have a new handle after a replug
        return true
    }

    // MARK: - Pairs

    /// One downloaded file of a commit: its entry's identity, the file, and the call that wrote it.
    struct Half {
        let identity: ObjectIdentity
        let url: URL
        let download: Download
    }

    /// A file is downloaded and the right size: commit it, alone or with the other half of its RAW+JPEG pair
    /// (section 7.1), or keep it until its partner is downloaded. Returns true when a new attempt has begun in this
    /// lane.
    ///
    /// - The partner is held (downloaded already): the two are committed as one unit, in this lane.
    /// - The partner is still to download (queued, downloading, waiting to retry, or put back by a pause, a stall or
    ///   a removal): this half is held on disk and the lane is freed for the partner.
    /// - The partner was skipped (missing after a replug, for one): this half is committed alone.
    /// - The partner failed for a real error after its retries: this half is held until nothing else is left to
    ///   download, then committed alone (`commitLoneHalves(of:)`).
    func commitOrHold(_ url: URL, identity: ObjectIdentity, of id: UUID, download: Download) async -> Bool {
        guard let job = current(id), let entry = job.entries[identity] else { return false }
        let mine = Half(identity: identity, url: url, download: download)
        guard let partner = job.partner(of: entry) else { return await commit([mine], lane: identity, of: id) }
        switch partner.phase {
        case let .held(held):
            let theirs = Half(identity: partner.identity, url: held.url, download: held.download)
            let rawFirst = RawPairingRule.role(ofFilename: entry.item.name) == .raw
            return await commit(rawFirst ? [mine, theirs] : [theirs, mine], lane: identity, of: id)
        case .queued, .downloading, .waitingToRetry, .done(.failed):
            hold(entry, HeldHalf(url: url, download: download), in: job)
            return false
        case .committing, .done:
            // Skipped (a committing partner can't be: it would be committing with this one).
            trace(.committedWithoutPartner(entry.item.name))
            return await commit([mine], lane: identity, of: id)
        }
    }

    /// Keeps a downloaded half on disk until its partner is downloaded too. Its rate sample is taken now, when its
    /// download ended, not when the pair is committed.
    func hold(_ entry: FileEntry, _ held: HeldHalf, in job: Job) {
        entry.phase = .held(held)
        if !entry.interrupted {
            job.rate.record(start: held.download.startedAt, end: clock.now, bytes: entry.item.size)
        }
        trace(.waitingForPartner(entry.item.name))
        refreshState()
    }

    /// Commits each held half whose partner won't come, alone and outside the download lanes: at once when the
    /// partner was skipped (or has left the job), and once nothing else is left to download when it failed for a
    /// real error (section 7.1: the failure is listed and the half is committed when the job would otherwise end).
    /// Commits aren't held back by a pause, as a download in flight across one is committed too (decision 4).
    func commitLoneHalves(of job: Job) {
        for entry in job.sortedEntries {
            guard let held = entry.held else { continue }
            let mine = Half(identity: entry.identity, url: held.url, download: held.download)
            let partner = job.partner(of: entry)
            switch partner?.phase {
            case .queued?, .downloading?, .waitingToRetry?:
                continue
            case let .held(theirs)?:
                // Both downloaded and neither committed (not a state the lanes leave): commit them together.
                guard let partner else { continue }
                let other = Half(identity: partner.identity, url: theirs.url, download: theirs.download)
                let rawFirst = RawPairingRule.role(ofFilename: entry.item.name) == .raw
                commitWithoutLane(rawFirst ? [mine, other] : [other, mine], of: job)
                continue
            case .done(.failed)?:
                guard job.nothingLeftToDownload else { continue }
            case .done?, .committing?, nil:
                break
            }
            trace(.committedWithoutPartner(entry.item.name))
            commitWithoutLane([mine], of: job)
        }
    }

    /// A commit no download lane waits for (a held half committed alone): its result is settled in its own task,
    /// which then wakes the driver and finishes the job if nothing is left.
    func commitWithoutLane(_ halves: [Half], of job: Job) {
        let id = job.id
        guard let started = startCommit(halves, of: job) else { return }
        Task {
            let result = await started.task.value
            self.commitsInFlight[started.token] = nil
            _ = await self.settle(result, halves, lane: nil, of: id)
            self.current(id)?.signal.fire()
            self.finishIfDrained(id)
        }
    }

    /// Commits the downloaded files as one unit (a lone file, or a pair, RAW first), records their rows and removes
    /// what is left of them. Returns true when the lane's file has to be downloaded again (its staged file vanished)
    /// and a new attempt has begun in this lane.
    ///
    /// The commit, the rows and the cleanup run in an unstructured task, not in this lane, so ending the job (which
    /// cancels the driver and its lanes) never cancels a Photos save or a move into the staging folder half-way:
    /// the files always get their rows. The retry after a failed commit runs back in the lane, where ending the job
    /// cancels its backoff.
    func commit(_ halves: [Half], lane: ObjectIdentity?, of id: UUID) async -> Bool {
        guard let job = current(id), let started = startCommit(halves, of: job) else { return false }
        let result = await started.task.value
        commitsInFlight[started.token] = nil
        return await settle(result, halves, lane: lane, of: id)
    }

    /// Marks the halves committing and starts their commit in its own task, registered in `commitsInFlight`. One
    /// synchronous step, so a half can't be committed twice.
    func startCommit(_ halves: [Half], of job: Job) -> (token: UUID, task: Task<CommitResult, Never>)? {
        var files: [CommitFile] = []
        for h in halves {
            guard let entry = job.entries[h.identity] else { return nil }
            files.append(CommitFile(url: h.url, item: entry.item, identity: h.identity,
                                    attemptDirectory: h.download.attempt.directory,
                                    checkStaged: !entry.queuedUnderStagingRule,
                                    checkpointWrites: entry.checkpointWrites))
        }
        for h in halves { job.entries[h.identity]?.phase = .committing }
        refreshState()
        let id = job.id
        let route = job.route
        let token = UUID()
        let task = Task { await self.commitAndRecord(files, of: id, route: route) }
        commitsInFlight[token] = (id, task)
        return (token, task)
    }

    /// Resolves the halves of a finished commit. Returns true when a new attempt has begun in the lane.
    func settle(_ result: CommitResult, _ halves: [Half], lane: ObjectIdentity?, of id: UUID) async -> Bool {
        switch result {
        case let .failed(failure):
            return await commitFailed(failure, halves: halves, lane: lane, of: id)
        case let .committed(outcomes, kind, written):
            // A commit that finishes after its job ended (cancelled, stopped) still resolves its files on the ended
            // job, so the finished Import screen's rows and counts show them as imported or staged.
            guard let job = current(id) ?? endedJob(id) else { return false }
            for (h, outcome) in zip(halves, outcomes) {
                guard let entry = job.entries[h.identity] else { continue }
                entry.resumable = nil // its folder went with the commit
                resolve(entry, outcome, into: kind)
            }
            guard current(id) != nil else {
                refreshState()
                return false
            }
            if let lane, let entry = job.entries[lane], !entry.interrupted,
               let h = halves.first(where: { $0.identity == lane }) {
                switch entry.outcome {
                case .imported?, .staged?:
                    job.rate.record(start: h.download.startedAt, end: clock.now, bytes: entry.item.size)
                case .skipped?, .failed?, nil:
                    break
                }
            }
            if written {
                refreshState()
            } else {
                end(job, .catalogueUnavailable)
            }
            return false
        }
    }

    /// One file of a commit, as the commit's task needs it.
    struct CommitFile: Sendable {
        let url: URL
        let item: CameraItem
        let identity: ObjectIdentity
        let attemptDirectory: URL
        /// Queued by an import job, whose done rule ignores staging (`FileEntry.queuedUnderStagingRule`).
        let checkStaged: Bool
        /// Its checkpoint writes in flight (`FileEntry.checkpointWrites`), waited for before its row is written
        /// (`settle(_:of:)`). No new one starts once the commit has begun (`FileEntry.takesCheckpoints`).
        let checkpointWrites: CheckpointWrites

        var staged: StagedFile { StagedFile(url: url, filename: item.name, captureDate: item.captureDate) }
    }

    /// How a commit ended: committed, with what became of each file in the order given (imported or staged and
    /// where, or `.skipped(.alreadyStaged)` for one left out because it was to be staged and is staged already), into
    /// which destination, and whether every row was written; or failed, for every file of the unit.
    enum CommitResult: Sendable {
        case committed([FileOutcome], DestinationKind, rowWritten: Bool)
        case failed(ImportDestinationFailure)
    }

    /// The commit itself, its rows and the cleanup of the staged files. Runs whether or not the job is still current:
    /// once a destination has the files, their rows are written. `files` are one unit: a lone file, or a pair with
    /// the RAW first.
    ///
    /// A file queued by an import job (`CommitFile.checkStaged`) whose job has been staged instead (a refused save,
    /// here or by another file; or a continue) is left out when the catalogue already has a staged copy of it, rather
    /// than staged a second time, which would leave the first copy in the staging folder with no row. The other half
    /// of a pair is then committed alone.
    ///
    /// Before any row is written, the commit waits for every committed file's checkpoint writes in flight
    /// (`settle(_:of:)`), a pair's two halves alike: one sent before the commit began (by the lane's half, or by a
    /// held half before it was held) must land before the rows, not after them, or a staged row would read as
    /// partial again, with its resume offset and temporary file back.
    func commitAndRecord(_ files: [CommitFile], of id: UUID, route: ImportRoute) async -> CommitResult {
        var outcomes = [FileOutcome?](repeating: nil, count: files.count)
        var going = Array(files.indices)
        let alreadyStaged = CommitResult.committed(outcomes.map { _ in .skipped(.alreadyStaged) }, .staging,
                                                   rowWritten: true)
        var used = route.destination
        if used.kind == .staging, !(await leaveOutStaged(files, going: &going, outcomes: &outcomes)) {
            return alreadyStaged
        }
        var unit = Self.commitUnit(for: going.map { files[$0].staged })
        // Whether `used` is the staging folder in iCloud Drive, which can go away mid-job.
        var usedICloudDrive = route.purpose == .staging && route.stagesInICloudDrive
        var result: ImportResult?
        var failure: ImportDestinationFailure?
        do throws(ImportDestinationFailure) {
            result = try await used.commit(unit)
        } catch {
            failure = error
        }

        // Photos refused the save (3311): not a failed file. This unit and the rest are staged, and the Import screen
        // says why (backlog section 5): a denial links to Settings, a restriction doesn't, so access is read again now
        // (`DestinationDecision.afterDeniedSave(authorisation:staging:)`). Switched once, however many files are in
        // flight: another file's refusal may switch it while this one reads access, so it's checked again.
        if failure == .photosAccessDenied, used.kind == .photos {
            if let job = current(id), job.route.decision == .photos {
                let authorisation = await job.route.authorisation()
                if let job = current(id), job.route.decision == .photos {
                    change(job, to: job.route.afterDeniedSave(authorisation))
                    refreshState()
                }
            }
            let staging = current(id)?.route ?? route
            used = staging.staging
            usedICloudDrive = staging.stagesInICloudDrive
            if !(await leaveOutStaged(files, going: &going, outcomes: &outcomes)) { return alreadyStaged }
            unit = Self.commitUnit(for: going.map { files[$0].staged })
            failure = nil
            do throws(ImportDestinationFailure) {
                result = try await used.commit(unit)
            } catch {
                failure = error
            }
        }

        // iCloud Drive went away while staging there (signed out, or iCloud Drive turned off, mid-job): not a failed
        // file. This unit and the rest are staged on this iPhone, and the Import screen says so
        // (`StagingFallbackReason.lostDuringImport`; Shamil, 11 Nov). Switched once, however many files are in
        // flight; a file whose commit began on the iCloud route while another switched it goes to this iPhone too.
        if failure == .stagingUnavailable, usedICloudDrive {
            if let job = current(id), job.route.stagesInICloudDrive {
                change(job, to: job.route.afterStagingLost())
                refreshState()
            }
            let next = current(id)?.route ?? route.afterStagingLost()
            if !next.stagesInICloudDrive {
                used = next.staging
                failure = nil
                do throws(ImportDestinationFailure) {
                    result = try await used.commit(unit)
                } catch {
                    failure = error
                }
            }
        }

        if let failure { return .failed(failure) }
        guard let result else { return .failed(.stagedFileMissing) } // unreachable: a commit returns or throws

        // A checkpoint write sent before the commit began must land before the rows: every file's, before any row.
        for i in going { await settle(files[i].checkpointWrites, of: files[i].item.name) }

        // The rows, then the cleanup. Written even if the job was cancelled meanwhile: the files were committed. An
        // import writes the imported row (`upsert`, which keeps any staged copy), one per file with the pair's one
        // asset; staging records each file's staged copy beside the row's state (`markStaged`, which keeps an
        // imported row imported and sends a partial row back to new with its resume cleared, since the partial file
        // was what was staged).
        //
        // The outcomes come in the unit's order (a pair's RAW first), matched back to the files by their downloads,
        // so each row gets its own file's location whatever order the files were given in.
        let committed = Self.outcomes(of: result, for: unit, at: Date())
        let inUnitOrder = unit.files.compactMap { staged in going.first { files[$0].url == staged.url } }
        var written = true
        for (k, i) in (inUnitOrder.count == going.count ? inUnitOrder : going).enumerated() {
            let file = files[i]
            let outcome = k < committed.count ? committed[k] : .imported(nil)
            outcomes[i] = outcome
            switch outcome {
            case let .staged(location):
                let staged = location ?? Self.unreportedStagedLocation(for: result)
                let ok = await writeRow {
                    try await self.catalogue.markStaged(file.identity, format: file.item.format, at: staged)
                }
                written = written && ok
            case let .imported(location):
                let record = CatalogueRecord(identity: file.identity, format: file.item.format, state: .imported,
                                             location: location)
                let ok = await writeRow { try await self.catalogue.upsert(record) }
                written = written && ok
            case .skipped, .failed:
                break // unreachable: a commit's outcome is imported or staged
            }
            Self.discard(file) // Photos copies; the staging folder moves the file, leaving only its folder
        }
        return .committed(outcomes.map { $0 ?? .skipped(.alreadyStaged) }, used.kind, rowWritten: written)
    }

    /// Leaves out the files still `going` that are to be checked and have a staged copy in the catalogue: their
    /// downloads are dropped and their outcome is `.skipped(.alreadyStaged)`. False when none is left to commit.
    func leaveOutStaged(_ files: [CommitFile], going: inout [Int], outcomes: inout [FileOutcome?]) async -> Bool {
        var kept: [Int] = []
        for i in going {
            if files[i].checkStaged, await isStaged(files[i].identity) {
                Self.discard(files[i])
                outcomes[i] = .skipped(.alreadyStaged)
            } else {
                kept.append(i)
            }
        }
        going = kept
        return !going.isEmpty
    }

    /// Drops a file's download once it is committed or left out.
    static func discard(_ file: CommitFile) {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.url.path(percentEncoded: false)) { try? fm.removeItem(at: file.url) }
        try? fm.removeItem(at: file.attemptDirectory)
    }

    /// Waits until none of a committing file's checkpoint writes is in flight, so its row is the last write; for at
    /// most `policy.checkpointWriteWait`, so a catalogue that never answers can't hold the commit (and its job) for
    /// ever. The row is then written anyway: the commit has the file, and a row that never comes is worse than one
    /// a stuck write might still overwrite.
    func settle(_ writes: CheckpointWrites, of name: String) async {
        guard !writes.isEmpty else { return }
        // The deadline is read before the trace, so a clock advanced by whoever sees the trace counts against it.
        let clock = self.clock
        let deadline = clock.now + policy.checkpointWriteWait
        trace(.waitingForCheckpointWrites(name))
        let settled = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await writes.waitUntilNone()
                return true
            }
            group.addTask {
                try? await clock.sleep(until: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !settled { trace(.checkpointWritesUnsettled(name)) }
    }

    /// Whether the catalogue has a staged copy of the file (by content). A catalogue that can't answer counts as
    /// not staged: a second copy is better than a file not staged at all.
    func isStaged(_ identity: ObjectIdentity) async -> Bool {
        guard let staged = try? await catalogue.stagedStates(of: [identity]) else { return false }
        return staged.contains(identity)
    }

    /// Writes a committed file's row, trying up to `policy.catalogueWriteAttempts` times; whether it was written.
    func writeRow(_ write: () async throws -> Void) async -> Bool {
        for _ in 0 ..< max(1, policy.catalogueWriteAttempts) {
            do {
                try await write()
                return true
            } catch {
                continue
            }
        }
        return false
    }

    /// A commit failed, for every file of its unit. A staged file that vanished is downloaded again (the lane's in
    /// this lane, after its backoff; a held partner's from the queue), while a half whose file is still there waits
    /// for its partner again; every other failure fails the unit's files, and a full phone stops the job.
    func commitFailed(_ failure: ImportDestinationFailure, halves: [Half], lane: ObjectIdentity?,
                      of id: UUID) async -> Bool {
        let fm = FileManager.default
        if failure == .stagedFileMissing, let job = current(id) {
            // A half whose file is still there keeps it, unless none is missing (then the destination can't read
            // them, and every half is downloaded again, as a lone file is), so this never loops.
            let present = halves.map { fm.fileExists(atPath: $0.url.path(percentEncoded: false)) }
            let keepPresent = present.contains(false)
            var again = false
            for (h, isThere) in zip(halves, present) {
                guard let entry = job.entries[h.identity] else { continue }
                if keepPresent, isThere {
                    entry.phase = .held(HeldHalf(url: h.url, download: h.download))
                    continue
                }
                // The staged file was the whole copy: nothing is left to continue from.
                try? fm.removeItem(at: h.download.attempt.directory)
                entry.resumable = nil
                if h.identity == lane {
                    again = true
                } else {
                    downloadAgain(entry, of: job, after: .destination(failure))
                }
            }
            refreshState()
            guard again, let lane else { return false }
            return await retry(lane, of: id, after: .destination(failure))
        }
        for h in halves {
            try? fm.removeItem(at: h.download.attempt.directory)
            // The staged file was the whole copy: nothing is left to continue from.
            (current(id) ?? endedJob(id))?.entries[h.identity]?.resumable = nil
        }
        guard let job = current(id) else {
            // The job ended while these files were being committed: no retry and no stop, but their rows say they
            // failed rather than staying at "committing".
            if let ended = endedJob(id) {
                for h in halves {
                    if let entry = ended.entries[h.identity] { resolve(entry, .failed(.destination(failure))) }
                }
                refreshState()
            }
            return false
        }
        let reason: FailureReason
        switch failure {
        case .photosAccessDenied:
            // From the staging folder, which has no Photos access to lose: treated as a rejection.
            reason = .destination(.rejected(detail: "access denied by the staging folder"))
        case .notEnoughSpace, .stagedFileMissing, .rejected, .stagingUnavailable:
            // A rejection: the same bytes would get the same answer, so no retry. Staging unavailable: the staging
            // folder on this iPhone said so too, after the switch from iCloud Drive, so there is nowhere else to go.
            reason = .destination(failure)
        }
        for h in halves {
            if let entry = job.entries[h.identity] { resolve(entry, .failed(reason)) }
        }
        if failure == .notEnoughSpace {
            end(job, .stopped(.phoneStorageFull))
        } else {
            refreshState()
        }
        return false
    }

    /// Puts a held half whose file vanished back in the queue to be downloaded again, counting a retry, or fails it
    /// once the retries are used up.
    func downloadAgain(_ entry: FileEntry, of job: Job, after reason: FailureReason) {
        guard entry.retries < policy.retryDelays.count else {
            resolve(entry, .failed(reason))
            return
        }
        entry.retries += 1
        trace(.retrying(entry.item.name, retry: entry.retries, until: clock.now))
        job.requeue(entry)
        job.signal.fire()
    }

    func resolve(_ entry: FileEntry, _ outcome: FileOutcome, into kind: DestinationKind? = nil) {
        entry.phase = .done(outcome)
        if let resumable = entry.resumable { // skipped or failed: nothing will continue the partial copy
            try? FileManager.default.removeItem(at: resumable.folder)
            entry.resumable = nil
        }
        switch outcome {
        case .imported: if let kind { trace(.imported(entry.item.name, kind)) }
        case let .staged(location): trace(.staged(entry.item.name, location))
        // One line per file: a file left out as staged already reads as the diff's and `append`'s do.
        case .skipped(.alreadyStaged): trace(.alreadyStaged(entry.item.name))
        case let .skipped(reason): trace(.skipped(entry.item.name, reason))
        case let .failed(reason): trace(.failed(entry.item.name, reason))
        }
    }

    /// What downloaded files are committed as: one file is a lone unit; two, the halves of a pair the pairing rule
    /// made (`RawPairingRule`, when the job was listed or the files appended), are one pair, the RAW as the RAW
    /// whichever order they come in, so Photos saves one asset (section 7.1) and staging puts both in the RAW's day
    /// folder under their own names.
    static func commitUnit(for files: [StagedFile]) -> CommitUnit {
        guard files.count == 2 else { return .single(files[0]) }
        if RawPairingRule.role(ofFilename: files[1].filename) == .raw {
            return .pair(raw: files[1], processed: files[0])
        }
        return .pair(raw: files[0], processed: files[1])
    }

    /// What became of each file of the unit, in the unit's order: imported as one Photos asset shared by every file,
    /// or staged with one location per file under the staging root the result names, staged at `date` (nil for any
    /// the destination didn't report).
    static func outcomes(of result: ImportResult, for unit: CommitUnit, at date: Date) -> [FileOutcome] {
        let count = unit.files.count
        switch result {
        case let .photosAsset(localIdentifier):
            return Array(repeating: .imported(.photosAsset(localIdentifier: localIdentifier)), count: count)
        case let .staged(place, locations):
            let root = StagingRoot(place)
            return (0 ..< count).map { i in
                .staged(i < locations.count
                    ? StagedLocation(root: root, relativePath: locations[i].relativePath, stagedAt: date) : nil)
            }
        }
    }

    /// The staged copy recorded for a file whose destination staged it without saying where (no staging destination
    /// here does that): its root, with an empty path, so the file still reads as staged and isn't staged twice. An
    /// empty path means unknown (`StagedLocation.relativePath`): `StagedLocation.fileURL(in:)` never resolves it, so
    /// nothing acts on a file it might name. Reconciling the staging folder with the catalogue (a later step) clears
    /// such a row.
    static func unreportedStagedLocation(for result: ImportResult) -> StagedLocation {
        let root: StagingRoot = if case let .staged(place, _) = result { StagingRoot(place) } else { .onThisIPhone }
        return StagedLocation(root: root, relativePath: "", stagedAt: Date())
    }
}

extension StagingRoot {
    /// The catalogue's root for a staging place (the place without its reason).
    init(_ place: StagingPlace) {
        switch place {
        case .iCloudDrive: self = .iCloudDrive
        case .onThisIPhone: self = .onThisIPhone
        }
    }
}
