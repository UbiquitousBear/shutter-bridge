import Catalogue
import Dispatch
import Foundation
import PhotosBridge
import PTPKit
import Synchronization

/// A catalogue whose calls can be held before they run, to put a checkpoint write (`markPartial`) in flight across a
/// file's commit. Every `CatalogueStore` call is synchronous on the store's actor, so a write can't be paused half-way;
/// what can be late is the call reaching the actor. This one runs on an executor (`HoldingExecutor`) that, while it
/// holds, keeps every call that reaches it until the test runs them. Its rows follow the catalogue's rules for the
/// calls the engine makes here (`PartialMark`, `StagedMark`), by identity rather than by content.
actor HoldingCatalogue: CatalogueStore {
    nonisolated let executor = HoldingExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    private var records: [ObjectIdentity: CatalogueRecord] = [:]

    func record(for identity: ObjectIdentity) -> CatalogueRecord? { records[identity] }

    func states(of identities: [ObjectIdentity]) -> [ObjectIdentity: ObjectState] {
        var out: [ObjectIdentity: ObjectState] = [:]
        for id in identities { out[id] = records[id]?.state ?? .new }
        return out
    }

    /// Keeps the stored row's staged copy, as `StagedMark.upserting` does.
    func upsert(_ record: CatalogueRecord) {
        executor.countRow()
        var kept = record
        if let existing = records[record.identity] { kept.staged = existing.staged }
        records[record.identity] = kept
    }

    func saveListing(_ listing: CardListing) {}
    func lastListing(for camera: CameraKey) -> CardListing? { nil }

    /// An imported row stays as it is; any other becomes `.partial`, keeping its location and staged copy
    /// (`PartialMark.record`).
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) {
        executor.countMarkPartial()
        let existing = records[identity]
        if existing?.state == .imported { return }
        records[identity] = CatalogueRecord(identity: identity, format: format, state: .partial,
                                            location: existing?.location, resumeOffset: offset, tempURL: tempURL,
                                            staged: existing?.staged)
    }

    /// A `.partial` row goes back to `.new` with its resume cleared; an imported row stays imported
    /// (`StagedMark.record`).
    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) {
        executor.countRow()
        guard var record = records[identity] else {
            records[identity] = CatalogueRecord(identity: identity, format: format, state: .new, staged: location)
            return
        }
        if record.state == .partial {
            record.state = .new
            record.resumeOffset = 0
            record.tempURL = nil
        }
        record.format = format
        record.staged = location
        records[identity] = record
    }

    func clearStaged(_ identity: ObjectIdentity) { records[identity]?.staged = nil }
    func stagedStates(of identities: [ObjectIdentity]) -> Set<ObjectIdentity> {
        Set(identities.filter { records[$0]?.staged != nil })
    }

    func camera(_ key: CameraKey) -> CameraRecord? { nil }
    func cameras() -> [CameraRecord] { [] }
    func upsertCamera(_ record: CameraRecord) {}
}

/// A serial executor on a dispatch queue that can hold the jobs enqueued on it: `hold()` keeps every job that arrives
/// until `runHeld()`, `stopHolding()` lets new ones run again (the held ones stay held). A test waits on what it has
/// seen (`waitUntil(_:)`) rather than sleeping.
final class HoldingExecutor: SerialExecutor, Sendable {
    /// What the executor and its catalogue have seen.
    struct Seen: Sendable {
        /// Jobs kept by `hold()` and not yet run.
        var held = 0
        /// `markPartial` calls that have run.
        var markPartials = 0
        /// Rows a commit writes (`markStaged`, `upsert`) that have run.
        var rows = 0
        /// Whatever the test noted (`note(_:)`).
        var notes: Set<String> = []
    }

    private struct Waiter {
        let until: @Sendable (Seen) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var holding = false
        var jobs: [UnownedJob] = []
        var seen = Seen()
        var waiters: [Waiter] = []
    }

    private let queue = DispatchQueue(label: "HoldingExecutor")
    private let state = Mutex(State())

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let held = change { s -> Bool in
            guard s.holding else { return false }
            s.jobs.append(job)
            s.seen.held = s.jobs.count
            return true
        }
        if !held { run(job) }
    }

    private func run(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func hold() { change { $0.holding = true } }
    func stopHolding() { change { $0.holding = false } }

    /// Runs the held jobs, in the order they arrived, before anything enqueued after this call.
    func runHeld() {
        let jobs = change { s -> [UnownedJob] in
            defer {
                s.jobs = []
                s.seen.held = 0
            }
            return s.jobs
        }
        for job in jobs { run(job) }
    }

    func note(_ note: String) { change { _ = $0.seen.notes.insert(note) } }

    func countMarkPartial() { change { $0.seen.markPartials += 1 } }
    func countRow() { change { $0.seen.rows += 1 } }

    var seen: Seen { state.withLock { $0.seen } }

    /// Returns once `until` holds for what has been seen.
    func waitUntil(_ until: @escaping @Sendable (Seen) -> Bool) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if until(s.seen) { return true }
                s.waiters.append(Waiter(until: until, continuation: c))
                return false
            }
            if now { c.resume() }
        }
    }

    /// Applies `body` and wakes every waiter whose condition now holds.
    @discardableResult
    private func change<T>(_ body: (inout State) -> T) -> T {
        let (result, ready) = state.withLock { s -> (T, [CheckedContinuation<Void, Never>]) in
            let result = body(&s)
            var ready: [CheckedContinuation<Void, Never>] = []
            var kept: [Waiter] = []
            for w in s.waiters {
                if w.until(s.seen) { ready.append(w.continuation) } else { kept.append(w) }
            }
            s.waiters = kept
            return (result, ready)
        }
        for c in ready { c.resume() }
        return result
    }
}

/// A destination whose first commit waits until the test releases it, then hands the unit to `inner`.
actor GatedDestination: ImportDestination {
    nonisolated let kind: DestinationKind
    private let inner: any ImportDestination
    private var holdFirst = true
    private var held: CheckedContinuation<Void, Never>?
    private var arrivedWaiter: CheckedContinuation<Void, Never>?

    init(_ inner: any ImportDestination) {
        self.inner = inner
        kind = inner.kind
    }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        if holdFirst {
            holdFirst = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                held = c
                arrivedWaiter?.resume()
                arrivedWaiter = nil
            }
        }
        return try await inner.commit(unit)
    }

    nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget { inner.commitTarget(for: unit) }

    /// Returns once the first commit is being held.
    func waitArrived() async {
        if held != nil { return }
        await withCheckedContinuation { arrivedWaiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
