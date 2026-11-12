import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge

/// History's rules over the job records (backlog section 4; D6), pure, so they are tested on Linux: which jobs stopped
/// early, how many of their files are left, what *Resume* and *Re-run* queue from a listing. What counts as done mirrors
/// the engine's own rule (`DoneRule`, Shamil, 11 Nov), and the engine's diff decides again when the job starts, so a
/// rule here can only queue too much, never import a file twice.
public enum HistoryRules {
    /// What a tap on a row offers.
    public enum Action: Sendable, Hashable {
        /// *Resumable*: the job stopped early and files are left; nil when how many isn't known.
        case resume(filesLeft: Int?)
        /// The job ended with failed files that still aren't done.
        case rerun(failedLeft: Int)
    }

    /// The Import button's choice that queues a job's files again with its purpose (D6: *Resumable* re-queues with the
    /// original purpose). Nil for a keepers job, whose files come from Staging, not from a camera (*Import keepers*,
    /// I12).
    public static func choice(for purpose: JobRecord.Purpose) -> DestinationKind? {
        switch purpose {
        case .import: .photos
        case .stage: .staging
        case .keepers: nil
        }
    }

    /// Whether the job stopped before it was done: the app's end interrupted it (no end and not running), or a failure
    /// or the catalogue stopped it. A cancel is the person's choice, so it isn't *Resumable* (its failed files can still
    /// be re-run).
    public static func stoppedEarly(_ job: JobRecord, running: Bool) -> Bool {
        switch job.outcome {
        case nil: !running
        case .stopped, .catalogueUnavailable: true
        case .completed, .cancelled: false
        }
    }

    /// The files the record says were neither done, skipped nor failed when it was last written.
    public static func recordLeft(_ job: JobRecord) -> Int {
        max(0, job.filesTotal - job.filesImported - job.filesStaged - job.filesSkipped - job.filesFailed)
    }

    /// Whether a file is done for a job of this purpose: imported, for an import to Photos; staged, or (when only new
    /// files were asked for) imported, for a stage job (`DoneRule`).
    public static func isDone(state: ObjectState, staged: Bool, purpose: DestinationKind, newOnly: Bool) -> Bool {
        switch purpose {
        case .photos: state == .imported
        case .staging: staged || (newOnly && state == .imported)
        }
    }

    /// Whether the selection asked only for new files (every selection but an explicit pick).
    public static func newOnly(_ selection: JobRecord.Selection) -> Bool {
        if case .picked = selection { false } else { true }
    }

    /// The action a row offers, from its record and what the catalogue says is left.
    ///
    /// - Parameters:
    ///   - running: The job is the one the engine runs now (its record has no end yet).
    ///   - filesLeft: The job's files still not done by the catalogue (`HistoryModel`'s count), nil when it can't
    ///     tell (an *all new* job whose card was never listed).
    ///   - failedLeft: The job's failed files still not done by the catalogue.
    public static func action(for job: JobRecord, running: Bool, filesLeft: Int?, failedLeft: Int) -> Action? {
        guard !running, choice(for: job.purpose) != nil else { return nil }
        if stoppedEarly(job, running: running) {
            // Only while files are left (section 4): by the catalogue when it can tell, else by the record, and a
            // job that never listed its card (no total) is offered while the catalogue can't say otherwise.
            if let filesLeft {
                if filesLeft > 0 { return .resume(filesLeft: filesLeft) }
            } else if recordLeft(job) > 0 || job.filesTotal == 0 {
                return .resume(filesLeft: job.filesTotal == 0 ? nil : recordLeft(job))
            }
        }
        return failedLeft > 0 ? .rerun(failedLeft: failedLeft) : nil
    }

    /// One listed file with the catalogue's facts about it.
    public struct Listed: Sendable, Hashable {
        public var item: CameraItem
        /// Nil for a file without a capture date: it has no identity, and the engine skips it (D10).
        public var identity: ObjectIdentity?
        public var state: ObjectState
        public var staged: Bool

        public init(item: CameraItem, identity: ObjectIdentity?, state: ObjectState = .new, staged: Bool = false) {
            self.item = item
            self.identity = identity
            self.state = state
            self.staged = staged
        }
    }

    /// What *Resume* queues: the job's stored selection rebuilt against the card as it is now (section 4). *All new*
    /// and a date range take the still photos that are new or partial (and, for a stage job, not staged), as the
    /// engine's diff of a whole card does; a pick takes the picked files by content key that aren't done. One file
    /// listed in two folders is queued once.
    public static func resumeQueue(_ selection: JobRecord.Selection, purpose: DestinationKind,
                                   listing: [Listed]) -> [CameraItem] {
        var seen = Set<ObjectIdentity.ContentKey>()
        var queue: [CameraItem] = []
        switch selection {
        case .allNew, .dateRange:
            var range: ClosedRange<Date>?
            if case let .dateRange(r) = selection { range = r }
            for file in listing where file.item.format.isStill {
                guard let identity = file.identity else { continue }
                if let range, let date = file.item.captureDate, !range.contains(date) { continue }
                guard file.state == .new || file.state == .partial else { continue }
                if purpose == .staging, file.staged { continue }
                if seen.insert(identity.contentKey).inserted { queue.append(file.item) }
            }
        case let .picked(keys), let .pickedNew(keys):
            let wanted = Set(keys)
            let newOnly = newOnly(selection)
            for file in listing {
                guard let identity = file.identity, wanted.contains(identity.contentKey) else { continue }
                if isDone(state: file.state, staged: file.staged, purpose: purpose, newOnly: newOnly) { continue }
                if seen.insert(identity.contentKey).inserted { queue.append(file.item) }
            }
        }
        return queue
    }

    /// What *Re-run* queues (section 4): exactly the job's failed files that are still not imported (for a stage job,
    /// not staged), matched by content key against the listing, and nothing else; a failed file still not done that the
    /// card no longer has is `missing`.
    ///
    /// - Parameter done: Whether each failed file is done now, by the catalogue (matched by content, so a file imported
    ///   since by another job, or from another camera, counts).
    public static func rerunQueue(failed: [ObjectIdentity.ContentKey], done: Set<ObjectIdentity.ContentKey>,
                                  listing: [Listed]) -> (queue: [CameraItem], missing: [ObjectIdentity.ContentKey]) {
        var byKey: [ObjectIdentity.ContentKey: CameraItem] = [:]
        for file in listing {
            guard let key = file.identity?.contentKey, byKey[key] == nil else { continue }
            byKey[key] = file.item
        }
        var seen = Set<ObjectIdentity.ContentKey>()
        var queue: [CameraItem] = []
        var missing: [ObjectIdentity.ContentKey] = []
        for key in failed where !done.contains(key) && seen.insert(key).inserted {
            if let item = byKey[key] { queue.append(item) } else { missing.append(key) }
        }
        return (queue, missing)
    }

    /// The calendar day a job started on, "YYYYMMDD" in `calendar`, which History groups by.
    public static func day(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
