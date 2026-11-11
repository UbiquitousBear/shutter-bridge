import CameraTransport
import Catalogue

/// One file of a job as the Import screen shows it: per-file rows with their state and progress (backlog section 6,
/// *Import*). A plain snapshot, taken on the engine; `ImportEngine.currentFiles` gives them in queue order.
public struct ImportFileStatus: Sendable, Hashable, Identifiable {
    /// Stable for the job's life, across a replug (the link's handle isn't).
    public enum ID: Sendable, Hashable {
        /// A file with a catalogue identity.
        case file(ObjectIdentity)
        /// A picked file without a capture date, so without an identity; its place among those.
        case undated(Int)
    }

    public enum Phase: Sendable, Hashable {
        /// Waiting for its turn (or to be copied again after a pause, a stall or a replug).
        case queued
        /// A `bytes` call is in flight.
        case downloading
        /// A real error is being retried after a short wait (decision 4).
        case waitingToRetry
        /// Downloaded; being saved to Photos or moved into the staging folder.
        case committing
        /// Done: where it went (nil if the destination didn't say).
        case imported(ImportedLocation?)
        /// Done: staged at this place in the staging folder (nil if the destination didn't say). Not imported.
        case staged(StagedLocation?)
        /// Left out, and why.
        case skipped(ImportSkipReason)
        /// Failed after its retries, and why.
        case failed(ImportFailureReason)
        /// The job ended (cancelled, stopped, catalogue unavailable) before this file was copied: it stays on the
        /// card and the next import offers it again.
        case notImported

        /// Imported, staged, skipped, failed or not imported: nothing more will happen to it in this job.
        public var isResolved: Bool {
            switch self {
            case .imported, .staged, .skipped, .failed, .notImported: true
            case .queued, .downloading, .waitingToRetry, .committing: false
            }
        }
    }

    public var id: ID
    /// The file as the job knows it (its handle is the current session's).
    public var item: CameraItem
    public var phase: Phase
    /// Bytes shown for this file: what its download has written (never going backwards, as in `ImportProgress`),
    /// its full size once it is committing or resolved.
    public var bytesDone: UInt64
    /// `bytes` calls made for it so far (1 for a file copied once).
    public var attempts: Int

    public init(id: ID, item: CameraItem, phase: Phase, bytesDone: UInt64, attempts: Int = 0) {
        self.id = id
        self.item = item
        self.phase = phase
        self.bytesDone = bytesDone
        self.attempts = attempts
    }

    /// 0 to 1, by bytes; 1 for an imported, staged, skipped or failed file, and for an empty one once it is committing;
    /// 0 for a file the ended job didn't copy.
    public var fractionCompleted: Double {
        if phase == .notImported { return 0 }
        if phase.isResolved { return 1 }
        guard item.size > 0 else { return phase == .committing ? 1 : 0 }
        return min(1, Double(bytesDone) / Double(item.size))
    }
}

/// The job's progress and its files, read together in one step on the engine, so the rows and the totals agree.
public struct ImportSnapshot: Sendable, Hashable {
    public var progress: ImportProgress
    public var files: [ImportFileStatus]

    public init(progress: ImportProgress, files: [ImportFileStatus]) {
        self.progress = progress
        self.files = files
    }

    public static let none = ImportSnapshot(progress: .none, files: [])
}

extension ImportEngine {
    /// The current job's files, or the last job's once it has finished, in queue order: listed files newest first,
    /// then appended files in the order they were added, then picked files that had no capture date (skipped).
    /// Empty before the first job and while the first listing runs. Once the job has ended, a file it never got to
    /// (queued, downloading or waiting to retry) reads `.notImported`; one still committing reads `.committing` until
    /// its commit finishes, which resolves it on the ended job.
    public var currentFiles: [ImportFileStatus] {
        guard let j = job ?? lastJob else { return [] }
        return fileStatuses(of: j)
    }

    /// `currentProgress` and `currentFiles` together.
    public var currentSnapshot: ImportSnapshot {
        ImportSnapshot(progress: currentProgress, files: currentFiles)
    }

    func fileStatuses(of job: Job) -> [ImportFileStatus] {
        var out: [ImportFileStatus] = []
        out.reserveCapacity(job.entries.count + job.unkeyed.count)
        let ended = job.finished != nil
        for entry in job.sortedEntries {
            let size = entry.item.size
            let phase: ImportFileStatus.Phase
            var bytes = entry.shownBytes
            switch entry.phase {
            case .queued:
                phase = ended ? .notImported : .queued
            case let .downloading(d):
                phase = ended ? .notImported : .downloading
                bytes = max(bytes, min(d.attempt.meter.reading.bytes, size))
            case .waitingToRetry:
                phase = ended ? .notImported : .waitingToRetry
            case .committing:
                phase = .committing
                bytes = size
            case let .done(outcome):
                bytes = size
                switch outcome {
                case let .imported(location): phase = .imported(location)
                case let .staged(location): phase = .staged(location)
                case let .skipped(reason): phase = .skipped(reason)
                case let .failed(reason): phase = .failed(reason)
                }
            }
            out.append(ImportFileStatus(id: .file(entry.identity), item: entry.item, phase: phase,
                                        bytesDone: bytes, attempts: entry.attempts))
        }
        for (i, item) in job.unkeyed.enumerated() {
            out.append(ImportFileStatus(id: .undated(i), item: item, phase: .skipped(.noCaptureDate),
                                        bytesDone: item.size))
        }
        return out
    }
}
