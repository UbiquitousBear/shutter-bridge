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

/// One half of a RAW+JPEG pair, downloaded and size-checked, kept on disk until its partner is downloaded too (or
/// won't be), so the pair is committed as one unit (section 7.1 of docs/iteration-2-backlog.md).
struct HeldHalf {
    /// The downloaded file.
    let url: URL
    /// The call that wrote it: its folder is removed with the file, and its start is the rate's.
    let download: Download
}

enum FilePhase {
    case queued
    case downloading(Download)
    case waitingToRetry
    /// Downloaded, waiting for the other half of its pair (`FileEntry.partner`).
    case held(HeldHalf)
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
    /// Its checkpoint writes in flight (`markPartial`), which its commit waits for before it writes its row.
    let checkpointWrites = CheckpointWrites()
    /// The other half of its RAW+JPEG pair in this job (`RawPairingRule`: same folder, same stem, within 1 s), by
    /// identity; nil for a lone file. The two are committed as one unit, so Photos makes one asset of them; a file
    /// whose partner is already done for the job's purpose, or not in the job, is a lone file.
    var partner: ObjectIdentity?

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

    /// Whether a checkpoint may still be written to the catalogue for it: not once its commit has begun
    /// (`ImportEngine.startCommit`), because the commit's row (`markStaged` or `upsert`) must be the file's last
    /// write. A late checkpoint can't undo an imported row (the catalogue keeps it), but a staged one stays `.new`,
    /// and a `.partial` written over it would bring back the resume the staging commit cleared. Not while it is held
    /// for its partner either: its download has ended, so the bytes are final, and the pair's commit may begin from
    /// the partner's lane at any moment. A write already in flight when it was held is counted in
    /// `checkpointWrites`, which the pair's commit waits for.
    var takesCheckpoints: Bool {
        switch phase {
        case .queued, .downloading, .waitingToRetry: true
        case .held, .committing, .done: false
        }
    }

    /// The downloaded file of a half waiting for its partner.
    var held: HeldHalf? {
        if case let .held(h) = phase { h } else { nil }
    }

    /// Downloading, waiting to retry or committing (owned by a running file task or commit), or held for its
    /// partner: the job isn't done while one is.
    var isActive: Bool {
        switch phase {
        case .downloading, .waitingToRetry, .held, .committing: true
        case .queued, .done: false
        }
    }

    /// Still to be downloaded: queued, downloading or waiting to retry.
    var isToDownload: Bool {
        switch phase {
        case .queued, .downloading, .waitingToRetry: true
        case .held, .committing, .done: false
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
    /// The generation of the link's session the job is using (`CameraLink.sessionGeneration`, read after each
    /// `open()`); 0 until read, and for a link without generations.
    var sessionInUse = 0
    /// Sessions of this link up to this generation were replaced by a `reconnect`: a `.sessionLost` stamped with one of
    /// them is late, and ignored (backlog section 2, I13).
    var replacedSessions = 0
    var hasListed = false
    var listRetries = 0
    /// When the camera (or its card) was lost, until the card is listed again: for `EngineTrace.reconnected`.
    var lostAt: Duration?
    /// When the job carried on after a loss, until the first progress report after it: for
    /// `EngineTrace.firstByteAfterReconnect`.
    var resumedAt: Duration?
    var route: ImportRoute
    /// What the job was started for (`ImportRoute.purpose` then), for its record: an import job staged instead part-way
    /// is still an import job.
    let startPurpose: DestinationKind
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
    /// Files left out for their Reject mark (D3), by content: not in the job, counted for the outcome
    /// (`ImportProgress.rejectsLeftOut`). A set, so a file left out twice (picked by *Select all new* again, or
    /// appended during the listing and left out by the diff too) counts once; a file added to the job later (an
    /// explicit pick) leaves it, since it wasn't left out after all.
    var rejectsLeftOut: Set<ObjectIdentity.ContentKey> = []
    /// Pending files, kept sorted by `FileEntry.index`.
    var queue: [ObjectIdentity] = []
    var nextIndex = 0
    var rate: RateEstimator
    var finished: JobOutcome?
    /// When the job started and ended, by the wall clock, for its record (`JobRecord`).
    let startedAt = Date()
    var finishedAt: Date?
    var driver: Task<Void, Never>?
    /// The driver has returned, and with it every lane and the commits they wait for; set once the job has ended.
    var driverReturned = false

    init(camera: CameraKey, timeZone: TimeZone, selection: ImportSelection, limit: Int, staging: URL,
         link: any CameraLink, route: ImportRoute, rateSamples: Int) {
        self.camera = camera
        self.timeZone = timeZone
        self.selection = selection
        self.settingsLimit = limit
        self.jobDirectory = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        self.link = link
        self.route = route
        self.startPurpose = route.purpose
        self.rate = RateEstimator(capacity: rateSamples)
    }

    var sortedEntries: [FileEntry] { entries.values.sorted { $0.index < $1.index } }

    /// Downloads in flight: the setting, capped by what the current link can carry (wireless plan, decision 5; USB
    /// 2, Wi-Fi 1). Read again after a reconnect, so a new link brings its own cap.
    var limit: Int { min(settingsLimit, link.capabilities.maxDownloadsInFlight) }

    /// The job carries on through `link` (`reconnect`): the session it was using counts as replaced, so a late
    /// `.sessionLost` of it, or of an older one, is ignored. A new link has generations of its own.
    func replaceSession(with link: any CameraLink) {
        if ObjectIdentifier(link) == ObjectIdentifier(self.link) {
            replacedSessions = max(replacedSessions, sessionInUse)
        } else {
            replacedSessions = 0
        }
        sessionInUse = 0
        self.link = link
    }

    /// The link's session after an `open()` (`CameraLink.sessionGeneration`). A reconnect that found the old session
    /// still open (nothing was lost: an expiry, a card that came back) didn't replace it, so its losses count again.
    /// Until this is read, a real loss of a session the reconnect took over is ignored; its calls still fail as
    /// `disconnected`, which pauses the job as well.
    func useSession(_ generation: Int) {
        sessionInUse = generation
        if generation > 0 { replacedSessions = min(replacedSessions, generation - 1) }
    }

    /// Whether a `.sessionLost` stamped with `generation` ends a session the job no longer uses: one a reconnect
    /// replaced, or one older than the session read after the latest `open()`. Never an unstamped loss (0).
    func isReplaced(session generation: Int) -> Bool {
        generation > 0 && (generation <= replacedSessions || generation < sessionInUse)
    }

    /// The job's file with the same content as `identity` (whatever its folder or camera key), if any.
    func entry(sameContentAs identity: ObjectIdentity) -> FileEntry? {
        byContent[identity.contentKey].flatMap { entries[$0] }
    }

    /// Adds a file, replacing any with the same content (and taking it out of the queue; a partner it had becomes a
    /// lone file, unless paired again).
    func add(_ entry: FileEntry) {
        if let existing = byContent[entry.identity.contentKey] {
            queue.removeAll { $0 == existing }
            if let old = entries[existing], let partner = partner(of: old) { partner.partner = nil }
            entries[existing] = nil
        }
        entries[entry.identity] = entry
        byContent[entry.identity.contentKey] = entry.identity
        rejectsLeftOut.remove(entry.identity.contentKey)
    }

    var hasActiveFiles: Bool { entries.values.contains { $0.isActive } }

    /// The other half of `entry`'s pair, if it has one in this job.
    func partner(of entry: FileEntry) -> FileEntry? { entry.partner.flatMap { entries[$0] } }

    /// Makes `a` and `b` the two halves of one pair.
    func pair(_ a: FileEntry, _ b: FileEntry) {
        a.partner = b.identity
        b.partner = a.identity
    }

    /// Nothing is queued, downloading or waiting to retry: what is left only needs committing.
    var nothingLeftToDownload: Bool { queue.isEmpty && !entries.values.contains { $0.isToDownload } }

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
