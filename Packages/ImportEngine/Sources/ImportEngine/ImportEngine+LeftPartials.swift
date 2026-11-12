import CameraTransport
import Catalogue
import Foundation

// What becomes of a resumable file's partial copy, and of its `.partial` row, when the file is resolved without being
// committed (backlog section 3, the fault matrix's known issues; I15): the harness's rule is that a `.partial` row
// exists only for a file left resumable.
//
// - A file skipped or failed for a reason of its own (it left the card, its retries are used up) won't be continued:
//   `resolve` deletes its partial copy, and its row goes back to `.new` here (`resolveForgettingPartial(_:_:)`, or
//   `forgetPartialRow(of:)` for a queued file the listing no longer holds), rather than pointing at a deleted file
//   until the 7-day prune.
// - A job stopped for a reason that isn't the file's (a full phone) keeps the file's partial copy and its row, with its
//   latest checkpoint written first, so the next job continues it, as it would after a drop
//   (`keepsPartialWhenStopped(by:download:entry:)`).
extension ImportEngine {
    /// Sends the file's `.partial` row back to `.new` (`CatalogueStore.forgetPartial`) while it still names a file in
    /// the file's own partial folder, at the offset read: called just before a queued file the listing no longer holds
    /// is resolved skipped (`remap`), which deletes that folder, and for a stop that is the file's own; a file skipped or
    /// failed from its lane goes through `resolveForgettingPartial(_:_:)` instead. A checkpoint written in another folder (another job's), an
    /// import or a staged copy is left alone. A catalogue that can't answer leaves the row: the launch pass
    /// (`reconcilePartials()`) sends it back to offset 0 once its file is gone.
    ///
    /// The row has to be the file's last write, so the partial copy is taken from the file while this runs: no
    /// checkpoint can start (`saveCheckpoint` and `checkpointCrossed` need it), and those in flight are waited for
    /// (`settle(_:of:)`) before the row is read. It is given back afterwards, its offset marked unwritten, so a file
    /// put back in the queue meanwhile (a reconnect, a stall) carries on from it and writes its row again; if the job
    /// ended meanwhile, or the file has a new copy, it is deleted, as `end(_:_:)` would have.
    func forgetPartialRow(of entry: FileEntry) async {
        guard let resumable = entry.resumable else { return }
        entry.resumable = nil
        await sendRowBackToNew(of: entry, for: resumable)
        let stillTheJobs = job?.entries[entry.identity] === entry && entry.outcome == nil
        if entry.resumable == nil, stillTheJobs {
            entry.resumable = resumable
        } else if !isHeld(resumable.folder) {
            try? FileManager.default.removeItem(at: resumable.folder)
        }
    }

    /// Waits for the file's checkpoint writes in flight, then sends its `.partial` row back to `.new` if it still names a
    /// file in `resumable`'s folder (`forgetPartialRow(of:)`'s catalogue half). `resumable.persistedOffset` goes to 0
    /// when the row was sent back.
    private func sendRowBackToNew(of entry: FileEntry, for resumable: ResumableFile) async {
        await settle(entry.checkpointWrites, of: entry.item.name)
        let folder = resumable.folder.standardizedFileURL.pathComponents
        if let row = try? await catalogue.record(for: entry.identity), row.state == .partial,
           let tempURL = row.tempURL, case let .inside(_, rowFolder) = partialLocation(of: row),
           rowFolder.standardizedFileURL.pathComponents == folder,
           (try? await catalogue.forgetPartial(entry.identity, ifTempURL: tempURL, offset: row.resumeOffset)) == true {
            resumable.persistedOffset = 0
        }
    }

    /// Resolves the file with `outcome` (skipped or failed for a reason of its own) and sends its `.partial` row back to
    /// `.new`. The outcome is recorded first, before the catalogue is awaited: a job that ends meanwhile (cancelled)
    /// then lists the file as it was resolved, not queued, and its record says so; and the file, no longer downloading,
    /// is not put back in the queue by a reconnect or a stall, nor does it take another checkpoint. Its partial folder
    /// is kept until the row has been sent back (the row is compared with it) and then deleted, as `resolve` would have
    /// at once. Without a partial copy it is `resolve` alone.
    func resolveForgettingPartial(_ entry: FileEntry, _ outcome: FileOutcome) async {
        guard let resumable = entry.resumable else {
            resolve(entry, outcome)
            return
        }
        entry.resumable = nil // so `resolve` leaves the folder for now
        resolve(entry, outcome)
        await sendRowBackToNew(of: entry, for: resumable)
        if !isHeld(resumable.folder) { try? FileManager.default.removeItem(at: resumable.folder) }
    }

    /// Whether a job stopped by `failure` keeps the partial copy of the file whose download failed with it: on a link
    /// that resumes, for a stop that isn't the file's (a full phone, the camera refusing or not authorising the app),
    /// but not for a camera that turned out to be another body (`identityChanged`), whose files these aren't.
    func keepsPartialWhenStopped(by failure: CameraLinkFailure, download: Download, entry: FileEntry) -> Bool {
        guard failure.outcome == .stopJob, failure.kind != .identityChanged, download.attempt.keepsFiles,
              entry.resumable != nil else { return false }
        return true
    }

    /// The file's download is still `download`, in the job `id`: nothing walked away from it while the engine awaited
    /// the catalogue (a reconnect, a stall or the job's end puts it back in the queue, and whoever did so cleans up).
    func stillDownloading(_ entry: FileEntry, _ download: Download, in id: UUID) -> Bool {
        current(id)?.entries[entry.identity] === entry && entry.download === download
    }

    /// The queued files of `job` that a listing after a reconnect or a relist doesn't hold (by content, as `remap`
    /// finds them) and that keep a partial copy: `remap` resolves them skipped, which deletes the copy.
    func resumablesLeavingTheCard(_ job: Job, _ listed: [CameraItem]) -> [FileEntry] {
        let onCard = Self.byContent(listed, camera: job.camera, timeZone: job.timeZone)
        return job.sortedEntries.filter { entry in
            guard case .queued = entry.phase, entry.resumable != nil else { return false }
            return onCard[entry.identity.contentKey] == nil
        }
    }
}
