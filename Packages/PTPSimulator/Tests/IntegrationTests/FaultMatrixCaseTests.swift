import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Testing

/// The fault matrix's other cases (backlog section 3): a swapped card, a full phone, Photos access revoked, two
/// cameras with one name, a slow link, a stall, a short file, duplicate names and a frame shot mid-job. Each asserts
/// no duplicates and no loss through `MatrixBench.verify`.
@Suite("Fault matrix: cases", .timeLimit(.minutes(2)))
struct FaultMatrixCaseTests {
    private static let usbAndWiFi: [MatrixLink] = [.usbMTP, .usbMSC, .wifi]

    private static func keys(_ objects: [ScriptedCard.Object]) -> Set<String> { MatrixBench.keys(objects) }

    /// `card` with the objects named in `names` replaced by `replacements`.
    private static func card(_ card: ScriptedCard, replacing names: Set<String>,
                             with replacements: [ScriptedCard.Object]) -> ScriptedCard {
        var out = card
        out.objects = card.objects.filter { !names.contains($0.filename) } + replacements
        return out
    }

    // MARK: Card swapped between sessions

    /// USB: the card is swapped while the cable is out, and the new one reuses two names at other sizes and seconds.
    /// The job carries on with what is still on the card, reports the old frame as skipped (it is gone), and copies
    /// nothing from the new files; a new job imports them as new files and nothing is overwritten or lost.
    @Test("USB card swapped for one that reuses the names", arguments: MatrixPurpose.allCases)
    func usbCardSwappedWithReusedNames(_ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, .usbMTP)
        let victim = MatrixBench.frame(card, fromNewest: 1)
        let arw = try #require(victim.first)
        await link.script(arw.filename, .holdAfter(arw.size / 2))
        try await bench.start(link, purpose)
        _ = try await bench.waitHeld([arw], atLeast: 1) { $0.size / 2 }
        await link.remove()
        try await bench.waitPaused(.cameraRemoved)

        // The same names, at other sizes and a second the old frame didn't have: new files, new handles.
        let reused = victim.enumerated().map { i, o in
            ScriptedCard.Object(handle: PTPObjectHandle(rawValue: 500 + UInt32(i)), folder: o.folder,
                                filename: o.filename, size: o.size + 1000, captureDateRaw: "20261101T090005",
                                format: o.format)
        }
        let swapped = Self.card(card, replacing: Set(victim.map(\.filename)), with: reused)
        let again = bench.link(swapped, .usbMTP, generation: 2)
        try await bench.engine.reconnect(again)
        #expect(try await bench.waitFinished() == .completed)
        let unchanged = card.objects.filter { o in !victim.contains(o) }
        await bench.verify([card, swapped], committed: Self.keys(unchanged), skipped: Self.keys(victim),
                           purpose: purpose)

        // A new job takes the new files; the old frame's name is a new file now, not the old one again.
        try await bench.start(again, purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card, swapped], committed: Self.keys(unchanged + reused), purpose: purpose)
        await bench.finish()
    }

    /// Wi-Fi: after the drop the camera's handles name other files (the card was swapped, the handles reused). The
    /// engine checks the file before it continues, so no byte of the new file lands in the old file's partial; the
    /// old file is reported skipped, its partial row doesn't linger, and a new job imports the new files.
    @Test("Wi-Fi card swapped, handles reused for other files", arguments: MatrixPurpose.allCases)
    func wifiCardSwappedWithReusedHandles(_ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, .wifi)
        let victim = MatrixBench.frame(card, fromNewest: 1)
        let arw = try #require(victim.first)
        await link.script(arw.filename, .holdAfter(arw.size / 2))
        try await bench.start(link, purpose)
        let job = try #require(await bench.engine.currentJobID)
        _ = try await bench.waitHeld([arw], atLeast: 1) { $0.size / 2 }
        await link.loseSession()
        try await bench.waitPaused(.cameraUnreachable)
        _ = try await bench.waitForRow(of: arw, "the partial row") { $0?.state == .partial }

        // The handles are the old frame's, naming other files now.
        let reused = victim.enumerated().map { i, o in
            ScriptedCard.Object(handle: o.handle, folder: "DCIM/101MSDCF", filename: "DSC0010\(i).\(o.format == .sonyARW ? "ARW" : "JPG")",
                                size: o.size + 1000, captureDateRaw: "20261101T090005", format: o.format)
        }
        let swapped = Self.card(card, replacing: Set(victim.map(\.filename)), with: reused)
        let again = bench.link(swapped, .wifi, generation: 2)
        try await again.open()
        let known = try await again.list()
        try await bench.engine.reconnect(job, to: again, knownItems: known)
        #expect(try await bench.waitFinished() == .completed)
        let unchanged = card.objects.filter { o in !victim.contains(o) }
        // Known engine bug (for I15): the old file is skipped as gone (itemNotFound), but its partial file stays in
        // `Partials` and its row stays `.partial` at the old offset until the 7-day prune, though nothing on the card
        // will ever continue it (the backlog: ".partial rows exist only for files the case leaves resumable").
        // Nothing wrong is committed: no bytes of the new file reach the old file. When I15 resets the row and
        // removes the file with the skip, the known-gap check fails: delete the `knownGaps`.
        // Only those two checks are known to fail: the duplicate, loss and bytes checks stay live.
        let gaps = MatrixBench.KnownGaps(
            reason: "a skipped Wi-Fi file keeps its partial file and .partial row (ImportEngine+File linkFailed)",
            staleRows: Self.keys([arw]), keptPartials: true)
        await bench.verify([card, swapped], committed: Self.keys(unchanged), skipped: Self.keys(victim),
                           purpose: purpose, knownGaps: gaps)
        #expect(await again.resumes.isEmpty, "nothing continued a partial file with another file's bytes")

        try await bench.start(again, purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card, swapped], committed: Self.keys(unchanged + reused), purpose: purpose, knownGaps: gaps)
        await bench.finish()
    }

    // MARK: The error taxonomy's outcomes

    /// A failure on one file's download, by the outcome its kind has (`CameraLinkFailure.Kind.outcome`): a failure to
    /// try again now is retried after its backoff and the file imported once; one that skips the file reports it
    /// skipped with its reason and carries on with the rest; one that stops the job ends it with that kind, keeping
    /// what was imported and leaving the rest for the next import. (A failure to retry on reconnect is the cuts in
    /// `FaultMatrixCutTests`.)
    @Test("Failure outcomes follow the taxonomy", arguments: Self.usbAndWiFi, Self.outcomeKinds)
    func failureOutcomes(_ flavour: MatrixLink, _ kind: CameraLinkFailure.Kind) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, flavour)
        let victim = try #require(MatrixBench.frame(card, fromNewest: 1).first)
        await link.script(victim.filename, .fail(kind))
        try await bench.start(link, .importToPhotos)
        switch kind.outcome {
        case .retryNow:
            #expect(try await bench.waitFinished() == .completed)
            await bench.verify([card], committed: Self.keys(card.objects), purpose: .importToPhotos)
            #expect(await link.bytesCalls.filter { $0 == victim.filename }.count == 2)
        case .skipFile:
            #expect(try await bench.waitFinished() == .completed)
            await bench.verify([card], committed: Self.keys(card.objects).subtracting([MatrixBench.key(victim)]),
                               skipped: [MatrixBench.key(victim)], purpose: .importToPhotos)
            let skipped = await bench.engine.currentFiles.first { $0.item.name == victim.filename }
            #expect(skipped?.phase == .skipped(.link(kind)))
        case .stopJob:
            #expect(try await bench.waitFinished() == .stopped(kind))
            let got = await bench.committedKeys([card])
            await bench.verify([card], committed: got, skipped: Self.keys(card.objects).subtracting(got),
                               purpose: .importToPhotos)
        case .retryOnReconnect:
            Issue.record("\(kind) is not one of the outcomes this test covers")
        }
        await bench.finish()
    }

    /// The failure kinds a download can end with whose outcome needs nothing from the link afterwards.
    static let outcomeKinds: [CameraLinkFailure.Kind] = CameraLinkFailure.Kind.allCases.filter {
        $0.outcome != .retryOnReconnect && $0 != .modeListsNoFiles
    }

    // MARK: Phone storage full mid-job

    /// A download fails because the phone has no room: the job stops (not paused, not failed files), what was
    /// imported is kept, and once there is room a new job copies the rest, each file once.
    @Test("Phone storage full during a download", arguments: MatrixCase.halfway)
    func storageFullDuringADownload(_ c: MatrixCase) async throws {
        let bench = MatrixBench(inFlight: c.inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, c.link)
        let victim = try #require(MatrixBench.frame(card, fromNewest: 1).first)
        await link.script(victim.filename, .fail(.phoneStorageFull))
        try await bench.start(link, c.purpose)
        #expect(try await bench.waitFinished() == .stopped(.phoneStorageFull))

        let got = await bench.committedKeys([card])
        if c.downloads == 1 {
            // Newest first: the newest frame was committed before the victim, in the frame before it, failed.
            #expect(Self.keys(MatrixBench.frame(card, fromNewest: 0)).isSubset(of: got))
        } // with 2 in flight a file of the newest frame can still be downloading when the other one stops the job
        #expect(!got.contains(MatrixBench.key(victim)))
        let rest = Self.keys(card.objects).subtracting(got)
        await bench.verify([card], committed: got, skipped: rest, purpose: c.purpose)

        // Room again: the next import copies what is left.
        try await bench.start(link, c.purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: c.purpose)
        await bench.finish()
    }

    /// Wi-Fi: the drop leaves a partial file, and the resumed read finds the phone full: the job stops, the partial
    /// file and its row are kept (the bytes already copied aren't thrown away), and a new job with room resumes it
    /// from where it was.
    @Test("Phone storage full when a Wi-Fi file resumes", arguments: MatrixPurpose.allCases)
    func storageFullWhenAWiFiFileResumes(_ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, .wifi)
        let victim = try #require(MatrixBench.frame(card, fromNewest: 1).first)
        let cut = victim.size / 2
        await link.script(victim.filename, .holdAfter(cut), .fail(.phoneStorageFull))
        try await bench.start(link, purpose)
        let job = try #require(await bench.engine.currentJobID)
        _ = try await bench.waitHeld([victim], atLeast: 1) { $0.size / 2 }
        await link.loseSession()
        try await bench.waitPaused(.cameraUnreachable)
        _ = try await bench.waitForRow(of: victim, "the partial row") { $0?.state == .partial && $0?.resumeOffset == cut }

        try await link.open()
        let known = try await link.list()
        try await bench.engine.reconnect(job, to: link, knownItems: known)
        #expect(try await bench.waitFinished() == .stopped(.phoneStorageFull))
        let got = await bench.committedKeys([card])
        let rest = Self.keys(card.objects).subtracting(got)
        // Known engine bug (for I15): the backlog says a full phone keeps the Wi-Fi partial, but the file whose read
        // failed is resolved as failed, and resolving a failed file deletes its partial folder. The catalogue's row
        // stays `.partial` at the old offset, pointing at nothing. Nothing is lost or duplicated: the next job copies
        // the file from 0. When I15 keeps the partial (a `.stopJob` failure isn't the file's), this passes and
        // the known-gap check fails: delete the `knownGaps`.
        // Only the kept-partial-file check is known to fail: the duplicate, loss, bytes and row checks stay live.
        let gaps = MatrixBench.KnownGaps(
            reason: "a full phone deletes the Wi-Fi partial the backlog says is kept (ImportEngine+File resolve)",
            keptPartials: true)
        await bench.verify([card], committed: got, skipped: rest, partials: [MatrixBench.key(victim)],
                           purpose: purpose, knownGaps: gaps)

        // Room again: the next job copies the file (continuing the partial, once the engine keeps it).
        try await bench.start(link, purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: purpose)
        await withKnownIssue("the next job can't continue a partial the stop deleted") {
            #expect(await link.resumes.last == SimulatedCameraLink.Resume(filename: victim.filename, offset: cut))
        }
        await bench.finish()
    }

    /// The phone fills up at the commit instead: the staged file is lost with the failed commit, the job stops, and
    /// the next import copies that file again, once.
    @Test("Phone storage full at the commit", arguments: MatrixCase.halfway)
    func storageFullAtTheCommit(_ c: MatrixCase) async throws {
        let bench = MatrixBench(inFlight: c.inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, c.link)
        let destination = c.purpose == .importToPhotos ? bench.photos : bench.staging
        await destination.fail(attempt: 2, with: .notEnoughSpace)
        try await bench.start(link, c.purpose)
        #expect(try await bench.waitFinished() == .stopped(.phoneStorageFull))
        let got = await bench.committedKeys([card])
        await bench.verify([card], committed: got, skipped: Self.keys(card.objects).subtracting(got), purpose: c.purpose)

        try await bench.start(link, c.purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: c.purpose)
        await bench.finish()
    }

    // MARK: Photos access revoked mid-job

    /// Photos refuses a save part-way (3311): that file and the rest are staged instead, the screen's route says so,
    /// and every file lands once, the first in Photos and the rest in staging.
    @Test("Photos access revoked mid-job", arguments: Self.usbAndWiFi, [1, 2])
    func photosAccessRevoked(_ flavour: MatrixLink, _ inFlight: Int) async throws {
        let bench = MatrixBench(inFlight: inFlight)
        let card = try MatrixBench.card()
        let link = bench.link(card, flavour)
        await bench.photos.deny(from: 2)
        try await bench.start(link, .importToPhotos)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: .importToPhotos, switched: true)
        let progress = await bench.engine.currentProgress
        #expect(progress.destination == .staging(.photosDenied, MatrixBench.place))
        #expect(await bench.photos.units.count == 1)
        #expect(!(await bench.staging.units.isEmpty))
        #expect(progress.filesStaged == card.objects.count - (await bench.photos.files.count))
        await bench.finish()
    }

    // MARK: Two cameras with the same name

    /// Two bodies that both call themselves "ILCE-7CM2", with different keys and cards: different files are all
    /// imported (the same names at other seconds are other files), and a file with the same name, second and size
    /// counts once, as Shamil accepted (8 Nov).
    @Test("Two cameras with one name", arguments: MatrixLink.allCases, MatrixPurpose.allCases)
    func twoCamerasWithOneName(_ flavour: MatrixLink, _ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let first = try MatrixBench.card(frames: 3)
        // Content follows the handle, so the second body's files get handles of their own: the same name at another
        // second is then another file in bytes too.
        var second = try MatrixBench.card(frames: 3, start: "20261102T100000")
        second.objects = second.objects.map { o in
            var o = o
            o.handle = PTPObjectHandle(rawValue: o.handle.rawValue + 100)
            return o
        }
        // One of the second body's files is the first's DSC00001.ARW to the second and the byte, a file of its own.
        let original = try #require(first.objects.first { $0.filename == "DSC00001.ARW" })
        let twin = ScriptedCard.Object(handle: PTPObjectHandle(rawValue: 900), folder: original.folder,
                                       filename: original.filename, size: original.size,
                                       captureDateRaw: original.captureDateRaw, format: original.format)
        var withTwin = second
        withTwin.objects.append(twin)
        let keyA = CameraKey(rawValue: "body-a")
        let keyB = CameraKey(rawValue: "body-b")

        let linkA = bench.link(first, flavour, name: "ILCE-7CM2", descriptorID: "body-a")
        try await bench.start(linkA, purpose, camera: keyA)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([first], committed: Self.keys(first.objects), purpose: purpose, camera: keyA)

        let linkB = bench.link(withTwin, flavour, name: "ILCE-7CM2", descriptorID: "body-b")
        try await bench.start(linkB, purpose, camera: keyB)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([first, withTwin], committed: Self.keys(first.objects) .union(Self.keys(second.objects)),
                           purpose: purpose, camera: keyB, otherCameras: [keyA])
        // The twin was not copied: the name was asked for once, for the body's own file of that name.
        #expect(await linkB.bytesCalls.filter { $0 == twin.filename }.count == 1)
        await bench.finish()
    }

    // MARK: Slow link, stall, short file

    /// A slow file that keeps making progress for longer than the 30 s stall limit never trips it: 1 KiB a second
    /// for a 40 KB file is about 40 s on the manual clock, and the job finishes without a pause or a second try.
    @Test("A slow link that keeps progressing never stalls", arguments: [MatrixLink.usbMTP, .wifi], MatrixPurpose.allCases)
    func slowLinkNeverStalls(_ flavour: MatrixLink, _ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let card = try #require(ScriptedCard.shoot([.raw])).scaled(down: 1000)
        let link = bench.link(card, flavour)
        await link.limitThroughput(bytesPerTick: 1024, every: .seconds(1))
        try await bench.start(link, purpose)
        var seconds = 0
        var stalled = false
        while seconds < 120, await link.waitUntilThrottled(timeout: .seconds(2)) {
            await bench.advance(.seconds(1), link: link)
            seconds += 1
            // The engine reads the byte progress before the next second: it's what keeps the stall timer at zero.
            let want = UInt64(seconds) * 1024
            try await bench.waitForFiles("the second's bytes") { files in
                files.contains { $0.bytesDone >= min(want, $0.item.size) || $0.phase.isResolved }
            }
            if await bench.engine.state == .paused(.stalled) { stalled = true }
        }
        #expect(seconds > 30, "the copy ran longer than the stall limit on the clock: \(seconds) s")
        #expect(!stalled)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: purpose)
        #expect(await link.bytesCalls.count == 1)
        await bench.finish()
    }

    /// A download that stops making progress for 30 s pauses the job as stalled, the file is tried again 5 s later and
    /// the job finishes; the abandoned first call, finishing late (USB ignores cancellation), commits nothing twice.
    @Test("Stall, then progress", arguments: [MatrixLink.usbMTP, .wifi], MatrixPurpose.allCases)
    func stallThenProgress(_ flavour: MatrixLink, _ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, flavour)
        let victim = try #require(MatrixBench.frame(card, fromNewest: 0).first)
        await link.script(victim.filename, .holdAfter(victim.size / 3))
        try await bench.start(link, purpose)
        _ = try await bench.waitHeld([victim], atLeast: 1) { $0.size / 3 }

        await bench.advance(.seconds(31))
        try await bench.waitPaused(.stalled)
        #expect(await bench.engine.currentProgress.filesFailed == 0)
        await bench.advance(.seconds(6)) // the retry delay
        #expect(try await bench.waitFinished() == .completed)
        // The first call, late: whatever it writes is no second copy.
        await link.release(victim.filename)
        try await Task.sleep(for: .milliseconds(50))
        await bench.verify([card], committed: Self.keys(card.objects), purpose: purpose)
        await bench.finish()
    }

    /// A file that arrives shorter than its listed size is caught by its size and fetched again; the short bytes are
    /// never committed.
    @Test("A short file", arguments: Self.usbAndWiFi, MatrixPurpose.allCases)
    func shortFile(_ flavour: MatrixLink, _ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, flavour)
        let victim = try #require(MatrixBench.frame(card, fromNewest: 1).first)
        await link.script(victim.filename, .deliverShort(100))
        try await bench.start(link, purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: purpose)
        #expect(await link.bytesCalls.filter { $0 == victim.filename }.count == 2)
        await bench.finish()
    }

    // MARK: Duplicate file names

    /// One name in two folders with the same second and size is one file (the catalogue's key), queued and copied once.
    @Test("One file name in two folders", arguments: Self.usbAndWiFi, MatrixPurpose.allCases)
    func oneNameInTwoFolders(_ flavour: MatrixLink, _ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        var card = try MatrixBench.card(frames: 2)
        let original = try #require(card.objects.first { $0.filename == "DSC00001.JPG" })
        card.objects.append(ScriptedCard.Object(
            handle: PTPObjectHandle(rawValue: 700), folder: "DCIM/101MSDCF", filename: original.filename,
            size: original.size, captureDateRaw: original.captureDateRaw, format: original.format))
        let link = bench.link(card, flavour)
        try await bench.start(link, purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: purpose)
        #expect(await link.bytesCalls.filter { $0 == original.filename }.count == 1)
        await bench.finish()
    }

    /// The camera's file counter wraps (DSC09999 then DSC00001 in the next folder) and the card still holds an older
    /// DSC00001: the same name is on the card twice, two files told apart by their seconds, and both are copied with
    /// their own bytes, none overwriting the other.
    @Test("File names reused after the counter wraps", arguments: Self.usbAndWiFi, MatrixPurpose.allCases)
    func counterWrap(_ flavour: MatrixLink, _ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let early = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG], start: "20261029T090000",
                                                     firstNumber: 1)).scaled(down: 1000)
        let before = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG], start: "20261101T090000",
                                                      firstNumber: 9998)).scaled(down: 1000)
        let after = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG], start: "20261103T090000",
                                                     firstNumber: 1, firstFolder: 101)).scaled(down: 1000)
        var card = early
        for (group, offset) in [(before, 100), (after, 200)] {
            card.objects += group.objects.map { o in
                var o = o
                o.handle = PTPObjectHandle(rawValue: o.handle.rawValue + UInt32(offset))
                return o
            }
        }
        let link = bench.link(card, flavour)
        try await bench.start(link, purpose)
        #expect(try await bench.waitFinished() == .completed)
        // The same name, two files: both are in the destination with their own bytes (`verify` matches each committed
        // file to a scripted file byte for byte, and expects every key once).
        let wrapped = card.objects.filter { $0.filename == "DSC00001.ARW" }
        #expect(wrapped.count == 2 && Self.keys(card.objects).count == card.objects.count)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: purpose)
        #expect(await bench.committedKeys([card]).isSuperset(of: Self.keys(wrapped)))
        await bench.finish()
    }

    /// The camera's counter wrapped on an earlier day and the new file shares an old file's name: the old one, already
    /// imported, is not copied again and the new one is.
    @Test("A reused name next to an imported file", arguments: Self.usbAndWiFi, MatrixPurpose.allCases)
    func reusedNameNextToAnImportedFile(_ flavour: MatrixLink, _ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let old = try MatrixBench.card(frames: 2)
        let link = bench.link(old, flavour)
        try await bench.start(link, purpose)
        #expect(try await bench.waitFinished() == .completed)

        let later = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG], start: "20261103T090000")).scaled(down: 1000)
        var card = old
        card.objects += later.objects.map { o in
            var o = o
            o.handle = PTPObjectHandle(rawValue: o.handle.rawValue + 100)
            return o
        }
        let again = bench.link(card, flavour, generation: 2)
        try await bench.start(again, purpose)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: purpose)
        #expect(await again.bytesCalls.count == later.objects.count)
        await bench.finish()
    }

    // MARK: ObjectAdded mid-job

    /// A frame shot during a Wi-Fi import isn't in the running job (nothing tells the engine, and the job's list is
    /// the one it made), and the next listing has it as new.
    @Test("A frame shot mid-job over Wi-Fi", arguments: MatrixPurpose.allCases)
    func frameShotMidJob(_ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, .wifi)
        let victim = try #require(MatrixBench.frame(card, fromNewest: 1).first)
        await link.script(victim.filename, .holdAfter(victim.size / 2))
        try await bench.start(link, purpose)
        _ = try await bench.waitHeld([victim], atLeast: 1) { $0.size / 2 }
        _ = await link.shoot([.rawPlusJPEG])
        await link.release(victim.filename)
        #expect(try await bench.waitFinished() == .completed)
        #expect(await bench.engine.currentProgress.filesTotal == card.objects.count)
        await bench.verify([card], committed: Self.keys(card.objects), purpose: purpose)

        let all = await link.card
        let added = Self.keys(all.objects).subtracting(Self.keys(card.objects))
        #expect(added.count == 2)
        try await bench.start(link, purpose)
        #expect(try await bench.waitFinished() == .completed)
        #expect(await bench.engine.currentProgress.filesTotal == 2)
        await bench.verify([all], committed: Self.keys(all.objects), purpose: purpose)
        await bench.finish()
    }

    /// The person appends the new frame to the running job: it is copied once, with the rest.
    @Test("A frame shot mid-job and appended", arguments: MatrixPurpose.allCases)
    func frameShotMidJobAndAppended(_ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        let card = try MatrixBench.card()
        let link = bench.link(card, .wifi)
        let victim = try #require(MatrixBench.frame(card, fromNewest: 1).first)
        await link.script(victim.filename, .holdAfter(victim.size / 2))
        try await bench.start(link, purpose)
        _ = try await bench.waitHeld([victim], atLeast: 1) { $0.size / 2 }
        let added = await link.shoot([.rawPlusJPEG])
        #expect(try await bench.engine.append(added) == 2)
        await link.release(victim.filename)
        #expect(try await bench.waitFinished() == .completed)
        let all = await link.card
        await bench.verify([all], committed: Self.keys(all.objects), purpose: purpose)
        #expect(await bench.engine.currentProgress.filesTotal == all.objects.count)
        await bench.finish()
    }
}
