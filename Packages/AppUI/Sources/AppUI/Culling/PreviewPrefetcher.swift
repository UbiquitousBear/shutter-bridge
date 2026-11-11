import Foundation
import Observation

/// Which units the loupe works on while the person looks at one (backlog section 7.3): the next 3 and the previous 1
/// are decoded; evicted files up to 10 ahead are downloaded. Pure.
public struct PrefetchPolicy: Sendable, Hashable {
    /// Units ahead of the current one that are decoded.
    public var decodeAhead = 3
    /// Units behind the current one that are decoded.
    public var decodeBehind = 1
    /// Units ahead whose evicted file is downloaded (this includes the decoded ones).
    public var downloadAhead = 10
    /// Decoded screen-size images held at most, the current one included.
    public var maxDecoded = 5
    /// Bytes of decoded images held at most (the current one is always kept). The app's whole budget is 150 MB; this
    /// is the share the previews may take, which five screen-size images (about 15 MB each) stay under.
    public var decodedByteBudget = 100_000_000
    public var maxConcurrentDecodes = 2
    /// A staged file is a local copy, so the link behind *Import keepers* also does 2 at a time.
    public var maxConcurrentDownloads = 2
    /// How long the person must stay on a unit before the units around it are fetched, so a fast swipe through a run
    /// of units loads only the one it stops on.
    public var settleDelay: Duration = .milliseconds(150)

    public init() {}

    /// The indices to decode, in the order to start them: the current one, then ahead, then behind. Clipped to the list.
    public func decodeIndices(focus: Int, count: Int) -> [Int] {
        guard (0 ..< count).contains(focus) else { return [] }
        let ahead = (0 ... max(decodeAhead, 0)).map { focus + $0 }
        let behind = (1 ... max(decodeBehind, 1)).prefix(max(decodeBehind, 0)).map { focus - $0 }
        return (ahead + behind).filter { (0 ..< count).contains($0) }
    }

    /// The indices whose evicted files are downloaded, in the order to start them: the decoded ones, then the rest of
    /// the way ahead.
    public func downloadIndices(focus: Int, count: Int) -> [Int] {
        guard (0 ..< count).contains(focus) else { return [] }
        let decoded = decodeIndices(focus: focus, count: count)
        let further = (focus + 1 ... max(focus + downloadAhead, focus + 1)).filter {
            (0 ..< count).contains($0) && !decoded.contains($0)
        }
        return decoded + further
    }
}

/// How far an evicted file's download has got; nil while it can't say (the progress ring spins).
public struct DownloadProgress: Sendable, Hashable {
    public var fraction: Double?
    public init(fraction: Double? = nil) { self.fraction = fraction }
}

/// Whether a staged file is on the phone, and getting it there when iCloud has evicted it.
public protocol StagedFileAvailability: Sendable {
    /// True when the file can be read now.
    func isLocal(_ file: CullFile) -> Bool
    /// Returns when the file is local; throws if it can't be got. Honours cancellation. `progress` is told the
    /// fraction done, or nil while that isn't known.
    func download(_ file: CullFile, progress: @Sendable (Double?) -> Void) async throws
}

/// Every file is local: the staging folder on the iPhone, and every test that isn't about downloads.
public struct AlwaysLocalFiles: StagedFileAvailability {
    public init() {}
    public func isLocal(_ file: CullFile) -> Bool { true }
    public func download(_ file: CullFile, progress: @Sendable (Double?) -> Void) async throws {}
}

/// Decodes the units around the one on screen and downloads evicted files further ahead, and holds at most
/// `PrefetchPolicy.maxDecoded` images within the byte budget. The logic is pure and tested on Linux with a fake loader,
/// fake availability and a manual clock; the loupe reads `preview(for:)` and `downloadProgress(for:)`.
///
/// - Moving the focus drops what left the window at once (its tasks are cancelled and its image released).
/// - The current unit is fetched immediately; the units around it only once the focus has stayed for `settleDelay`.
/// - A unit is decoded only once its file is local, so an evicted one is downloaded first.
/// - If the held images go over the byte budget, the farthest from the current unit go first (behind counts double),
///   and aren't fetched again until the focus moves.
/// - A unit whose load failed isn't retried until `retry(_:)` or until it has left the window and come back.
@MainActor
@Observable
public final class PreviewPrefetcher<Image: Sendable> {
    public let policy: PrefetchPolicy
    public private(set) var units: [CullUnit] = []
    public private(set) var focus = 0
    public private(set) var previews: [CullUnit.ID: LoadedPreview<Image>] = [:]
    public private(set) var downloads: [CullUnit.ID: DownloadProgress] = [:]
    public private(set) var failed: Set<CullUnit.ID> = []
    /// The most decoded images, and the most bytes of them, held at once since this prefetcher was made: what the
    /// 360-file bench (I5) reads against the memory budget.
    public private(set) var peakHeldCount = 0
    public private(set) var peakHeldBytes = 0

    @ObservationIgnored private let loader: any PreviewLoading<Image>
    @ObservationIgnored private let files: any StagedFileAvailability
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let maxPixelSize: Int

    private struct Running {
        var token: UInt64
        var task: Task<Void, Never>
    }

    @ObservationIgnored private var decodeTasks: [CullUnit.ID: Running] = [:]
    @ObservationIgnored private var downloadTasks: [CullUnit.ID: Running] = [:]
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var aheadReleased = false
    @ObservationIgnored private var nextToken: UInt64 = 0
    @ObservationIgnored private var indexByID: [CullUnit.ID: Int] = [:]
    @ObservationIgnored private var localUnits: Set<CullUnit.ID> = []
    @ObservationIgnored private var evictedForBudget: Set<CullUnit.ID> = []

    /// - Parameter maxPixelSize: the longer side, in pixels, of the screen the previews are drawn on.
    public init(loader: any PreviewLoading<Image>, files: any StagedFileAvailability = AlwaysLocalFiles(),
                clock: any Clock<Duration> = ContinuousClock(), policy: PrefetchPolicy = PrefetchPolicy(),
                maxPixelSize: Int) {
        self.loader = loader
        self.files = files
        self.clock = clock
        self.policy = policy
        self.maxPixelSize = maxPixelSize
    }

    // MARK: What the loupe reads

    public func preview(for unit: CullUnit) -> LoadedPreview<Image>? { previews[unit.id] }
    public func downloadProgress(for unit: CullUnit) -> DownloadProgress? { downloads[unit.id] }
    public func hasFailed(_ unit: CullUnit) -> Bool { failed.contains(unit.id) }

    /// How many decoded images are held, and the bytes they take.
    public var heldCount: Int { previews.count }
    public var heldBytes: Int { previews.values.reduce(0) { $0 + $1.byteCost } }

    // MARK: Moving the focus

    /// Starts (or restarts) over `units` with the person on `index`.
    public func show(_ units: [CullUnit], focusing index: Int) {
        self.units = units
        indexByID = [:]
        for (i, unit) in units.enumerated() where indexByID[unit.id] == nil { indexByID[unit.id] = i }
        move(to: index, force: true)
    }

    /// The person is now on `index`.
    public func focus(on index: Int) {
        move(to: index, force: false)
    }

    /// Tries a failed unit again.
    public func retry(_ unit: CullUnit) {
        failed.remove(unit.id)
        pump()
    }

    /// Stops everything and releases every image (the loupe closed).
    public func stop() {
        settleTask?.cancel()
        settleTask = nil
        for running in decodeTasks.values { running.task.cancel() }
        for running in downloadTasks.values { running.task.cancel() }
        decodeTasks = [:]
        downloadTasks = [:]
        downloads = [:]
        previews = [:]
    }

    private func move(to index: Int, force: Bool) {
        let clamped = units.isEmpty ? 0 : min(max(index, 0), units.count - 1)
        let moved = clamped != focus
        focus = clamped
        if moved || force {
            aheadReleased = false
            evictedForBudget = []
            startSettling()
        }
        trimToWindow()
        pump()
    }

    private func startSettling() {
        settleTask?.cancel()
        let (clock, delay) = (clock, policy.settleDelay)
        settleTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            self?.releaseAhead()
        }
    }

    private func releaseAhead() {
        aheadReleased = true
        pump()
    }

    /// Drops everything outside the window.
    private func trimToWindow() {
        let decode = Set(policy.decodeIndices(focus: focus, count: units.count).map { units[$0].id })
        let download = Set(policy.downloadIndices(focus: focus, count: units.count).map { units[$0].id })
        for id in previews.keys where !decode.contains(id) { previews[id] = nil }
        for (id, running) in decodeTasks where !decode.contains(id) {
            running.task.cancel()
            decodeTasks[id] = nil
        }
        for (id, running) in downloadTasks where !download.contains(id) {
            running.task.cancel()
            downloadTasks[id] = nil
            downloads[id] = nil
        }
        failed = failed.filter { download.contains($0) }
        localUnits = localUnits.filter { download.contains($0) }
    }

    // MARK: Starting work

    private func isLocal(_ unit: CullUnit) -> Bool {
        if localUnits.contains(unit.id) { return true }
        guard let file = unit.previewSource.file, !files.isLocal(file) else {
            localUnits.insert(unit.id)
            return true
        }
        return false
    }

    private func pump() {
        guard units.indices.contains(focus) else { return }
        pumpDownloads()
        pumpDecodes()
    }

    private func pumpDownloads() {
        for i in policy.downloadIndices(focus: focus, count: units.count) {
            let unit = units[i]
            guard i == focus || aheadReleased else { continue }
            guard let file = unit.previewSource.file, previews[unit.id] == nil, downloadTasks[unit.id] == nil,
                  !failed.contains(unit.id), !isLocal(unit)
            else { continue }
            guard downloadTasks.count < policy.maxConcurrentDownloads || i == focus else { continue }
            nextToken += 1
            let (token, id, files) = (nextToken, unit.id, files)
            downloads[id] = DownloadProgress()
            downloadTasks[id] = Running(token: token, task: Task { [weak self] in
                guard let owner = self else { return }
                do {
                    try await files.download(file) { fraction in
                        Task { @MainActor in owner.downloadProgressed(id, token: token, fraction) }
                    }
                    owner.downloadFinished(id, token: token, error: nil)
                } catch {
                    owner.downloadFinished(id, token: token, error: error)
                }
            })
        }
    }

    private func downloadProgressed(_ id: CullUnit.ID, token: UInt64, _ fraction: Double?) {
        guard downloadTasks[id]?.token == token else { return }
        downloads[id] = DownloadProgress(fraction: fraction.map { min(max($0, 0), 1) })
    }

    private func downloadFinished(_ id: CullUnit.ID, token: UInt64, error: (any Error)?) {
        guard downloadTasks[id]?.token == token else { return }
        downloadTasks[id] = nil
        downloads[id] = nil
        if error == nil {
            localUnits.insert(id)
        } else if !(error is CancellationError) {
            failed.insert(id)
        }
        pump()
    }

    private func pumpDecodes() {
        for i in policy.decodeIndices(focus: focus, count: units.count) {
            let unit = units[i]
            let source = unit.previewSource
            guard i == focus || aheadReleased else { continue }
            guard source.file != nil, previews[unit.id] == nil, decodeTasks[unit.id] == nil,
                  !failed.contains(unit.id), !evictedForBudget.contains(unit.id), isLocal(unit)
            else { continue }
            if i != focus {
                // Room for it: not too many running, and not over what may be held.
                guard decodeTasks.count < policy.maxConcurrentDecodes,
                      previews.count + decodeTasks.count < policy.maxDecoded,
                      heldBytes < policy.decodedByteBudget
                else { continue }
            }
            nextToken += 1
            let (token, id, loader, size) = (nextToken, unit.id, loader, maxPixelSize)
            decodeTasks[id] = Running(token: token, task: Task { [weak self] in
                guard let owner = self else { return }
                do {
                    try await loader.load(source, maxPixelSize: size) { loaded in
                        await owner.accept(loaded, for: id, token: token)
                    }
                    owner.decodeFinished(id, token: token, error: nil)
                } catch {
                    owner.decodeFinished(id, token: token, error: error)
                }
            })
        }
    }

    private func accept(_ loaded: LoadedPreview<Image>, for id: CullUnit.ID, token: UInt64) {
        guard decodeTasks[id]?.token == token else { return }
        previews[id] = loaded
        enforceBudget()
        peakHeldCount = max(peakHeldCount, heldCount)
        peakHeldBytes = max(peakHeldBytes, heldBytes)
    }

    private func decodeFinished(_ id: CullUnit.ID, token: UInt64, error: (any Error)?) {
        guard decodeTasks[id]?.token == token else { return }
        decodeTasks[id] = nil
        // A render that failed after a stand-in was shown leaves the stand-in.
        if let error, !(error is CancellationError), previews[id] == nil { failed.insert(id) }
        pump()
    }

    // MARK: Memory

    /// Releases the farthest images until the count and bytes fit. The current unit is never released.
    private func enforceBudget() {
        let currentID = units.indices.contains(focus) ? units[focus].id : nil
        while previews.count > policy.maxDecoded || (heldBytes > policy.decodedByteBudget && previews.count > 1) {
            let victim = previews.keys.filter { $0 != currentID }.max { cost(of: $0) < cost(of: $1) }
            guard let victim else { return }
            previews[victim] = nil
            evictedForBudget.insert(victim)
            if let running = decodeTasks[victim] {
                running.task.cancel()
                decodeTasks[victim] = nil
            }
        }
    }

    /// How little a held image is worth: its distance from the current unit, doubled behind it. Higher goes first.
    private func cost(of id: CullUnit.ID) -> Int {
        guard let position = indexByID[id] else { return Int.max }
        let distance = position - focus
        return distance >= 0 ? distance * 2 : -distance * 2 + 1
    }
}

#if os(iOS)
/// A staged file in iCloud Drive: local or evicted by the file's downloading status, and downloaded by asking iCloud and
/// waiting for the status to change. iCloud gives no byte progress here, so the progress ring spins (`nil`). Compiled
/// only by CI's Xcode job; evicted files are checked on the bench (I5).
public struct UbiquitousFileAvailability: StagedFileAvailability {
    /// How long a download may take before it counts as failed.
    public var timeout: Duration = .seconds(300)

    public init() {}

    public func isLocal(_ file: CullFile) -> Bool {
        // A file that isn't an iCloud item has no status: it is on the phone.
        guard let status = try? file.url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        else { return true }
        return status == .current || status == .downloaded
    }

    public func download(_ file: CullFile, progress: @Sendable (Double?) -> Void) async throws {
        guard !isLocal(file) else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: file.url)
        let deadline = ContinuousClock.now + timeout
        while !isLocal(file) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw PreviewLoadingFailure("the download didn't finish") }
            progress(nil)
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}
#endif
