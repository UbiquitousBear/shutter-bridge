import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// Partial files between launches and session generations (backlog section 2, I13): partials under the work folder
/// (Caches in the app) with paths relative to it that still resolve once the container moves, the launch pass that
/// sends a row whose file is gone back to offset 0 (after the 7-day prune too), and a late loss of a replaced session
/// ignored. All on the manual clock, waiting on the trace.
@Suite("Partials in the work folder, their reconciliation, and session generations", .timeLimit(.minutes(1)))
struct PartialsAndSessionsTests {
    private static func isCheckpoint(_ name: String, _ offset: UInt64) -> @Sendable (EngineTrace) -> Bool {
        { $0 == .checkpointSaved(name, offset: offset) }
    }

    private func expectStaged(_ h: Harness, _ items: [CameraItem], sourceLocation: SourceLocation = #_sourceLocation) {
        for item in items {
            let data = try? Data(contentsOf: h.filesDirectory.appendingPathComponent(item.name))
            #expect(data == ResumingLink.content(of: item.name, count: item.size), "\(item.name) bytes",
                    sourceLocation: sourceLocation)
        }
    }

    /// Starts a stage job on `link`, cuts `item` at `offset` with a lost session, waits for its checkpoint in the
    /// catalogue and cancels the job, leaving the partial file and its `.partial` row for a later job.
    private func leavePartial(_ h: Harness, _ item: CameraItem, at offset: UInt64, on link: ResumingLink,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws -> CatalogueRecord {
        await link.script(item.name, .holdAfter(offset))
        try await h.start(.items([item]), from: link, to: h.stageRoute)
        await link.waitUntilHeld(item.name)
        let mark = h.trace.count
        link.send(.sessionLost(generation: 0))
        _ = await h.trace.wait(from: mark, where: Self.isCheckpoint(item.name, offset))
        await h.engine.cancel()
        #expect(await h.waitFinished(after: mark) == .cancelled, sourceLocation: sourceLocation)
        return try #require(await h.record(for: item), sourceLocation: sourceLocation)
    }

    // MARK: - The work folder

    /// The engine made with a Caches-like work folder keeps a partial in `Partials/<uuid>/<camera file name>` under it,
    /// and the row holds that path relative to the work folder. After an app update moves the container (the same
    /// tree under another absolute path), an engine on the new path resolves the row and continues the file from its
    /// offset, byte for byte.
    @Test func aPartialUnderTheWorkFolderResolvesAfterTheContainerMoves() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportEngineTests-container-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let before = base.appendingPathComponent("A", isDirectory: true)
        let after = base.appendingPathComponent("B", isDirectory: true)
        let catalogue = InMemoryCatalogue()
        let work = "Library/Caches/Imports"

        let first = Harness(catalogue: catalogue, root: before, workFolder: work)
        let a = first.item("A.ARW", size: 3000)
        let link = first.resumingLink([a])
        let row = try await leavePartial(first, a, at: 1500, on: link)
        #expect(row.state == .partial && row.resumeOffset == 1500)
        let tempURL = try #require(row.tempURL)
        #expect(tempURL.baseURL == nil)
        let components = tempURL.relativePath.split(separator: "/").map(String.init)
        #expect(components.count == 3 && components[0] == "Partials" && components[2] == "A.ARW")
        #expect(UUID(uuidString: components[1]) != nil, "the folder that marks a partial: \(components)")
        let file = try #require(row.partialFile(in: first.staging))
        #expect(file.path(percentEncoded: false).contains("/A/Library/Caches/Imports/Partials/"))
        #expect(DownloadAttempt.length(of: file) >= 1500)
        await link.shutdown()

        try FileManager.default.moveItem(at: before, to: after)
        let second = Harness(catalogue: catalogue, root: after, workFolder: work)
        #expect(await second.engine.reconcilePartials() == 0) // the file is there, under the new path
        let again = second.resumingLink([a])
        try await second.start(.items([a]), from: again, to: second.stageRoute)
        #expect(await second.waitFinished() == .completed)
        #expect(await again.resumes == [ResumingLink.Resume(name: "A.ARW", offset: 1500)])
        expectStaged(second, [a])
        #expect(await second.record(for: a)?.tempURL == nil)
        await first.cleanup()
        await second.cleanup()
    }

    /// An earlier work folder's partials (`tmp/Imports`, before I13) move into the new one, where their rows resolve;
    /// one already there is kept, and the earlier `Partials` folder is removed.
    @Test func partialsOfAnEarlierWorkFolderMoveIntoTheNewOne() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ImportEngineTests-move-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let earlier = base.appendingPathComponent("tmp/Imports", isDirectory: true)
        let work = base.appendingPathComponent("Library/Caches/Imports", isDirectory: true)
        func write(_ root: URL, _ folder: String, _ name: String, _ bytes: Int) throws {
            let dir = root.appendingPathComponent("Partials/\(folder)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: dir.appendingPathComponent(name))
        }
        try write(earlier, "F1", "A.ARW", 100)
        try write(earlier, "F2", "B.ARW", 200)
        try write(work, "F2", "B.ARW", 300)

        ImportEngine.movePartials(from: earlier, to: work)
        #expect(DownloadAttempt.length(of: work.appendingPathComponent("Partials/F1/A.ARW")) == 100)
        #expect(DownloadAttempt.length(of: work.appendingPathComponent("Partials/F2/B.ARW")) == 300)
        #expect(!fm.fileExists(atPath: earlier.appendingPathComponent("Partials").path(percentEncoded: false)))
        // Once more, with nothing left to move: nothing changes.
        ImportEngine.movePartials(from: earlier, to: work)
        #expect(DownloadAttempt.length(of: work.appendingPathComponent("Partials/F1/A.ARW")) == 100)
        // The work folder onto itself: nothing is touched.
        ImportEngine.movePartials(from: work, to: work)
        #expect(DownloadAttempt.length(of: work.appendingPathComponent("Partials/F2/B.ARW")) == 300)
    }

    @Test func theAppsWorkFolderIsInCaches() {
        let folder = ImportEngine.cachesWorkFolder
        #expect(folder.lastPathComponent == "Imports")
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        #expect(folder.deletingLastPathComponent().standardizedFileURL == caches?.standardizedFileURL)
    }

    // MARK: - Reconciliation

    /// iOS empties Caches between two jobs: the second job's diff first sends the row back to offset 0 with no file,
    /// so the file is copied from its start (no resume offered), its bytes are right and nothing is reported failed.
    @Test func aPurgedPartialIsResetBeforeTheNextDiffAndCopiedFromZero() async throws {
        let h = Harness()
        let a = h.item("A.ARW", size: 3000)
        let link = h.resumingLink([a])
        _ = try await leavePartial(h, a, at: 1500, on: link)
        try FileManager.default.removeItem(at: h.staging.appendingPathComponent("Partials", isDirectory: true))

        let mark = h.trace.count
        try await h.start(.items([a]), from: link, to: h.stageRoute)
        #expect(await h.waitFinished(after: mark) == .completed)
        let log = Array(h.trace.log[mark...])
        let reset = try #require(log.firstIndex(of: .partialReset("A.ARW")))
        let listed = try #require(log.firstIndex { if case .listed = $0 { true } else { false } })
        #expect(reset < listed, "the row is reset before the diff")
        #expect(await link.resumes.isEmpty)
        #expect(await link.bytesCalls == ["A.ARW", "A.ARW"])
        expectStaged(h, [a])
        #expect(await h.engine.currentProgress.filesFailed == 0)
        #expect(await h.outcome(of: a).map { if case .staged = $0 { true } else { false } } == true)
        let row = await h.record(for: a)
        #expect(row?.resumeOffset == 0 && row?.tempURL == nil && row?.staged != nil)
        await h.cleanup()
    }

    /// The launch pass, after the engine's prune: a partial pruned by age (one 7-day rule for both), one shorter than
    /// its offset (its folder deleted too), one whose file is missing and one outside the `Partials` folder all go back
    /// to offset 0 and stay `.partial`; a whole partial and an imported row are left alone. A second pass finds nothing.
    @Test func theLaunchPassResetsRowsWhoseFilesArePrunedMissingOrShort() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ImportEngineTests-launch-\(UUID().uuidString)")
        let partials = root.appendingPathComponent("staging/Partials", isDirectory: true)
        let catalogue = InMemoryCatalogue()
        let probe = Harness(catalogue: InMemoryCatalogue(), root: root) // for items and identities only
        let names = ["OLD.ARW", "SHORT.ARW", "MISSING.ARW", "OUT.ARW", "GOOD.ARW"]
        let items = probe.singles(names, sizes: [1000, 1000, 1000, 1000, 1000])
        var folders: [String: URL] = [:]
        for (item, length) in zip(items, [1000, 100, -1, -1, 600]) {
            let folder = partials.appendingPathComponent(UUID().uuidString, isDirectory: true)
            folders[item.name] = folder
            if length >= 0 {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(repeating: 1, count: length).write(to: folder.appendingPathComponent(item.name))
            }
            let relative = item.name == "OUT.ARW" ? "Elsewhere/OUT.ARW"
                : "Partials/\(folder.lastPathComponent)/\(item.name)"
            try await catalogue.markPartial(probe.identity(of: item), format: item.format,
                                            tempURL: URL(string: relative)!, offset: 500)
        }
        let imported = probe.item("DONE.ARW", size: 1000)
        await catalogue.upsert(CatalogueRecord(identity: probe.identity(of: imported), format: .raw,
                                                   state: .imported, location: .photosAsset(localIdentifier: "x")))
        // Eight days without a write: older than `ImportPolicy.partialRetention`.
        let old = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let oldFolder = try #require(folders["OLD.ARW"])
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: oldFolder.appendingPathComponent("OLD.ARW").path)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: oldFolder.path)

        let h = Harness(catalogue: catalogue, root: root) // the launch: its engine prunes
        #expect(!fm.fileExists(atPath: oldFolder.path(percentEncoded: false)), "pruned by age")
        #expect(await h.engine.reconcilePartials() == 4)
        for item in items.prefix(4) {
            let row = await h.record(for: item)
            #expect(row?.state == .partial && row?.resumeOffset == 0 && row?.tempURL == nil, "\(item.name)")
            #expect(h.trace.log.contains(.partialReset(item.name)))
        }
        #expect(!fm.fileExists(atPath: try #require(folders["SHORT.ARW"]).path(percentEncoded: false)))
        let good = await h.record(for: items[4])
        #expect(good?.resumeOffset == 500 && good?.tempURL != nil)
        #expect(DownloadAttempt.length(of: try #require(folders["GOOD.ARW"]).appendingPathComponent("GOOD.ARW")) == 600)
        #expect(await h.record(for: imported)?.state == .imported)
        #expect(await catalogue.states(of: items.map(probe.identity(of:))).values.allSatisfy { $0 == .partial })

        #expect(await h.engine.reconcilePartials() == 0)
        await probe.cleanup()
        await h.cleanup()
    }

    /// A catalogue that can't list its partial rows leaves everything as it is, and the job runs as before.
    @Test func aCatalogueThatCantListPartialRowsLeavesThem() async throws {
        let failing = FailingCatalogue()
        await failing.setFailPartialRecords(true)
        let h = Harness(catalogue: failing)
        #expect(await h.engine.reconcilePartials() == 0)
        let a = h.item("A.JPG", size: 3000)
        try await h.start(.items([a]), from: h.link([a]))
        #expect(await h.waitFinished() == .completed)
        await h.cleanup()
    }

    /// I9 deletes a resumable file's Partials folder when its marker can't be written, but the checkpoint row stays
    /// `.partial` at its offset. Once the catalogue takes writes again, the next job's reconciliation resets that row
    /// (its file is gone), so the file is copied from 0, with no resume offered, and committed once, with no failure.
    @Test func aRowLeftByAFailedMarkerIsResetAndTheFileCopiedFromZero() async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailBeginCommit(from: 1)
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        let h = Harness(catalogue: catalogue, policy: policy)
        let a = h.item("A.ARW", size: 3000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdAfter(2400))
        try await h.start(.allNew, from: link, to: h.photosRoute)
        await h.trace.next { $0 == .checkpointSaved("A.ARW", offset: 2100) }
        await link.waitUntilHeld("A.ARW")
        await link.release("A.ARW")
        #expect(await h.waitFinished() == .catalogueUnavailable)
        await h.engine.lastJobDriver()?.value
        #expect(h.stagedFiles == 0, "the partial's folder is deleted with the download")
        let left = try #require(await h.record(for: a))
        #expect(left.state == .partial && left.resumeOffset == 2100 && left.tempURL != nil,
                "the checkpoint row still points to the deleted file")

        await catalogue.setFailBeginCommit(from: nil)
        // Held before its first checkpoint, so the row read there is the one reconciliation left.
        await link.script("A.ARW", .holdAfter(500))
        let mark = h.trace.count
        try await h.start(.allNew, from: link, to: h.photosRoute)
        await link.waitUntilHeld("A.ARW")
        let cleared = await h.record(for: a)
        #expect(cleared?.state == .partial && cleared?.resumeOffset == 0 && cleared?.tempURL == nil,
                "the catalogue row itself is reset, not only reported")
        await link.release("A.ARW")
        #expect(await h.waitFinished(after: mark) == .completed)
        let log = Array(h.trace.log[mark...])
        let reset = try #require(log.firstIndex(of: .partialReset("A.ARW")))
        let listed = try #require(log.firstIndex { if case .listed = $0 { true } else { false } })
        #expect(reset < listed, "the row is reset before the diff")
        #expect(await link.resumes.isEmpty)
        #expect(await link.bytesCalls == ["A.ARW", "A.ARW"])
        #expect(await h.photos.committedNames == ["A.ARW"])
        #expect(await h.engine.currentProgress.filesFailed == 0)
        let row = await h.record(for: a)
        #expect(row?.state == .imported && row?.resumeOffset == 0 && row?.tempURL == nil)
        #expect(try await catalogue.pendingCommits().isEmpty)
        await h.cleanup()
    }

    // MARK: - Session generations

    /// The old session's loss reaches the engine after the reconnect: ignored, the job carries on in the new session.
    /// A loss of the new session still pauses it.
    @Test func aLateLossOfAReplacedSessionIsIgnored() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.resumingLink(card)
        await link.setSessionGeneration(1)
        await link.script("A.JPG", .holdAfter(1500))
        await link.script("B.JPG", .holdAfter(900))
        let job = try await h.start(.items(card), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")
        link.send(.sessionLost(generation: 1))
        await h.trace.next(.paused(.cameraUnreachable))

        await link.setSessionGeneration(2) // the app reopened the link
        try await h.engine.reconnect(job, to: link)
        _ = await h.trace.next { if case .started("B.JPG", _) = $0 { true } else { false } }
        await link.waitUntilHeld("B.JPG")
        let mark = h.trace.count
        link.send(.sessionLost(generation: 1)) // late: from the session the reconnect replaced
        _ = await h.trace.wait(from: mark) { $0 == .lateSessionLossIgnored(generation: 1) }
        #expect(await h.engine.state == .running)
        #expect(!h.trace.log[mark...].contains(.paused(.cameraUnreachable)))

        link.send(.sessionLost(generation: 2)) // the new session is lost too
        _ = await h.trace.wait(from: mark) { $0 == .paused(.cameraUnreachable) }
        await link.setSessionGeneration(3)
        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished(after: mark) == .completed)
        expectStaged(h, card)
        #expect(await h.engine.currentProgress.filesFailed == 0)
        await h.cleanup()
    }

    /// A reconnect that finds the same session still open (Continue after an expiry) replaced nothing: a loss of that
    /// session still pauses the job. And a loss with no generation (a link without them) always counts.
    @Test func aReconnectToTheSameSessionKeepsItsLossesLive() async throws {
        let h = Harness()
        let a = h.item("A.JPG", size: 3000)
        let link = h.resumingLink([a])
        await link.setSessionGeneration(1)
        await link.script("A.JPG", .holdAfter(900), .holdAfter(2100))
        let job = try await h.start(.items([a]), from: link, to: h.stageRoute)
        await link.waitUntilHeld("A.JPG")
        await h.engine.flushCheckpoints()
        try await h.engine.pause(.taskExpired)

        let mark = h.trace.count
        try await h.engine.reconnect(job, to: link) // the session never went: still generation 1
        _ = await h.trace.wait(from: mark) { $0 == .started("A.JPG", attempt: 2) }
        await link.waitUntilHeld("A.JPG")
        link.send(.sessionLost(generation: 1))
        _ = await h.trace.wait(from: mark) { $0 == .paused(.cameraUnreachable) }
        #expect(!h.trace.log[mark...].contains { if case .lateSessionLossIgnored = $0 { true } else { false } })

        let unstamped = h.trace.count
        await link.setSessionGeneration(2)
        try await h.engine.reconnect(job, to: link)
        #expect(await h.waitFinished(after: unstamped) == .completed)
        expectStaged(h, [a])
        await h.cleanup()
    }

    /// The rule itself: losses at or below the replaced generation, or older than the session in use, are late; an
    /// unstamped loss never is; a new link starts afresh.
    @Test func whichLossesAreLate() async throws {
        let link = ResumingLink(card: [])
        let other = ResumingLink(card: [])
        let job = Job(camera: CameraKey(rawValue: "k"), timeZone: .gmt, selection: .allNew, limit: 1,
                      staging: FileManager.default.temporaryDirectory, link: link,
                      route: .staging(NoDestination(), reason: .chosen, place: Harness.onThisIPhone,
                                      onThisIPhone: NoDestination()),
                      rateSamples: 1)
        #expect(!job.isReplaced(session: 1) && !job.isReplaced(session: 0))
        job.useSession(3)
        #expect(job.isReplaced(session: 2) && !job.isReplaced(session: 3) && !job.isReplaced(session: 0))
        job.replaceSession(with: link)
        #expect(job.isReplaced(session: 3) && !job.isReplaced(session: 4))
        job.useSession(4)
        #expect(job.isReplaced(session: 3) && !job.isReplaced(session: 4))
        job.replaceSession(with: link)
        job.useSession(4) // the same session after all
        #expect(job.isReplaced(session: 3) && !job.isReplaced(session: 4))
        job.replaceSession(with: other)
        #expect(!job.isReplaced(session: 1) && !job.isReplaced(session: 4))
        await link.shutdown()
        await other.shutdown()
    }
}
