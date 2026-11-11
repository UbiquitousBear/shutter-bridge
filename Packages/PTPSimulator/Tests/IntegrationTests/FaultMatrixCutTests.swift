import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

/// The fault matrix's cuts (backlog section 3): the camera or the link going away part-way through a file, at 10, 50
/// and 99 % of it, with 1 and 2 downloads in flight on USB, in MTP and MSC keying, for an import to Photos and for a
/// stage job. After each case recovers, `MatrixBench.verify` asserts no duplicates and no loss.
@Suite("Fault matrix: cuts", .timeLimit(.minutes(2)))
struct FaultMatrixCutTests {
    /// The frame the cuts fall in: the second from the newest, so the newest frame is committed before the cut and
    /// must not be copied again after it.
    static let victimFrame = 1

    /// Holds the first `downloads` files of the victim frame at `percent` of their size: the files the engine copies
    /// when the cut falls (RAW first, then JPEG). Only those are scripted, so a file that waits its turn is not held
    /// when it is finally copied.
    private func holdVictims(_ card: ScriptedCard, _ link: SimulatedCameraLink, percent: UInt64,
                             downloads: Int) async -> [ScriptedCard.Object] {
        let victims = Array(MatrixBench.frame(card, fromNewest: Self.victimFrame).prefix(downloads))
        for v in victims { await link.script(v.filename, .holdAfter(v.size * percent / 100)) }
        return victims
    }

    /// The newest frame is done (committed) before the cut: its files are resolved, so a verification in the middle
    /// of the pause has a settled destination to look at.
    private func waitForNewestFrame(_ bench: MatrixBench, _ card: ScriptedCard) async throws {
        let done = MatrixBench.keys(MatrixBench.frame(card, fromNewest: 0))
        try await bench.waitForFiles("the newest frame committed") { files in
            let resolved = files.filter {
                switch $0.phase {
                case .imported, .staged: true
                default: false
                }
            }.map { MatrixBench.key($0.item) }
            return done.isSubset(of: Set(resolved))
        }
    }

    // MARK: Cable pulled (removal) mid-file

    /// USB: the cable is pulled mid-file; the job waits for the camera, nothing counts as failed, the partial file
    /// is gone (USB can't continue one); the replug lists the card again and every file is copied once, the
    /// interrupted ones again from their start.
    @Test("Cable pulled mid-file", arguments: MatrixCase.usb)
    func cablePulledMidFile(_ c: MatrixCase) async throws {
        let bench = MatrixBench(inFlight: c.inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, c.link)
        let victims = await holdVictims(card, link, percent: c.percent, downloads: c.downloads)
        try await bench.start(link, c.purpose)
        let held = try await bench.waitHeld(victims, atLeast: c.downloads) { $0.size * c.percent / 100 }
        try await waitForNewestFrame(bench, card)

        await link.remove()
        try await bench.waitPaused(.cameraRemoved)
        let paused = await bench.engine.currentProgress
        #expect(paused.filesFailed == 0 && paused.filesSkipped == 0) // retry on reconnect, never a failure
        await bench.verify([card], committed: MatrixBench.keys(MatrixBench.frame(card, fromNewest: 0)), job: false)

        let again = await bench.replugged(link)
        try await bench.engine.reconnect(again)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: MatrixBench.keys(card.objects), purpose: c.purpose)
        #expect(await again.resumes.isEmpty) // USB doesn't resume: nothing continued a partial file
        let asked = await again.bytesCalls
        for v in held { #expect(asked.contains(v.filename), "\(v.filename) was copied again from its start") }
        for v in MatrixBench.frame(card, fromNewest: 0) {
            #expect(!asked.contains(v.filename), "\(v.filename) was committed before the cut and not copied again")
        }
        await bench.finish()
    }

    // MARK: Wi-Fi drop, reconnect at the same address

    /// Wi-Fi: the session is lost mid-file; the partial file and its row are kept; the reopen lists nothing again and
    /// the file continues from its checkpoint; every file is copied once.
    @Test("Wi-Fi dropped mid-file, reconnected at the same address", arguments: MatrixCase.wifi)
    func wifiDropMidFile(_ c: MatrixCase) async throws {
        let bench = MatrixBench(inFlight: c.inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, c.link)
        let victims = await holdVictims(card, link, percent: c.percent, downloads: c.downloads)
        try await bench.start(link, c.purpose)
        let job = try #require(await bench.engine.currentJobID)
        let held = try await bench.waitHeld(victims, atLeast: 1) { $0.size * c.percent / 100 }
        #expect(held.count == 1) // one transaction at a time, whatever the setting
        let victim = try #require(held.first)
        let cut = victim.size * c.percent / 100
        try await waitForNewestFrame(bench, card)

        await link.loseSession()
        try await bench.waitPaused(.cameraUnreachable)
        #expect(await bench.engine.currentProgress.filesFailed == 0)
        let row = try await bench.waitForRow(of: victim, "the partial row at the cut") {
            $0?.state == .partial && $0?.resumeOffset == cut
        }
        #expect(row?.state == .partial)
        await bench.verify([card], committed: MatrixBench.keys(MatrixBench.frame(card, fromNewest: 0)),
                           partials: [MatrixBench.key(victim)], job: false)

        try await link.open()
        let known = try await link.list()
        try await bench.engine.reconnect(job, to: link, knownItems: known)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: MatrixBench.keys(card.objects), purpose: c.purpose)
        #expect(await link.resumes == [SimulatedCameraLink.Resume(filename: victim.filename, offset: cut)])
        #expect(await link.listCount == 2) // the engine's first listing and the app's reopen; none after it
        await bench.finish()
    }

    // MARK: Wi-Fi reconnect at a different address

    /// A camera that comes back somewhere else: another port on its address (nothing listens at the old port: refused),
    /// or another address (nothing answers). The link finds it only through the location provider, as the app's
    /// locator does; once it does, the file continues from its checkpoint and every file is copied once. The wire
    /// version of this (a server restarted on another port) is `PTPIPSimulatorServer`'s, which needs Network.framework.
    enum Move: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case anotherPort, anotherAddress

        var location: PTPIPEndpoint {
            switch self {
            case .anotherPort: PTPIPEndpoint(host: PTPIPEndpoint.cameraNetwork.host, port: 15_741)
            case .anotherAddress: PTPIPEndpoint(host: "192.0.2.7")
            }
        }

        /// What dialling the old place answers.
        var staleAnswer: CameraLinkFailure.Kind {
            switch self {
            case .anotherPort: .refused
            case .anotherAddress: .disconnected
            }
        }

        var testDescription: String { rawValue }
    }

    final class Locator: Sendable {
        private let found = Mutex(PTPIPEndpoint.cameraNetwork)
        var location: PTPIPEndpoint { found.withLock { $0 } }
        func found(_ location: PTPIPEndpoint) { found.withLock { $0 = location } }
    }

    static let moveCases: [(Move, UInt64, MatrixPurpose)] = Move.allCases.flatMap { move in
        MatrixCase.offsets.flatMap { percent in MatrixPurpose.allCases.map { (move, percent, $0) } }
    }

    @Test("Wi-Fi camera reconnects at a different address", arguments: moveCases.map { MoveCase($0.0, $0.1, $0.2) })
    func wifiReconnectAtADifferentAddress(_ c: MoveCase) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let locator = Locator()
        let link = bench.link(card, .wifi, locationProvider: { locator.location })
        let victims = await holdVictims(card, link, percent: c.percent, downloads: c.downloads)
        try await bench.start(link, c.purpose)
        let job = try #require(await bench.engine.currentJobID)
        let victim = try #require(try await bench.waitHeld(victims, atLeast: 1) { $0.size * c.percent / 100 }.first)
        let cut = victim.size * c.percent / 100

        await link.moveCamera(to: c.move.location)
        try await bench.waitPaused(.cameraUnreachable)
        _ = try await bench.waitForRow(of: victim, "the partial row at the cut") {
            $0?.state == .partial && $0?.resumeOffset == cut
        }

        // The app dials where it last knew the camera: nobody there, and the job keeps waiting.
        do throws(CameraLinkFailure) {
            try await link.open()
            Issue.record("the old address answered")
        } catch {
            #expect(error.kind == c.move.staleAnswer)
        }
        #expect(await bench.engine.state == .paused(.cameraUnreachable))

        locator.found(c.move.location)
        try await link.open()
        #expect(await link.dialLocation == c.move.location)
        let known = try await link.list()
        try await bench.engine.reconnect(job, to: link, knownItems: known)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: MatrixBench.keys(card.objects), purpose: c.purpose)
        #expect(await link.resumes == [SimulatedCameraLink.Resume(filename: victim.filename, offset: cut)])
        await bench.finish()
    }

    // MARK: Camera powers off (battery)

    /// USB: the camera leaves the bus and never comes back: the job stays paused, not failed, however long it waits
    /// on the clock; when it is switched on and plugged in again an hour later, the job finishes.
    @Test("Camera powers off over USB, back an hour later", arguments: MatrixCase.halfway.filter { !$0.link.isWiFi })
    func powerOffOverUSB(_ c: MatrixCase) async throws {
        let bench = MatrixBench(inFlight: c.inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, c.link)
        let victims = await holdVictims(card, link, percent: c.percent, downloads: c.downloads)
        try await bench.start(link, c.purpose)
        _ = try await bench.waitHeld(victims, atLeast: c.downloads) { $0.size * c.percent / 100 }
        try await waitForNewestFrame(bench, card)

        await link.powerOff()
        try await bench.waitPaused(.cameraRemoved)
        await bench.advance(.seconds(3600))
        try await Task.sleep(for: .milliseconds(50)) // the engine's tick at the new time
        #expect(await bench.engine.state == .paused(.cameraRemoved))
        let progress = await bench.engine.currentProgress
        #expect(progress.filesFailed == 0 && progress.filesSkipped == 0)
        await bench.verify([card], committed: MatrixBench.keys(MatrixBench.frame(card, fromNewest: 0)), job: false)

        await link.powerOn()
        let again = await bench.replugged(link)
        try await bench.engine.reconnect(again)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: MatrixBench.keys(card.objects), purpose: c.purpose)
        await bench.finish()
    }

    /// Wi-Fi: the session is lost and the camera never answers (every open fails as disconnected): the job stays
    /// paused, the partial row and file are kept an hour on, and the reconnect then continues the file from its
    /// checkpoint.
    @Test("Camera powers off over Wi-Fi, back an hour later", arguments: MatrixCase.halfway.filter { $0.link.isWiFi })
    func powerOffOverWiFi(_ c: MatrixCase) async throws {
        let bench = MatrixBench(inFlight: c.inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, c.link)
        let victims = await holdVictims(card, link, percent: c.percent, downloads: c.downloads)
        try await bench.start(link, c.purpose)
        let job = try #require(await bench.engine.currentJobID)
        let victim = try #require(try await bench.waitHeld(victims, atLeast: 1) { $0.size * c.percent / 100 }.first)
        let cut = victim.size * c.percent / 100
        try await waitForNewestFrame(bench, card)

        await link.powerOff()
        try await bench.waitPaused(.cameraUnreachable)
        do throws(CameraLinkFailure) {
            try await link.open()
            Issue.record("a camera that is off answered")
        } catch {
            #expect(error.kind == .disconnected)
        }
        await bench.advance(.seconds(3600))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await bench.engine.state == .paused(.cameraUnreachable))
        let progress = await bench.engine.currentProgress
        #expect(progress.filesFailed == 0 && progress.filesSkipped == 0)
        _ = try await bench.waitForRow(of: victim, "the partial row at the cut") {
            $0?.state == .partial && $0?.resumeOffset == cut
        }
        await bench.verify([card], committed: MatrixBench.keys(MatrixBench.frame(card, fromNewest: 0)),
                           partials: [MatrixBench.key(victim)], job: false)

        await link.powerOn()
        try await link.open()
        let known = try await link.list()
        try await bench.engine.reconnect(job, to: link, knownItems: known)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: MatrixBench.keys(card.objects), purpose: c.purpose)
        #expect(await link.resumes == [SimulatedCameraLink.Resume(filename: victim.filename, offset: cut)])
        await bench.finish()
    }

    // MARK: App killed mid-job, relaunched (the download phase)

    /// USB: the app is killed while a file is downloading: its partial file is left in the work folder, with no row.
    /// The relaunched engine empties the folder and a new job copies what the catalogue doesn't have, the
    /// interrupted file again from 0 and the committed ones not at all.
    @Test("App killed mid-download over USB", arguments: MatrixCase.halfway.filter { !$0.link.isWiFi })
    func killedMidDownloadOverUSB(_ c: MatrixCase) async throws {
        let bench = MatrixBench(inFlight: c.inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, c.link)
        let victims = await holdVictims(card, link, percent: c.percent, downloads: c.downloads)
        try await bench.start(link, c.purpose)
        let held = try await bench.waitHeld(victims, atLeast: c.downloads) { $0.size * c.percent / 100 }
        try await waitForNewestFrame(bench, card)
        #expect(!bench.workFiles().others.isEmpty || !bench.workFiles().partials.isEmpty) // a partial file is on disk

        bench.relaunch()
        let (partials, others) = bench.workFiles()
        #expect(partials.isEmpty && others.isEmpty) // left over from a crash: emptied at launch
        let again = await bench.replugged(link)
        try await bench.start(again, c.purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: MatrixBench.keys(card.objects), purpose: c.purpose)
        let asked = await again.bytesCalls
        for v in held { #expect(asked.contains(v.filename)) }
        for v in MatrixBench.frame(card, fromNewest: 0) { #expect(!asked.contains(v.filename)) }
        #expect(await again.resumes.isEmpty)
        await bench.finish()
    }

    /// Wi-Fi: the link dropped (the catalogue's partial row was written) and the app was killed before the reconnect:
    /// the relaunched engine's new job continues the file from the row's offset, though the partial file is days old
    /// (the 7-day rule keeps it).
    @Test("App killed after a Wi-Fi drop, relaunched", arguments: MatrixCase.halfway.filter { $0.link.isWiFi })
    func killedAfterAWiFiDrop(_ c: MatrixCase) async throws {
        let bench = MatrixBench(inFlight: c.inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, c.link)
        let victims = await holdVictims(card, link, percent: c.percent, downloads: c.downloads)
        try await bench.start(link, c.purpose)
        let victim = try #require(try await bench.waitHeld(victims, atLeast: 1) { $0.size * c.percent / 100 }.first)
        let cut = victim.size * c.percent / 100
        try await waitForNewestFrame(bench, card)
        await link.loseSession()
        try await bench.waitPaused(.cameraUnreachable)
        _ = try await bench.waitForRow(of: victim, "the partial row at the cut") {
            $0?.state == .partial && $0?.resumeOffset == cut
        }
        // Six days pass with the app dead (the file's own clock, not the engine's).
        let sixDaysAgo = Date().addingTimeInterval(-6 * 24 * 60 * 60)
        for file in bench.workFiles().partials {
            try FileManager.default.setAttributes([.modificationDate: sixDaysAgo], ofItemAtPath: file.path)
            try FileManager.default.setAttributes([.modificationDate: sixDaysAgo],
                                                  ofItemAtPath: file.deletingLastPathComponent().path)
        }

        bench.relaunch()
        #expect(bench.workFiles().partials.count == 1) // not pruned before 7 days
        let again = await bench.replugged(link)
        try await bench.start(again, c.purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: MatrixBench.keys(card.objects), purpose: c.purpose)
        #expect(await again.resumes == [SimulatedCameraLink.Resume(filename: victim.filename, offset: cut)])
        await bench.finish()
    }

    /// Wi-Fi: the app is killed mid-download, before anything flushed a row (a file under 16 MiB has no checkpoint
    /// row): the new job copies the file from 0 and nothing is lost or duplicated. The orphaned partial file waits
    /// for the 7-day prune, the engine's own rule for a file with no row to clean it up.
    @Test("App killed mid-download over Wi-Fi", arguments: MatrixCase.halfway.filter { $0.link.isWiFi })
    func killedMidDownloadOverWiFi(_ c: MatrixCase) async throws {
        let bench = MatrixBench(inFlight: c.inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, c.link)
        let victims = await holdVictims(card, link, percent: c.percent, downloads: c.downloads)
        try await bench.start(link, c.purpose)
        let victim = try #require(try await bench.waitHeld(victims, atLeast: 1) { $0.size * c.percent / 100 }.first)
        try await waitForNewestFrame(bench, card)
        #expect(await bench.record(of: victim)?.state != .partial) // no row yet

        bench.relaunch()
        let again = await bench.replugged(link)
        try await bench.start(again, c.purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: MatrixBench.keys(card.objects), orphans: 1, purpose: c.purpose)
        #expect(await again.resumes.isEmpty)
        await bench.finish()
    }
}

/// One cell of the different-address matrix.
struct MoveCase: Sendable, CustomTestStringConvertible {
    var move: FaultMatrixCutTests.Move
    var percent: UInt64
    var purpose: MatrixPurpose
    /// Wi-Fi: one download in flight.
    let downloads = 1

    init(_ move: FaultMatrixCutTests.Move, _ percent: UInt64, _ purpose: MatrixPurpose) {
        self.move = move
        self.percent = percent
        self.purpose = purpose
    }

    var testDescription: String { "\(move.rawValue) \(percent)% \(purpose.rawValue)" }
}
