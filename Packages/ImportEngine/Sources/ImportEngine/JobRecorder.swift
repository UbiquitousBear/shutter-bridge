import CameraTransport
import Catalogue
import Foundation
import PhotosBridge

// Every job leaves one record for History (backlog section 4; I9): written when it starts, at each pause, on a
// reconnect (the same record carries on over the new link) and when it ends, and again when a commit still in flight at
// the end resolves its files on the ended job. Each write is the whole record as the job stands, its counts the job's
// `ImportProgress` at that moment (the Import screen's numbers), so the last write matches the last progress. A job the
// app's end interrupts keeps its last record, with no end time: History reads it as *Stopped early*.

extension ImportEngine {
    /// Writes the job's record as it stands (`recordJob`, which replaces the one with the same id) after the writes
    /// before it, so they land in the order they were made; a refused write is traced and the next one replaces it.
    /// Synchronous for its caller: the record is taken now, written in a task of its own.
    func writeJobRecord(of job: Job) {
        let record = jobRecord(of: job)
        let previous = jobRecordWrite
        let catalogue = self.catalogue
        jobRecordWrite = Task {
            await previous?.value
            do {
                try await catalogue.recordJob(record)
            } catch {
                self.trace(.jobRecordNotWritten)
            }
        }
    }

    /// Waits until every job record written so far has landed (or been refused).
    func settleJobRecords() async {
        await jobRecordWrite?.value
    }

    /// The job as History keeps it.
    func jobRecord(of job: Job) -> JobRecord {
        let progress = snapshot(of: job)
        let failed = job.sortedEntries.compactMap { entry -> ObjectIdentity.ContentKey? in
            if case .failed = entry.outcome { entry.identity.contentKey } else { nil }
        }
        return JobRecord(
            id: job.id, camera: job.camera,
            purpose: job.route.isKeepers ? .keepers : JobRecord.Purpose(job.startPurpose),
            destination: job.route.decision.kind.map(JobRecord.Destination.init),
            carrier: JobRecord.Carrier(job.link.descriptor.carrier),
            selection: Self.recordedSelection(job.selection, camera: job.camera, timeZone: job.timeZone),
            startedAt: job.startedAt, finishedAt: job.finished == nil ? nil : job.finishedAt,
            outcome: job.finished.map(JobRecord.Outcome.init), filesTotal: progress.filesTotal,
            filesImported: progress.filesImported, filesStaged: progress.filesStaged,
            filesSkipped: progress.filesSkipped, filesFailed: progress.filesFailed,
            bytesTotal: progress.bytesTotal, bytesDone: progress.bytesDone, failedFiles: failed)
    }

    /// What was asked for, with picked files by content key (link handles don't survive a replug); a pick without a
    /// capture date has no key and is left out of the list.
    static func recordedSelection(_ selection: ImportSelection, camera: CameraKey, timeZone: TimeZone)
        -> JobRecord.Selection {
        func keys(_ items: [CameraItem]) -> [ObjectIdentity.ContentKey] {
            items.compactMap { $0.identity(camera: camera, timeZone: timeZone)?.contentKey }
        }
        return switch selection {
        case .allNew: .allNew
        case let .dateRange(range): .dateRange(range)
        case let .items(items), let .requeued(items): .picked(keys(items))
        case let .newItems(items): .pickedNew(keys(items))
        }
    }
}

extension JobRecord.Purpose {
    /// A job's purpose from its route's when it started (`ImportRoute.purpose`). *Import keepers* is a Photos job whose
    /// route has no fallback (`ImportRoute.isKeepers`), recorded as `.keepers` by `jobRecord(of:)`.
    init(_ purpose: DestinationKind) {
        switch purpose {
        case .photos: self = .import
        case .staging: self = .stage
        }
    }
}

extension JobRecord.Destination {
    /// Where the job's files go now: Photos, or Staging (a stage job, or an import job staged instead).
    init(_ kind: DestinationKind) {
        switch kind {
        case .photos: self = .photos
        case .staging: self = .staging
        }
    }
}

extension JobRecord.Carrier {
    init(_ carrier: CameraCarrier) {
        switch carrier {
        case .usb: self = .usb
        case .wifi: self = .wifi
        case .staging: self = .staging
        }
    }
}

extension JobRecord.Outcome {
    /// The reason a keepers job stopped for Photos access is recorded under (`JobOutcome.photosAccessNeeded`): not a
    /// `CameraLinkFailure.Kind`, so it can't be taken for one.
    public static let photosAccessReason = "photosAccess"

    /// The engine's outcome; a stop keeps its kind's name, for wording.
    init(_ outcome: JobOutcome) {
        switch outcome {
        case .completed: self = .completed
        case .cancelled: self = .cancelled
        case let .stopped(kind): self = .stopped(reason: kind.rawValue)
        case .catalogueUnavailable: self = .catalogueUnavailable
        case .photosAccessNeeded: self = .stopped(reason: Self.photosAccessReason)
        }
    }
}
