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
                    guard await commit(url, identity: identity, of: id, download: download) else { return }
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
    func saveCheckpoint(_ seed: PartialSeed, of identity: ObjectIdentity, in id: UUID) async {
        guard let entry = current(id)?.entries[identity], entry.outcome == nil, let resumable = entry.resumable,
              seed.offset > resumable.persistedOffset, seed.offset <= entry.identity.size,
              let relative = relativeToStaging(seed.download.file, in: resumable.folder) else { return }
        resumable.persistedOffset = seed.offset
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

    /// Commits the staged file, records its row and removes what is left of it. Returns true when the file has to be
    /// downloaded again (the staged file vanished) and a new attempt has begun in this lane.
    ///
    /// The commit, the row and the cleanup run in an unstructured task, not in this lane, so ending the job (which
    /// cancels the driver and its lanes) never cancels a Photos save or a move into the staging folder half-way: the
    /// file always gets its row. The retry after a failed commit runs back in the lane, where ending the job cancels
    /// its backoff.
    func commit(_ url: URL, identity: ObjectIdentity, of id: UUID, download: Download) async -> Bool {
        guard let job = current(id), let entry = job.entries[identity] else { return false }
        entry.phase = .committing
        refreshState()
        let item = entry.item
        let route = job.route
        let directory = download.attempt.directory
        let checkStaged = !entry.queuedUnderStagingRule
        let token = UUID()
        let task = Task {
            await self.commitAndRecord(url, item: item, identity: identity, of: id, route: route,
                                       attemptDirectory: directory, checkStaged: checkStaged)
        }
        commitsInFlight[token] = (id, task)
        let result = await task.value
        commitsInFlight[token] = nil

        switch result {
        case let .failed(failure):
            return await commitFailed(failure, identity: identity, of: id, download: download, name: item.name)
        case .alreadyStaged:
            // Staged instead part-way, and staged already: left out, as a stage job's diff would have.
            guard let job = current(id) ?? endedJob(id), let entry = job.entries[identity] else { return false }
            resolve(entry, .skipped(.alreadyStaged))
            refreshState()
            return false
        case let .committed(outcome, kind, written):
            // A commit that finishes after its job ended (cancelled, stopped) still resolves its file on the ended
            // job, so the finished Import screen's row and counts show it as imported or staged.
            guard let job = current(id) ?? endedJob(id), let entry = job.entries[identity] else { return false }
            entry.resumable = nil // its folder went with the commit
            resolve(entry, outcome, into: kind)
            guard current(id) != nil else {
                refreshState()
                return false
            }
            if !entry.interrupted {
                job.rate.record(start: download.startedAt, end: clock.now, bytes: item.size)
            }
            if written {
                refreshState()
            } else {
                end(job, .catalogueUnavailable)
            }
            return false
        }
    }

    /// How a commit ended: committed (imported or staged, and where; into which destination; and whether its row was
    /// written), left out because it was to be staged and is staged already, or failed.
    enum CommitResult: Sendable {
        case committed(FileOutcome, DestinationKind, rowWritten: Bool)
        case alreadyStaged
        case failed(ImportDestinationFailure)
    }

    /// The commit itself, its row and the cleanup of the staged file. Runs whether or not the job is still current:
    /// once a destination has the file, its row is written.
    ///
    /// - Parameter checkStaged: The file was queued by an import job, whose done rule ignores staging
    ///   (`FileEntry.queuedUnderStagingRule`). If the job has been staged instead (a refused save, here or by another
    ///   file; or a continue), a file the catalogue already has a staged copy of is left out (`.alreadyStaged`) rather
    ///   than staged a second time, which would leave the first copy in the staging folder with no row.
    func commitAndRecord(_ url: URL, item: CameraItem, identity: ObjectIdentity, of id: UUID, route: ImportRoute,
                         attemptDirectory: URL, checkStaged: Bool) async -> CommitResult {
        let unit = commitUnit(for: StagedFile(url: url, filename: item.name, captureDate: item.captureDate))
        let fm = FileManager.default
        /// Drops the downloaded file of one that is left out.
        func discard() {
            if fm.fileExists(atPath: url.path(percentEncoded: false)) { try? fm.removeItem(at: url) }
            try? fm.removeItem(at: attemptDirectory)
        }
        var used = route.destination
        if checkStaged, used.kind == .staging, await isStaged(identity) {
            discard()
            return .alreadyStaged
        }
        // Whether `used` is the staging folder in iCloud Drive, which can go away mid-job.
        var usedICloudDrive = route.purpose == .staging && route.stagesInICloudDrive
        var result: ImportResult?
        var failure: ImportDestinationFailure?
        do throws(ImportDestinationFailure) {
            result = try await used.commit(unit)
        } catch {
            failure = error
        }

        // Photos refused the save (3311): not a failed file. This file and the rest are staged, and the Import screen
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
            if checkStaged, await isStaged(identity) {
                discard()
                return .alreadyStaged
            }
            failure = nil
            do throws(ImportDestinationFailure) {
                result = try await used.commit(unit)
            } catch {
                failure = error
            }
        }

        // iCloud Drive went away while staging there (signed out, or iCloud Drive turned off, mid-job): not a failed
        // file. This file and the rest are staged on this iPhone, and the Import screen says so
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

        // The row, then the cleanup. Written even if the job was cancelled meanwhile: the file was committed. An
        // import writes the imported row (`upsert`, which keeps any staged copy); staging records the staged copy
        // beside the row's state (`markStaged`, which keeps an imported row imported and sends a partial row back
        // to new with its resume cleared, since the partial file was what was staged).
        let outcome = Self.outcomes(of: result, for: unit, at: Date()).first ?? .imported(nil)
        let written: Bool
        switch outcome {
        case let .staged(location):
            let staged = location ?? Self.unreportedStagedLocation(for: result)
            written = await writeRow { try await self.catalogue.markStaged(identity, format: item.format, at: staged) }
        case let .imported(location):
            let record = CatalogueRecord(identity: identity, format: item.format, state: .imported, location: location)
            written = await writeRow { try await self.catalogue.upsert(record) }
        case .skipped, .failed:
            written = true // unreachable: a commit's outcome is imported or staged
        }
        discard() // Photos copies; the staging folder moves the file, leaving only its folder
        return .committed(outcome, used.kind, rowWritten: written)
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

    func commitFailed(_ failure: ImportDestinationFailure, identity: ObjectIdentity, of id: UUID,
                      download: Download, name: String) async -> Bool {
        try? FileManager.default.removeItem(at: download.attempt.directory)
        // The staged file was the whole copy: nothing is left to continue from.
        (current(id) ?? endedJob(id))?.entries[identity]?.resumable = nil
        if current(id) == nil, let ended = endedJob(id), let entry = ended.entries[identity] {
            // The job ended while this file was being committed: no retry and no stop, but its row says it failed
            // rather than staying at "committing".
            resolve(entry, .failed(.destination(failure)))
            refreshState()
            return false
        }
        guard let job = current(id), let entry = job.entries[identity] else { return false }
        switch failure {
        case .notEnoughSpace:
            resolve(entry, .failed(.destination(failure)))
            end(job, .stopped(.phoneStorageFull))
            return false
        case .stagedFileMissing:
            return await retry(identity, of: id, after: .destination(failure))
        case .rejected:
            // The same bytes would get the same answer: no retry.
            resolve(entry, .failed(.destination(failure)))
            refreshState()
            return false
        case .photosAccessDenied:
            // From the staging folder, which has no Photos access to lose: treated as a rejection.
            resolve(entry, .failed(.destination(.rejected(detail: "access denied by the staging folder"))))
            refreshState()
            return false
        case .stagingUnavailable:
            // The staging folder on this iPhone said it was unavailable too, after the switch from iCloud Drive (or
            // the job had ended): nowhere else to go, so the file fails without a retry, like a rejection.
            resolve(entry, .failed(.destination(failure)))
            refreshState()
            return false
        }
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

    /// What one downloaded file is committed as. Every file is its own unit for now; section 5's pairing rule
    /// replaces this for Photos (a RAW and its JPEG come out of the diff next to each other).
    func commitUnit(for file: StagedFile) -> CommitUnit { .single(file) }

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
