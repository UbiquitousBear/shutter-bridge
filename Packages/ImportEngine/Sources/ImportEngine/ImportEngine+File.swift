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
                try? FileManager.default.removeItem(at: download.attempt.directory)
                guard await linkFailed(failure, entry: entry, download: download, job: job) else { return }
            case let .written(url):
                let expected = entry.item.size
                let actual = Self.fileSize(at: url)
                // Every file is checked against the listing; it costs a stat, and it is how a file that finished
                // suspiciously fast after a continue (the spike's 35.4 MB in 0.02 s) gets checked.
                if actual != expected {
                    trace(.sizeMismatch(entry.item.name, expected: expected, actual: actual))
                    try? FileManager.default.removeItem(at: download.attempt.directory)
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
    func linkFailed(_ failure: CameraLinkFailure, entry: FileEntry, download: Download, job: Job) async -> Bool {
        let id = job.id
        switch failure.outcome {
        case .retryNow:
            // A call that was in flight across a pause doesn't fail the file (decision 4): no retry is counted.
            if download.pausedDuring {
                job.requeue(entry)
                refreshState()
                return false
            }
            return await retry(entry.identity, of: id, after: .link(failure.kind))
        case .retryOnReconnect:
            cameraRemoved(job) // puts this file back in the queue too, with no retry counted
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
    /// cancels the driver and its lanes) never cancels a Photos save or a Files move half-way: the file always gets
    /// its row. The retry after a failed commit runs back in the lane, where ending the job cancels its backoff.
    func commit(_ url: URL, identity: ObjectIdentity, of id: UUID, download: Download) async -> Bool {
        guard let job = current(id), let entry = job.entries[identity] else { return false }
        entry.phase = .committing
        refreshState()
        let item = entry.item
        let route = job.route
        let directory = download.attempt.directory
        let token = UUID()
        let task = Task {
            await self.commitAndRecord(url, item: item, identity: identity, of: id, route: route,
                                       attemptDirectory: directory)
        }
        commitsInFlight[token] = (id, task)
        let result = await task.value
        commitsInFlight[token] = nil

        switch result {
        case let .failed(failure):
            return await commitFailed(failure, identity: identity, of: id, download: download, name: item.name)
        case let .committed(location, kind, written):
            guard let job = current(id), let entry = job.entries[identity] else { return false }
            resolve(entry, .imported(location), into: kind)
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

    /// How a commit ended: committed (where, into which destination, and whether its row was written), or failed.
    enum CommitResult: Sendable {
        case committed(ImportedLocation?, DestinationKind, rowWritten: Bool)
        case failed(ImportDestinationFailure)
    }

    /// The commit itself, its row and the cleanup of the staged file. Runs whether or not the job is still current:
    /// once a destination has the file, its row is written.
    func commitAndRecord(_ url: URL, item: CameraItem, identity: ObjectIdentity, of id: UUID, route: ImportRoute,
                         attemptDirectory: URL) async -> CommitResult {
        let unit = commitUnit(for: StagedFile(url: url, filename: item.name, captureDate: item.captureDate))
        var used = route.destination
        var result: ImportResult?
        var failure: ImportDestinationFailure?
        do throws(ImportDestinationFailure) {
            result = try await used.commit(unit)
        } catch {
            failure = error
        }

        // Photos refused the save (3311): not a failed file. This file and the rest go to the Files folder, and the
        // Import screen says why (backlog section 5): a denial links to Settings, a restriction doesn't, so access is
        // read again now (`DestinationDecision.afterDeniedSave(authorisation:)`). Switched once, however many files
        // are in flight: another file's refusal may switch it while this one reads access, so it's checked again.
        if failure == .photosAccessDenied, used.kind == .photos {
            if let job = current(id), job.route.decision == .photos {
                let authorisation = await job.route.authorisation()
                if let job = current(id), job.route.decision == .photos {
                    change(job, to: job.route.afterDeniedSave(authorisation))
                    refreshState()
                }
            }
            used = (current(id)?.route ?? route).filesFolder
            failure = nil
            do throws(ImportDestinationFailure) {
                result = try await used.commit(unit)
            } catch {
                failure = error
            }
        }

        if let failure { return .failed(failure) }
        guard let result else { return .failed(.stagedFileMissing) } // unreachable: a commit returns or throws

        // The row, then the cleanup. Written even if the job was cancelled meanwhile: the file was committed.
        let location = Self.locations(of: result, for: unit).first ?? nil
        let record = CatalogueRecord(identity: identity, format: item.format, state: .imported, location: location)
        var written = false
        for _ in 0 ..< max(1, policy.catalogueWriteAttempts) {
            do {
                try await catalogue.upsert(record)
                written = true
                break
            } catch {
                continue
            }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path(percentEncoded: false)) { try? fm.removeItem(at: url) } // Photos copies
        try? fm.removeItem(at: attemptDirectory)
        return .committed(location, used.kind, rowWritten: written)
    }

    func commitFailed(_ failure: ImportDestinationFailure, identity: ObjectIdentity, of id: UUID,
                      download: Download, name: String) async -> Bool {
        try? FileManager.default.removeItem(at: download.attempt.directory)
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
            // From the Files folder, which has no Photos access to lose: treated as a rejection.
            resolve(entry, .failed(.destination(.rejected(detail: "access denied by the Files folder"))))
            refreshState()
            return false
        }
    }

    func resolve(_ entry: FileEntry, _ outcome: FileOutcome, into kind: DestinationKind? = nil) {
        entry.phase = .done(outcome)
        switch outcome {
        case .imported: if let kind { trace(.imported(entry.item.name, kind)) }
        case let .skipped(reason): trace(.skipped(entry.item.name, reason))
        case let .failed(reason): trace(.failed(entry.item.name, reason))
        }
    }

    /// What one staged file is committed as. Every file is its own unit for now; section 5's pairing rule replaces
    /// this for Photos (a RAW and its JPEG come out of the diff next to each other). For Files every file stays its
    /// own unit.
    func commitUnit(for file: StagedFile) -> CommitUnit { .single(file) }

    /// Where each file of the unit went, in the unit's order: one Photos asset shared by every file, or one location
    /// per file in the Files folder (nil for any the destination didn't report).
    static func locations(of result: ImportResult, for unit: CommitUnit) -> [ImportedLocation?] {
        let count = unit.files.count
        switch result {
        case let .photosAsset(localIdentifier):
            return Array(repeating: .photosAsset(localIdentifier: localIdentifier), count: count)
        case let .files(locations):
            return (0 ..< count).map { i in
                i < locations.count ? .file(relativePath: locations[i].relativePath) : nil
            }
        }
    }
}
