import Foundation
import PhotosBridge

// *Import keepers* (backlog section 7.5; I12): a keepers job's route has no fallback (`ImportRoute.keepers`), so when
// Photos refuses a save (3311) the job stops for Photos access instead of staging the rest, which are in Staging already.

extension ImportEngine {
    /// The halves of a commit Photos refused on a route with no fallback (`CommitResult.photosRefused`): nothing was
    /// saved or staged and the marker is gone (`commitAndRecord`), so they go back to waiting, with no retry counted
    /// and not failed, as a commit that didn't begin does (`requeueUncommitted`). The job ends
    /// `.photosAccessNeeded`; one that has ended already (another refused commit ended it, or it was cancelled) keeps
    /// its outcome and its record is written again.
    func stopForPhotosAccess(_ halves: [Half], _ authorisation: PhotosAuthorisation, of id: UUID) {
        guard let job = current(id) ?? endedJob(id) else { return }
        let running = current(id) != nil
        for h in halves {
            guard let entry = job.entries[h.identity] else { continue }
            entry.resumable = nil
            if running { job.requeue(entry) } else { entry.phase = .queued }
        }
        if running {
            end(job, .photosAccessNeeded(authorisation))
        } else {
            refreshState()
            writeJobRecord(of: job)
        }
    }
}
