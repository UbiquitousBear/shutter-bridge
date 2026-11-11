import Foundation
import PTPKit
import Synchronization
import Testing
@testable import CameraTransport

/// A scratch folder with a Staging folder and an engine work folder in it, removed when the test is done.
private final class Scratch: Sendable {
    let root: URL
    let staging: URL
    let work: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-link-\(UUID().uuidString)")
        staging = root.appendingPathComponent("Staging")
        work = root.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Writes `bytes` into Staging under `name` and returns an entry that names them.
    func stage(
        _ name: String, folder: String = "DCIM/100MSDCF", bytes: Data, date: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> StagedEntry {
        let url = staging.appendingPathComponent("\(folder.replacingOccurrences(of: "/", with: "_"))_\(name)")
        try bytes.write(to: url)
        return StagedEntry(folder: folder, name: name, captureDate: date, size: UInt64(bytes.count), url: url)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

private func pattern(_ count: Int, seed: UInt8 = 7) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

private let standInDescriptor = CameraDescriptor(id: .init(rawValue: "staging-test"), name: "Staging", mode: .wifi(.otherNetwork))

private func makeLink(_ entries: [StagedEntry], reader: any StagedFileReading = PlainStagedFileReader()) -> StagingFolderLink {
    StagingFolderLink(descriptor: standInDescriptor, entries: entries, reader: reader)
}

/// Bytes written so far, as a copy reports them.
private final class Reports: Sendable {
    private let state = Mutex<[UInt64]>([])
    func add(_ n: UInt64) { state.withLock { $0.append(n) } }
    var all: [UInt64] { state.withLock { $0 } }
}

/// A reader that never finishes by itself: it waits until its task is cancelled, as a slow disk or a large iCloud
/// file would, and says when it started.
private final class SlowReader: StagedFileReading {
    private let started = Mutex(false)
    var hasStarted: Bool { started.withLock { $0 } }

    func presence(of source: URL, expectedSize: UInt64) -> StagedPresence { .present }

    func copy(
        _ source: URL, expectedSize: UInt64, to destination: URL, progress: @escaping @Sendable (UInt64) -> Void
    ) async throws(CameraLinkFailure) {
        started.withLock { $0 = true }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        throw StagedFileCopy.cancelled()
    }
}

@Suite("StagingFolderLink: listing and identity", .timeLimit(.minutes(1)))
struct StagingFolderLinkListingTests {
    @Test func listsEntriesWithTheirOriginalIdentity() async throws {
        let scratch = try Scratch()
        let date = Date(timeIntervalSince1970: 1_699_000_000)
        let raw = try scratch.stage("DSC04512.ARW", folder: "DCIM/100MSDCF", bytes: pattern(100), date: date)
        let jpg = try scratch.stage("DSC04512.JPG", folder: "DCIM/100MSDCF", bytes: pattern(40), date: date)
        let link = makeLink([raw, jpg])
        try await link.open()
        let items = try await link.list()

        #expect(items.count == 2)
        let arw = try #require(items.first { $0.name == "DSC04512.ARW" })
        #expect(arw.folder == "DCIM/100MSDCF")
        #expect(arw.size == 100)
        #expect(arw.captureDate == date)
        #expect(arw.format == CameraItem.format(ofFilename: "DSC04512.ARW"))
        let jpeg = try #require(items.first { $0.name == "DSC04512.JPG" })
        #expect(jpeg.size == 40)
        #expect(jpeg.format == CameraItem.format(ofFilename: "DSC04512.JPG"))
        #expect(arw.id != jpeg.id)
    }

    @Test func aFormatGivenByTheCallerIsKept() async throws {
        let scratch = try Scratch()
        var entry = try scratch.stage("DSC00001.ARW", bytes: pattern(8))
        entry.format = .other
        let items = try await makeLink([entry]).list()
        #expect(items.first?.format == .other)
    }

    @Test func aNameFromTwoCardFoldersIsTwoFilesAndOneIdentityTwiceIsOne() async throws {
        let scratch = try Scratch()
        let a = try scratch.stage("DSC00001.ARW", folder: "DCIM/100MSDCF", bytes: pattern(10))
        let b = try scratch.stage("DSC00001.ARW", folder: "DCIM/101MSDCF", bytes: pattern(10))
        var again = a
        again.url = b.url   // the same identity listed twice
        let items = try await makeLink([a, b, again]).list()
        #expect(items.count == 2)
        #expect(Set(items.map(\.folder)) == ["DCIM/100MSDCF", "DCIM/101MSDCF"])
    }

    @Test func listsNewestFirstAndKeepsAnItemWithNoDateLast() async throws {
        let scratch = try Scratch()
        let old = try scratch.stage("A.ARW", bytes: pattern(4), date: Date(timeIntervalSince1970: 100))
        let new = try scratch.stage("B.ARW", bytes: pattern(4), date: Date(timeIntervalSince1970: 200))
        let undated = try scratch.stage("C.ARW", bytes: pattern(4), date: nil)
        let items = try await makeLink([undated, old, new]).list()
        #expect(items.map(\.name) == ["B.ARW", "A.ARW", "C.ARW"])
    }

    @Test func infoReturnsTheEntryAndAnUnknownIDIsNotFound() async throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(12))
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        #expect(try await link.info(of: item.id) == item)
        do throws(CameraLinkFailure) { _ = try await link.info(of: .init(rawValue: "nope")) } catch { #expect(error.kind == .itemNotFound) }
    }

    @Test func infoOfAFileThatWentIsNotFound() async throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(12))
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        try FileManager.default.removeItem(at: entry.url)
        do throws(CameraLinkFailure) { _ = try await link.info(of: item.id); Issue.record("expected a failure") } catch {
            #expect(error.kind == .itemNotFound)
        }
    }

    @Test func thumbnailsAreNotThere() async throws {
        let scratch = try Scratch()
        let link = makeLink([try scratch.stage("DSC00001.ARW", bytes: pattern(12))])
        let item = try #require(try await link.list().first)
        do throws(CameraLinkFailure) { _ = try await link.thumbnail(of: item.id); Issue.record("expected a failure") } catch {
            #expect(error.kind == .unreadableItem)
            #expect(error.outcome == .skipFile)
        }
    }

    @Test func capabilitiesAreALocalCopyWithNoDeleteResumeOrThumbnails() async {
        let link = makeLink([])
        let caps = link.capabilities
        #expect(caps.maxDownloadsInFlight == 2)
        #expect(!caps.resumesPartialFiles)
        #expect(!caps.deletes)
        #expect(!caps.reportsBatteryAndFreeSpace)
        #expect(link.descriptor == standInDescriptor)
    }
}

@Suite("StagingFolderLink: copying", .timeLimit(.minutes(1)))
struct StagingFolderLinkCopyTests {
    @Test func copiesIntoTheWorkFolderUnderTheCameraNameAndLeavesTheStagedFileAlone() async throws {
        let scratch = try Scratch()
        let content = pattern(2_600_000)   // three chunks
        let entry = try scratch.stage("DSC04512.ARW", bytes: content)
        let before = try FileManager.default.attributesOfItem(atPath: entry.url.path)
        let link = makeLink([entry])
        try await link.open()
        let item = try #require(try await link.list().first)

        let reports = Reports()
        let copied = try await link.bytes(of: item.id, into: scratch.work, progress: { reports.add($0) })

        #expect(copied == scratch.work.appendingPathComponent("DSC04512.ARW"))
        #expect(try Data(contentsOf: copied) == content)
        // Copy, never move: the staged file is where it was, with the same bytes and the same modification date.
        #expect(scratch.exists(entry.url))
        #expect(try Data(contentsOf: entry.url) == content)
        let after = try FileManager.default.attributesOfItem(atPath: entry.url.path)
        #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        // Progress counts up to the file's size.
        let seen = reports.all
        #expect(seen == seen.sorted())
        #expect(seen.last == UInt64(content.count))
        #expect(seen.count >= 3)
    }

    @Test func aFreshCopyReplacesWhatAnInterruptedOneLeft() async throws {
        let scratch = try Scratch()
        let content = pattern(5000)
        let entry = try scratch.stage("DSC00001.ARW", bytes: content)
        try Data(repeating: 0xFF, count: 9000).write(to: scratch.work.appendingPathComponent("DSC00001.ARW"))
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        let copied = try await link.bytes(of: item.id, into: scratch.work)
        #expect(try Data(contentsOf: copied) == content)
    }

    @Test func createsTheWorkFolderIfItIsMissing() async throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(300))
        let nested = scratch.work.appendingPathComponent("job-1/files")
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        let copied = try await link.bytes(of: item.id, into: nested)
        #expect(try Data(contentsOf: copied) == pattern(300))
    }

    @Test func anEmptyFileCopies() async throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("EMPTY.ARW", bytes: Data())
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        let copied = try await link.bytes(of: item.id, into: scratch.work)
        #expect(try Data(contentsOf: copied).isEmpty)
    }

    @Test func resumeIsIgnoredAndNoCheckpointIsKept() async throws {
        let scratch = try Scratch()
        let content = pattern(3_000_000)
        let entry = try scratch.stage("DSC00001.ARW", bytes: content)
        let partial = scratch.work.appendingPathComponent("DSC00001.ARW")
        try content.prefix(1000).write(to: partial)
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        let checkpoints = Reports()
        let copied = try await link.bytes(
            of: item.id, into: scratch.work, resuming: PartialDownload(file: partial, bytesWritten: 1000),
            checkpoint: { checkpoints.add($0.bytesWritten) }, progress: { _ in })
        #expect(try Data(contentsOf: copied) == content)
        #expect(checkpoints.all.isEmpty)
    }

    @Test func aMissingFileIsNotFoundAndWritesNothing() async throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(100))
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        try FileManager.default.removeItem(at: entry.url)
        do throws(CameraLinkFailure) { _ = try await link.bytes(of: item.id, into: scratch.work); Issue.record("expected a failure") } catch {
            #expect(error.kind == .itemNotFound)
            #expect(error.outcome == .skipFile)
        }
        #expect(!scratch.exists(scratch.work.appendingPathComponent("DSC00001.ARW")))
    }

    @Test func aFolderWhereTheFileShouldBeIsNotFound() async throws {
        let scratch = try Scratch()
        var entry = try scratch.stage("DSC00001.ARW", bytes: pattern(100))
        try FileManager.default.removeItem(at: entry.url)
        try FileManager.default.createDirectory(at: entry.url, withIntermediateDirectories: false)
        entry.size = 100
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        do throws(CameraLinkFailure) { _ = try await link.bytes(of: item.id, into: scratch.work); Issue.record("expected a failure") } catch {
            #expect(error.kind == .itemNotFound)
        }
    }

    @Test func aChangedSizeIsNotFoundAndTheStagedFileIsKept() async throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(100))
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        try pattern(101).write(to: entry.url)   // replaced by a different file
        do throws(CameraLinkFailure) { _ = try await link.bytes(of: item.id, into: scratch.work); Issue.record("expected a failure") } catch {
            #expect(error.kind == .itemNotFound)
        }
        #expect(!scratch.exists(scratch.work.appendingPathComponent("DSC00001.ARW")))
        #expect(try Data(contentsOf: entry.url) == pattern(101))
    }

    @Test func aFileThatGrowsWhileItIsReadIsNotFoundAndLeavesNoCopy() throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(64))
        let destination = scratch.work.appendingPathComponent("DSC00001.ARW")
        do throws(CameraLinkFailure) {
            try StagedFileCopy.copy(
                from: entry.url, to: destination, expectedSize: 64, chunkSize: 16, isCancelled: { false },
                progress: { written in
                    if written == 16, let handle = try? FileHandle(forWritingTo: entry.url) {
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: Data(repeating: 1, count: 10))
                        try? handle.close()
                    }
                })
            Issue.record("expected a failure")
        } catch {
            #expect(error.kind == .itemNotFound)
        }
        #expect(!scratch.exists(destination))
        #expect(scratch.exists(entry.url))
    }

    @Test func aFileThatEndsShortIsNotFoundAndLeavesNoCopy() throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(64))
        let destination = scratch.work.appendingPathComponent("DSC00001.ARW")
        do throws(CameraLinkFailure) {
            try StagedFileCopy.copy(
                from: entry.url, to: destination, expectedSize: 64, chunkSize: 16, isCancelled: { false },
                progress: { written in
                    if written == 16 { try? Data(pattern(20)).write(to: entry.url) }   // truncated under the reader
                })
            Issue.record("expected a failure")
        } catch {
            #expect(error.kind == .itemNotFound)
        }
        #expect(!scratch.exists(destination))
    }

    @Test func aNameThatIsAPathIsNeverWrittenOutsideTheWorkFolder() async throws {
        let scratch = try Scratch()
        let source = try scratch.stage("real.ARW", bytes: pattern(10))
        for bad in ["../escaped.ARW", "a/b.ARW", "..", ""] {
            var entry = source
            entry.name = bad
            let link = makeLink([entry])
            let items = try await link.list()
            let item = try #require(items.first)
            do throws(CameraLinkFailure) { _ = try await link.bytes(of: item.id, into: scratch.work); Issue.record("expected a failure for \(bad)") } catch {
                #expect(error.kind == .unreadableItem)
            }
        }
        #expect(!scratch.exists(scratch.root.appendingPathComponent("escaped.ARW")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.work.path).isEmpty)
    }

    @Test func aPlainReaderSeesPresenceBeforeOpeningTheFile() throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(10))
        let reader = PlainStagedFileReader()
        #expect(reader.presence(of: entry.url, expectedSize: 10) == .present)
        #expect(reader.presence(of: entry.url, expectedSize: 11) == .sizeChanged)
        #expect(reader.presence(of: scratch.staging.appendingPathComponent("nothing"), expectedSize: 10) == .missing)
        #expect(reader.presence(of: scratch.staging, expectedSize: 10) == .missing)
    }
}

@Suite("StagingFolderLink: cancelling and closing", .timeLimit(.minutes(1)))
struct StagingFolderLinkCancellationTests {
    /// Waits, in short bounded steps, until `condition` holds.
    private func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func cancellingASlowCopyEndsItAsTheLinksCancelAndKeepsTheStagedFile() async throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(100))
        let reader = SlowReader()
        let link = makeLink([entry], reader: reader)
        let item = try #require(try await link.list().first)

        let work = scratch.work
        let task = Task { () -> CameraLinkFailure? in
            do throws(CameraLinkFailure) { _ = try await link.bytes(of: item.id, into: work); return nil } catch { return error }
        }
        #expect(await waitUntil { reader.hasStarted })
        task.cancel()
        let failure = await task.value
        #expect(failure?.kind == .busy)
        #expect(failure?.detail?.contains("cancelled") == true)
        #expect(scratch.exists(entry.url))
    }

    @Test func theLinkStaysUsableAfterACancelledCopy() async throws {
        let scratch = try Scratch()
        let content = pattern(5000)
        let entry = try scratch.stage("DSC00001.ARW", bytes: content)
        let link = makeLink([entry])
        let item = try #require(try await link.list().first)
        let work = scratch.work
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return (try? await link.bytes(of: item.id, into: work)) == nil
        }
        task.cancel()
        #expect(await task.value)   // started cancelled, so the copy ended before it wrote anything
        #expect(!scratch.exists(work.appendingPathComponent("DSC00001.ARW")))
        let copied = try await link.bytes(of: item.id, into: work)
        #expect(try Data(contentsOf: copied) == content)
    }

    @Test func aCopyCancelledBetweenChunksLeavesNoFile() throws {
        let scratch = try Scratch()
        let entry = try scratch.stage("DSC00001.ARW", bytes: pattern(64))
        let destination = scratch.work.appendingPathComponent("DSC00001.ARW")
        let chunks = Mutex(0)
        do throws(CameraLinkFailure) {
            try StagedFileCopy.copy(
                from: entry.url, to: destination, expectedSize: 64, chunkSize: 16,
                isCancelled: { chunks.withLock { $0 >= 2 } },
                progress: { _ in chunks.withLock { $0 += 1 } })
            Issue.record("expected a cancel")
        } catch {
            #expect(error.kind == .busy)
        }
        #expect(chunks.withLock { $0 } == 2)
        #expect(!scratch.exists(destination))
        #expect(try Data(contentsOf: entry.url) == pattern(64))
    }

    @Test func closeFinishesEventsAndRefusesFurtherCalls() async throws {
        let scratch = try Scratch()
        let link = makeLink([try scratch.stage("DSC00001.ARW", bytes: pattern(10))])
        let item = try #require(try await link.list().first)
        let events = link.events
        await link.close()
        await link.close()   // closing a closed link does nothing
        var seen = 0
        for await _ in events { seen += 1 }
        #expect(seen == 0)   // no events at all
        for await _ in link.events { seen += 1 }   // a stream read after close is already finished
        #expect(seen == 0)
        do throws(CameraLinkFailure) { try await link.open(); Issue.record("expected a failure") } catch { #expect(error.kind == .disconnected) }
        do throws(CameraLinkFailure) { _ = try await link.list(); Issue.record("expected a failure") } catch { #expect(error.kind == .disconnected) }
        do throws(CameraLinkFailure) { _ = try await link.bytes(of: item.id, into: scratch.work); Issue.record("expected a failure") } catch {
            #expect(error.kind == .disconnected)
        }
    }

    @Test func openingAnOpenLinkDoesNothing() async throws {
        let link = makeLink([])
        try await link.open()
        try await link.open()
        #expect(try await link.list().isEmpty)
    }
}

@Suite("StagedFileCopy: iCloud download progress", .timeLimit(.minutes(1)))
struct StagedDownloadProgressTests {
    @Test func theDownloadTakesTheFirstHalfOfTheFileAndGrowsWithThePercent() {
        let size: UInt64 = 50_000_000
        let steps = [0, 1, 10, 50, 99, 100].map { StagedFileCopy.downloadProgress(percent: Double($0), expectedSize: size) }
        #expect(steps == steps.sorted())
        #expect(steps.first == 0)
        #expect(steps.last == size / 2)
        #expect(steps.allSatisfy { $0 < size })
    }

    @Test func oddPercentsAreClamped() {
        let size: UInt64 = 1000
        #expect(StagedFileCopy.downloadProgress(percent: -5, expectedSize: size) == 0)
        #expect(StagedFileCopy.downloadProgress(percent: .nan, expectedSize: size) == 0)
        #expect(StagedFileCopy.downloadProgress(percent: .infinity, expectedSize: size) == 0)
        #expect(StagedFileCopy.downloadProgress(percent: 250, expectedSize: size) == 500)
        #expect(StagedFileCopy.downloadProgress(percent: 50, expectedSize: 0) == 0)
    }
}
