import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Observation
import PhotosBridge

/// One job as the History screen lists it: every line already worded, and what a tap does.
public struct HistoryRow: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var camera: CameraKey
    /// The camera's display name (D11), never its key.
    public var cameraName: String
    public var purpose: JobRecord.Purpose
    public var title: String
    public var time: String
    public var outcome: String
    public var counts: String
    public var bytes: String
    public var duration: String?
    public var place: String?
    /// *Resumable* or the failures left, when the row offers either.
    public var action: HistoryRules.Action?
    /// The action's line ("Resumable: 12 files left", "2 failed files not imported yet").
    public var actionLine: String?
    /// The job's files went to Staging: a tap shows its folder (D6; a document picker, CI only).
    public var opensStagingFolder: Bool
    /// The whole row as one line for VoiceOver (section 4: one line per job).
    public var accessibilityLabel: String
}

/// One day of History, newest first.
public struct HistorySection: Sendable, Hashable, Identifiable {
    /// The day, "YYYYMMDD".
    public var id: String
    public var title: String
    public var rows: [HistoryRow]
}

/// A camera as History's filter and *Forget imports* know it: its display name and every catalogue key with that name
/// (D11: one camera in MSC and in MTP has two keys and one name).
public struct HistoryCamera: Sendable, Hashable, Identifiable {
    public var name: String
    public var keys: [CameraKey]
    public var id: String { name }
}

/// The History screen's model (backlog section 4; D6, Shamil, 11 Nov), over Catalogue V4's job records (written by the
/// engine since I9): the jobs newest first, grouped by day, for every camera or one; a *Resumable* row for a job that
/// stopped early while its files are left; *Re-run* of a job's failed files still not done; *Forget imports* for a
/// camera with its confirmation; a stage job's Staging folder. Plain Swift, tested on Linux against `InMemoryCatalogue`,
/// a fake importer and fake links; the screen is CI only.
///
/// *Resume* and *Re-run* need the camera connected: the app's finder (`CameraFinding`) answers with a link only for a
/// USB camera on the port, or a Wi-Fi camera whose link Browse or the import already holds, so a tap never starts a
/// join by itself. The card is listed again and the job's stored selection rebuilt against it (`HistoryRules`), then
/// handed to the import as an explicit pick with the job's purpose; the engine's diff decides again, so nothing already
/// done is copied.
@MainActor
@Observable
public final class HistoryModel {
    public enum Phase: Sendable, Hashable {
        case loading
        case loaded
        case failed
    }

    public private(set) var phase: Phase = .loading
    /// The jobs of the camera filtered for (all of them when `cameraFilter` is nil), by day, newest first.
    public private(set) var sections: [HistorySection] = []
    /// The cameras with jobs, by name, for the filter.
    public private(set) var cameras: [HistoryCamera] = []
    /// Every camera the catalogue knows, by name, for *Forget imports*: those with jobs and those without (imports made
    /// before job records were written, Catalogue V4, have none, and must still be forgettable).
    public private(set) var forgettableCameras: [HistoryCamera] = []
    /// The camera name shown, or nil for every camera.
    public var cameraFilter: String? {
        didSet { if cameraFilter != oldValue { rebuild() } }
    }
    /// What came of the last tap or *Forget imports*, for a strip at the top.
    public private(set) var notice: StatusNotice?
    /// The job whose files are being queued (the card is being read), while one is.
    public private(set) var busyJob: UUID?

    @ObservationIgnored private let catalogue: any CatalogueStore
    @ObservationIgnored private let importer: (any BrowseImporting)?
    @ObservationIgnored private let finder: (any CameraFinding)?
    @ObservationIgnored private let leases: LinkLeases
    @ObservationIgnored private let onThisIPhone: URL
    @ObservationIgnored private let locator: any StagingLocator
    @ObservationIgnored private let activeCamera: @MainActor () -> CameraKey?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let log: any BenchLog
    @ObservationIgnored private var jobs: [JobRecord] = []
    @ObservationIgnored private var names: [CameraKey: String] = [:]
    @ObservationIgnored private var actions: [UUID: HistoryRules.Action] = [:]
    @ObservationIgnored private var runningJob: UUID?
    @ObservationIgnored private var noticeCount = 0
    @ObservationIgnored private var loads = 0

    /// - Parameters:
    ///   - importer: Takes the files *Resume* and *Re-run* queue (the app's `ImportModel`).
    ///   - finder: The connected camera's link by key (the app: USB cameras on the port and held Wi-Fi links only).
    ///   - leases: Shared with Browse and the import: the link is held while its card is read and handed over.
    ///   - onThisIPhone: The app's Documents folder, the root of On My iPhone › Shutter Bridge › Staging.
    ///   - locator: Where the iCloud Drive staging root is, for a stage job's folder.
    ///   - activeCamera: The key of the camera whose job is running or paused now, if any: its newest record with no
    ///     end is that job, not one that stopped early.
    ///   - calendar: Days and times are in its time zone.
    public init(catalogue: any CatalogueStore, importer: (any BrowseImporting)?, finder: (any CameraFinding)?,
                leases: LinkLeases, onThisIPhone: URL, locator: any StagingLocator,
                activeCamera: @escaping @MainActor () -> CameraKey? = { nil },
                now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .autoupdatingCurrent,
                locale: Locale = .autoupdatingCurrent, log: any BenchLog = SilentBenchLog()) {
        self.catalogue = catalogue
        self.importer = importer
        self.finder = finder
        self.leases = leases
        self.onThisIPhone = onThisIPhone
        self.locator = locator
        self.activeCamera = activeCamera
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.log = log
    }

    // MARK: - Reading

    /// Reads the job records and the cameras' names, and works out each row's action from the catalogue. If that fails,
    /// what was shown stays, and an empty screen says so with Try Again.
    public func load() async {
        loads += 1
        let load = loads
        if jobs.isEmpty { phase = .loading }
        let read: [JobRecord]
        let rows: [CameraRecord]
        do {
            read = try await catalogue.jobs(camera: nil)
            // Not optional: without the names every camera would read as "Camera", one entry whose *Forget imports*
            // would forget every camera's imports.
            rows = try await catalogue.cameras()
        } catch {
            guard load == loads else { return }
            phase = .failed
            return
        }
        let names = Dictionary(rows.map { ($0.key, HistoryWording.cameraName($0)) }, uniquingKeysWith: { a, _ in a })
        // The running job is the newest record with no end of the camera importing now.
        let active = activeCamera()
        let running = read.first { $0.finishedAt == nil && $0.outcome == nil && $0.camera == active }?.id
        var actions: [UUID: HistoryRules.Action] = [:]
        for job in read {
            if let action = await action(for: job, running: job.id == running) { actions[job.id] = action }
        }
        guard load == loads else { return }
        jobs = read
        self.names = names
        self.actions = actions
        runningJob = running
        cameras = grouped(read.map(\.camera))
        forgettableCameras = grouped(read.map(\.camera) + rows.map(\.key))
        if let filter = cameraFilter, !cameras.contains(where: { $0.name == filter }) { cameraFilter = nil }
        phase = .loaded
        rebuild()
    }

    /// `keys` by display name (D11), names in the person's order, each name's keys once.
    private func grouped(_ keys: [CameraKey]) -> [HistoryCamera] {
        let byName = Dictionary(grouping: keys, by: { name(of: $0) })
        return byName.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            HistoryCamera(name: name, keys: Array(Set(byName[name] ?? [])).sorted { $0.rawValue < $1.rawValue })
        }
    }

    /// Whether there is nothing to list for the filter.
    public var isEmpty: Bool { sections.isEmpty }

    private func name(of key: CameraKey) -> String { names[key] ?? CamerasWording.genericName }

    /// The row's action: *Resumable* while files are left, else the failed files still not done.
    private func action(for job: JobRecord, running: Bool) async -> HistoryRules.Action? {
        guard !running, let choice = HistoryRules.choice(for: job.purpose) else { return nil }
        let stopped = HistoryRules.stoppedEarly(job, running: running)
        guard stopped || !job.failedFiles.isEmpty else { return nil }
        let left = stopped ? await filesLeft(of: job, purpose: choice) : nil
        let failed = job.failedFiles.isEmpty ? 0 : await failedLeft(of: job, purpose: choice)
        return HistoryRules.action(for: job, running: running, filesLeft: left, failedLeft: failed)
    }

    /// The job's files the catalogue says aren't done: its picks by content key, or, for *all new* and a date range,
    /// the camera's last-known card (Browse's listing); nil when there is neither or the catalogue can't say.
    private func filesLeft(of job: JobRecord, purpose: DestinationKind) async -> Int? {
        let identities: [ObjectIdentity]
        let newOnly = HistoryRules.newOnly(job.selection)
        switch job.selection {
        case let .picked(keys), let .pickedNew(keys):
            identities = Array(Set(keys)).map { Self.identity(of: $0, camera: job.camera) }
        case .allNew, .dateRange:
            guard let listing = try? await catalogue.lastListing(for: job.camera) else { return nil }
            var range: ClosedRange<Date>?
            if case let .dateRange(r) = job.selection { range = r }
            var seen = Set<ObjectIdentity.ContentKey>()
            identities = listing.entries.compactMap { entry in
                guard entry.format.isStill, seen.insert(entry.identity.contentKey).inserted else { return nil }
                if let range, let date = entry.identity.captureDate.date(in: calendar.timeZone),
                   !range.contains(date) { return nil }
                return entry.identity
            }
        }
        guard !identities.isEmpty else { return 0 }
        guard let (states, staged) = await facts(of: identities, purpose: purpose) else { return nil }
        let wholeCard = !job.selection.isPick
        return identities.count(where: { identity in
            let state = states[identity] ?? .new
            let isStaged = staged.contains(identity)
            if wholeCard { return (state == .new || state == .partial) && !(purpose == .staging && isStaged) }
            return !HistoryRules.isDone(state: state, staged: isStaged, purpose: purpose, newOnly: newOnly)
        })
    }

    /// How many of the job's failed files the catalogue says aren't done yet; 0 when it can't say (nothing is offered
    /// that may be wrong).
    private func failedLeft(of job: JobRecord, purpose: DestinationKind) async -> Int {
        let keys = Array(Set(job.failedFiles))
        return await done(keys, camera: job.camera, purpose: purpose).map { keys.count - $0.count } ?? 0
    }

    /// Which of `keys` are done for `purpose` (an explicit pick: a stage job's file is done once staged), by content;
    /// nil when the catalogue can't say.
    private func done(_ keys: [ObjectIdentity.ContentKey], camera: CameraKey,
                      purpose: DestinationKind) async -> Set<ObjectIdentity.ContentKey>? {
        guard !keys.isEmpty else { return [] }
        let identities = keys.map { Self.identity(of: $0, camera: camera) }
        guard let (states, staged) = await facts(of: identities, purpose: purpose) else { return nil }
        return Set(identities.filter {
            HistoryRules.isDone(state: states[$0] ?? .new, staged: staged.contains($0), purpose: purpose, newOnly: false)
        }.map(\.contentKey))
    }

    /// The catalogue's states of `identities` and, for a stage job, which are staged, by content; nil when it can't
    /// say.
    private func facts(of identities: [ObjectIdentity], purpose: DestinationKind) async
        -> ([ObjectIdentity: ObjectState], Set<ObjectIdentity>)? {
        do {
            let states = try await catalogue.states(of: identities)
            let staged = purpose == .staging ? try await catalogue.stagedStates(of: identities) : []
            return (states, staged)
        } catch {
            return nil
        }
    }

    /// An identity for a content key, for the catalogue's by-content reads (camera and folder don't take part).
    private static func identity(of key: ObjectIdentity.ContentKey, camera: CameraKey) -> ObjectIdentity {
        ObjectIdentity(camera: camera, folder: "", filename: key.filename, captureDate: key.captureDate, size: key.size)
    }

    /// The sections for the filter, from what was last read.
    private func rebuild() {
        let shown = jobs.filter { cameraFilter == nil || name(of: $0.camera) == cameraFilter }
        let today = now()
        var order: [String] = []
        var byDay: [String: [HistoryRow]] = [:]
        for job in shown {
            let day = HistoryRules.day(of: job.startedAt, calendar: calendar)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(row(for: job))
        }
        sections = order.map { day in
            HistorySection(id: day, title: HistoryWording.dayTitle(day, now: today, calendar: calendar, locale: locale),
                           rows: byDay[day] ?? [])
        }
    }

    private func row(for job: JobRecord) -> HistoryRow {
        let camera = name(of: job.camera)
        let title = HistoryWording.title(job.purpose, camera: camera)
        let time = HistoryWording.time(job.startedAt, locale: locale, calendar: calendar)
        let outcome = HistoryWording.outcome(job.outcome, running: job.id == runningJob)
        let counts = HistoryWording.counts(job)
        let bytes = HistoryWording.bytes(job, locale: locale)
        let place = HistoryWording.place(job, camera: camera)
        let action = actions[job.id]
        let actionLine: String? = switch action {
        case let .resume(left): HistoryWording.resumable(filesLeft: left)
        case let .rerun(failed): HistoryWording.failedLeft(failed, purpose: job.purpose)
        case nil: nil
        }
        return HistoryRow(
            id: job.id, camera: job.camera, cameraName: camera, purpose: job.purpose, title: title, time: time,
            outcome: outcome, counts: counts, bytes: bytes, duration: HistoryWording.duration(job, locale: locale),
            place: place, action: action, actionLine: actionLine, opensStagingFolder: job.destination == .staging,
            accessibilityLabel: HistoryWording.rowAccessibility(
                title: title, time: time, outcome: outcome, counts: counts, bytes: bytes,
                durationSpoken: HistoryWording.durationSpoken(job, locale: locale), place: place, action: actionLine))
    }

    // MARK: - Resume and re-run

    /// *Resume* or *Re-run* for the row: with the camera connected, its card is listed again and the files the row's
    /// action queues are handed to the import with the job's purpose. Returns true when the import took them (the
    /// screen opens Import); otherwise `notice` says why: connect the camera, nothing left, the card couldn't be read,
    /// or the import's own answer (another job running, for example).
    @discardableResult
    public func act(on id: UUID) async -> Bool {
        guard busyJob == nil, let job = jobs.first(where: { $0.id == id }), let action = actions[id],
              let choice = HistoryRules.choice(for: job.purpose), let importer else { return false }
        let camera = name(of: job.camera)
        guard let link = await finder?.link(forCameraWith: job.camera) else {
            show(HistoryWording.connectCamera(camera, carrier: job.carrier), tone: .info)
            return false
        }
        busyJob = id
        defer { busyJob = nil }
        // Held while the card is read and the files handed over; the import holds it for its job from then.
        leases.acquire(link)
        let listed: [CameraItem]
        do throws(CameraLinkFailure) {
            try await link.open()
            listed = try await link.list()
        } catch {
            await leases.release(link)
            log.note("history: the card couldn't be read to queue a job again: \(error.kind)")
            show(HistoryWording.listingFailed(camera), tone: .problem)
            return false
        }
        let zone = TimeZone(identifier: calendar.timeZone.identifier) ?? calendar.timeZone
        let identities = listed.map { $0.identity(camera: job.camera, timeZone: zone) }
        let keyed = identities.compactMap(\.self)
        let states: [ObjectIdentity: ObjectState]
        let staged: Set<ObjectIdentity>
        do {
            states = keyed.isEmpty ? [:] : try await catalogue.states(of: keyed)
            staged = choice == .staging && !keyed.isEmpty ? try await catalogue.stagedStates(of: keyed) : []
        } catch {
            await leases.release(link)
            show(HistoryWording.catalogueFailed, tone: .problem)
            return false
        }
        let listing = zip(listed, identities).map { item, identity in
            HistoryRules.Listed(item: item, identity: identity, state: identity.flatMap { states[$0] } ?? .new,
                                staged: identity.map { staged.contains($0) } ?? false)
        }
        let queue: [CameraItem]
        var missing = 0
        let newOnly: Bool
        let kind: String
        switch action {
        case .resume:
            queue = HistoryRules.resumeQueue(job.selection, purpose: choice, listing: listing)
            newOnly = HistoryRules.newOnly(job.selection)
            kind = "resume"
        case .rerun:
            let failed = Array(Set(job.failedFiles))
            guard let done = await done(failed, camera: job.camera, purpose: choice) else {
                await leases.release(link)
                show(HistoryWording.catalogueFailed, tone: .problem)
                return false
            }
            let rerun = HistoryRules.rerunQueue(failed: job.failedFiles, done: done, listing: listing)
            queue = rerun.queue
            missing = rerun.missing.count
            newOnly = false
            kind = "re-run"
        }
        guard !queue.isEmpty else {
            await leases.release(link)
            log.note("history: nothing left to \(kind), \(missing) file(s) no longer on the card")
            show(missing > 0 ? HistoryWording.missing(missing) : HistoryWording.nothingLeft(purpose: job.purpose),
                 tone: .info)
            await load()
            return false
        }
        let outcome = await importer.importItems(queue, from: ImportCamera(descriptor: link.descriptor, key: job.camera),
                                                 link: link, as: choice, newOnly: newOnly)
        await leases.release(link)
        switch outcome {
        case .started, .appended:
            log.note("history: queued \(queue.count) file(s) to \(kind) a job, \(missing) no longer on the card")
            if missing > 0 { show(HistoryWording.missing(missing), tone: .info) } else { notice = nil }
            return true
        case .nothingNew:
            show(HistoryWording.nothingLeft(purpose: job.purpose), tone: .info)
            await load()
            return false
        case .busyWithAnotherCamera, .busyWithAnotherMode, .stillStarting, .failed:
            if let line = BrowseWording.importRequested(outcome, choice: choice) { show(line, tone: .problem) }
            return false
        }
    }

    // MARK: - Forget imports (D6)

    /// The confirmation for *Forget imports* of `camera`.
    public func forgetConfirmation(for camera: HistoryCamera) -> HistoryWording.ForgetConfirmation {
        HistoryWording.forgetConfirmation(camera: camera.name)
    }

    /// *Forget imports* for every key of `camera` (`CatalogueStore.forgetImports(camera:)`, D6): the camera's imported
    /// and skipped rows go, or go back to new where a staged copy is kept; Photos, Staging, marks, the card and the job
    /// records are left alone. Called once the person confirmed. Refused while that camera's import runs: forgetting
    /// removes the camera's pending-commit markers too, and a commit in flight must stay bracketed by its marker
    /// (section 3.1), or a kill before its row lands would import the file twice.
    public func forgetImports(of camera: HistoryCamera) async {
        if let active = activeCamera(), camera.keys.contains(active) {
            log.note("history: didn't forget a camera's imports while its import runs")
            show(HistoryWording.forgetWhileImporting(camera.name), tone: .info)
            return
        }
        var forgotten = 0
        do {
            for key in camera.keys { forgotten += try await catalogue.forgetImports(camera: key) }
        } catch {
            log.note("history: forgetting a camera's imports failed: \(type(of: error))", level: .error)
            show(HistoryWording.catalogueFailed, tone: .problem)
            await load()
            return
        }
        log.note("history: forgot \(forgotten) imported file(s) of one camera")
        show(HistoryWording.forgot(forgotten, camera: camera.name), tone: .success)
        await load()
    }

    // MARK: - A stage job's folder

    /// The folder to show for a job whose files went to Staging (D6: a document picker on it): the camera's folder
    /// under Staging where this job's copies are (the copies staged while it ran, by their recorded paths), else the
    /// camera's newest staged copy's, else the Staging folder itself in the root the job's files went to. Nil when
    /// iCloud Drive isn't available for an iCloud copy.
    public func stagingFolder(for id: UUID) async -> URL? {
        guard let job = jobs.first(where: { $0.id == id }), job.destination == .staging else { return nil }
        let iCloud = await locator.locate().iCloudDocuments
        let records = ((try? await catalogue.stagedRecords(camera: job.camera)) ?? []).compactMap { record in
            record.staged.flatMap { $0.isResolvable ? $0 : nil }
        }
        let end = job.finishedAt ?? .distantFuture
        let during = records.filter { ($0.stagedAt.map { $0 >= job.startedAt && $0 <= end }) ?? false }
        let newest = records.max { ($0.stagedAt ?? .distantPast) < ($1.stagedAt ?? .distantPast) }
        func documents(_ root: StagingRoot) -> URL? { root == .iCloudDrive ? iCloud : onThisIPhone }
        if let location = during.first ?? newest, let documents = documents(location.root),
           let file = location.fileURL(in: documents) {
            // Staging/<camera>/<day>/<file>: the camera's folder.
            return file.deletingLastPathComponent().deletingLastPathComponent()
        }
        return (iCloud ?? onThisIPhone).appendingPathComponent(StagedLocation.stagingFolderName, isDirectory: true)
    }

    // MARK: - Notices

    public func dismissNotice() { notice = nil }

    private func show(_ text: String, tone: StatusNotice.Tone) {
        noticeCount += 1
        notice = StatusNotice(id: noticeCount, text: text, tone: tone,
                              systemImage: tone == .success ? "checkmark.circle" : "info.circle",
                              dismissesItself: tone == .success)
    }
}

extension JobRecord.Selection {
    /// An explicit pick (Browse's selection or *Select all new*), rather than the whole card.
    var isPick: Bool {
        switch self {
        case .picked, .pickedNew: true
        case .allNew, .dateRange: false
        }
    }
}
