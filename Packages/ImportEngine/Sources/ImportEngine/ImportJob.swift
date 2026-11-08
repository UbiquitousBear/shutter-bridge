import CameraTransport
import Catalogue
import Foundation
import PhotosBridge

/// Why a file was left out. Public for the Import screen's rows (`ImportFileStatus`).
public enum ImportSkipReason: Sendable, Hashable {
    /// The link's failure has the outcome *skip this file* (or the file wasn't on the card after a replug).
    case link(CameraLinkFailure.Kind)
    /// Picked in Browse but not a still: 1.0 imports stills only.
    case notAStill
    /// The link gave no capture date, so the file has no identity (section 4 decides what to do with these).
    case noCaptureDate
}

/// Why a file failed: real errors only, after the retries (decision 4). Public for the Import screen's rows.
public enum ImportFailureReason: Sendable, Hashable {
    case link(CameraLinkFailure.Kind)
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case destination(ImportDestinationFailure)
}

typealias SkipReason = ImportSkipReason
typealias FailureReason = ImportFailureReason

enum FileOutcome: Sendable, Hashable {
    case imported(ImportedLocation?)
    case skipped(SkipReason)
    case failed(FailureReason)
}

/// One `bytes` call in flight. Confined to the engine actor.
final class Download {
    let attempt: DownloadAttempt
    let startedAt: Duration
    /// The meter's count at the last tick, to notice progress.
    var lastBytes: UInt64 = 0
    /// When the stall clock last restarted: the start, or a resume.
    var lastProgressAt: Duration
    /// In flight when a pause began: a `.retryNow` failure of this call doesn't count as a retry.
    var pausedDuring = false

    init(attempt: DownloadAttempt, startedAt: Duration) {
        self.attempt = attempt
        self.startedAt = startedAt
        self.lastProgressAt = startedAt
    }
}

enum FilePhase {
    case queued
    case downloading(Download)
    case waitingToRetry
    case committing
    case done(FileOutcome)
}

/// One file of a job. Confined to the engine actor; never sent anywhere.
final class FileEntry {
    let identity: ObjectIdentity
    /// Queue order: listed files before files appended during the listing, then appended files in order.
    let index: Int
    /// The current session's item; its handle is replaced when the card is listed again after a replug.
    var item: CameraItem
    var phase: FilePhase = .queued
    /// Real-error retries used.
    var retries = 0
    /// Stalls of this file since the job started or the person last continued. Never reset by progress: a file that
    /// always stalls part-way must still reach the limit and wait for the person.
    var stalls = 0
    /// Every `bytes` call for the file.
    var attempts = 0
    /// In flight across a pause, or after an abandoned attempt: kept out of the rate.
    var interrupted = false
    /// The most bytes progress has shown for this file, so a restarted download holds its place in the bar until
    /// the new attempt passes it.
    var shownBytes: UInt64 = 0

    init(identity: ObjectIdentity, index: Int, item: CameraItem) {
        self.identity = identity
        self.index = index
        self.item = item
    }

    var download: Download? {
        if case let .downloading(d) = phase { d } else { nil }
    }

    var outcome: FileOutcome? {
        if case let .done(o) = phase { o } else { nil }
    }

    /// Downloading, waiting to retry or committing: owned by a running file task.
    var isActive: Bool {
        switch phase {
        case .downloading, .waitingToRetry, .committing: true
        case .queued, .done: false
        }
    }
}

enum JobPhase: Sendable, Hashable {
    case listing
    case downloading
    case waitingForCamera
}

/// The engine's one job. Confined to the engine actor; child tasks get only the job's `id` and a file's identity and
/// look them up again after every await, so a job that has finished turns late work into cleanup.
final class Job {
    let id = UUID()
    let camera: CameraKey
    /// The zone identities are computed in, frozen for the job (`start` turns an autoupdating zone into a fixed one).
    let timeZone: TimeZone
    let selection: ImportSelection
    /// Downloads in flight, from the settings at the start.
    let limit: Int
    /// `staging/<id>/`; every attempt gets its own folder inside.
    let jobDirectory: URL
    let signal = WakeSignal()

    var link: any CameraLink
    var linkGeneration = 0
    var hasListed = false
    var listRetries = 0
    var route: ImportRoute
    var phase: JobPhase = .listing
    var pauses: Set<PauseReason> = []
    var stallResumeAt: Duration?
    /// A file stalled more often than the automatic retries allow: the stall waits for the person.
    var stallHold = false
    /// The job's files by the identity each was picked or listed under, which its row is written with.
    private(set) var entries: [ObjectIdentity: FileEntry] = [:]
    /// Each file's identity by its content key (name, capture time, size: Shamil's rule of 8 Nov), so a file a later
    /// listing or a pick reports in another folder is found as the one already in the job.
    private var byContent: [ObjectIdentity.ContentKey: ObjectIdentity] = [:]
    /// Picked files without an identity (no capture date), skipped and counted.
    var unkeyed: [CameraItem] = []
    /// Pending files, kept sorted by `FileEntry.index`.
    var queue: [ObjectIdentity] = []
    var nextIndex = 0
    var rate: RateEstimator
    var finished: JobOutcome?
    var driver: Task<Void, Never>?

    init(camera: CameraKey, timeZone: TimeZone, selection: ImportSelection, limit: Int, staging: URL,
         link: any CameraLink, route: ImportRoute, rateSamples: Int) {
        self.camera = camera
        self.timeZone = timeZone
        self.selection = selection
        self.limit = limit
        self.jobDirectory = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        self.link = link
        self.route = route
        self.rate = RateEstimator(capacity: rateSamples)
    }

    var sortedEntries: [FileEntry] { entries.values.sorted { $0.index < $1.index } }

    /// The job's file with the same content as `identity` (whatever its folder or camera key), if any.
    func entry(sameContentAs identity: ObjectIdentity) -> FileEntry? {
        byContent[identity.contentKey].flatMap { entries[$0] }
    }

    /// Adds a file, replacing any with the same content (and taking it out of the queue).
    func add(_ entry: FileEntry) {
        if let existing = byContent[entry.identity.contentKey] {
            queue.removeAll { $0 == existing }
            entries[existing] = nil
        }
        entries[entry.identity] = entry
        byContent[entry.identity.contentKey] = entry.identity
    }

    var hasActiveFiles: Bool { entries.values.contains { $0.isActive } }

    /// Puts a file back in the queue in its original place (which is at the front of what's left, because files are
    /// claimed in index order).
    func requeue(_ entry: FileEntry) {
        entry.phase = .queued
        guard !queue.contains(entry.identity) else { return }
        let at = queue.firstIndex { (entries[$0]?.index ?? .max) > entry.index } ?? queue.endIndex
        queue.insert(entry.identity, at: at)
    }

    /// The pause the person has to deal with first.
    var primaryPause: PauseReason? {
        for r in [PauseReason.cameraRemoved, .appInBackground, .stalled, .byPerson] where pauses.contains(r) {
            return r
        }
        return nil
    }

    var state: ImportJobState {
        if let finished { return .finished(finished) }
        if let p = primaryPause { return .paused(p) }
        return .running
    }

    /// A USB job running, or paused for a removal or a stall it gets over by itself: the app keeps the screen on
    /// meanwhile (decision 1). Not while the person or the app's leaving paused it, nor once a stall waits for the
    /// person after the automatic retries.
    var isUSBImportRunning: Bool {
        finished == nil && link.descriptor.carrier == .usb && pauses.isSubset(of: [.cameraRemoved, .stalled])
            && !stallHold
    }
}
