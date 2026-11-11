import Catalogue
import Foundation
import PhotosBridge

// The pending-commit marker (backlog section 3.1; I9 writes and clears it, I15 resolves it). Every commit is bracketed
// by one, under the commit's token (`commitsInFlight`'s key): `commitAndRecord` writes it before the destination is
// called and again before a switch to another destination, removes it when the commit fails, and clears it in the same
// store save as the rows when it succeeds (`finishCommit`). A pair is one commit, so one marker covers both its files.

extension ImportEngine {
    /// Writes the commit's marker (`beginCommit`), naming where `destination` would send `unit` now, with as many
    /// tries as a row gets; a second write under the same token replaces the first (the switch from Photos to the
    /// staging folder, or from iCloud Drive to this iPhone). Whether it was written.
    func beginMarker(_ token: UUID, of id: UUID, unit: CommitUnit, files: [CommitFile],
                     to destination: any ImportDestination) async -> Bool {
        let marker = Self.pendingCommit(token, job: id, unit: unit, files: files,
                                        target: destination.commitTarget(for: unit), at: Date())
        return await writeRow { try await self.catalogue.beginCommit(marker) }
    }

    /// Removes the marker of a commit that failed or committed nothing, with one try: a marker left behind is
    /// harmless (the resolution finds nothing for it, or finds a later retry's copy, which is also right).
    func abandonMarker(_ token: UUID) async {
        try? await catalogue.abandonCommit(token)
    }

    /// The commit's marker couldn't be written, so nothing was sent on: the downloads still going are deleted (a
    /// resumable partial too, since no checkpoint for it can be trusted to be written either) and the commit reports
    /// `.markerNotWritten`, which puts its files back in the queue and ends the job `.catalogueUnavailable`. A marker
    /// written before a refused rewrite (Photos refused the save, so it saved nothing) is removed if the catalogue
    /// lets it be; left behind, it is harmless.
    func markerNotWritten(_ token: UUID, _ files: [CommitFile], going: [Int], unit: CommitUnit) async
        -> CommitResult {
        trace(.commitMarkerNotWritten(unit.files.first?.filename ?? ""))
        for i in going { Self.discard(files[i]) }
        await abandonMarker(token)
        return .markerNotWritten
    }

    /// The halves of a commit that didn't begin (`.markerNotWritten`): back to queued, with no retry counted and not
    /// failed, so the next job queues them again (they have no row); their downloads are gone. The job ends
    /// `.catalogueUnavailable`, as a row that can't be written ends it; a job that had already ended keeps its outcome
    /// and its record is written again.
    func requeueUncommitted(_ halves: [Half], of id: UUID) {
        guard let job = current(id) ?? endedJob(id) else { return }
        let running = current(id) != nil
        for h in halves {
            guard let entry = job.entries[h.identity] else { continue }
            entry.resumable = nil
            if running { job.requeue(entry) } else { entry.phase = .queued }
        }
        if running {
            end(job, .catalogueUnavailable)
        } else {
            refreshState()
            writeJobRecord(of: job)
        }
    }

    /// The marker for committing `unit` (its files matched back to `files` by their downloads) to `target`.
    static func pendingCommit(_ token: UUID, job: UUID, unit: CommitUnit, files: [CommitFile], target: CommitTarget,
                              at date: Date) -> PendingCommit {
        let roles: [PendingCommit.Role] = switch unit {
        case .single: [.single]
        case .pair: [.raw, .processed]
        }
        var marked: [PendingCommit.File] = []
        for (staged, role) in zip(unit.files, roles) {
            guard let file = files.first(where: { $0.url == staged.url }) else { continue }
            marked.append(PendingCommit.File(identity: file.identity, format: file.item.format, role: role,
                                             assetDate: staged.captureDate))
        }
        return PendingCommit(id: token, jobID: job, destination: PendingCommit.Destination(target), files: marked,
                             writtenAt: date)
    }
}

extension PendingCommit.Destination {
    /// The catalogue's form of a destination's commit target (its staging place without the reason).
    init(_ target: CommitTarget) {
        switch target {
        case .photosLibrary: self = .photos
        case let .stagingFolder(place, folderPath): self = .staging(root: StagingRoot(place), folder: folderPath)
        }
    }
}
