import CameraTransport
import Foundation
import ImportEngine
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

/// `IPLink`'s 0x9211 resume, reopen with known handles and abort against the simulated α7C II (plan W8), through public
/// API only: a download cut mid-file by the Wi-Fi going (`dropAll`, losing what was in flight), the reopen and the
/// resume from the checkpoint with 0x9211; 0x101B never sent; a relist that asks GetObjectInfo only for new handles; a
/// handle that names another file after a card swap caught before anything is written; the abort for the continued
/// task's expiry; and the engine resuming through the link end to end. Every copy is compared byte for byte with the
/// camera's content (stronger than the SHA-256 the plan names, which needs no CryptoKit this way).
///
/// The camera's files are its real sizes scaled down by 100 (an ARW of about 420 KB), so the reads are 16 KiB here
/// instead of 4 MiB (`partialReadChunkSize`); the rules don't depend on the size.
@Suite("IPLink's resume and reopen against the simulated camera", .timeLimit(.minutes(1)))
struct IPLinkResumeAgainstSimulatorTests {
    typealias LinkBench = IPLinkAgainstSimulatorTests.Bench

    static let chunk: UInt32 = 16 * 1024

    /// A bench whose link reads 16 KiB chunks.
    static func bench(frames: [ScriptedCard.Frame] = [.rawPlusJPEG, .jpeg, .raw], deviceInfo: PTPDeviceInfo? = nil,
                      trace: TransportTrace = .none) throws -> LinkBench {
        try LinkBench(frames: frames, deviceInfo: deviceInfo, trace: trace) { $0.partialReadChunkSize = Self.chunk }
    }

    /// The camera's whole content of `item`.
    static func content(of item: CameraItem, on camera: InMemoryPTPIPCamera) throws -> Data {
        let handle = try #require(camera.card.objects.first { $0.filename == item.name }?.handle)
        return ScriptedCard.content(of: handle, in: 0 ..< item.size)
    }

    /// Starts a fresh download of `item` and cuts it as the Wi-Fi going does once about `fraction` of it has been
    /// read: the camera drops every connection and what was in flight is lost. Returns the failure, the checkpoints
    /// and the partial file, once the link has reported `.sessionLost`.
    static func cutFreshDownload(_ item: CameraItem, at fraction: Double, on bench: LinkBench,
                                 events: inout AsyncStream<CameraLinkEvent>.Iterator) async throws
        -> (failure: CameraLinkFailure?, checkpoints: [PartialDownload]) {
        let checkpoints = Checkpoints()
        let link = bench.link
        let directory = bench.directory
        bench.gate.hold(afterReceiving: Int(Double(item.size) * fraction))
        let download = Task { () async -> CameraLinkFailure? in
            do throws(CameraLinkFailure) {
                _ = try await link.bytes(of: item.id, into: directory, resuming: nil,
                                         checkpoint: { checkpoints.add($0) }, progress: { _ in })
                return nil
            } catch {
                return error
            }
        }
        try await bench.gate.waitUntilHoldingAReceive()
        bench.camera.dropAll(losingUndelivered: true)
        bench.gate.release()
        let failure = await download.value
        #expect(await events.next()?.isSessionLost == true)
        return (failure, checkpoints.values)
    }

    // MARK: Capabilities

    @Test func resumeIsReportedOnceTheCamerasDeviceInfoLists0x9211() async throws {
        let bench = try Self.bench()
        // Before the first open the link knows nothing of the camera: never more than it can do.
        #expect(!bench.link.capabilities.resumesPartialFiles)
        try await bench.open()
        #expect(bench.link.capabilities == .wifi)
        #expect(try #require(await bench.link.deviceInfo).supports(.sonySDIOGetPartialLargeObject))
        await bench.link.close()
    }

    @Test func without0x9211TheLinkIgnoresThePartialAndNeverCheckpoints() async throws {
        var info = try CapturedA7C2.deviceInfo(.ptpIP)
        info.operationsSupported.removeAll { $0 == PTPOperationCode.sonySDIOGetPartialLargeObject.rawValue }
        let bench = try Self.bench(deviceInfo: info)
        try await bench.open()
        #expect(bench.link.capabilities == IPLink.capabilitiesWithoutResume)
        let raw = try #require(try await bench.link.list().first { $0.format == .raw })
        // A partial from somewhere else: ignored, as USBLink ignores it.
        let elsewhere = bench.directory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let partial = elsewhere.appendingPathComponent(raw.name)
        try Data(count: 1000).write(to: partial)
        let checkpoints = Checkpoints()
        let url = try await bench.link.bytes(of: raw.id, into: bench.directory,
                                             resuming: PartialDownload(file: partial, bytesWritten: 1000),
                                             checkpoint: { checkpoints.add($0) }, progress: { _ in })
        #expect(url == bench.directory.appendingPathComponent(raw.name))
        #expect(try Data(contentsOf: url) == Self.content(of: raw, on: bench.camera))
        #expect(checkpoints.values.isEmpty)
        #expect(try Data(contentsOf: partial).count == 1000)  // untouched
        #expect(!bench.camera.commandsAnswered.contains(.sonySDIOGetPartialLargeObject))
        await bench.link.close()
    }

    // MARK: Resume

    /// The 2 Nov 23:10 run: a GetObject cut at about 54 % by the Wi-Fi going, a reopen that lists nothing again and
    /// finds the same handle, and the rest read with 0x9211 from the checkpoint; the copy matches the camera's file.
    @Test func aDownloadCutAt54PercentResumesWith0x9211AndMatches() async throws {
        let bench = try Self.bench()
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let items = try await bench.link.list()
        let raw = try #require(items.first { $0.format == .raw })
        let content = try Self.content(of: raw, on: bench.camera)

        let (failure, checkpoints) = try await Self.cutFreshDownload(raw, at: 0.54, on: bench, events: &events)
        #expect(failure?.kind == .disconnected && failure?.outcome == .retryOnReconnect)
        let partial = bench.directory.appendingPathComponent(raw.name)
        let last = try #require(checkpoints.last)
        // A checkpoint each time the copy crossed 16 KiB, then one where it broke off; all in the same file, in order.
        #expect(checkpoints.allSatisfy { $0.file == partial })
        let offsets = checkpoints.map(\.bytesWritten)
        #expect(offsets == offsets.sorted() && Set(offsets).count == offsets.count)
        let strides = offsets.dropLast().map { $0 / UInt64(Self.chunk) }
        #expect(strides == Array(1 ... UInt64(strides.count)), "\(offsets)")
        #expect(last.bytesWritten > raw.size * 40 / 100 && last.bytesWritten < raw.size * 60 / 100, "\(offsets)")
        // Kept on the phone, and its bytes up to the checkpoint are the camera's.
        let kept = try Data(contentsOf: partial)
        #expect(kept.count == Int(last.bytesWritten))
        #expect(kept == content.prefix(Int(last.bytesWritten)))

        // Reopen (500 ms, then the plan as a reopen) and relist with what is known: no GetObjectInfo at all.
        try await bench.open()
        let before = bench.camera.commandsAnswered.count
        let again = try await bench.link.list(reusing: items)
        #expect(again == items)
        #expect(!bench.camera.commandsAnswered.dropFirst(before).contains(.getObjectInfo))
        let diagnostics = await bench.link.diagnostics
        #expect(diagnostics.objectInfosAsked == 0 && diagnostics.reusedHandles == items.count)
        // The engine checks the file's name and size before it resumes (a handle is a hint).
        #expect(try await bench.link.info(of: raw.id) == raw)

        let resumedFrom = bench.camera.commandsAnswered.count
        let progress = Progressions()
        let more = Checkpoints()
        let url = try await bench.link.bytes(of: raw.id, into: bench.directory, resuming: last,
                                             checkpoint: { more.add($0) }, progress: { progress.add($0) })
        #expect(url == partial)
        #expect(try Data(contentsOf: url) == content)
        // Only 0x9211 from the offset, in 16 KiB chunks; never GetObject again.
        let sent = Array(bench.camera.commandsAnswered.dropFirst(resumedFrom))
        let chunks = Int((raw.size - last.bytesWritten + UInt64(Self.chunk) - 1) / UInt64(Self.chunk))
        #expect(sent == Array(repeating: .sonySDIOGetPartialLargeObject, count: chunks), "\(sent)")
        // A checkpoint after each chunk but the last; progress counts bytes in the file, from the offset.
        let expected = stride(from: last.bytesWritten + UInt64(Self.chunk), to: raw.size, by: Int(Self.chunk))
        #expect(more.values.map(\.bytesWritten) == Array(expected))
        #expect(progress.values.first.map { $0 > last.bytesWritten } == true && progress.values.last == raw.size)
        // 0x101B and 0x9219 answer InvalidObjectHandle in this session: never sent.
        #expect(!bench.camera.commandsAnswered.contains(.getPartialObject))
        #expect(!bench.camera.commandsAnswered.contains(.sonySDIO0x9219))
        #expect(await bench.link.diagnostics.resumes == 1)
        await bench.link.close()
    }

    @Test func aResumeCutInItsTurnResumesAgainFromItsOwnCheckpoint() async throws {
        let bench = try Self.bench()
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let items = try await bench.link.list()
        let raw = try #require(items.first { $0.format == .raw })
        let content = try Self.content(of: raw, on: bench.camera)
        let first = try #require(try await Self.cutFreshDownload(raw, at: 0.3, on: bench, events: &events)
            .checkpoints.last)

        // The resume, cut by the Wi-Fi going again partway through its 0x9211 reads.
        try await bench.open()
        _ = try await bench.link.list(reusing: items)
        let checkpoints = Checkpoints()
        let link = bench.link
        let directory = bench.directory
        bench.gate.hold(afterReceiving: Int(raw.size / 3))
        let resume = Task { () async -> CameraLinkFailure? in
            do throws(CameraLinkFailure) {
                _ = try await link.bytes(of: raw.id, into: directory, resuming: first,
                                         checkpoint: { checkpoints.add($0) }, progress: { _ in })
                return nil
            } catch {
                return error
            }
        }
        try await bench.gate.waitUntilHoldingAReceive()
        bench.camera.dropAll(losingUndelivered: true)
        bench.gate.release()
        #expect(await resume.value?.kind == .disconnected)
        #expect(await events.next()?.isSessionLost == true)
        let second = try #require(checkpoints.values.last)
        #expect(second.file == first.file && second.bytesWritten > first.bytesWritten && second.bytesWritten < raw.size)
        #expect(try Data(contentsOf: second.file).prefix(Int(second.bytesWritten)) == content.prefix(Int(second.bytesWritten)))

        // And once more, to the end.
        try await bench.open()
        _ = try await bench.link.list(reusing: items)
        let url = try await bench.link.bytes(of: raw.id, into: bench.directory, resuming: second,
                                             checkpoint: { _ in }, progress: { _ in })
        #expect(try Data(contentsOf: url) == content)
        #expect(bench.camera.commandsAnswered.filter { $0 == .getObject }.count == 1)
        #expect(!bench.camera.commandsAnswered.contains(.getPartialObject))
        #expect(await bench.link.diagnostics.resumes == 2)
        await bench.link.close()
    }

    @Test func aPartialTheLinkCannotContinueIsCopiedAgainIntoTheSameFile() async throws {
        let bench = try Self.bench()
        try await bench.open()
        let raw = try #require(try await bench.link.list().first { $0.format == .raw })
        let folder = bench.directory.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Shorter than its offset: the file isn't what the checkpoint said.
        let short = folder.appendingPathComponent(raw.name)
        try Data(count: 100).write(to: short)
        let url = try await bench.link.bytes(of: raw.id, into: bench.directory,
                                             resuming: PartialDownload(file: short, bytesWritten: 5000),
                                             checkpoint: { _ in }, progress: { _ in })
        #expect(url == short)
        #expect(try Data(contentsOf: url) == Self.content(of: raw, on: bench.camera))
        #expect(bench.camera.commandsAnswered.last == .getObject)
        #expect(!bench.camera.commandsAnswered.contains(.sonySDIOGetPartialLargeObject))
        await bench.link.close()
    }

    /// Each 0x9211 read is a transfer of its own, so a thumbnail asked for during a resume waits for the chunk on the
    /// wire, not for the file (when it has queued by the time that chunk ends, it goes before the next one).
    @Test func aThumbnailAskedForDuringAResumeWaitsOnlyForTheChunkOnTheWire() async throws {
        let bench = try Self.bench()
        try await bench.open()
        let items = try await bench.link.list()
        let raw = try #require(items.first { $0.format == .raw })
        let jpeg = try #require(items.first { $0.format == .jpeg })
        let content = try Self.content(of: raw, on: bench.camera)
        // A partial file of the first 16 KiB, as an earlier session's checkpoint left it.
        let partial = bench.directory.appendingPathComponent(raw.name)
        try FileManager.default.createDirectory(at: bench.directory, withIntermediateDirectories: true)
        try content.prefix(Int(Self.chunk)).write(to: partial)
        let link = bench.link
        let directory = bench.directory
        bench.gate.hold(afterReceiving: Int(Self.chunk) / 2)
        let resume = Task {
            try await link.bytes(of: raw.id, into: directory,
                                 resuming: PartialDownload(file: partial, bytesWritten: UInt64(Self.chunk)),
                                 checkpoint: { _ in }, progress: { _ in })
        }
        try await bench.gate.waitUntilHoldingAReceive()
        let thumbnail = Task { try await link.thumbnail(of: jpeg.id) }
        try await Task.sleep(for: .milliseconds(20))  // time to queue behind the chunk on the wire
        bench.gate.release()
        #expect(try await resume.value == partial)
        #expect(try await !thumbnail.value.isEmpty)
        #expect(try Data(contentsOf: partial) == content)
        // Neither failed as busy, and the thumbnail never cut into the chunk on the wire.
        let sent = bench.camera.commandsAnswered
        let first = try #require(sent.firstIndex(of: .sonySDIOGetPartialLargeObject))
        let thumb = try #require(sent.lastIndex(of: .getThumb))
        let last = try #require(sent.lastIndex(of: .sonySDIOGetPartialLargeObject))
        // After the chunk on the wire, and before the last chunk: it didn't wait for the whole file.
        #expect(thumb > first && thumb < last, "\(sent.suffix(from: first))")
        await link.close()
    }

    /// 0x9211 has worked in one spike run (`unverified`): should the camera refuse a resume's first read with the
    /// session up and the card there, the file is copied again with GetObject into the same file, not skipped.
    @Test func aRefusedFirst0x9211ReadFallsBackToGetObjectIntoTheSameFile() async throws {
        let bench = try Self.bench()
        try await bench.open()
        let raw = try #require(try await bench.link.list().first { $0.format == .raw })
        let content = try Self.content(of: raw, on: bench.camera)
        let partial = bench.directory.appendingPathComponent(raw.name)
        try FileManager.default.createDirectory(at: bench.directory, withIntermediateDirectories: true)
        try content.prefix(Int(Self.chunk)).write(to: partial)
        bench.camera.withResponder { $0.inject(.invalidObjectHandle, forNext: .sonySDIOGetPartialLargeObject) }
        let before = bench.camera.commandsAnswered.count
        let url = try await bench.link.bytes(of: raw.id, into: bench.directory,
                                             resuming: PartialDownload(file: partial, bytesWritten: UInt64(Self.chunk)),
                                             checkpoint: { _ in }, progress: { _ in })
        #expect(url == partial)
        #expect(try Data(contentsOf: url) == content)
        let sent = Array(bench.camera.commandsAnswered.dropFirst(before))
        // The refused read, the check that the card is still there, then the whole file.
        #expect(sent == [.sonySDIOGetPartialLargeObject, .getStorageIDs, .getObject], "\(sent)")
        let diagnostics = await bench.link.diagnostics
        #expect(diagnostics.resumeFallbacks == 1 && diagnostics.sessionsLost == 0)
        #expect(await bench.link.isOpen)
        await bench.link.close()
    }

    /// A pause (the caller's cancellation) during a resume lets the 0x9211 chunk on the wire finish and stops at its
    /// boundary: the session stays open, so the next resume needs no reopen.
    @Test func aPauseDuringAResumeStopsAtTheChunkBoundaryAndKeepsTheSession() async throws {
        let bench = try Self.bench()
        let events = bench.link.events
        try await bench.open()
        let raw = try #require(try await bench.link.list().first { $0.format == .raw })
        let content = try Self.content(of: raw, on: bench.camera)
        let partial = bench.directory.appendingPathComponent(raw.name)
        try FileManager.default.createDirectory(at: bench.directory, withIntermediateDirectories: true)
        try content.prefix(Int(Self.chunk)).write(to: partial)
        let link = bench.link
        let directory = bench.directory
        let checkpoints = Checkpoints()
        bench.gate.hold(afterReceiving: Int(Self.chunk) / 2)
        let resume = Task { () async -> CameraLinkFailure? in
            do throws(CameraLinkFailure) {
                _ = try await link.bytes(of: raw.id, into: directory,
                                         resuming: PartialDownload(file: partial, bytesWritten: UInt64(Self.chunk)),
                                         checkpoint: { checkpoints.add($0) }, progress: { _ in })
                return nil
            } catch {
                return error
            }
        }
        try await bench.gate.waitUntilHoldingAReceive()
        resume.cancel()
        bench.gate.release()
        #expect(await resume.value?.kind == .disconnected)
        #expect(await link.isOpen)
        #expect(bench.camera.commandsAnswered.filter { $0 == .sonySDIOGetPartialLargeObject }.count == 1)
        // The chunk on the wire finished and was checkpointed at its end.
        let boundary = try #require(checkpoints.values.last)
        #expect(boundary.bytesWritten == 2 * UInt64(Self.chunk) && boundary.file == partial)
        #expect(try Data(contentsOf: partial).prefix(Int(boundary.bytesWritten)) == content.prefix(Int(boundary.bytesWritten)))
        // Continue on the same session: no reopen.
        let url = try await link.bytes(of: raw.id, into: directory, resuming: boundary, checkpoint: { _ in },
                                       progress: { _ in })
        #expect(try Data(contentsOf: url) == content)
        let diagnostics = await link.diagnostics
        #expect(diagnostics.sessionsOpened == 1 && diagnostics.sessionsLost == 0)
        await link.close()
        var forwarded: [CameraLinkEvent] = []
        for await event in events { forwarded.append(event) }
        #expect(!forwarded.contains { $0.isSessionLost })
    }

    // MARK: Reopen with known handles

    /// A second relist in one session keeps what this session's GetObjectInfo confirmed: a download after it asks no
    /// ObjectInfo again.
    @Test func aSecondRelistInOneSessionKeepsConfirmedFiles() async throws {
        let bench = try Self.bench()
        try await bench.open()
        let items = try await bench.link.list()
        let again = try await bench.link.list(reusing: items)
        #expect(again == items)
        let raw = try #require(again.first { $0.format == .raw })
        let before = bench.camera.commandsAnswered.count
        let url = try await bench.link.bytes(of: raw.id, into: bench.directory)
        #expect(Array(bench.camera.commandsAnswered.dropFirst(before)) == [.getObject])
        #expect(try Data(contentsOf: url) == Self.content(of: raw, on: bench.camera))
        await bench.link.close()
    }

    @Test func aReopenAsksObjectInfoOnlyForTheNewHandles() async throws {
        let bench = try Self.bench()
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let items = try await bench.link.list()
        #expect(await bench.link.diagnostics.objectInfosAsked == items.count)

        // The Wi-Fi goes; meanwhile one file is deleted on the camera and two frames are shot. The loss carries the
        // lost session's generation, and the reopen is the next one.
        #expect(await bench.link.sessionGeneration == 1)
        bench.camera.dropAll()
        #expect(await events.next() == .sessionLost(generation: 1))
        var card = bench.camera.card
        let deleted = try #require(card.objects.first)
        card.objects.removeFirst()
        let shot = card.shootMore([.jpeg, .raw])
        bench.camera.withResponder { $0.replaceCard(with: card) }

        try await bench.open()
        #expect(await bench.link.sessionGeneration == 2)
        let before = bench.camera.commandsAnswered.count
        let listed = try await bench.link.list(reusing: items)
        let sent = Array(bench.camera.commandsAnswered.dropFirst(before))
        #expect(sent.filter { $0 == .getObjectInfo }.count == 2, "\(sent)")
        #expect(sent.first == .getStorageIDs && sent.contains(.getObjectHandles))
        let diagnostics = await bench.link.diagnostics
        #expect(diagnostics.listedHandles == items.count + 1 && diagnostics.objectInfosAsked == 2)
        #expect(diagnostics.reusedHandles == items.count - 1)
        // The new frames first (newest), the deleted file gone, the rest as they were.
        #expect(Set(listed.map(\.name)) == Set(card.objects.map(\.filename)))
        #expect(!listed.map(\.name).contains(deleted.filename))
        #expect(Array(listed.prefix(2).map(\.name)) == shot.reversed().map(\.filename))
        #expect(listed == listed.newestFirst())
        #expect(listed.filter { item in items.contains(item) }.count == items.count - 1)

        // A kept file is confirmed when used: one GetObjectInfo, then GetObject, and the bytes are right.
        let kept = try #require(listed.first { $0.format == .raw && items.contains($0) })
        let url = try await bench.link.bytes(of: kept.id, into: bench.directory)
        #expect(Array(bench.camera.commandsAnswered.suffix(2)) == [.getObjectInfo, .getObject])
        #expect(try Data(contentsOf: url) == Self.content(of: kept, on: bench.camera))
        // A new file was confirmed by the listing itself.
        let new = try #require(listed.first { $0.name == shot.last?.filename })
        let beforeNew = bench.camera.commandsAnswered.count
        _ = try await bench.link.bytes(of: new.id, into: bench.directory)
        #expect(Array(bench.camera.commandsAnswered.dropFirst(beforeNew)) == [.getObject])
        await bench.link.close()
    }

    /// The fault matrix's "card swapped between sessions": the new card numbers its handles from the same start, so a
    /// known handle names another file. A relist with known items can't tell (it asks no ObjectInfo for them), but
    /// the download reads the ObjectInfo first and refuses it; nothing is written under the old name.
    @Test func aHandleThatNowNamesAnotherFileIsCaughtBeforeAnythingIsWritten() async throws {
        let bench = try Self.bench(frames: [.raw, .jpeg])
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let items = try await bench.link.list()
        let raw = try #require(items.first { $0.format == .raw })

        bench.camera.dropAll()
        #expect(await events.next()?.isSessionLost == true)
        let swapped = try #require(ScriptedCard.shoot([.raw, .jpeg], start: "20261105T120000", firstNumber: 500))
            .scaled(down: 100)
        bench.camera.withResponder { $0.replaceCard(with: swapped) }
        #expect(Set(swapped.handles) == Set(bench.camera.card.handles))

        try await bench.open()
        let listed = try await bench.link.list(reusing: items)
        #expect(listed == items)  // hints, unchecked until used
        let before = bench.camera.commandsAnswered.count
        let failure = await #expect(throws: CameraLinkFailure.self) {
            try await bench.link.bytes(of: raw.id, into: bench.directory)
        }
        #expect(failure?.kind == .itemNotFound && failure?.outcome == .skipFile)
        #expect(Array(bench.camera.commandsAnswered.dropFirst(before)) == [.getObjectInfo])
        #expect(!FileManager.default.fileExists(atPath: bench.directory.appendingPathComponent(raw.name).path))
        #expect(await bench.link.diagnostics.staleHandlesRefused == 1)
        // What the engine checks before a resume: the camera's answer for the handle, which is the new file.
        let now = try await bench.link.info(of: raw.id)
        #expect(now.name != raw.name)
        #expect(now.name == swapped.objects.first { $0.format == .sonyARW }?.filename)
        // Neither the refusal nor `info(of:)` made the old item's handle good: a second try (a Copy as JPEG retry from
        // Browse) is refused the same way, and writes nothing.
        let retried = bench.camera.commandsAnswered.count
        let again = await #expect(throws: CameraLinkFailure.self) {
            try await bench.link.bytes(of: raw.id, into: bench.directory)
        }
        #expect(again?.kind == .itemNotFound)
        #expect(Array(bench.camera.commandsAnswered.dropFirst(retried)) == [.getObjectInfo])
        #expect(!FileManager.default.fileExists(atPath: bench.directory.appendingPathComponent(raw.name).path))
        #expect(!FileManager.default.fileExists(atPath: bench.directory.appendingPathComponent(now.name).path))
        #expect(await bench.link.diagnostics.staleHandlesRefused == 2)
        // Once a swap is seen, a relist no longer keeps the old items: it asks every handle and shows the new card.
        let relisted = try await bench.link.list(reusing: items)
        #expect(Set(relisted.map(\.name)) == Set(swapped.objects.map(\.filename)))
        let diagnostics = await bench.link.diagnostics
        #expect(diagnostics.reusedHandles == 0 && diagnostics.objectInfosAsked == diagnostics.listedHandles)
        await bench.link.close()
    }

    // MARK: Abort

    @Test func abortCutsTheDownloadOffKeepsThePartialAndTheResumeFinishesIt() async throws {
        let bench = try Self.bench()
        var events = bench.link.events.makeAsyncIterator()
        try await bench.open()
        let items = try await bench.link.list()
        let raw = try #require(items.first { $0.format == .raw })
        let checkpoints = Checkpoints()
        let link = bench.link
        let directory = bench.directory
        bench.gate.hold(afterReceiving: Int(raw.size / 2))
        let download = Task { () async -> CameraLinkFailure? in
            do throws(CameraLinkFailure) {
                _ = try await link.bytes(of: raw.id, into: directory, resuming: nil,
                                         checkpoint: { checkpoints.add($0) }, progress: { _ in })
                return nil
            } catch {
                return error
            }
        }
        try await bench.gate.waitUntilHoldingAReceive()
        // The continued task expired: W13's hook reaches the link through the protocol, not the type.
        let generic: any CameraLink = link
        let aborting = try #require(generic as? any TransferAborting)
        await aborting.abortCurrentTransfer()
        bench.gate.release()
        let failure = await download.value
        #expect(failure?.kind == .disconnected)
        #expect(await events.next()?.isSessionLost == true)
        #expect(!(await link.isOpen))
        #expect(await link.diagnostics.transfersAborted == 1)
        let last = try #require(checkpoints.values.last)
        #expect(last.bytesWritten > 0 && last.bytesWritten < raw.size)
        #expect(try Data(contentsOf: last.file).count == Int(last.bytesWritten))

        // Continue: reopen, relist with what is known, resume.
        try await bench.open()
        _ = try await link.list(reusing: items)
        let url = try await link.bytes(of: raw.id, into: directory, resuming: last, checkpoint: { _ in },
                                       progress: { _ in })
        #expect(try Data(contentsOf: url) == Self.content(of: raw, on: bench.camera))
        await link.close()
    }

    @Test func abortWithNothingInFlightLeavesTheSessionAlone() async throws {
        let bench = try Self.bench()
        let events = bench.link.events
        try await bench.open()
        await bench.link.abortCurrentTransfer()
        #expect(await bench.link.isOpen)
        #expect(try await bench.link.list().count == bench.camera.card.objects.count)
        #expect(await bench.link.diagnostics.transfersAborted == 0)
        await bench.link.close()
        var forwarded: [CameraLinkEvent] = []
        for await event in events { forwarded.append(event) }
        #expect(!forwarded.contains { $0.isSessionLost })
    }

    // MARK: The engine through the link

    /// The engine (W7) and the link (W8) together: a file cut midway pauses the job for the camera, the app reopens and
    /// relists with what it knows, `reconnect` hands that over, and the engine continues the file from its checkpoint
    /// with 0x9211 after checking its name and size; the imported file matches the camera's.
    @Test func theEngineResumesAFileCutMidwayThroughTheLink() async throws {
        let engine = Bench()
        let bench = try Self.bench(frames: [.raw])
        try await bench.open()
        let items = try await bench.link.list()
        let raw = try #require(items.first)
        let objectInfosBefore = bench.camera.commandsAnswered.filter { $0 == .getObjectInfo }.count

        bench.gate.hold(afterReceiving: Int(raw.size / 2))
        try await engine.engine.start(.allNew, from: bench.link, camera: engine.camera, to: engine.route)
        let job = try #require(await engine.engine.currentJobID)
        try await bench.gate.waitUntilHoldingAReceive()
        bench.camera.dropAll(losingUndelivered: true)
        bench.gate.release()
        try await engine.waitFor("the lost session") { $0 == .paused(.cameraUnreachable) }
        #expect(await engine.engine.currentProgress.filesFailed == 0)
        #expect(engine.stagedFiles() == 1)  // the partial file, kept for the resume

        try await bench.open()
        let known = try await bench.link.list(reusing: items)
        let reopened = bench.camera.commandsAnswered.count
        try await engine.engine.reconnect(job, to: bench.link, knownItems: known)
        #expect(try await engine.waitFinished() == .completed)
        engine.expectImported([raw.name], from: bench.camera.card)
        #expect(engine.stagedFiles() == 0)
        let after = Array(bench.camera.commandsAnswered.dropFirst(reopened))
        // The engine's identity check, then 0x9211 from the checkpoint; no listing, no second GetObject.
        #expect(after.first == .getObjectInfo && after.dropFirst().allSatisfy { $0 == .sonySDIOGetPartialLargeObject },
                "\(after)")
        #expect(bench.camera.commandsAnswered.filter { $0 == .getObject }.count == 1)
        // The engine's own first listing asked once per file; the relist asked nothing.
        #expect(bench.camera.commandsAnswered.filter { $0 == .getObjectInfo }.count == objectInfosBefore + 1 + 1)
        #expect(!bench.camera.commandsAnswered.contains(.getPartialObject))
        await bench.link.close()
    }
}

/// Checkpoints reported by a download, in order.
final class Checkpoints: Sendable {
    private let state = Mutex<[PartialDownload]>([])
    func add(_ value: PartialDownload) { state.withLock { $0.append(value) } }
    var values: [PartialDownload] { state.withLock { $0 } }
}
