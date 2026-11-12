import Catalogue
import Foundation
import Observation
import PhotosBridge

// Whether staged files in iCloud Drive have uploaded (staging PR 7, bench S10): the quota error said in Settings'
// Staging section and on the Import screen. The selection, the tally, the coalescing and the wording are Linux-tested
// through `StagedUploadReading`; the reader over the files' metadata (`UbiquitousUploadReader`) is iOS only.

/// What one read of the staged files' upload states found.
public struct StagedUploadSummary: Sendable, Hashable {
    /// Files whose state was read.
    public var read = 0
    public var uploaded = 0
    /// Uploading, waiting, or waiting for iCloud's servers (4355).
    public var waiting = 0
    /// Not uploaded because the iCloud quota is full (4354).
    public var quotaFull = 0
    /// Not uploaded for any other error.
    public var otherProblems = 0
    /// The first of those, for the log.
    public var firstOther: UploadProblem?
    /// Staged in iCloud Drive but not read (past the limit).
    public var notRead = 0

    public init(read: Int = 0, uploaded: Int = 0, waiting: Int = 0, quotaFull: Int = 0, otherProblems: Int = 0,
                firstOther: UploadProblem? = nil, notRead: Int = 0) {
        self.read = read
        self.uploaded = uploaded
        self.waiting = waiting
        self.quotaFull = quotaFull
        self.otherProblems = otherProblems
        self.firstOther = firstOther
        self.notRead = notRead
    }

    /// The counts of `states`: uploading, waiting and server-unavailable count as waiting; not in iCloud and unreadable
    /// count only as read.
    static func tally(_ states: [StagedUploadState], notRead: Int) -> StagedUploadSummary {
        var summary = StagedUploadSummary(read: states.count, notRead: notRead)
        for state in states {
            switch state {
            case .uploaded: summary.uploaded += 1
            case .uploading, .waiting, .failed(.serverUnavailable): summary.waiting += 1
            case .failed(.quotaFull): summary.quotaFull += 1
            case let .failed(problem):
                summary.otherProblems += 1
                if summary.firstOther == nil { summary.firstOther = problem }
            case .notInICloud, .unreadable: break
            }
        }
        return summary
    }
}

/// Reads whether the staged files in iCloud Drive have uploaded, and says so when they haven't (`problemLine`,
/// `waitingLine`). The app reads it after the reconcile step when it comes to the front, when Settings appears and when
/// a job starts and ends; a quota error that appears while the app sits in front shows at the next of those.
///
/// - iCloud Drive not available, or nothing staged there: no summary, and the reader isn't called.
/// - At most the newest `limit` files (by when they were staged) are read; the rest are counted as not read.
/// - Each read runs off the main actor. Reads asked for while one runs share it and one more read after it, so they
///   never pile up, and a caller's `refresh()` returns once a read that started after its call has finished.
@MainActor
@Observable
public final class StagedUploadMonitor {
    /// The last read's counts; nil before the first, and while nothing is staged in iCloud Drive or it isn't available.
    public private(set) var summary: StagedUploadSummary?
    public static let defaultLimit = 1000

    @ObservationIgnored private let catalogue: any CatalogueStore
    @ObservationIgnored private let locator: any StagingLocator
    @ObservationIgnored private let reader: any StagedUploadReading
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private let log: any BenchLog
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var soon: Task<Void, Never>?
    /// How many times `refresh()` was called (for tests).
    @ObservationIgnored private(set) var refreshCalls = 0

    public init(catalogue: any CatalogueStore, locator: any StagingLocator, reader: any StagedUploadReading,
                limit: Int = defaultLimit, log: any BenchLog = SilentBenchLog()) {
        self.catalogue = catalogue
        self.locator = locator
        self.reader = reader
        self.limit = limit
        self.log = log
    }

    /// Reads the upload states again, sharing a read already running and one more after it.
    public func refresh() async {
        refreshCalls += 1
        again = true
        let task: Task<Void, Never>
        if let running {
            task = running
        } else {
            task = Task { [weak self] in await self?.readWhileAsked() }
            running = task
        }
        await task.value
    }

    /// `refresh()` without waiting for it: a job's start and end.
    public func refreshSoon() {
        let previous = soon
        soon = Task { [weak self] in
            await previous?.value
            await self?.refresh()
        }
    }

    /// Waits until every read asked for so far has finished (for tests).
    func settled() async {
        await soon?.value
        while let running { await running.value }
    }

    private func readWhileAsked() async {
        while again {
            again = false
            await readOnce()
        }
        running = nil
    }

    private func readOnce() async {
        guard let iCloud = await locator.locate().iCloudDocuments else {
            if summary != nil { summary = nil }
            return
        }
        let records: [CatalogueRecord]
        do {
            records = try await catalogue.stagedRecords(camera: nil)
        } catch {
            log.note("staging: upload status not read: catalogue error (\(type(of: error)))", level: .error)
            return
        }
        let (urls, notRead) = Self.filesToRead(records, in: iCloud, limit: limit)
        guard !urls.isEmpty else {
            if summary != nil { summary = nil }
            return
        }
        let started = ContinuousClock.now
        let reader = self.reader
        let states = await StagedRemoval.offThePool { urls.map { reader.uploadState(of: $0) } }
        let read = StagedUploadSummary.tally(states, notRead: notRead)
        log.note(Self.line(read, seconds: StagedCopyReconciler.seconds(since: started)))
        if read != summary { summary = read }
    }

    /// The files to read: staged in iCloud Drive with a path that resolves, the most recently staged first (no time
    /// last), at most `limit` of them; and how many were left out.
    static func filesToRead(_ records: [CatalogueRecord], in iCloud: URL, limit: Int) -> (urls: [URL], notRead: Int) {
        let candidates = records.compactMap { record -> (url: URL, at: Date?)? in
            guard let staged = record.staged, staged.root == .iCloudDrive,
                  let url = staged.fileURL(in: iCloud) else { return nil }
            return (url, staged.stagedAt)
        }
        let newestFirst = candidates.enumerated().sorted { a, b in
            switch (a.element.at, b.element.at) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element.url)
        let kept = Array(newestFirst.prefix(max(0, limit)))
        return (kept, newestFirst.count - kept.count)
    }

    /// The bench line: counts only, and the domain and code of the first other problem.
    static func line(_ summary: StagedUploadSummary, seconds: Double) -> String {
        let other: String
        if case let .other(domain, code)? = summary.firstOther { other = "\(domain) \(code)" } else { other = "none" }
        return "staging: upload status of \(summary.read) staged file(s) in iCloud Drive in "
            + "\(String(format: "%.2f", seconds)) s: \(summary.uploaded) uploaded, \(summary.waiting) waiting, "
            + "\(summary.quotaFull) over the iCloud quota, \(summary.otherProblems) other problems (\(other)), "
            + "\(summary.notRead) not read"
    }

    /// What Settings and the Import screen say when staged files haven't uploaded: the full quota first, else any other
    /// problem; nil when there is none.
    public var problemLine: String? {
        guard let summary else { return nil }
        if summary.quotaFull > 0 { return StagingWording.uploadQuotaFull(summary.quotaFull) }
        if summary.otherProblems > 0 { return StagingWording.uploadFailed(summary.otherProblems) }
        return nil
    }

    /// How many are still waiting to upload, when there is no problem to say.
    public var waitingLine: String? {
        guard problemLine == nil, let summary, summary.waiting > 0 else { return nil }
        return StagingWording.uploadWaiting(summary.waiting)
    }
}
