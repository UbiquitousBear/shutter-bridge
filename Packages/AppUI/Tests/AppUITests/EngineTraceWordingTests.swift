import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing
@testable import AppUI

// The engine's lines in the log (I8): the exact wording of every event, its level (each failure at error, the rest at
// notice), that no line holds a private value however hostile the input, and a whole import through the real engine whose
// lines hold no camera name, serial, address or error text. Every wait is bounded.

/// A log that keeps each line with its level, through either `note`.
final class LeveledLog: BenchLog, Sendable {
    struct Entry: Sendable, Hashable {
        var line: String
        var level: BenchLogLevel
    }

    private let stored = Mutex<[Entry]>([])

    var entries: [Entry] { stored.withLock { $0 } }
    var lines: [String] { entries.map(\.line) }

    func note(_ line: String) { note(line, level: .notice) }
    func note(_ line: String, level: BenchLogLevel) { stored.withLock { $0.append(Entry(line: line, level: level)) } }
}

@Suite("Engine trace: the log's wording")
struct EngineTraceWordingTests {
    private func line(_ event: EngineTrace) -> String? { EngineTraceWording.line(for: event) }

    // MARK: Each line

    @Test func theListingAndTheFilesDecisions() {
        #expect(line(.listed(onCard: 12, queued: 5)) == "engine: listed 12 on the card, 5 to copy")
        #expect(line(.started("DSC00001.ARW", attempt: 1)) == nil)
        #expect(line(.started("DSC00001.ARW", attempt: 2)) == "engine: copying DSC00001.ARW again, attempt 2")
        #expect(line(.retrying("DSC00001.ARW", retry: 2, until: .seconds(9)))
            == "engine: DSC00001.ARW failed, trying again (retry 2)")
        #expect(line(.retrying(EngineTrace.listingName, retry: 1, until: .seconds(9)))
            == "engine: listing the card failed, trying again (retry 1)")
        #expect(line(.stalled("DSC00001.ARW", count: 1)) == "engine: stall 1 on DSC00001.ARW, retrying")
        #expect(line(.sizeMismatch("DSC00001.ARW", expected: 100, actual: 90))
            == "engine: DSC00001.ARW came to 90 B but the camera lists 100 B")
        #expect(line(.alreadyStaged("DSC00001.ARW")) == "engine: skipped DSC00001.ARW: already staged")
        #expect(line(.rejectedLeftOut("DSC00001.ARW")) == "engine: skipped DSC00001.ARW: rejected")
        #expect(line(.sameFileListedTwice("DSC00001.ARW"))
            == "engine: left out a second copy of DSC00001.ARW listed in another folder")
        #expect(line(.waitingForPartner("DSC00001.ARW")) == nil)
        #expect(line(.committedWithoutPartner("DSC00001.ARW"))
            == "engine: committed DSC00001.ARW without the other half of its pair")
        #expect(line(.identityChanged("DSC00001.ARW"))
            == "engine: DSC00001.ARW changed on the camera since its partial copy began; copying it again")
        #expect(line(.checkpointSaved("DSC00001.ARW", offset: 16_777_216)) == "engine: checkpoint DSC00001.ARW at 16777216 B")
        #expect(line(.waitingForCheckpointWrites("DSC00001.ARW"))
            == "engine: DSC00001.ARW is waiting for a checkpoint write before its row")
        #expect(line(.checkpointWritesUnsettled("DSC00001.ARW"))
            == "engine: DSC00001.ARW's row was written without the checkpoint write it waited for")
        #expect(line(.commitMarkerNotWritten("DSC00001.ARW"))
            == "engine: catalogue unavailable: DSC00001.ARW wasn't committed and goes back in the queue")
        #expect(line(.jobRecordNotWritten)
            == "engine: the job's History record couldn't be written; trying again at its next change")
    }

    @Test func skipsSayWhy() {
        #expect(line(.skipped("DSC00001.ARW", .link(.itemNotFound))) == "engine: skipped DSC00001.ARW: no longer on the card")
        #expect(line(.skipped("DSC00001.ARW", .link(.unreadableItem)))
            == "engine: skipped DSC00001.ARW: the camera couldn't read it")
        #expect(line(.skipped("C0001.MP4", .link(.unsupportedFormat))) == "engine: skipped C0001.MP4: a format that isn't imported")
        #expect(line(.skipped("C0001.MP4", .notAStill)) == "engine: skipped C0001.MP4: not a still")
        #expect(line(.skipped("DSC00004.ARW", .noCaptureDate)) == "engine: skipped DSC00004.ARW: no capture date")
        #expect(line(.skipped("DSC00001.ARW", .alreadyStaged)) == "engine: skipped DSC00001.ARW: already staged")
    }

    @Test func failuresSayWhy() {
        #expect(line(.failed("DSC00001.ARW", .link(.busy))) == "engine: failed DSC00001.ARW: the camera was busy")
        #expect(line(.failed("DSC00001.ARW", .link(.phoneStorageFull))) == "engine: failed DSC00001.ARW: this iPhone is full")
        #expect(line(.failed("DSC00001.ARW", .sizeMismatch(expected: 100, actual: 90)))
            == "engine: failed DSC00001.ARW: it came to 90 B but the camera lists 100 B")
        #expect(line(.failed("DSC00001.ARW", .destination(.notEnoughSpace)))
            == "engine: failed DSC00001.ARW: this iPhone has no room")
        #expect(line(.failed("DSC00001.ARW", .destination(.stagedFileMissing)))
            == "engine: failed DSC00001.ARW: the downloaded file was gone")
        #expect(line(.failed("DSC00001.ARW", .destination(.stagingUnavailable)))
            == "engine: failed DSC00001.ARW: the staging folder was unavailable")
        #expect(line(.failed("DSC00001.ARW", .destination(.photosAccessDenied)))
            == "engine: failed DSC00001.ARW: Photos access is denied")
        #expect(line(.failed("DSC00001.ARW", .destination(.rejected(detail: "PHPhotosErrorDomain 3301"))))
            == "engine: failed DSC00001.ARW: the destination rejected it")
    }

    @Test func pausesContinuesAndTheCamerasEvents() {
        #expect(line(.paused(.cameraRemoved)) == "engine: paused (the camera was removed)")
        #expect(line(.paused(.appInBackground)) == "engine: paused (the app left the foreground)")
        #expect(line(.paused(.stalled)) == "engine: paused (a download stalled)")
        #expect(line(.paused(.cameraUnreachable)) == "engine: paused (the camera is unreachable)")
        #expect(line(.paused(.needsJoin)) == "engine: paused (the phone needs to join the camera's network)")
        #expect(line(.resumed) == "engine: continued")
        #expect(line(.linkEvent(.sessionLost(generation: 2))) == "engine: camera link: session lost")
        #expect(line(.linkEvent(.storeRemoved)) == "engine: camera link: card removed from the session")
        #expect(line(.linkEvent(.removed)) == "engine: camera link: removed")
        // Every pause and every event has words.
        for reason in PauseReason.allCases { #expect(line(.paused(reason))?.hasPrefix("engine: paused (") == true) }
    }

    @Test func destinationsAndRoutes() {
        #expect(line(.destinationChanged(.photos)) == "engine: the destination is now Photos")
        #expect(line(.destinationChanged(.staging(.photosDenied, .onThisIPhone(.containerUnavailable))))
            == "engine: the destination is now staging on this iPhone (Photos access is off)")
        #expect(line(.destinationChanged(.staging(.chosen, .iCloudDrive))) == "engine: the destination is now staging in iCloud Drive")
        #expect(line(.routeRefused(.photos)) == "engine: kept the job's destination; Photos isn't allowed mid-job")
    }

    @Test func jobEnds() {
        #expect(line(.finished(.completed)) == "engine: job finished: completed")
        #expect(line(.finished(.cancelled)) == "engine: job finished: cancelled")
        #expect(line(.finished(.stopped(.phoneStorageFull))) == "engine: job stopped: this iPhone is full")
        #expect(line(.finished(.catalogueUnavailable)) == "engine: catalogue unavailable: the job stopped")
        // A keepers job Photos refused (I12): stopped, nothing staged, at notice (the person's setting, not a failure).
        #expect(line(.finished(.photosAccessNeeded(.denied)))
            == "engine: job stopped: Photos refused the save (access denied); nothing staged")
        #expect(line(.finished(.photosAccessNeeded(.restricted)))
            == "engine: job stopped: Photos refused the save (access restricted); nothing staged")
    }

    @Test func theReconnectLinesTheBenchSheetReads() {
        #expect(line(.reconnected(.usb, sinceLost: .milliseconds(3_040), filesLeft: 7))
            == "engine: job resumed after a reconnect (usb), 3.0 s after the camera went away, 7 files left")
        #expect(line(.reconnected(.wifi, sinceLost: .seconds(12), filesLeft: 1))
            == "engine: job resumed after a reconnect (wifi), 12.0 s after the camera went away, 1 file left")
        #expect(line(.reconnected(.wifi, sinceLost: nil, filesLeft: 0))
            == "engine: job resumed after a reconnect (wifi), 0 files left")
        #expect(line(.firstByteAfterReconnect("DSC00001.ARW", bytes: 16_777_216 + 65_536, sinceResumed: .milliseconds(1_250)))
            == "engine: first byte after the reconnect: DSC00001.ARW at 16842752 B, 1.3 s after the job resumed")
    }

    @Test func theLinesForPartialsAndSessionsBetweenLaunches() {
        #expect(line(.lateSessionLossIgnored(generation: 1))
            == "engine: ignored a late loss of session 1, which the reconnect replaced")
        #expect(line(.partialReset("DSC00001.ARW"))
            == "engine: the partial copy of DSC00001.ARW is gone; it will be copied from its start")
    }

    /// One line per pending commit resolved (I15): the camera file name and the outcome only.
    @Test func theLinesForPendingCommitsResolved() {
        #expect(line(.pendingCommitResolved("DSC00001.ARW", .replayed))
            == "engine: interrupted commit of DSC00001.ARW: its row was written from memory")
        #expect(line(.pendingCommitResolved("DSC00001.ARW", .foundInPhotos))
            == "engine: interrupted commit of DSC00001.ARW: found in Photos, marked imported")
        #expect(line(.pendingCommitResolved("DSC00001.ARW", .foundInStaging))
            == "engine: interrupted commit of DSC00001.ARW: found in Staging, marked staged")
        #expect(line(.pendingCommitResolved("DSC00001.ARW", .notFound))
            == "engine: interrupted commit of DSC00001.ARW: not found, so it reads as not imported")
        #expect(line(.pendingCommitResolved("DSC00001.ARW", .possibleDuplicate))
            == "engine: interrupted commit of DSC00001.ARW: not found with Limited Access, so it may be imported twice")
        #expect(line(.pendingCommitResolved("DSC00001.ARW", .waiting))
            == "engine: interrupted commit of DSC00001.ARW: can't be checked yet; kept for the next pass")
        for resolution in PendingCommitResolution.allCases {
            #expect(EngineTraceWording.level(for: .pendingCommitResolved("A.JPG", resolution)) == .notice)
        }
    }

    @Test func eventsThatHaveNoLine() {
        #expect(line(.imported("A.JPG", .photos)) == nil) // the import model's line carries it
        #expect(line(.staged("A.JPG", nil)) == nil)
        #expect(line(.idle(queued: 1, inFlight: 0)) == nil)
        #expect(line(.tick(.seconds(1))) == nil)
        #expect(line(.published(.seconds(1))) == nil)
        #expect(line(.discardedLateFile) == nil)
    }

    // MARK: Levels

    /// One event of every case, so a new case can't be left without a level.
    private var everyCase: [EngineTrace] {
        [
            .listed(onCard: 1, queued: 1), .started("A.JPG", attempt: 1), .retrying("A.JPG", retry: 1, until: .zero),
            .stalled("A.JPG", count: 1), .sizeMismatch("A.JPG", expected: 2, actual: 1), .imported("A.JPG", .staging),
            .staged("A.JPG", nil), .alreadyStaged("A.JPG"), .skipped("A.JPG", .noCaptureDate),
            .sameFileListedTwice("A.JPG"), .failed("A.JPG", .link(.busy)), .waitingForPartner("A.ARW"),
            .committedWithoutPartner("A.ARW"), .destinationChanged(.photos),
            .routeRefused(.photos), .linkEvent(.removed), .paused(.byPerson), .resumed, .idle(queued: 0, inFlight: 0),
            .tick(.zero), .published(.zero), .discardedLateFile, .checkpointSaved("A.JPG", offset: 1),
            .waitingForCheckpointWrites("A.JPG"), .checkpointWritesUnsettled("A.JPG"),
            .identityChanged("A.JPG"), .finished(.completed), .finished(.cancelled), .finished(.stopped(.refused)),
            .finished(.catalogueUnavailable), .finished(.photosAccessNeeded(.denied)),
            .reconnected(.usb, sinceLost: .zero, filesLeft: 0), .reconnected(.staging, sinceLost: nil, filesLeft: 1),
            .firstByteAfterReconnect("A.JPG", bytes: 1, sinceResumed: .zero), .commitMarkerNotWritten("A.ARW"),
            .jobRecordNotWritten, .lateSessionLossIgnored(generation: 1), .partialReset("A.JPG"),
            .rejectedLeftOut("A.JPG"),
            .pendingCommitResolved("A.JPG", .foundInPhotos),
        ]
    }

    @Test func everyFailureIsAnErrorAndEverythingElseIsANotice() {
        let errors: Set<String> = ["failed", "finished(stopped)", "finished(catalogueUnavailable)",
                                   "commitMarkerNotWritten"]
        for event in everyCase {
            let name = Self.name(of: event)
            #expect(EngineTraceWording.level(for: event) == (errors.contains(name) ? .error : .notice), "\(name)")
        }
        // The failures of every kind and reason are errors, whatever the reason.
        for kind in CameraLinkFailure.Kind.allCases {
            #expect(EngineTraceWording.level(for: .failed("A.JPG", .link(kind))) == .error)
            #expect(EngineTraceWording.level(for: .finished(.stopped(kind))) == .error)
            #expect(EngineTraceWording.level(for: .skipped("A.JPG", .link(kind))) == .notice)
        }
        for failure in [ImportDestinationFailure.photosAccessDenied, .notEnoughSpace, .stagedFileMissing,
                        .stagingUnavailable, .rejected(detail: "x")] {
            #expect(EngineTraceWording.level(for: .failed("A.JPG", .destination(failure))) == .error)
        }
        // Pauses, stalls, skips and the reconnect lines stay at notice.
        for reason in PauseReason.allCases { #expect(EngineTraceWording.level(for: .paused(reason)) == .notice) }
    }

    @Test func everyEventThatHasALineHasAnEngineLineOnOneRow() {
        for event in everyCase {
            guard let text = line(event) else { continue }
            #expect(text.hasPrefix("engine: "), "\(text)")
            #expect(!text.contains("\n"))
        }
    }

    private static func name(of event: EngineTrace) -> String {
        switch event {
        case .failed: "failed"
        case .finished(.stopped): "finished(stopped)"
        case .finished(.catalogueUnavailable): "finished(catalogueUnavailable)"
        case .commitMarkerNotWritten: "commitMarkerNotWritten"
        default: "other"
        }
    }

    // MARK: Nothing private

    @Test func aHostileNameOrDetailNeverWritesASecondLineOrCarriesTheDetail() throws {
        let serial = "7654321"
        let name = "DSC\n2026-11-11T10:00:00Z error [browse] serial \(serial)\u{0}\u{7}.ARW"
        // The checkpoint-wait and lone-half lines carry a name too, so they clean it the same way.
        for event in [EngineTrace.waitingForCheckpointWrites(name), .checkpointWritesUnsettled(name),
                      .committedWithoutPartner(name), .commitMarkerNotWritten(name), .partialReset(name),
                      .rejectedLeftOut(name), .pendingCommitResolved(name, .possibleDuplicate)] {
            let waiting = try #require(line(event))
            #expect(!waiting.contains("\n") && !waiting.contains("\u{0}") && !waiting.contains("\u{7}"))
        }
        let text = try #require(line(.failed(name, .destination(.rejected(detail: "serial \(serial) at 192.168.1.20 DIRECT-Qx7k")))))
        #expect(!text.contains("\n") && !text.contains("\u{0}") && !text.contains("\u{7}"))
        #expect(!text.contains("192.168.1.20") && !text.contains("DIRECT-Qx7k"))
        #expect(text.hasSuffix("the destination rejected it"))
        // A very long name is cut.
        let long = String(repeating: "A", count: 500) + ".ARW"
        let cut = try #require(line(.skipped(long, .notAStill)))
        #expect(cut.count < 120)
    }

    // MARK: The sink

    @Test func theBenchSinkWritesEachLineAtItsLevelAndDropsTheRest() {
        let log = LeveledLog()
        let sink = EngineTraceSink.bench(log)
        #expect(sink.isOn)
        for event in [EngineTrace.tick(.zero), .paused(.cameraRemoved), .imported("A.JPG", .photos),
                      .failed("A.JPG", .link(.busy)), .finished(.catalogueUnavailable)] {
            sink.record(event)
        }
        #expect(log.entries == [
            .init(line: "engine: paused (the camera was removed)", level: .notice),
            .init(line: "engine: failed A.JPG: the camera was busy", level: .error),
            .init(line: "engine: catalogue unavailable: the job stopped", level: .error),
        ])
    }
}

// MARK: - A whole import

/// Whole imports through the real engine and the simulated camera (the camera's name and serial carry fake private values),
/// with the engine's trace going to a log: every line is the engine's, none holds a private value, and the levels are the
/// failures' alone.
@Suite("Engine trace: a whole import's lines", .timeLimit(.minutes(2)))
struct EngineTraceWholeImportTests {
    private let cameraName = "Shamil's A7C II 7654321"
    private let serial = "7654321"

    private func run(destination: any ImportDestination, to place: StagingPlace = testStagingPlace) async throws -> LeveledLog {
        let log = LeveledLog()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUITests-trace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ImportEngine(catalogue: InMemoryCatalogue(),
                                  stagingDirectory: root.appendingPathComponent("staging", isDirectory: true),
                                  trace: .bench(log))
        let link = SimulatedCameraLink(card: standInCard(), name: cameraName, chunkSize: 4096)
        let route = ImportRoute.staging(destination, reason: .chosen, place: place, onThisIPhone: destination)
        try await engine.start(.allNew, from: link, camera: CameraKey(rawValue: serial), to: route)
        // Bounded: the suite's time limit ends a job that never finishes.
        while await engine.state.isActive { try await Task.sleep(for: .milliseconds(5)) }
        await link.close()
        return log
    }

    private func expectClean(_ log: LeveledLog) {
        for entry in log.entries {
            #expect(entry.line.hasPrefix("engine: "), "\(entry.line)")
            for private_ in [cameraName, serial, "Shamil", "192.168", "7654321"] {
                #expect(!entry.line.contains(private_), "\(entry.line)")
            }
        }
    }

    @Test func aCleanImportHasNoErrorLine() async throws {
        let log = try await run(destination: RecordingDestination(kind: .staging))
        // The card's undated RAW is left out and said so (D10) as the listing is read; then the listing's line.
        #expect(log.lines.first == "engine: skipped DSC00004.ARW: no capture date")
        #expect(log.lines.dropFirst().first?.hasPrefix("engine: listed ") == true)
        #expect(log.lines.contains("engine: job finished: completed"))
        #expect(!log.entries.contains { $0.level == .error })
        expectClean(log)
    }

    @Test func aFileTheDestinationRefusesIsOneErrorLineWithoutTheDetail() async throws {
        let log = try await run(destination: RefusingDestination(detail: "serial \(serial) DIRECT-Qx7k 192.168.1.20"))
        let errors = log.entries.filter { $0.level == .error }
        #expect(!errors.isEmpty)
        #expect(errors.allSatisfy { $0.line.contains("failed ") && $0.line.hasSuffix("the destination rejected it") })
        expectClean(log)
        #expect(!log.lines.contains { $0.contains("DIRECT") })
    }
}

/// A destination that refuses every file, with detail text that a log must never carry.
struct RefusingDestination: ImportDestination {
    let detail: String
    var kind: DestinationKind { .staging }

    func commitTarget(for unit: CommitUnit) -> CommitTarget {
        .stagingFolder(place: testStagingPlace, folderPath: "Staging/Untitled")
    }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        throw .rejected(detail: detail)
    }
}
