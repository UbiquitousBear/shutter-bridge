import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// Resolving pending-commit markers (backlog section 3.1, "Tests that prove it"; I15): a commit whose catalogue write
/// was lost, by a kill between the save and the row or by a store failing every try, is found again before the next
/// diff instead of being committed a second time; one that isn't found is committed once more; a commit still in
/// flight is never touched; and the launch pass resolves before it reconciles partial rows.
@Suite("The commit boundary", .timeLimit(.minutes(1)))
struct CommitBoundaryTests {
    /// A launch killed between a commit's save and its row: `first` commits `item` through `route(first)` over a
    /// catalogue whose `finishCommit` never lands, and is dropped. Returns the marker it left behind.
    func killedAfterTheSave(_ first: Harness, _ items: [CameraItem], route: ImportRoute,
                            store: InMemoryCatalogue) async throws -> PendingCommit {
        try await first.start(.allNew, from: first.link(items), to: route)
        #expect(await first.waitFinished() == .catalogueUnavailable)
        await first.engine.settleCommits(ofJobsOtherThan: UUID())
        await first.engine.lastJobDriver()?.value
        #expect(await store.allRecords.isEmpty, "no row: the finish never landed")
        let markers = await store.pendingCommits()
        #expect(markers.count == 1)
        return try #require(markers.first)
    }

    func route(_ kind: DestinationKind, _ h: Harness, _ staging: RealStaging,
               photos: FakeDestination? = nil) -> ImportRoute {
        kind == .photos ? h.photosRoute(to: photos ?? h.photos) : staging.route
    }

    // MARK: A kill between the save and the row

    /// Found at the next launch: one row with the asset's identifier (or the numbered staged copy's path), no marker,
    /// and the next job doesn't commit the file again.
    @Test(arguments: [DestinationKind.photos, .staging])
    func aKillBetweenTheSaveAndTheRowIsFoundAtTheNextLaunch(_ kind: DestinationKind) async throws {
        let store = InMemoryCatalogue()
        let first = Harness(catalogue: KilledAtFinishCatalogue(store))
        let staging = RealStaging(under: first.root, zone: first.zone)
        // An older file of the same name and another size: the staged copy is numbered.
        try staging.put("DSC00001.ARW", size: 10)
        let a = first.item("DSC00001.ARW", size: 4016)
        let marker = try await killedAfterTheSave(first, [a], route: route(kind, first, staging), store: store)
        if kind == .staging { #expect(staging.names == ["DSC00001 (2).ARW", "DSC00001.ARW"]) }
        await first.engine.cancel()

        let library = CommittedLibrary(first.photos)
        let lookup = CountingLookup(staging.lookup(library: library))
        let second = Harness(catalogue: store, root: first.root, commitLookup: lookup)
        let report = await second.engine.launchPass()
        #expect(lookup.asked.map(\.id) == [marker.id])
        #expect(await store.pendingCommits().isEmpty)
        let row = try #require(await second.record(for: a))
        if kind == .photos {
            #expect(report == PendingCommitReport(foundInPhotos: 1))
            #expect(row.state == .imported)
            #expect(row.location == .photosAsset(localIdentifier: "asset-1"))
            #expect(second.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .foundInPhotos)))
        } else {
            #expect(report == PendingCommitReport(foundInStaging: 1))
            #expect(row.staged == StagedLocation(root: .onThisIPhone, relativePath: staging.dayFolder
                                                     + "/DSC00001 (2).ARW", stagedAt: marker.writtenAt))
            #expect(second.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .foundInStaging)))
        }

        // The next job leaves the file out: it is committed once.
        let mark = second.trace.count
        try await second.start(.allNew, from: second.link([a]), to: route(kind, second, staging, photos: first.photos))
        #expect(await second.waitFinished(after: mark) == .completed)
        #expect(await first.photos.commits.count == (kind == .photos ? 1 : 0))
        #expect(staging.names == (kind == .photos ? ["DSC00001.ARW"] : ["DSC00001 (2).ARW", "DSC00001.ARW"]))
        await second.cleanup()
        await first.cleanup()
    }

    /// Not found at the next launch (deleted from Photos, or from Staging, since): the marker is removed, the file reads
    /// new, and the next job commits it once more.
    @Test(arguments: [DestinationKind.photos, .staging])
    func aKillWhoseCommitIsNotFoundLeavesTheFileNew(_ kind: DestinationKind) async throws {
        let store = InMemoryCatalogue()
        let first = Harness(catalogue: KilledAtFinishCatalogue(store))
        let staging = RealStaging(under: first.root, zone: first.zone)
        try staging.put("DSC00001.ARW", size: 10)
        let a = first.item("DSC00001.ARW", size: 4016)
        _ = try await killedAfterTheSave(first, [a], route: route(kind, first, staging), store: store)
        await first.engine.cancel()
        let library = CommittedLibrary(first.photos)
        await library.setDeleted(true)
        if kind == .staging {
            try FileManager.default.removeItem(at: staging.dayFolderURL.appendingPathComponent("DSC00001 (2).ARW"))
        }

        let second = Harness(catalogue: store, root: first.root, commitLookup: staging.lookup(library: library))
        let report = await second.engine.launchPass()
        #expect(report == PendingCommitReport(notFound: 1))
        #expect(await store.pendingCommits().isEmpty)
        #expect(await second.record(for: a) == nil, "no row: the file reads new")
        #expect(second.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", kind == .photos ? .notFound : .notStaged)))

        let mark = second.trace.count
        try await second.start(.allNew, from: second.link([a]), to: route(kind, second, staging, photos: first.photos))
        #expect(await second.waitFinished(after: mark) == .completed)
        let row = try #require(await second.record(for: a))
        if kind == .photos {
            #expect(await first.photos.commits.count == 2)
            #expect(row.state == .imported)
        } else {
            #expect(staging.names == ["DSC00001 (2).ARW", "DSC00001.ARW"])
            #expect(row.staged?.relativePath == staging.dayFolder + "/DSC00001 (2).ARW")
        }
        #expect(await second.engine.currentProgress.possibleDuplicates == 0)
        await second.cleanup()
        await first.cleanup()
    }

    /// Not found under Limited Access: counted as a possible duplicate, and the next job's outcome carries it.
    @Test func notFoundUnderLimitedAccessIsAPossibleDuplicateTheNextJobSays() async throws {
        let store = InMemoryCatalogue()
        let first = Harness(catalogue: KilledAtFinishCatalogue(store))
        let staging = RealStaging(under: first.root, zone: first.zone)
        let a = first.item("DSC00001.ARW", size: 4016)
        _ = try await killedAfterTheSave(first, [a], route: first.photosRoute, store: store)
        await first.engine.cancel()
        let library = CommittedLibrary(first.photos)
        await library.setAccess(.limited)
        await library.setDeleted(true) // out of sight

        let second = Harness(catalogue: store, root: first.root, commitLookup: staging.lookup(library: library))
        #expect(await second.engine.launchPass() == PendingCommitReport(notFound: 1, possibleDuplicates: 1))
        #expect(second.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .possibleDuplicate)))
        let mark = second.trace.count
        try await second.start(.allNew, from: second.link([a]), to: second.photosRoute(to: first.photos))
        #expect(await second.waitFinished(after: mark) == .completed)
        #expect(await second.engine.currentProgress.possibleDuplicates == 1)
        // Said once: the job after it doesn't say it again.
        let next = second.trace.count
        try await second.start(.allNew, from: second.link([a]), to: second.photosRoute(to: first.photos))
        #expect(await second.waitFinished(after: next) == .completed)
        #expect(await second.engine.currentProgress.possibleDuplicates == 0)
        await second.cleanup()
        await first.cleanup()
    }

    /// Photos access not given: the lookup can't look, so the marker waits for a later pass and nothing is guessed.
    @Test func aMarkerThatCannotBeLookedUpWaits() async throws {
        let store = InMemoryCatalogue()
        let first = Harness(catalogue: KilledAtFinishCatalogue(store))
        let staging = RealStaging(under: first.root, zone: first.zone)
        let a = first.item("DSC00001.ARW", size: 4016)
        let marker = try await killedAfterTheSave(first, [a], route: first.photosRoute, store: store)
        await first.engine.cancel()
        let library = CommittedLibrary(first.photos)
        await library.setAccess(.denied)

        let second = Harness(catalogue: store, root: first.root, commitLookup: staging.lookup(library: library))
        #expect(await second.engine.launchPass() == PendingCommitReport(waiting: 1))
        #expect(await store.pendingCommits().map(\.id) == [marker.id])
        #expect(second.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .waiting)))
        // Access comes back: the next pass finds it.
        await library.setAccess(.authorised)
        #expect(await second.engine.resolvePendingCommits() == PendingCommitReport(foundInPhotos: 1))
        #expect(await store.pendingCommits().isEmpty)
        await second.cleanup()
        await first.cleanup()
    }

    // MARK: A pair

    /// A pair is one commit: one lookup, one marker, both rows (the asset's one identifier, or both staged copies
    /// under one number, never a lone half's higher number).
    @Test(arguments: [DestinationKind.photos, .staging])
    func aPairIsResolvedAsOneCommit(_ kind: DestinationKind) async throws {
        let store = InMemoryCatalogue()
        let first = Harness(catalogue: KilledAtFinishCatalogue(store))
        let staging = RealStaging(under: first.root, zone: first.zone)
        let card = first.card(frames: 1)
        // The JPG's name is taken by another file, so the pair is numbered (2); a stray "(3).ARW" of the RAW's size
        // has no JPG beside it.
        try staging.put("DSC00001.JPG", size: 10)
        try staging.put("DSC00001 (3).ARW", size: Int(card[0].size))
        let marker = try await killedAfterTheSave(first, card, route: route(kind, first, staging), store: store)
        #expect(marker.files.map(\.role) == [.raw, .processed])
        await first.engine.cancel()

        let library = CommittedLibrary(first.photos)
        let lookup = CountingLookup(staging.lookup(library: library))
        let second = Harness(catalogue: store, root: first.root, commitLookup: lookup)
        let report = await second.engine.launchPass()
        #expect(lookup.asked.count == 1)
        #expect(await store.pendingCommits().isEmpty)
        let raw = try #require(await second.record(for: card[0]))
        let jpeg = try #require(await second.record(for: card[1]))
        if kind == .photos {
            #expect(report == PendingCommitReport(foundInPhotos: 1))
            #expect(raw.location == .photosAsset(localIdentifier: "asset-1"))
            #expect(jpeg.location == .photosAsset(localIdentifier: "asset-1"))
            // The query is the save's layout: the JPG as the photo, the ARW as its alternate, at the RAW's date.
            let query = try #require(await library.queries.first)
            #expect(query.resources.map(\.role) == [.photo, .alternatePhoto])
            #expect(query.resources.map(\.originalFilename) == ["DSC00001.JPG", "DSC00001.ARW"])
            #expect(query.creationDate == card[0].captureDate)
        } else {
            #expect(report == PendingCommitReport(foundInStaging: 1))
            #expect(raw.staged?.relativePath == staging.dayFolder + "/DSC00001 (2).ARW")
            #expect(jpeg.staged?.relativePath == staging.dayFolder + "/DSC00001 (2).JPG")
        }
        await second.cleanup()
        await first.cleanup()
    }

    // MARK: A write that fails every try

    /// `finishCommit` fails every try, then a job later in the same launch: the rows are written from memory, with no
    /// lookup asked, and the file isn't committed again.
    @Test(arguments: [DestinationKind.photos, .staging])
    func aFinishThatFailsEveryTryIsWrittenFromMemoryBeforeTheNextJob(_ kind: DestinationKind) async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailFinishCommit(true)
        // Were it asked, this would remove the marker and lose the commit.
        let lookup = CountingLookup(answer: .notFound(underLimitedAccess: false))
        let h = Harness(catalogue: catalogue, commitLookup: lookup)
        let a = h.item("DSC00001.ARW", size: 4016)
        let link = h.link([a])
        try await h.start(.allNew, from: link, to: h.route(kind))
        #expect(await h.waitFinished() == .catalogueUnavailable)
        await h.engine.settleCommits(ofJobsOtherThan: UUID())
        #expect(await h.engine.unrecordedCommits.count == 1)

        await catalogue.setFailFinishCommit(false)
        let mark = h.trace.count
        try await h.start(.allNew, from: link, to: h.route(kind))
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(lookup.asked.isEmpty)
        #expect(h.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .replayed)))
        #expect(await h.engine.unrecordedCommits.isEmpty)
        #expect(try await catalogue.pendingCommits().isEmpty)
        let destination = kind == .photos ? h.photos : h.files
        #expect(await destination.committedNames == ["DSC00001.ARW"])
        let row = try #require(await h.record(for: a))
        if kind == .photos { #expect(row.state == .imported) } else { #expect(row.staged != nil) }
        await h.cleanup()
    }

    /// A replay the catalogue still refuses keeps the rows in memory and the marker, and a later pass writes them.
    @Test func aReplayThatFailsWaitsForTheNextPass() async throws {
        let catalogue = FailingCatalogue()
        await catalogue.setFailFinishCommit(true)
        let lookup = CountingLookup(answer: .notFound(underLimitedAccess: false))
        let h = Harness(catalogue: catalogue, commitLookup: lookup)
        let a = h.item("DSC00001.ARW", size: 4016)
        try await h.start(.allNew, from: h.link([a]), to: h.photosRoute)
        #expect(await h.waitFinished() == .catalogueUnavailable)
        await h.engine.settleCommits(ofJobsOtherThan: UUID())

        #expect(await h.engine.resolvePendingCommits() == PendingCommitReport(waiting: 1))
        #expect(await h.engine.unrecordedCommits.count == 1)
        #expect(try await catalogue.pendingCommits().count == 1)
        await catalogue.setFailFinishCommit(false)
        #expect(await h.engine.resolvePendingCommits() == PendingCommitReport(foundInPhotos: 1, replayed: 1))
        #expect(lookup.asked.isEmpty)
        #expect(await h.record(for: a)?.state == .imported)
        await h.cleanup()
    }

    /// *Forget imports* between a finish that failed every try and the next job: the camera key's markers went with
    /// its rows (`forgetImports(camera:)`, "so a later pass can't mark the forgotten files imported again"), so the
    /// rows kept in memory are written only as far as the forget would have left them had they landed first: an
    /// imported row isn't written (the file is offered again, as forgetting asks), a staged copy is (forgetting keeps
    /// staged copies), and no lookup is asked either way.
    @Test(arguments: [DestinationKind.photos, .staging])
    func aForgetBeforeTheReplayIsHonoured(_ kind: DestinationKind) async throws {
        let store = InMemoryCatalogue()
        let catalogue = KilledAtFinishCatalogue(store)
        let lookup = CountingLookup(answer: .notFound(underLimitedAccess: false))
        let h = Harness(catalogue: catalogue, commitLookup: lookup)
        let a = h.item("DSC00001.ARW", size: 4016)
        let link = h.link([a])
        try await h.start(.allNew, from: link, to: h.route(kind))
        #expect(await h.waitFinished() == .catalogueUnavailable)
        await h.engine.settleCommits(ofJobsOtherThan: UUID())
        #expect(await h.engine.unrecordedCommits.count == 1)
        await store.forgetImports(camera: h.camera)
        #expect(await store.pendingCommits().isEmpty, "the forget took the marker")

        await catalogue.setRefusesFinish(false)
        let mark = h.trace.count
        try await h.start(.allNew, from: link, to: h.route(kind))
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(lookup.asked.isEmpty)
        #expect(await h.engine.unrecordedCommits.isEmpty)
        #expect(await store.pendingCommits().isEmpty)
        let row = try #require(await h.record(for: a))
        if kind == .photos {
            #expect(h.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .forgotten)))
            #expect(!h.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .replayed)))
            // Offered again and imported again, as forgetting asks.
            #expect(await h.photos.committedNames == ["DSC00001.ARW", "DSC00001.ARW"])
            #expect(row.state == .imported)
        } else {
            #expect(h.trace.log.contains(.pendingCommitResolved("DSC00001.ARW", .replayed)))
            // The staged copy is recorded, so the stage job leaves the file out: staged once.
            #expect(await h.files.committedNames == ["DSC00001.ARW"])
            #expect(row.staged != nil)
        }
        await h.cleanup()
    }

    // MARK: A commit still in flight

    /// A pass run from `append` while a commit is with its destination leaves that commit's marker alone: no lookup,
    /// marker kept, and the commit then finishes as usual.
    @Test(arguments: [DestinationKind.photos, .staging])
    func aMarkerOfACommitInFlightIsNotTouchedByAPassFromAppend(_ kind: DestinationKind) async throws {
        let catalogue = InMemoryCatalogue()
        let lookup = CountingLookup(answer: .notFound(underLimitedAccess: false))
        let h = Harness(catalogue: catalogue, commitLookup: lookup)
        let gate = GateDestination(kind == .photos ? h.photos : h.files)
        let route: ImportRoute = kind == .photos ? h.photosRoute(to: gate)
            : .staging(gate, reason: .chosen, place: Harness.onThisIPhone, onThisIPhone: h.files)
        let card = h.singles(["A.JPG", "B.JPG"])
        try await h.start(.items([card[0]]), from: h.link(card), to: route)
        await gate.waitArrived()
        let live = await catalogue.pendingCommits()
        #expect(live.count == 1)

        #expect(try await h.engine.append([card[1]]) == 1)
        #expect(lookup.asked.isEmpty)
        #expect(await catalogue.pendingCommits() == live)

        await gate.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await catalogue.pendingCommits().isEmpty)
        #expect(lookup.asked.isEmpty)
        for item in card {
            let row = try #require(await h.record(for: item))
            if kind == .photos { #expect(row.state == .imported) } else { #expect(row.staged != nil) }
        }
        await h.cleanup()
    }

    // MARK: The launch pass

    /// Resolve, then reconcile: a stage job over Wi-Fi whose partial file the staging folder took, killed before the
    /// row, leaves a `.partial` row naming a file that is gone and a marker. The next launch's pass records the staged
    /// copy (which clears the partial row) without depending on that file, resets nothing, and the next stage job
    /// copies nothing: one staged copy, no marker.
    @Test func theLaunchPassResolvesAStageCommitWhosePartialFileIsGone() async throws {
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        let store = InMemoryCatalogue()
        let first = Harness(catalogue: KilledAtFinishCatalogue(store), policy: policy)
        let staging = RealStaging(under: first.root, zone: first.zone)
        let a = first.item("DSC00001.ARW", size: 3000)
        let link = first.resumingLink([a])
        await link.script("DSC00001.ARW", .holdAfter(2400))
        try await first.start(.allNew, from: link, to: staging.route)
        // Both crossings (1,200 and 2,100 B) are in the catalogue before the download ends.
        await first.trace.next { $0 == .checkpointSaved("DSC00001.ARW", offset: 2100) }
        await link.waitUntilHeld("DSC00001.ARW")
        await link.release("DSC00001.ARW")
        #expect(await first.waitFinished() == .catalogueUnavailable)
        await first.engine.settleCommits(ofJobsOtherThan: UUID())
        await first.engine.lastJobDriver()?.value
        let partial = try #require(await store.record(for: first.identity(of: a)))
        #expect(partial.state == .partial)
        let partialFile = try #require(partial.partialFile(in: first.staging))
        #expect(!FileManager.default.fileExists(atPath: partialFile.path(percentEncoded: false)))
        #expect(await store.pendingCommits().count == 1)
        #expect(staging.names == ["DSC00001.ARW"])
        await first.engine.cancel()

        let second = Harness(catalogue: store, policy: policy, root: first.root,
                             commitLookup: staging.lookup(library: CommittedLibrary(first.photos)))
        #expect(await second.engine.launchPass() == PendingCommitReport(foundInStaging: 1))
        #expect(await store.pendingCommits().isEmpty)
        let row = try #require(await second.record(for: a))
        #expect(row.state == .new && row.tempURL == nil && row.resumeOffset == 0)
        #expect(row.staged?.relativePath == staging.dayFolder + "/DSC00001.ARW")
        #expect(!second.trace.log.contains(.partialReset("DSC00001.ARW")))
        // Called again, the launch pass is the same one.
        #expect(await second.engine.launchPass() == PendingCommitReport(foundInStaging: 1))

        let mark = second.trace.count
        try await second.start(.allNew, from: second.resumingLink([a]), to: staging.route)
        #expect(await second.waitFinished(after: mark) == .completed)
        #expect(staging.names == ["DSC00001.ARW"])
        await second.cleanup()
        await first.cleanup()
    }

    /// A job started while the launch pass is looking a marker up lists only once the pass is done, so a commit the
    /// pass finds is left out rather than committed again.
    @Test func aJobStartedDuringTheLaunchPassWaitsForIt() async throws {
        let store = InMemoryCatalogue()
        let gated = GatedLookup { .found($0.importedWrites(localIdentifier: "earlier")) }
        let h = Harness(catalogue: store, commitLookup: gated)
        let a = h.item("DSC00001.ARW", size: 4016)
        try await store.beginCommit(PendingCommit(
            id: UUID(), destination: .photos,
            files: [PendingCommit.File(identity: h.identity(of: a), format: a.format, role: .single,
                                       assetDate: a.captureDate)],
            writtenAt: Harness.t0))
        let engine = h.engine
        let launch = Task { await engine.launchPass() }
        await gated.waitArrived()
        try await h.start(.allNew, from: h.link([a]), to: h.photosRoute)
        await gated.open()
        #expect(await h.waitFinished() == .completed)
        #expect(await launch.value == PendingCommitReport(foundInPhotos: 1))
        #expect(await gated.calls == 1)
        #expect(await h.photos.attempts == 0)
        #expect(await h.record(for: a)?.location == .photosAsset(localIdentifier: "earlier"))
        let log = h.trace.log
        let resolved = try #require(log.firstIndex(of: .pendingCommitResolved("DSC00001.ARW", .foundInPhotos)))
        let listed = try #require(log.firstIndex { if case .listed = $0 { true } else { false } })
        #expect(resolved < listed)
        await h.cleanup()
    }

    // MARK: The production lookup's parts

    /// A marker for iCloud Drive while iCloud Drive isn't available can't be looked up yet; once it is, the finder
    /// looks under the container's Documents folder.
    @Test func anICloudMarkerWaitsForICloudDrive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CommitLookup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let iCloud = root.appendingPathComponent("iCloud", isDirectory: true)
        let folder = "Staging/ILCE-7CM2/2026-10-26"
        try FileManager.default.createDirectory(at: iCloud.appendingPathComponent(folder),
                                                withIntermediateDirectories: true)
        try Data(count: 12).write(to: iCloud.appendingPathComponent(folder + "/A.JPG"))
        let identity = ObjectIdentity(camera: CameraKey(rawValue: "c"), folder: "DCIM", filename: "A.JPG",
                                      captureDate: CaptureDate(rawValue: "20261026T073320")!, size: 12)
        let marker = PendingCommit(id: UUID(), destination: .staging(root: .iCloudDrive, folder: folder),
                                   files: [PendingCommit.File(identity: identity, format: .jpeg, role: .single)],
                                   writtenAt: Harness.t0)
        let locator = FakeStagingLocator(.unavailable(.iCloudDriveOff))
        let lookup = LibraryCommitLookup(library: CommittedLibrary(FakeDestination(kind: .photos, folder: root)),
                                         staging: locator, onThisIPhone: root.appendingPathComponent("Documents"))
        #expect(await lookup.look(for: marker) == .cannotLook)
        await locator.set(.iCloudDrive(documents: iCloud))
        #expect(await lookup.look(for: marker) == .found([
            .staged(identity, format: .jpeg, at: StagedLocation(root: .iCloudDrive, relativePath: folder + "/A.JPG",
                                                                stagedAt: Harness.t0)),
        ]))
    }
}
