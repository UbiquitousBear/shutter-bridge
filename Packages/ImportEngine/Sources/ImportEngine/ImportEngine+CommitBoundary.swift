import Catalogue
import Foundation
import PhotosBridge

// Resolving the commit boundary (backlog section 3.1, I15). Every commit is bracketed by a pending-commit marker
// (`ImportEngine+PendingCommit.swift`, I9); a marker left behind means the commit may have reached Photos or Staging
// with no row to say so: the app was killed between the save and the row, or `finishCommit` failed every try. Before
// anything reads the catalogue to decide what to copy, the engine resolves them:
//
// - this launch's own commits whose rows couldn't be written (`unrecordedCommits`) are written from memory, with no
//   lookup (all but their imported rows when the camera's imports were forgotten since, which took the marker);
// - every other marker, unless its commit is still in flight in this process, is looked up (`CommitLookup`): found
//   writes the rows and removes the marker in one save (`finishCommit`); not found removes the marker
//   (`abandonCommit`) and the files read as their rows say; can't look keeps it for the next pass.
//
// The writes never depend on a row still naming its partial file: `.imported` upserts and `markStaged` both clear a
// `.partial` row's offset and temporary file, so the order with I13's reset doesn't matter for them; the launch pass
// still resolves first and reconciles after (`launchPass()`), and so does every job before its diff.
extension ImportEngine {
    /// Resolves the markers left behind (above) and returns what it did. One pass at a time: a caller arriving during
    /// a pass awaits it, and runs one of its own after it only if a commit's rows went unrecorded since that pass
    /// began (so a job's diff never reads past rows it could have written). With no markers it is one empty fetch. A
    /// catalogue that can't list its markers ends the pass with nothing done; the diff that follows fails as before.
    @discardableResult
    public func resolvePendingCommits() async -> PendingCommitReport {
        while let pass = pendingCommitPass {
            let report = await pass.task.value
            // Whoever resumes first after the pass clears it, so a caller that loops doesn't join it again.
            if pendingCommitPass?.task == pass.task { pendingCommitPass = nil }
            if pass.epoch == unrecordedEpoch { return report }
        }
        let epoch = unrecordedEpoch
        let task = Task { await self.resolveMarkers() }
        pendingCommitPass = (task, epoch)
        let report = await task.value
        if pendingCommitPass?.task == task { pendingCommitPass = nil }
        return report
    }

    /// The launch pass (backlog section 3.1, "When resolution runs", and I13): pending commits resolved, then partial
    /// rows whose file is gone reset, in that order, once. The app calls it once the catalogue is open and the engine
    /// made (after the engine's work-folder prune); every job's pass before its diff waits for it first, so the first
    /// job can't race it. Called again, it returns the first call's report.
    @discardableResult
    public func launchPass() async -> PendingCommitReport {
        if let pass = launchPassTask { return await pass.value }
        let pass = Task {
            let report = await self.resolvePendingCommits()
            await self.reconcilePartials()
            return report
        }
        launchPassTask = pass
        return await pass.value
    }

    /// Before a diff (a job's listing, `append`, `picksToDo`): waits for the launch pass, resolves pending commits,
    /// and hands any possible duplicates found so far to the job `id` (when it is current), for its outcome.
    func resolveCommitBoundary(for id: UUID?) async {
        if let launch = launchPassTask { _ = await launch.value }
        let report = await resolvePendingCommits()
        // A pass that wrote rows (a replay, or a waiting marker found once access returned) may have changed what Browse
        // shows as imported or staged, and a job that then imports nothing would never tell it: the app reads the badges
        // again. Callers that joined one pass each call this, which is harmless: reading the badges is idempotent.
        if report.changedRows { onRowsRecovered?() }
        if let id, let job = current(id), possibleDuplicatesUnreported > 0 {
            job.possibleDuplicates += possibleDuplicatesUnreported
            possibleDuplicatesUnreported = 0
            refreshState()
        }
    }

    /// Sets what runs right after a destination returns and before the commit's `finishCommit`, for the bench check
    /// that ends the app there (a Debug-only launch argument, docs/iteration-2-bench.md); nil removes it. It runs on
    /// the engine's actor, synchronously, so ending the process in it leaves the marker and no row.
    public func setBeforeFinishCommit(_ hook: (@Sendable () -> Void)?) {
        beforeFinishCommit = hook
    }

    /// Sets what runs after a pass before a job's diff wrote rows (`PendingCommitReport.changedRows`), for the app to
    /// read Browse's badges again; nil removes it. It runs on the engine's actor, synchronously, and must return at
    /// once and never call back into the engine (hand the work to a task). The launch pass's own report goes to its
    /// caller (`launchPass()`), not here.
    public func setOnRowsRecovered(_ hook: (@Sendable () -> Void)?) {
        onRowsRecovered = hook
    }

    /// One pass of `resolvePendingCommits()`.
    func resolveMarkers() async -> PendingCommitReport {
        var report = PendingCommitReport()
        guard let markers = try? await catalogue.pendingCommits() else { return report }
        let named = Dictionary(markers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // This launch's own: the rows are known, so they are written as they are, with no lookup.
        var replayed = Set<UUID>()
        for (token, kept) in unrecordedCommits.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let name = named[token]?.files.first?.identity.filename ?? Self.firstName(of: kept)
            var writes = kept
            // A marker gone from the store went with its camera's imports (`forgetImports(camera:)` removes them "so
            // a later pass can't mark the forgotten files imported again"): the rows are written only as far as the
            // forget would have left them had they landed first, so no imported row and every staged copy. Read
            // again before deciding, since the listing above may predate a commit that has failed since; a store that
            // can't answer counts as the marker still being there (writing is then right, as the photo was saved).
            if named[token] == nil,
               let now = try? await catalogue.pendingCommits(), !now.contains(where: { $0.id == token }) {
                writes = Self.afterForget(writes)
                guard !writes.isEmpty else {
                    unrecordedCommits[token] = nil
                    report.notFound += 1
                    trace(.pendingCommitResolved(name, .forgotten))
                    continue
                }
            }
            guard await writeRow({ try await self.catalogue.finishCommit(token, writing: writes) }) else {
                report.waiting += 1
                trace(.pendingCommitResolved(name, .waiting))
                continue
            }
            unrecordedCommits[token] = nil
            replayed.insert(token)
            report.replayed += 1
            if writes.contains(where: { if case .staged = $0 { true } else { false } }) {
                report.foundInStaging += 1
            } else {
                report.foundInPhotos += 1
            }
            trace(.pendingCommitResolved(name, .replayed))
        }

        // The rest: from an earlier launch, or a failed `abandonCommit`. A commit still in flight here isn't touched.
        // Every lookup first, then one read of the store for all of them (not one per marker).
        var answers: [(marker: PendingCommit, answer: CommitLookupAnswer)] = []
        for marker in markers where !replayed.contains(marker.id) && isLeftOver(marker.id) {
            answers.append((marker, await commitLookup.look(for: marker)))
        }
        guard !answers.isEmpty else { return report }
        // The lookups suspended: each marker must still be there and still a leftover (a commit of this launch that
        // ended meanwhile may have cleared it, or left its rows in memory for the next pass). A store that can't list
        // them again leaves every marker for the next pass, which counts as waiting.
        let still = (try? await catalogue.pendingCommits()).map { Set($0.map(\.id)) }
        for (marker, answer) in answers {
            let name = marker.files.first?.identity.filename ?? ""
            guard isLeftOver(marker.id) else { continue }
            guard let still else {
                report.waiting += 1
                trace(.pendingCommitResolved(name, .waiting))
                continue
            }
            guard still.contains(marker.id) else { continue }
            switch answer {
            case let .found(found):
                var writes = found
                var spared: [String] = []
                if case .staging = marker.destination {
                    (writes, spared) = await withoutSpareCopies(found)
                }
                guard await writeRow({ try await self.catalogue.finishCommit(marker.id, writing: writes) }) else {
                    report.waiting += 1
                    trace(.pendingCommitResolved(name, .waiting))
                    continue
                }
                // Each spare copy is said under its own file's name, also when the pair's other file was written.
                for file in spared { trace(.pendingCommitResolved(file, .spareStagedCopy)) }
                if case .photos = marker.destination {
                    report.foundInPhotos += 1
                    trace(.pendingCommitResolved(name, .foundInPhotos))
                } else if writes.isEmpty, !spared.isEmpty {
                    report.spareCopies += 1
                } else {
                    report.foundInStaging += 1
                    trace(.pendingCommitResolved(name, .foundInStaging))
                }
            case let .notFound(underLimitedAccess):
                guard (try? await catalogue.abandonCommit(marker.id)) != nil else {
                    report.waiting += 1
                    trace(.pendingCommitResolved(name, .waiting))
                    continue
                }
                report.notFound += 1
                if underLimitedAccess {
                    report.possibleDuplicates += 1
                    possibleDuplicatesUnreported += 1
                }
                let resolution: PendingCommitResolution = if underLimitedAccess {
                    .possibleDuplicate
                } else if case .staging = marker.destination {
                    .notStaged
                } else {
                    .notFound
                }
                trace(.pendingCommitResolved(name, resolution))
            case .cannotLook:
                report.waiting += 1
                trace(.pendingCommitResolved(name, .waiting))
            }
        }
        return report
    }

    /// A found stage commit's writes without those for a file whose row already has a staged copy elsewhere, and the
    /// camera file names of those left out. A marker for iCloud Drive that couldn't be looked up waits, and a stage job meanwhile stages
    /// the same file On My iPhone; found once iCloud Drive is back, writing the marker's rows would repoint the row at
    /// the iCloud copy and leave the other copy with no row. The row that exists is kept (the person's copy that Staging
    /// shows and culls), the marker goes, and the spare copy stays where it is: nothing is deleted. A row that can't be
    /// read counts as having none, so the write is tried (and waits if the catalogue is down).
    func withoutSpareCopies(_ writes: [CommitWrite]) async -> (writes: [CommitWrite], spared: [String]) {
        var kept: [CommitWrite] = []
        var spared: [String] = []
        for write in writes {
            guard case let .staged(identity, _, location) = write,
                  // A row that names this very copy is no spare; one that names another copy is.
                  let existing = try? await catalogue.record(for: identity)?.staged,
                  existing.root != location.root || existing.relativePath != location.relativePath else {
                kept.append(write)
                continue
            }
            spared.append(identity.filename)
        }
        return (kept, spared)
    }

    /// Whether the marker `id` is no commit of this process still running and none whose rows are kept in memory.
    /// A token is registered in `commitsInFlight` before its commit's task can run and removed only after it has
    /// returned, so a marker that isn't there now can't be written again by this process.
    func isLeftOver(_ id: UUID) -> Bool {
        commitsInFlight[id] == nil && unrecordedCommits[id] == nil
    }

    /// What *Forget imports* leaves of a commit's writes had they landed before it (`CatalogueStore.forgetImports`):
    /// an imported row is forgotten, a staged copy is kept.
    static func afterForget(_ writes: [CommitWrite]) -> [CommitWrite] {
        writes.filter { if case .staged = $0 { true } else { false } }
    }

    /// The camera file name of a commit's first write, for the trace.
    static func firstName(of writes: [CommitWrite]) -> String {
        switch writes.first {
        case let .imported(record)?: record.identity.filename
        case let .staged(identity, _, _)?: identity.filename
        case nil: ""
        }
    }
}
