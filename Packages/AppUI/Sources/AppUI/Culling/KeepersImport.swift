import CameraTransport
import Catalogue
import Foundation
import Observation
import PhotosBridge

/// Which staged photos *Import keepers* takes: a day, a camera (its section on the Staging screen) or all of Staging.
public enum KeepersScope: Sendable, Hashable {
    case all
    /// A camera's section, by its name (its folder under Staging, D11).
    case camera(String)
    case day(CullDayRow.ID)

    /// The rows of `rows` in this scope.
    public func rows(in rows: [CullDayRow]) -> [CullDayRow] {
        switch self {
        case .all: rows
        case let .camera(name): rows.filter { $0.cameraName == name }
        case let .day(id): rows.filter { $0.id == id }
        }
    }
}

/// What *Import keepers* did, for the Staging screen's strip.
public struct KeepersSummary: Sendable, Hashable {
    public enum Problem: Sendable, Hashable {
        /// The marks couldn't be read: nothing was imported or removed.
        case couldNotRead
        /// No keepers to import and nothing to remove.
        case nothingToDo
    }

    public var problem: Problem?
    /// The jobs' outcome, added up; nil when no job was asked for (no keepers in scope).
    public var run: KeepersRun?
    /// Evicted iCloud keepers downloaded before the job started.
    public var downloadedFirst = 0
    /// The removal offered, if one was.
    public var plan: StagingRemovalPlan?
    /// What the removal did; nil when nothing was removed (the person kept the copies, or no removal was offered).
    public var removal: StagingRemovalResult?

    public init(problem: Problem? = nil, run: KeepersRun? = nil, downloadedFirst: Int = 0,
                plan: StagingRemovalPlan? = nil, removal: StagingRemovalResult? = nil) {
        self.problem = problem
        self.run = run
        self.downloadedFirst = downloadedFirst
        self.plan = plan
        self.removal = removal
    }
}

/// *Import keepers* from the Staging screen, then the removal of the staged copies (backlog sections 7.5 and 7.6; D2,
/// Shamil, 11 Nov), as one flow:
///
/// 1. The marks of the photos in scope are read again from the catalogue (the truth, whatever the screen last showed).
/// 2. The kept units are grouped by **staged camera key**: the engine writes every row of a job under one key, and the
///    album is keyed by it, so each key is one job, named for its camera's folder under Staging (D11), with one
///    `StagingFolderLink` over that key's kept files only.
/// 3. **Evicted keepers are downloaded first**, before any job starts, and the strip says so: an iCloud download inside
///    the job could pass the engine's 30 s stall limit if `NSMetadataQuery` reports no progress (`unverified`, bench).
/// 4. The jobs run one after another through the Import screen's model (`ImportModel.importKeepers(_:reader:)`).
/// 5. Only if every job ran to its end, the removal is planned from the catalogue as it is now (`StagingRemovalRule`)
///    and offered in **one confirmation** (D2). Photos access off, a cancelled or stopped job: nothing is removed.
/// 6. Confirmed, the plan is made again from the catalogue as it is then, and `StagingRemover` removes only the recorded
///    copies both plans name: a mark changed while the confirmation waited (the loupe stays usable over the screen) is
///    never removed on its old mark. Kept, nothing is removed.
///
/// Nothing in this flow can reach a camera: the only link is Staging's, which has no delete call and reports
/// `deletes: false`. Pure logic on the main actor, tested on Linux against `InMemoryCatalogue` and a temporary Staging
/// folder; the cull screen only shows `phase`.
@MainActor
@Observable
public final class KeepersImport {
    public enum Phase: Sendable, Hashable {
        case idle
        case preparing
        /// Evicted iCloud keepers downloading before the job.
        case downloading(done: Int, total: Int)
        case importing
        /// The one confirmation (D2).
        case confirming(StagingRemovalPlan)
        case removing
        case finished(KeepersSummary)
    }

    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let catalogue: any CatalogueStore
    @ObservationIgnored private let importer: ImportModel
    @ObservationIgnored private let onThisIPhone: URL
    @ObservationIgnored private let locator: any StagingLocator
    @ObservationIgnored private let reader: any StagedFileReading
    @ObservationIgnored private let files: any StagedFileAvailability
    @ObservationIgnored private let plain: any StagedFileRemoving
    @ObservationIgnored private let coordinated: any StagedFileRemoving
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let log: any BenchLog
    /// The summary so far, while a removal is offered.
    @ObservationIgnored private var pending = KeepersSummary()
    /// The days the removal was planned over, so the accepted plan is checked against the catalogue again at removal.
    @ObservationIgnored private var plannedDays: [CullDayRow] = []
    /// The accepted removal is under way.
    @ObservationIgnored private var removalStarted = false

    /// - Parameters:
    ///   - onThisIPhone: The app's Documents folder, the root of On My iPhone › Shutter Bridge › Staging.
    ///   - locator: Finds the iCloud container's Documents folder, for removing copies in iCloud Drive.
    ///   - reader: How the jobs' link reads the staged copies (`StagedFileReaders.platform` in the app).
    ///   - files: Whether a staged file is on the phone, and downloads an evicted one (`UbiquitousFileAvailability`).
    ///   - plain: Removes copies on this iPhone.
    ///   - coordinated: Removes copies in iCloud Drive (`StagedFileRemovers.iCloudDrive`).
    ///   - timeZone: The engine's zone, which the files' capture times are given in (the app's engine reads the
    ///     current zone).
    public init(catalogue: any CatalogueStore, importer: ImportModel, onThisIPhone: URL, locator: any StagingLocator,
                reader: any StagedFileReading = StagedFileReaders.platform,
                files: any StagedFileAvailability = AlwaysLocalFiles(),
                plain: any StagedFileRemoving = PlainStagedFileRemover(),
                coordinated: any StagedFileRemoving = StagedFileRemovers.iCloudDrive,
                timeZone: TimeZone = .current, log: any BenchLog = SilentBenchLog()) {
        self.catalogue = catalogue
        self.importer = importer
        self.onThisIPhone = onThisIPhone
        self.locator = locator
        self.reader = reader
        self.files = files
        self.plain = plain
        self.coordinated = coordinated
        self.timeZone = timeZone
        self.log = log
    }

    /// Something is under way (the Staging screen's buttons wait).
    public var isBusy: Bool {
        switch phase {
        case .idle, .finished: false
        case .preparing, .downloading, .importing, .confirming, .removing: true
        }
    }

    /// The removal offered, while the confirmation is up.
    public var confirmation: StagingRemovalPlan? {
        if case let .confirming(plan) = phase { plan } else { nil }
    }

    /// The finished summary, until dismissed.
    public var summary: KeepersSummary? {
        if case let .finished(summary) = phase { summary } else { nil }
    }

    /// The Staging screen's strip for the flow: what it is doing, or what it did (kept until closed); nil while idle and
    /// while the confirmation is up. While the jobs run it says which, as the Import screen does.
    public var notice: StatusNotice? {
        switch phase {
        case .idle, .confirming:
            return nil
        case .preparing:
            return StatusNotice(text: KeepersWording.preparing, tone: .info, systemImage: "photo.on.rectangle",
                                dismissesItself: false)
        case let .downloading(done, total):
            return StatusNotice(text: KeepersWording.downloading(done: done, of: total), tone: .info,
                                systemImage: "icloud.and.arrow.down", dismissesItself: false)
        case .importing:
            let parts = [importer.keepersLine, importer.statusLine].compactMap(\.self)
            return StatusNotice(text: parts.isEmpty ? KeepersWording.importing : parts.joined(separator: ": "),
                                tone: .info, systemImage: "photo.on.rectangle", dismissesItself: false)
        case .removing:
            return StatusNotice(text: KeepersWording.removing, tone: .info, systemImage: "trash",
                                dismissesItself: false)
        case let .finished(summary):
            let problem = summary.problem == .couldNotRead || summary.run.map { !$0.completed } == true
                || (summary.removal?.failed ?? 0) > 0
            return StatusNotice(id: 1, text: KeepersWording.finished(summary), tone: problem ? .problem : .success,
                                systemImage: "checkmark.circle", dismissesItself: false)
        }
    }

    /// Imports the keepers of `scope` in `rows` (the Staging screen's day rows), then offers the removal. Returns once
    /// the confirmation is up or the flow has finished.
    public func start(_ scope: KeepersScope, in rows: [CullDayRow]) async {
        guard !isBusy else { return }
        let days = scope.rows(in: rows)
        pending = KeepersSummary()
        phase = .preparing
        guard let marks = await readMarks(of: days) else {
            finish(problem: .couldNotRead)
            return
        }
        let jobs = Self.jobs(days: days, marks: marks, timeZone: timeZone)
        if !jobs.isEmpty {
            await downloadEvicted(jobs)
            phase = .importing
            let run = await importer.importKeepers(jobs.map(\.job), reader: reader)
            pending.run = run
            // Photos access off, a job cancelled or stopped: nothing is removed from Staging (section 7.5).
            guard run.completed else {
                finish()
                return
            }
        }
        guard let plan = await plan(days) else {
            finish(problem: pending.run == nil ? .couldNotRead : nil)
            return
        }
        guard !plan.isEmpty else {
            finish(problem: pending.run == nil ? .nothingToDo : nil)
            return
        }
        // Counts only.
        log.note("keepers: removal offered for \(plan.copies.count) file(s): keepers \(plan.keepersInPhotos), "
            + "rejects \(plan.rejects), held keepers \(plan.keepersHeld), held rejects \(plan.rejectsHeld), "
            + "unmarked \(plan.unmarked)")
        pending.plan = plan
        plannedDays = days
        phase = .confirming(plan)
    }

    /// The confirmation's default action (D2): removes what the plan names, through each copy's recorded path only.
    public func confirmRemoval() async {
        guard acceptRemoval() else { return }
        await removeAccepted()
    }

    /// The confirmation's default action, taken at once (the screen calls it from the button, before the dialog
    /// closes): the flow moves on to removing, so closing the dialog no longer reads as keeping the copies. False when no
    /// removal is offered. `removeAccepted()` then removes.
    public func acceptRemoval() -> Bool {
        guard case .confirming = phase else { return false }
        phase = .removing
        return true
    }

    /// Removes what the accepted plan names (`acceptRemoval()`), once, and only what the rules still allow now: the
    /// plan was made when the jobs ended, and the person may have changed a mark before confirming (a reject made a
    /// keeper not in Photos, or a new keeper that holds its day's rejects back). A copy the plan made now doesn't name,
    /// or names at another path, stays; if the catalogue can't be read now, nothing is removed.
    public func removeAccepted() async {
        guard case .removing = phase, !removalStarted, let plan = pending.plan else { return }
        removalStarted = true
        defer { removalStarted = false }
        guard let now = await self.plan(plannedDays) else {
            var kept = StagingRemovalResult()
            kept.failed = plan.copies.count
            pending.removal = kept
            finish()
            return
        }
        let allowed = Set(now.copies)
        let copies = plan.copies.filter { allowed.contains($0) }
        if copies.count < plan.copies.count {
            // Counts only.
            log.note("keepers: \(plan.copies.count - copies.count) staged file(s) kept, their marks changed since the "
                + "confirmation was offered")
        }
        let iCloud = await locator.locate().iCloudDocuments
        let remover = StagingRemover(catalogue: catalogue, onThisIPhone: onThisIPhone, iCloud: iCloud, plain: plain,
                                     coordinated: coordinated, log: log)
        pending.removal = await remover.remove(copies)
        finish()
    }

    /// The confirmation's other action: nothing is removed.
    public func keepStaged() {
        guard case .confirming = phase else { return }
        log.note("keepers: the staged copies were kept")
        finish()
    }

    /// Clears the finished summary.
    public func dismiss() {
        if case .finished = phase { phase = .idle }
    }

    private func finish(problem: KeepersSummary.Problem? = nil) {
        pending.problem = problem
        phase = .finished(pending)
    }

    // MARK: Steps

    /// The catalogue's marks of every file in `days`, as the cull session reads them; nil when they can't be read.
    private func readMarks(of days: [CullDayRow]) async -> [ObjectIdentity.ContentKey: CullMark]? {
        let keys = days.flatMap(\.units).flatMap(\.keys)
        guard !keys.isEmpty else { return [:] }
        guard let stored = try? await catalogue.marks(of: keys) else {
            log.note("keepers: couldn't read the marks", level: .error)
            return nil
        }
        return stored.mapValues(CatalogueMarkWriter.mark)
    }

    /// Downloads every evicted keeper before the first job starts. One that fails is left to the job, whose reader
    /// downloads it too (or skips it, keeping it in Staging).
    private func downloadEvicted(_ jobs: [PlannedJob]) async {
        let evicted = jobs.flatMap(\.files).filter { !files.isLocal($0) }
        guard !evicted.isEmpty else { return }
        pending.downloadedFirst = evicted.count
        log.note("keepers: downloading \(evicted.count) evicted keeper file(s) before the import")
        for (done, file) in evicted.enumerated() {
            phase = .downloading(done: done, total: evicted.count)
            do {
                try await files.download(file, progress: { _ in })
            } catch {
                log.note("keepers: an evicted keeper didn't download first (\(type(of: error)))", level: .error)
            }
        }
        phase = .downloading(done: evicted.count, total: evicted.count)
    }

    /// The removal from the catalogue as it is now: the marks read again (a keeper given up meanwhile no longer holds
    /// its day back), the files' states by content, and the copies recorded now. Nil when the catalogue can't say.
    private func plan(_ days: [CullDayRow]) async -> StagingRemovalPlan? {
        guard let marks = await readMarks(of: days) else { return nil }
        let identities = days.flatMap(\.units).flatMap(\.files).map(\.identity)
        guard !identities.isEmpty else { return StagingRemovalPlan() }
        do {
            let states = try await catalogue.states(of: identities)
            let wanted = Set(identities)
            var staged: [ObjectIdentity: StagedLocation] = [:]
            for record in try await catalogue.stagedRecords(camera: nil) where wanted.contains(record.identity) {
                if let location = record.staged { staged[record.identity] = location }
            }
            return StagingRemovalRule.plan(days: days, marks: marks, states: states, staged: staged)
        } catch {
            log.note("keepers: couldn't read the catalogue for the removal (\(type(of: error)))", level: .error)
            return nil
        }
    }

    // MARK: Grouping

    /// One job, with the files it reads (for the evicted check).
    struct PlannedJob: Sendable {
        var job: KeepersJob
        var files: [CullFile]
    }

    /// The kept units of `days` grouped by staged camera key, in the order the keys first appear (camera by camera, newest
    /// day first, as the Staging screen lists them): one job per key, named for the camera's folder its first kept unit
    /// is listed under, with each kept file as a `StagedEntry` (its original identity, and its staged copy's URL).
    static func jobs(days: [CullDayRow], marks: [ObjectIdentity.ContentKey: CullMark],
                     timeZone: TimeZone) -> [PlannedJob] {
        var order: [CameraKey] = []
        var byKey: [CameraKey: PlannedJob] = [:]
        for day in days {
            for unit in day.units where CullMark.of(unit, in: marks).decision == .keep {
                let key = unit.camera
                if byKey[key] == nil {
                    order.append(key)
                    byKey[key] = PlannedJob(job: KeepersJob(camera: key, cameraName: day.cameraName, entries: []),
                                            files: [])
                }
                for file in unit.files {
                    byKey[key]?.files.append(file)
                    byKey[key]?.job.entries.append(entry(for: file, timeZone: timeZone))
                }
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// The file as Staging's link lists it: its folder, name and size from the card, and its capture time read in the
    /// engine's zone, so the engine's identity of it is the staged row's.
    static func entry(for file: CullFile, timeZone: TimeZone) -> StagedEntry {
        StagedEntry(folder: file.identity.folder, name: file.identity.filename,
                    captureDate: file.identity.captureDate.date(in: timeZone), size: file.identity.size, url: file.url)
    }
}
