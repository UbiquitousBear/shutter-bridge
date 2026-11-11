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
    /// An import job was staged instead part-way (Photos access was turned off: a refused save, or a continue), and
    /// the catalogue already has a staged copy of this file (by content), so it isn't staged a second time.
    case alreadyStaged
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
    /// Staged (a stage job, or an import job staged instead), at this place in the staging folder (nil if the
    /// destination didn't say). Not imported: the catalogue's state is kept (`CatalogueStore.markStaged`).
    case staged(StagedLocation?)
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
    /// Its partial copy, on a link that resumes; nil on one that doesn't (each attempt has a folder of its own).
    var resumable: ResumableFile?
    /// Queued under a stage job's done rule, which already left it out if it was staged. False for a file queued by
    /// an import job, which ignores staging: if that job is staged instead, the file is checked for a staged copy
    /// before it is committed (`ImportEngine.commitAndRecord`), so it is never staged twice.
    var queuedUnderStagingRule = false

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

/// A file's partial copy on a link that resumes (Wi-Fi). Confined to the engine actor.
final class ResumableFile {
    /// `staging/Partials/<uuid>/`: every attempt at the file writes here, and the catalogue's `tempURL` points
    /// here. Outside the job's folder, so it outlives the job (a later job resumes from it through the catalogue).
    let folder: URL
    /// The last attempt that wrote into the folder; the next continues from its latest checkpoint once its call
    /// has ended.
    var previous: DownloadAttempt?
    /// A partial file an earlier job left, found through the catalogue, until an attempt in this job takes it.
    var adopted: PartialSeed?
    /// The offset last written to the catalogue (0: none).
    var persistedOffset: UInt64 = 0

    init(folder: URL, adopted: PartialSeed? = nil, persistedOffset: UInt64 = 0) {
        self.folder = folder
        self.adopted = adopted
        self.persistedOffset = persistedOffset
    }

    /// The newest prefix known to be on disk.
    var best: PartialSeed? {
        if let previous { return previous.latestCheckpoint }
        return adopted
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
    let settingsLimit: Int
    /// `staging/<id>/`; every attempt gets its own folder inside.
    let jobDirectory: URL
    let signal = WakeSignal()

    var link: any CameraLink
    var linkGeneration = 0
    /// The card as the app has just listed it, handed over by `reconnect(_:to:knownItems:route:)`: the next listing
    /// uses it instead of asking the link again (W8 reopens with known handles).
    var pendingListing: [CameraItem]?
    /// What a `disconnected` failure means for this job: `.cameraUnreachable` once a link has reported a lost
    /// session (Wi-Fi), `.cameraRemoved` until then (USB never reports one).
    var cameraLossReason: PauseReason = .cameraRemoved
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
        self.settingsLimit = limit
        self.jobDirectory = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        self.link = link
        self.route = route
        self.rate = RateEstimator(capacity: rateSamples)
    }

    var sortedEntries: [FileEntry] { entries.values.sorted { $0.index < $1.index } }

    /// Downloads in flight: the setting, capped by what the current link can carry (wireless plan, decision 5; USB
    /// 2, Wi-Fi 1). Read again after a reconnect, so a new link brings its own cap.
    var limit: Int { min(settingsLimit, link.capabilities.maxDownloadsInFlight) }

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

    /// The pause the person has to deal with first (`PauseReason.precedence`).
    var primaryPause: PauseReason? { PauseReason.precedence.first { pauses.contains($0) } }

    var state: ImportJobState {
        if let finished { return .finished(finished) }
        if let p = primaryPause { return .paused(p) }
        return .running
    }

    /// The job's link's carrier, while the job is running or paused only for what it gets over without the person
    /// (a removal, a lost card or session, a stall it retries by itself); nil otherwise. Not while the person, the
    /// app's leaving, an expiry or a needed join paused it, nor once a stall waits for the person.
    var runningCarrier: CameraCarrier? {
        guard finished == nil, pauses.isSubset(of: PauseReason.overcomeWithoutThePerson), !stallHold else { return nil }
        return link.descriptor.carrier
    }

    /// Whether this job is a running import over `carrier` (`runningCarrier`). Over USB the app keeps the screen on
    /// meanwhile (decision 1).
    func importRunning(carrier: CameraCarrier) -> Bool { runningCarrier == carrier }
}
