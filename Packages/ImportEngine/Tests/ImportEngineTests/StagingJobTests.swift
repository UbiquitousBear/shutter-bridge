import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// Stage jobs (Shamil, 11 Nov): each import is *Import to Photos* or *Stage*, and the job's purpose comes from its
/// route. A stage job leaves out what is already staged (by content) and, where only new files were asked for, what is
/// already imported; an import job ignores staging. A staged file is recorded with `markStaged`, beside its state.
/// When iCloud Drive goes away mid-job the rest is staged on this iPhone, once, saying so. The purpose holds across a
/// pause, a continue, a reconnect and an expiry. All on the manual clock, waiting on the trace.
@Suite("Stage jobs", .timeLimit(.minutes(1)))
struct StagingJobTests {
    /// A row of `item` as another job left it: imported to Photos, staged, or both, under another camera key and
    /// folder, so only its content matches.
    static func row(_ h: Harness, _ item: CameraItem, imported: Bool = false, staged: Bool = false)
        -> CatalogueRecord {
        var identity = h.identity(of: item)
        identity.camera = CameraKey(rawValue: "usb-msc-name:other")
        identity.folder = "DCIM/101MSDCF"
        return CatalogueRecord(
            identity: identity, format: item.format, state: imported ? .imported : .new,
            location: imported ? .photosAsset(localIdentifier: "old-\(item.name)") : nil,
            staged: staged ? StagedLocation(root: .iCloudDrive, relativePath: "Staging/Camera/\(item.name)") : nil)
    }

    /// A harness whose catalogue holds `rows`, made from a card of four singles: A imported, B staged, C both, D
    /// neither.
    static func seeded() async -> (Harness, [CameraItem]) {
        let probe = Harness()
        let card = probe.singles(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        let rows = [row(probe, card[0], imported: true), row(probe, card[1], staged: true),
                    row(probe, card[2], imported: true, staged: true)]
        await probe.cleanup()
        return (Harness(catalogue: InMemoryCatalogue(records: rows)), card)
    }

    static func isStaged(_ name: String) -> @Sendable (EngineTrace) -> Bool {
        { if case .staged(name, _) = $0 { true } else { false } }
    }

    // MARK: - What counts as done

    /// The rule as a table: an import job ignores staging; a stage job leaves out staged files, and imported ones
    /// where only new files were asked for; a listed card wants only new and partial rows, as before.
    @Test func theDoneRuleFollowsThePurpose() {
        func wanted(_ state: ObjectState, staged: Bool = false, _ purpose: DestinationKind, newOnly: Bool = true,
                    wholeCard: Bool = false) -> Bool {
            DoneRule.isWanted(state: state, staged: staged, purpose: purpose, newOnly: newOnly, wholeCard: wholeCard)
        }
        // Import: imported is done, staging is ignored.
        #expect(!wanted(.imported, .photos))
        #expect(!wanted(.imported, staged: true, .photos, newOnly: false))
        #expect(wanted(.new, staged: true, .photos))
        #expect(wanted(.partial, staged: true, .photos, wholeCard: true))
        #expect(wanted(.skipped, .photos, newOnly: false))
        #expect(!wanted(.skipped, .photos, wholeCard: true))
        // Stage: staged is done; imported is done only where new files were asked for.
        #expect(!wanted(.new, staged: true, .staging, newOnly: false))
        #expect(!wanted(.imported, staged: true, .staging, newOnly: false))
        #expect(!wanted(.imported, .staging, newOnly: true))
        #expect(wanted(.imported, .staging, newOnly: false))
        #expect(wanted(.new, .staging))
        #expect(wanted(.partial, .staging, wholeCard: true))
        #expect(!wanted(.skipped, .staging, wholeCard: true))
        #expect(wanted(.skipped, .staging, newOnly: false))
        // Which selections ask for new files only.
        #expect(ImportSelection.allNew.newOnly)
        #expect(ImportSelection.dateRange(Harness.t0 ... Harness.t0).newOnly)
        #expect(ImportSelection.newItems([]).newOnly)
        #expect(!ImportSelection.items([]).newOnly)
        #expect(ImportSelection.newItems([]).isEmpty)
    }

    /// What a job would hold, read before it starts so the app counts what it copies: the same rule as the diff,
    /// by the route's purpose (an import staged because Photos access is off leaves out staged files), each file
    /// once, in the pick's order.
    @Test func picksToDoFollowTheRoutesPurpose() async throws {
        let (h, card) = await Self.seeded()   // A imported, B staged, C both, D neither
        func names(_ selection: ImportSelection, _ route: ImportRoute) async throws -> [String] {
            try await h.engine.picksToDo(selection, camera: h.camera, for: route).map(\.name)
        }
        #expect(try await names(.items(card), h.photosRoute) == ["B.JPG", "D.JPG"])
        #expect(try await names(.items(card), h.stageRoute(reason: .photosDenied)) == ["A.JPG", "D.JPG"])
        #expect(try await names(.newItems(card), h.stageRoute) == ["D.JPG"])
        #expect(try await names(.items([card[3], card[3], card[1]]), h.stageRoute) == ["D.JPG"])
        #expect(try await names(.items([card[1], card[2]]), h.stageRoute).isEmpty)
        #expect(try await names(.allNew, h.photosRoute).isEmpty)
        // The job then holds exactly those.
        let link = h.link(card)
        let denied = h.stageRoute(reason: .photosDenied)
        let toDo = try await h.engine.picksToDo(.items(card), camera: h.camera, for: denied)
        try await h.start(.items(toDo), from: link, to: denied)
        #expect(await h.waitFinished() == .completed)
        #expect(await h.engine.currentProgress.filesTotal == 2)
        #expect(await h.files.committedNames.sorted() == ["A.JPG", "D.JPG"])
        await h.cleanup()
    }

    /// *Stage* with all new: staged files and imported ones are left out, by content whatever the camera key or
    /// folder, and saying which were staged already.
    @Test func allNewStagesOnlyWhatIsNeitherStagedNorImported() async throws {
        let (h, card) = await Self.seeded()
        let link = h.link(card)
        try await h.start(.allNew, from: link, to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["D.JPG"])
        #expect(await h.files.committedNames == ["D.JPG"])
        #expect(h.trace.log.contains(.alreadyStaged("B.JPG")))
        #expect(h.trace.log.contains(.alreadyStaged("C.JPG")))
        #expect(!h.trace.log.contains(.alreadyStaged("A.JPG")))
        await h.cleanup()
    }

    /// *Import to Photos* ignores staging: a staged file is imported like any other; only imported ones are left out.
    @Test func anImportJobIgnoresStaging() async throws {
        let (h, card) = await Self.seeded()
        let link = h.link(card)
        try await h.start(.allNew, from: link, to: h.photosRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls.sorted() == ["B.JPG", "D.JPG"])
        #expect(Set(await h.photos.committedNames) == ["B.JPG", "D.JPG"])
        #expect(h.trace.count { if case .alreadyStaged = $0 { true } else { false } } == 0)
        // B keeps its staged copy beside the import (`upsert` doesn't change it): its row here is new, so the
        // copy stays on the other camera's row, and B now reads as both imported and staged.
        let b = h.identity(of: card[1])
        #expect(try await h.catalogue.states(of: [b])[b] == .imported)
        #expect(try await h.catalogue.stagedStates(of: [b]) == [b])
        await h.cleanup()
    }

    /// An explicit pick of an imported file may still be staged; a staged one is left out. *Select all new*'s pick
    /// (`newItems`) leaves imported ones out too.
    @Test func anExplicitPickMayStageAnImportedFile() async throws {
        do {
            let (h, card) = await Self.seeded()
            let link = h.link(card)
            try await h.start(.items(card), from: link, to: h.stageRoute)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["A.JPG", "D.JPG"])
            await h.cleanup()
        }
        do {
            let (h, card) = await Self.seeded()
            let link = h.link(card)
            try await h.start(.newItems(card), from: link, to: h.stageRoute)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["D.JPG"])
            await h.cleanup()
        }
        do { // An import job treats Select all new's pick like any pick: imported files are left out.
            let (h, card) = await Self.seeded()
            let link = h.link(card)
            try await h.start(.newItems(card), from: link, to: h.photosRoute)
            #expect(await h.waitFinished() == .completed)
            #expect(await link.bytesCalls == ["B.JPG", "D.JPG"])
            await h.cleanup()
        }
    }

    /// Staging an imported file keeps it imported, where it went and all; the staged copy goes beside it.
    @Test func stagingAnImportedFileKeepsItImported() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let imported = CatalogueRecord(identity: h.identity(of: card[0]), format: card[0].format, state: .imported,
                                       location: .photosAsset(localIdentifier: "old-A"))
        let catalogue = InMemoryCatalogue(records: [imported])
        let h2 = Harness(catalogue: catalogue)
        await h.cleanup()
        let link = h2.link(card)
        try await h2.start(.items(card), from: link, to: h2.stageRoute)
        #expect(await h2.waitFinished() == .completed)
        let row = try #require(await h2.record(for: card[0]))
        #expect(row.state == .imported)
        #expect(row.location == .photosAsset(localIdentifier: "old-A"))
        #expect(row.staged?.relativePath == "Untitled/A.JPG")
        #expect(row.staged?.root == .onThisIPhone)
        await h2.cleanup()
    }

    // MARK: - Appending

    /// Files added to a running stage job: staged ones are left out; imported ones only with `newOnly`.
    @Test func appendFollowsTheJobsPurpose() async throws {
        let (h, card) = await Self.seeded()
        let e = h.item("E.JPG", size: 3000, date: Harness.t0.addingTimeInterval(10))
        let link = h.link([e] + card)
        await link.script("E.JPG", .hold)
        try await h.start(.items([e]), from: link, to: h.stageRoute)
        let held = await link.nextHeldCall("E.JPG")
        #expect(try await h.engine.append(card, newOnly: true) == 1) // D only
        #expect(try await h.engine.append(card) == 1) // A, an explicit pick of an imported file
        #expect(try await h.engine.append(card) == 0) // all in the job or staged
        held.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["E.JPG", "D.JPG", "A.JPG"])
        #expect(h.trace.log.contains(.alreadyStaged("B.JPG")))
        await h.cleanup()
    }

    /// Files added to a running import job: imported ones are left out, staged ones are not.
    @Test func appendToAnImportJobIgnoresStaging() async throws {
        let (h, card) = await Self.seeded()
        let e = h.item("E.JPG", size: 3000, date: Harness.t0.addingTimeInterval(10))
        let link = h.link([e] + card)
        await link.script("E.JPG", .hold)
        try await h.start(.items([e]), from: link)
        let held = await link.nextHeldCall("E.JPG")
        #expect(try await h.engine.append(card, newOnly: true) == 2) // B and D
        held.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["E.JPG", "B.JPG", "D.JPG"])
        await h.cleanup()
    }

    // MARK: - Counts, rows and phases

    /// A stage job's files read as staged: the progress counts them apart from imported, their rows and outcomes say
    /// where they went, and the trace says so.
    @Test func countsAndPhasesSayStaged() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"]) + [h.item("C0001.MP4", size: 8000)]
        let link = h.link(card)
        await link.script("B.JPG", .fail(.itemNotFound))
        try await h.start(.items(card), from: link, to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        let p = await h.engine.currentProgress
        #expect(p.filesDone == 3)
        #expect(p.filesStaged == 1)
        #expect(p.filesSkipped == 2)
        #expect(p.filesImported == 0)
        #expect(p.destination == .stagedHere(.chosen))
        let files = await h.engine.currentFiles
        guard case let .staged(location?) = files.first(where: { $0.item.name == "A.JPG" })?.phase else {
            Issue.record("A.JPG should read as staged")
            await h.cleanup()
            return
        }
        let row = await h.record(for: card[0])
        #expect(location == row?.staged)
        #expect(h.trace.log.contains(.staged("A.JPG", location)))
        #expect(await h.engine.currentPurpose == nil) // the job has ended
        await h.cleanup()
    }

    // MARK: - iCloud Drive lost mid-job

    /// iCloud Drive goes away while staging there: the file in hand and the rest are staged on this iPhone, switched
    /// once, and the progress says why (`lostDuringImport`). Nothing fails.
    @Test(arguments: [1, 2])
    func iCloudLostMidJobStagesTheRestOnThisIPhone(_ n: Int) async throws {
        let h = Harness(downloadsInFlight: n)
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        let link = h.link(card)
        await h.iCloud.becomeUnavailable(from: 2)
        try await h.start(.items(card), from: link, to: h.stageRouteInICloud)
        #expect(await h.engine.currentPurpose == .staging)
        #expect(await h.waitFinished() == .completed)

        let lost = DestinationDecision.staging(.chosen, .onThisIPhone(.lostDuringImport))
        #expect(h.trace.count { $0.isDestinationChanged } == 1)
        #expect(h.trace.log.contains(.destinationChanged(lost)))
        let p = await h.engine.currentProgress
        #expect(p.destination == lost)
        #expect(p.destination?.stagingPlace?.fallbackReason == .lostDuringImport)
        #expect(p.filesFailed == 0)
        #expect(p.filesStaged == 4)
        let inICloud = await h.iCloud.committedNames
        let here = await h.files.committedNames
        #expect(inICloud.count == 1)
        #expect(Set(inICloud + here) == Set(card.map(\.name)))
        // Each row names the root its copy is under.
        for item in card {
            let row = try #require(await h.record(for: item))
            #expect(row.state == .new)
            #expect(row.staged?.root == (inICloud.contains(item.name) ? .iCloudDrive : .onThisIPhone))
        }
        await h.cleanup()
    }

    /// Photos refuses a save, so the rest is staged in iCloud Drive; then iCloud Drive goes too, so the rest is
    /// staged on this iPhone. Two switches, each once; the reason stays the Photos denial.
    @Test func aPhotosDenialThenALostICloudDriveEndOnThisIPhone() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        let link = h.link(card)
        await h.photos.deny(from: 2)
        await h.iCloud.becomeUnavailable(from: 2)
        h.photosAccess.set(.denied)
        try await h.start(.items(card), from: link, to: h.photosRouteStagingInICloud)
        #expect(await h.waitFinished() == .completed)
        let denied = DestinationDecision.staging(.photosDenied, .iCloudDrive)
        let lost = DestinationDecision.staging(.photosDenied, .onThisIPhone(.lostDuringImport))
        #expect(h.trace.log.filter(\.isDestinationChanged) == [.destinationChanged(denied), .destinationChanged(lost)])
        #expect(await h.photos.committedNames == ["A.JPG"])
        #expect(await h.iCloud.committedNames == ["B.JPG"])
        #expect(await h.files.committedNames == ["C.JPG", "D.JPG"])
        let p = await h.engine.currentProgress
        #expect(p.destination == lost)
        #expect(p.destination?.stagingReason?.offersSettingsLink == true)
        #expect(p.filesFailed == 0 && p.filesStaged == 3 && p.filesImported == 1)
        await h.cleanup()
    }

    /// A Photos import that loses iCloud Drive before anything is staged keeps going to Photos; only its fallback
    /// moves to this iPhone.
    @Test func losingStagingAfterADenialOfAPhotosRouteMovesOnlyItsFallback() {
        let h = Harness()
        let after = h.photosRouteStagingInICloud.afterStagingLost()
        #expect(after.decision == .photos)
        #expect(after.destination.kind == .photos)
        #expect(after.stagingPlace == .onThisIPhone(.lostDuringImport))
        #expect(!after.stagesInICloudDrive)
        let staged = h.stageRouteInICloud.afterStagingLost()
        #expect(staged.decision == .staging(.chosen, .onThisIPhone(.lostDuringImport)))
        #expect(staged.purpose == .staging)
    }

    /// Staging on this iPhone that says it is unavailable has nowhere else to go: the file fails without a retry,
    /// and nothing switches.
    @Test func stagingUnavailableOnThisIPhoneFailsTheFile() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await h.files.becomeUnavailable(from: 2)
        try await h.start(.items(card), from: link, to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await h.outcome(of: card[1]) == .failed(.destination(.stagingUnavailable)))
        #expect(await h.files.attempts == 2)
        #expect(h.trace.count { $0.isDestinationChanged } == 0)
        #expect(await h.record(for: card[1]) == nil)
        await h.cleanup()
    }

    /// An import job staged instead by a refused save never stages a file a second time: a picked file that is
    /// staged already (B, by content) is left out, saying so, and its staged copy keeps its one row.
    @Test func anImportStagedByADenialLeavesOutWhatIsStaged() async throws {
        let (h, card) = await Self.seeded()
        let link = h.link(card)
        await h.photos.deny(from: 1)
        h.photosAccess.set(.denied)
        try await h.start(.items([card[1], card[3]]), from: link, to: h.photosRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await h.files.committedNames == ["D.JPG"])
        #expect(await h.outcome(of: card[1]) == .skipped(.alreadyStaged))
        // One line for the file, as when a stage job's diff leaves it out.
        #expect(h.trace.count { $0 == .alreadyStaged("B.JPG") } == 1)
        #expect(h.trace.count { $0 == .skipped("B.JPG", .alreadyStaged) } == 0)
        #expect(await h.record(for: card[1]) == nil) // no second row with a second staged copy
        let b = h.identity(of: card[1])
        #expect(try await h.catalogue.stagedStates(of: [b]) == [b]) // the other row's copy still counts
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }

    /// An import job staged instead by a continue (Photos access turned off meanwhile) leaves out the files it had
    /// queued that are staged already, rather than staging them twice.
    @Test func anImportStagedByAContinueLeavesOutWhatIsStaged() async throws {
        let (h, card) = await Self.seeded()
        let link = h.link(card)
        await link.script("D.JPG", .hold)
        try await h.start(.items([card[3], card[1]]), from: link, to: h.photosRoute)
        let held = await link.nextHeldCall("D.JPG")
        try await h.engine.pause()
        try await h.engine.resume(to: h.stageRoute(reason: .photosDenied))
        held.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await h.photos.attempts == 0)
        #expect(await h.files.committedNames == ["D.JPG"])
        #expect(await h.outcome(of: card[1]) == .skipped(.alreadyStaged))
        #expect(h.trace.count { $0 == .alreadyStaged("B.JPG") } == 1)
        #expect(h.trace.count { $0 == .skipped("B.JPG", .alreadyStaged) } == 0)
        #expect(await h.record(for: card[1]) == nil)
        await h.cleanup()
    }

    // MARK: - The purpose holds

    /// A stage job stays one across a pause and a continue: a Photos route offered with the continue is refused, and
    /// so is moving staging from this iPhone to iCloud Drive. An import job may still be staged instead.
    @Test func aContinueNeverTurnsAStageJobIntoAnImport() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        try await h.start(.items(card), from: link, to: h.stageRoute)
        let a = await link.nextHeldCall("A.JPG")
        try await h.engine.pause()
        try await h.engine.resume(to: h.photosRoute)
        #expect(h.trace.log.contains(.routeRefused(.photos)))
        #expect(await h.engine.currentPurpose == .staging)
        try await h.engine.pause()
        try await h.engine.resume(to: h.stageRouteInICloud)
        #expect(h.trace.log.contains(.routeRefused(.staging(.chosen, .iCloudDrive))))
        a.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await h.photos.attempts == 0)
        #expect(await h.iCloud.attempts == 0)
        #expect(await h.files.committedNames == ["A.JPG", "B.JPG", "C.JPG"])
        #expect(h.trace.count { $0.isDestinationChanged } == 0)
        #expect(await h.engine.currentProgress.destination == .stagedHere(.chosen))
        await h.cleanup()
    }

    /// An import job staged instead by a continue (Photos access turned off meanwhile) becomes a stage job: what it
    /// appends then leaves out staged files.
    @Test func anImportJobStagedByAContinueAppendsAsAStageJob() async throws {
        let (h, card) = await Self.seeded()
        let e = h.item("E.JPG", size: 3000, date: Harness.t0.addingTimeInterval(10))
        let link = h.link([e] + card)
        await link.script("E.JPG", .hold)
        try await h.start(.items([e]), from: link)
        let held = await link.nextHeldCall("E.JPG")
        #expect(await h.engine.currentPurpose == .photos)
        try await h.engine.pause()
        try await h.engine.resume(to: h.stageRoute(reason: .photosDenied))
        #expect(await h.engine.currentPurpose == .staging)
        #expect(try await h.engine.append(card) == 2) // A (an explicit pick) and D; B and C are staged
        held.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await h.files.committedNames == ["E.JPG", "A.JPG", "D.JPG"])
        await h.cleanup()
    }

    /// A reconnect keeps a stage job's purpose: a Photos route offered with it is refused, and the rest is staged.
    @Test func aReconnectKeepsTheStageJob() async throws {
        let h = Harness()
        let card1 = h.singles(["A.JPG", "B.JPG"], prefix: "s1")
        let link1 = h.link(card1)
        await link1.script("B.JPG", .hold)
        try await h.start(.items(card1), from: link1, to: h.stageRoute)
        let b = await link1.nextHeldCall("B.JPG")
        link1.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        b.release(.fail(.disconnected))
        let link2 = h.link(h.singles(["A.JPG", "B.JPG"], prefix: "s2"))
        try await h.engine.reconnect(link2, to: h.photosRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(h.trace.log.contains(.routeRefused(.photos)))
        #expect(await h.photos.attempts == 0)
        #expect(await h.files.committedNames == ["A.JPG", "B.JPG"])
        await h.cleanup()
    }

    /// Over Wi-Fi, an expiry and the continue after it (a reconnect in a new session) keep the stage job: the file in
    /// flight is continued from its checkpoint and staged, written once.
    @Test func anExpiryAndItsContinueKeepTheStageJob() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.resumingLink(card)
        await link.script("B.JPG", .holdAfter(1500))
        let job = try await h.start(.items(card), from: link, to: h.stageRouteInICloud)
        await link.waitUntilHeld("B.JPG")
        await h.engine.flushCheckpoints()
        try await h.engine.pause(.taskExpired)
        link.send(.sessionLost)
        await h.trace.next(.paused(.cameraUnreachable))
        try await h.engine.reconnect(job, to: link, keepingExpiry: true)
        #expect(await h.engine.currentPurpose == .staging)
        try await h.engine.resume()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.resumes == [ResumingLink.Resume(name: "B.JPG", offset: 1500)])
        #expect(await h.iCloud.committedNames == ["A.JPG", "B.JPG"])
        #expect(await h.engine.currentProgress.destination == .staging(.chosen, .iCloudDrive))
        let row = try #require(await h.record(for: card[1]))
        #expect(row.state == .new && row.resumeOffset == 0 && row.tempURL == nil)
        #expect(row.staged?.root == .iCloudDrive)
        await h.cleanup()
    }

    /// A Wi-Fi file an earlier *import* left part-way (its checkpoint in the catalogue) is continued from that
    /// checkpoint by a later stage job and staged: the bytes are the same whatever the purpose. Its row goes back to
    /// new with the resume cleared, staged.
    @Test func aWiFiPartialFromAnImportIsResumedIntoAStageJob() async throws {
        var policy = ImportPolicy.standard
        policy.checkpointInterval = 1000
        let h = Harness(policy: policy)
        let a = h.item("A.ARW", size: 5000)
        let link = h.resumingLink([a])
        await link.script("A.ARW", .holdAfter(2400))
        try await h.start(.allNew, from: link, to: h.photosRoute)
        await h.trace.next(where: { $0 == .checkpointSaved("A.ARW", offset: 2100) })
        await link.waitUntilHeld("A.ARW")
        await h.engine.cancel()
        #expect(await h.record(for: a)?.state == .partial)

        let mark = h.trace.count
        try await h.start(.allNew, from: link, to: h.stageRoute)
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(await link.resumes == [ResumingLink.Resume(name: "A.ARW", offset: 2100)])
        #expect(await h.photos.attempts == 0)
        let staged = try Data(contentsOf: h.filesDirectory.appendingPathComponent("A.ARW"))
        #expect(staged == ResumingLink.content(of: "A.ARW", count: a.size))
        let row = try #require(await h.record(for: a))
        #expect(row.state == .new && row.resumeOffset == 0 && row.tempURL == nil)
        #expect(row.staged?.relativePath == "Untitled/A.ARW")
        #expect(h.stagedFiles == 0)
        await h.cleanup()
    }
}
