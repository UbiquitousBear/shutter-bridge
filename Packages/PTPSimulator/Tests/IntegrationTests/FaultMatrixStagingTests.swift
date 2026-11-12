import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Testing

/// The fault matrix's stage-job cases (backlog section 3; I15): iCloud Drive lost mid-job, the on-iPhone fallback
/// holding for the rest of the job across a cut and a continue, and the phone filling up while staging. Each runs the
/// real engine over the simulated camera, and asserts no duplicates and no loss across Staging (both roots) through
/// `MatrixBench.verify`: every staged file goes through the bench's staging fake, iCloud Drive's commits included
/// (`ICloudDriveStaging`), so a file staged once in iCloud Drive and again on this iPhone is a duplicate the check sees.
@Suite("Fault matrix: stage jobs", .timeLimit(.minutes(2)))
struct FaultMatrixStagingTests {
    private static let usbAndWiFi: [MatrixLink] = [.usbMTP, .usbMSC, .wifi]

    private static func keys(_ objects: [ScriptedCard.Object]) -> Set<String> { MatrixBench.keys(objects) }

    /// A stage job into iCloud Drive, falling back to the bench's staging folder on this iPhone.
    private static func iCloudRoute(_ bench: MatrixBench, _ iCloud: ICloudDriveStaging) -> ImportRoute {
        .staging(iCloud, reason: .chosen, place: .iCloudDrive, onThisIPhone: bench.staging)
    }

    private static let lost = DestinationDecision.staging(.chosen, .onThisIPhone(.lostDuringImport))

    /// Opens `link` and starts a stage job into iCloud Drive on it.
    @discardableResult
    private static func start(_ bench: MatrixBench, _ link: SimulatedCameraLink, _ iCloud: ICloudDriveStaging) async throws
        -> ImportJobID {
        try await link.open()
        return try await bench.engine.start(.allNew, from: link, camera: MatrixBench.camera, to: iCloudRoute(bench, iCloud))
    }

    /// Polls (bounded, as the bench's waits are) until the job's route reads `decision`.
    private static func waitForDecision(_ bench: MatrixBench, _ decision: DestinationDecision,
                                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: MatrixBench.patience)
        while await bench.engine.currentProgress.destination != decision {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for the route \(decision)", sourceLocation: sourceLocation)
                throw MatrixTimeout(what: "the route \(decision)")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Each committed file's row names the root it was staged under: iCloud Drive for the files `iCloud` took, this
    /// iPhone for the rest.
    private static func expectRoots(_ bench: MatrixBench, _ card: ScriptedCard, iCloud: Set<String>,
                                    sourceLocation: SourceLocation = #_sourceLocation) async {
        for object in card.objects {
            guard let staged = await bench.record(of: object)?.staged else { continue }
            let want: StagingRoot = iCloud.contains(object.filename) ? .iCloudDrive : .onThisIPhone
            #expect(staged.root == want, "\(object.filename) staged under \(staged.root), expected \(want)",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: iCloud Drive lost mid-job

    /// iCloud Drive goes (signed out, or iCloud Drive turned off) after the first unit: the unit whose commit found it
    /// gone and the rest are staged on this iPhone, the route says so, every file is staged once across the two roots
    /// with its row under the root it went to, and no pending-commit marker is left.
    @Test("iCloud Drive lost mid-job", arguments: Self.usbAndWiFi, [1, 2])
    func iCloudLostMidJob(_ flavour: MatrixLink, _ inFlight: Int) async throws {
        let bench = MatrixBench(inFlight: inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, flavour)
        let iCloud = ICloudDriveStaging(over: bench.staging)
        await iCloud.lose(from: 2)
        try await Self.start(bench, link, iCloud)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: .stage)

        #expect(await bench.engine.currentProgress.destination == Self.lost)
        let inICloud = await iCloud.names
        // The first unit (a RAW+JPEG pair) went to iCloud Drive; no file whose commit found it gone did.
        #expect(inICloud.count == 2, "staged in iCloud Drive: \(inICloud)")
        await Self.expectRoots(bench, card, iCloud: Set(inICloud))
        #expect(await bench.catalogue.pendingCommits().isEmpty)
        await bench.finish()
    }

    // MARK: The on-iPhone fallback

    /// Once iCloud Drive is lost, the job stays on this iPhone: a cut mid-file (a pulled cable, a Wi-Fi drop) and a
    /// reconnect that offers iCloud Drive again (it's back) don't move it back half-way, so the interrupted file and
    /// the rest are staged on this iPhone, each once. The next stage job, with iCloud Drive back, stages only the
    /// frames shot since, into iCloud Drive: nothing staged on this iPhone is staged again.
    @Test("The on-iPhone fallback holds for the rest of the job", arguments: Self.usbAndWiFi)
    func onThisIPhoneFallbackHolds(_ flavour: MatrixLink) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, flavour)
        let iCloud = ICloudDriveStaging(over: bench.staging)
        await iCloud.lose(from: 2)
        let victim = try #require(MatrixBench.frame(card, fromNewest: 2).first)
        await link.script(victim.filename, .holdAfter(victim.size / 2))
        let job = try await Self.start(bench, link, iCloud)
        _ = try await bench.waitHeld([victim], atLeast: 1) { $0.size / 2 }
        try await Self.waitForDecision(bench, Self.lost)

        let back = ICloudDriveStaging(over: bench.staging)
        var camera = link // the link the camera is on now: a replug makes a new one
        if flavour.isWiFi {
            await link.loseSession()
            try await bench.waitPaused(.cameraUnreachable)
            try await link.open()
            let known = try await link.list()
            try await bench.engine.reconnect(job, to: link, knownItems: known, route: Self.iCloudRoute(bench, back))
        } else {
            await link.remove()
            try await bench.waitPaused(.cameraRemoved)
            camera = await bench.replugged(link)
            try await bench.engine.reconnect(camera, to: Self.iCloudRoute(bench, back))
        }
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: .stage)
        #expect(await bench.engine.currentProgress.destination == Self.lost)
        #expect(await back.attempts == 0, "nothing went back to iCloud Drive mid-job")
        await Self.expectRoots(bench, card, iCloud: Set(await iCloud.names))

        // iCloud Drive is back for the next job, in a later launch: only the frame shot since is staged, there.
        let shot = await camera.shoot([.rawPlusJPEG])
        let all = await camera.card
        #expect(shot.count == 2)
        bench.relaunch()
        try await Self.start(bench, camera, back)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([all], committed: Self.keys(all.objects), purpose: .stage)
        #expect(Set(await back.names) == Set(shot.map(\.name)))
        #expect(await bench.catalogue.pendingCommits().isEmpty)
        await bench.finish()
    }

    // MARK: Storage full while staging

    /// iCloud Drive is lost, then this iPhone's staging folder finds the phone full: the job stops, what was staged
    /// stays staged under its root, and the next stage job, with room and iCloud Drive back, stages the rest once,
    /// across the two roots.
    @Test("Phone storage full while staging, after iCloud Drive went", arguments: Self.usbAndWiFi, [1, 2])
    func storageFullWhileStaging(_ flavour: MatrixLink, _ inFlight: Int) async throws {
        let bench = MatrixBench(inFlight: inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, flavour)
        let iCloud = ICloudDriveStaging(over: bench.staging)
        await iCloud.lose(from: 2)
        // The staging fake's second commit is the first on this iPhone (iCloud Drive's first went through it).
        await bench.staging.fail(attempt: 2, with: .notEnoughSpace)
        try await Self.start(bench, link, iCloud)
        #expect(try await bench.waitFinished() == .stopped(.phoneStorageFull))
        let got = await bench.committedKeys([card])
        await bench.verify([card], committed: got, skipped: Self.keys(card.objects).subtracting(got), purpose: .stage)
        await Self.expectRoots(bench, card, iCloud: Set(await iCloud.names))

        // Room again, and iCloud Drive back, in a later launch.
        let back = ICloudDriveStaging(over: bench.staging)
        bench.relaunch()
        try await Self.start(bench, link, back)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: .stage)
        let inICloud = Set((await iCloud.names) + (await back.names))
        await Self.expectRoots(bench, card, iCloud: inICloud)
        #expect(await bench.catalogue.pendingCommits().isEmpty)
        await bench.finish()
    }
}

/// iCloud Drive's staging folder, for the stage-job cases: each commit goes through the bench's staging fake (so
/// `MatrixBench.verify` sees every staged file, whichever root it went to) and is reported as staged in iCloud Drive,
/// until iCloud Drive goes away: from a given commit on, every commit fails `.stagingUnavailable` before anything is
/// moved, as the real folder does when the container goes.
actor ICloudDriveStaging: ImportDestination {
    nonisolated var kind: DestinationKind { .staging }
    private let inner: RecordingDestination
    private var lostFrom: Int?
    /// Every commit call, failed or not.
    private(set) var attempts = 0
    /// The camera file names of every file staged here.
    private(set) var names: [String] = []

    init(over inner: RecordingDestination) { self.inner = inner }

    /// From this attempt (1-based) on, iCloud Drive is gone.
    func lose(from attempt: Int) { lostFrom = attempt }

    nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget {
        .stagingFolder(place: .iCloudDrive, folderPath: "Staging/Matrix")
    }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        attempts += 1
        if let lostFrom, attempts >= lostFrom { throw .stagingUnavailable }
        let result = try await inner.commit(unit)
        names += unit.files.map(\.filename)
        guard case let .staged(_, locations) = result else { return result }
        return .staged(place: .iCloudDrive, locations)
    }
}
