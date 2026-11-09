import Foundation
import PTPKit
import Testing
@testable import CameraTransport

/// The pure parts of `IPLink`'s 0x9211 resume and reopen (plan W8): the capabilities a DeviceInfo earns, where a
/// partial file continues from, the chunk and checkpoint rules, the relist's reuse of known items, and the file sink's
/// cut-back and checkpoint bookkeeping. The link itself runs against the simulated camera in PTPSimulator's
/// `IPLinkResumeAgainstSimulatorTests`.
@Suite("IPLink's resume and reopen rules")
struct IPResumeLogicTests {
    static let mib: UInt64 = 1024 * 1024

    /// A Sony body's DeviceInfo listing `operations` (no serial: nothing here needs one).
    static func deviceInfo(operations: [PTPOperationCode], manufacturer: String = "Sony Corporation",
                           vendor: UInt32 = 0x11) -> PTPDeviceInfo {
        PTPDeviceInfo(standardVersion: 100, vendorExtensionID: vendor, vendorExtensionVersion: 100,
                      vendorExtensionDescription: "", functionalMode: 0, operationsSupported: operations.map(\.rawValue),
                      eventsSupported: [], devicePropertiesSupported: [], captureFormats: [], imageFormats: [],
                      manufacturer: manufacturer, model: "ILCE-7CM2", deviceVersion: "1.00", serialNumber: "")
    }

    // MARK: Capabilities

    @Test func resumeIsReportedOnlyOnceDeviceInfoLists0x9211() {
        let whole: [PTPOperationCode] = [.getObject, .sonySDIOOpenSession, .sonySDIOSetContentsTransferMode]
        #expect(IPLink.capabilities(for: nil) == IPLink.capabilitiesWithoutResume)
        #expect(IPLink.capabilities(for: Self.deviceInfo(operations: whole)) == IPLink.capabilitiesWithoutResume)
        let with9211 = Self.deviceInfo(operations: whole + [.sonySDIOGetPartialLargeObject])
        #expect(IPLink.capabilities(for: with9211) == .wifi)
        #expect(IPLink.capabilities(for: with9211).resumesPartialFiles)
        // 0x101B and 0x9219 don't earn it: they answer InvalidObjectHandle in this session.
        let without = Self.deviceInfo(operations: whole + [.getPartialObject, .sonySDIO0x9219])
        #expect(!IPLink.capabilities(for: without).resumesPartialFiles)
        // A vendor code means nothing on another maker's body.
        let other = Self.deviceInfo(operations: whole + [.sonySDIOGetPartialLargeObject], manufacturer: "Other",
                                    vendor: 0x6)
        #expect(!IPLink.capabilities(for: other).resumesPartialFiles)
        // Everything else is the carrier's baseline either way.
        let without9211 = IPLink.capabilities(for: nil)
        #expect(without9211.maxDownloadsInFlight == 1 && !without9211.deletes && without9211.itemIDsSurviveReopen)
    }

    @Test func theChunkIsTheSpikes4MiBUnlessConfigured() {
        #expect(IPLink.Configuration(guid: UUID()).partialReadChunkSize == 4 * 1024 * 1024)
    }

    // MARK: Where a partial file continues from

    @Test func aUsablePartialResumesAtItsOffset() {
        #expect(IPPartialReader.start(offset: 22 * Self.mib, fileLength: 22 * Self.mib, objectSize: 40 * Self.mib)
            == .resume(at: 22 * Self.mib))
        // A file longer than its offset is cut back to it: what lies beyond was never checkpointed.
        #expect(IPPartialReader.start(offset: 100, fileLength: 5_000, objectSize: 10_000) == .resume(at: 100))
        // Already whole.
        #expect(IPPartialReader.start(offset: 10_000, fileLength: 10_000, objectSize: 10_000) == .complete)
    }

    @Test func anUnusablePartialIsCopiedAgainFromZero() {
        func restarts(_ start: IPPartialReader.Start) -> Bool {
            if case .restart = start { true } else { false }
        }
        #expect(restarts(IPPartialReader.start(offset: 100, fileLength: nil, objectSize: 1_000)))  // missing
        #expect(restarts(IPPartialReader.start(offset: 100, fileLength: 99, objectSize: 1_000)))   // short
        #expect(restarts(IPPartialReader.start(offset: 1_001, fileLength: 2_000, objectSize: 1_000)))  // past the end
        #expect(restarts(IPPartialReader.start(offset: 0, fileLength: 0, objectSize: 1_000)))      // nothing to continue
        // 4 GiB or more: ObjectInfo says 0xFFFFFFFF and the end isn't known.
        #expect(restarts(IPPartialReader.start(offset: 100, fileLength: 100, objectSize: UInt64(UInt32.max))))
        #expect(!IPPartialReader.canResume(objectSize: UInt64(UInt32.max)) && !IPPartialReader.canResume(objectSize: 0))
        #expect(IPPartialReader.canResume(objectSize: 1))
    }

    // MARK: Chunks and checkpoints

    @Test func chunksRunFromTheOffsetWithACheckpointAfterEachButTheLast() {
        let size = 10 * Self.mib + 5
        var reader = IPPartialReader(offset: 3 * Self.mib, objectSize: size, chunkSize: UInt32(4 * Self.mib))
        var steps: [IPPartialReader.Step] = []
        var chunks: [PTPPartialRead.Chunk] = []
        while let chunk = reader.nextChunk {
            chunks.append(chunk)
            steps.append(reader.received(UInt64(chunk.length), of: chunk))
        }
        #expect(chunks.map(\.offset) == [3 * Self.mib, 7 * Self.mib])
        #expect(chunks.map(\.length) == [UInt32(4 * Self.mib), UInt32(3 * Self.mib + 5)])
        #expect(steps == [.checkpoint(7 * Self.mib), .complete])
        #expect(reader.isComplete && reader.nextChunk == nil)
    }

    @Test func aShortReadMovesTheOffsetByWhatArrived() throws {
        var reader = IPPartialReader(offset: 0, objectSize: 1_000, chunkSize: 400)
        let first = try #require(reader.nextChunk)
        #expect(reader.received(150, of: first) == .checkpoint(150))
        let second = try #require(reader.nextChunk)
        #expect(second == PTPPartialRead.Chunk(offset: 150, length: 400))
    }

    @Test func nothingOrTooMuchIsRefusedAndLeavesTheOffset() throws {
        var reader = IPPartialReader(offset: 100, objectSize: 1_000, chunkSize: 400)
        let chunk = try #require(reader.nextChunk)
        if case .failed = reader.received(0, of: chunk) {} else { Issue.record("an empty read was accepted") }
        if case .failed = reader.received(401, of: chunk) {} else { Issue.record("an overlong read was accepted") }
        let stale = PTPPartialRead.Chunk(offset: 0, length: 400)
        if case .failed = reader.received(400, of: stale) {} else { Issue.record("a stale chunk was accepted") }
        #expect(reader.offset == 100)
        // A zero chunk size counts as 1 rather than hanging.
        #expect(IPPartialReader(offset: 0, objectSize: 10, chunkSize: 0).nextChunk?.length == 1)
    }

    @Test func aBreakMidChunkCheckpointsWhatArrivedOfIt() {
        let reader = IPPartialReader(offset: 400, objectSize: 1_000, chunkSize: 400)
        let chunk = PTPPartialRead.Chunk(offset: 400, length: 400)
        #expect(reader.checkpoint(afterBreakIn: chunk, written: 650) == 650)
        // Never past the chunk (bytes beyond it weren't asked for), never behind the offset.
        #expect(reader.checkpoint(afterBreakIn: chunk, written: 900) == 800)
        #expect(reader.checkpoint(afterBreakIn: chunk, written: 10) == 400)
    }

    @Test func aWholeFileCopyCheckpointsAtEachStrideButNotAtItsEnd() {
        let stride: UInt64 = 4 * Self.mib
        let size = 8 * Self.mib
        #expect(!IPPartialReader.streamCheckpointDue(previous: 0, current: stride - 1, objectSize: size, stride: stride))
        #expect(IPPartialReader.streamCheckpointDue(previous: 0, current: stride + 10, objectSize: size, stride: stride))
        #expect(!IPPartialReader.streamCheckpointDue(previous: stride + 10, current: stride + 20, objectSize: size,
                                                     stride: stride))
        // The last bytes cross 8 MiB, but the file is whole: nothing is left to resume.
        #expect(!IPPartialReader.streamCheckpointDue(previous: stride + 10, current: size, objectSize: size,
                                                     stride: stride))
    }

    @Test func theCommandIs0x9211WithFiveParameters() {
        let handle = PTPObjectHandle(rawValue: 0x4000_10A3)
        let chunk = PTPPartialRead.Chunk(offset: 0x1_2345_6789, length: 0x40_0000)
        let command = IPLink.partialRead(handle, chunk: chunk, variant: .sonyLarge9211, tx: 7)
        #expect(command.code == PTPOperationCode.sonySDIOGetPartialLargeObject.rawValue)
        #expect(command.transactionID == 7)
        #expect(command.parameters == [0x4000_10A3, 0x2345_6789, 0x1, 0x40_0000, 0])
    }

    // MARK: Reopen without relisting

    private func item(_ handle: UInt32, _ name: String, size: UInt64 = 100) -> CameraItem {
        CameraItem(id: IPItemID.id(for: PTPObjectHandle(rawValue: handle)), folder: "", name: name, size: size,
                   captureDate: nil)
    }

    @Test func aRelistAsksOnlyForHandlesItDoesNotKnow() {
        let known = [item(1, "DSC00001.ARW"), item(2, "DSC00001.JPG"), item(3, "DSC00002.ARW")]
        let listed = [1, 0x8_0000, 2, 4, 5].map(PTPObjectHandle.init(rawValue:))
        let (kept, unseen) = IPListing.reuse(known, listed: listed)
        #expect(Set(kept.keys.map(\.rawValue)) == [1, 2])          // 3 has gone
        #expect(kept[PTPObjectHandle(rawValue: 2)]?.name == "DSC00001.JPG")
        // In listing order; the folder is always asked, so new files get their folder path.
        #expect(unseen.map(\.rawValue) == [0x8_0000, 4, 5])
    }

    @Test func foreignOrUnsafeKnownItemsAreNotKept() {
        let foreign = CameraItem(id: CameraItem.ID(rawValue: "usb-1"), folder: "", name: "DSC00001.ARW", size: 1,
                                 captureDate: nil)
        let known = [foreign, item(2, "../escape"), item(3, "DSC00003.ARW"), item(3, "DSC09999.ARW")]
        let (kept, unseen) = IPListing.reuse(known, listed: [1, 2, 3].map(PTPObjectHandle.init(rawValue:)))
        #expect(Array(kept.keys.map(\.rawValue)) == [3])
        #expect(kept[PTPObjectHandle(rawValue: 3)]?.name == "DSC00003.ARW")  // the first of two wins
        #expect(unseen.map(\.rawValue) == [1, 2])
        // Nothing known: every handle is asked, as `list()` does.
        #expect(IPListing.reuse([], listed: [7, 8].map(PTPObjectHandle.init(rawValue:))).unseen.map(\.rawValue) == [7, 8])
    }

    // MARK: The file sink

    private func temporaryFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPResumeLogicTests-\(UUID().uuidString)", isDirectory: false)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func continuingCutsTheFileBackToItsOffsetAndAppends() throws {
        let url = try temporaryFile(Array(0 ..< 10))
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try IPFileSink(continuing: url, at: 4)
        #expect(sink.written == 4)
        #expect(sink.write(Data([40, 50])) == 6)
        #expect(sink.finish().failure == nil)
        #expect(try Data(contentsOf: url) == Data([0, 1, 2, 3, 40, 50]))
        #expect(IPLink.length(of: url) == 6)
        #expect(IPLink.length(of: url.appendingPathExtension("missing")) == nil)
    }

    @Test func eachCheckpointIsReportedOnceForwardsAndOnDisk() throws {
        let url = try temporaryFile(Array(0 ..< 8))
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try IPFileSink(continuing: url, at: 8)
        #expect(!sink.reportCheckpoint(at: 8, objectSize: 100))   // where it started: already known
        #expect(!sink.reportCheckpoint(at: 9, objectSize: 100))   // not on disk yet
        _ = sink.write(Data(repeating: 1, count: 12))
        #expect(sink.reportCheckpoint(at: 20, objectSize: 100))
        #expect(!sink.reportCheckpoint(at: 20, objectSize: 100))  // once
        #expect(!sink.reportCheckpoint(at: 15, objectSize: 100))  // never backwards
        #expect(!sink.reportCheckpoint(at: 20, objectSize: 20))   // never at the end
        // A whole-file copy's stride.
        _ = sink.write(Data(repeating: 2, count: 20))              // 40 on disk
        #expect(sink.reportCheckpoint(ifStreamCrosses: 32, objectSize: 100))
        #expect(!sink.reportCheckpoint(ifStreamCrosses: 32, objectSize: 100))
        _ = sink.finish()
    }

    /// A refused first 0x9211 read falls back to GetObject only when the camera refused the read itself, not for a
    /// missing card, a lost session, a busy camera or a short data phase (the engine retries those as they are).
    @Test func onlyARefusedReadFallsBackToGetObject() {
        for kind in CameraLinkFailure.Kind.allCases {
            let expected = [.itemNotFound, .unreadableItem, .modeListsNoFiles].contains(kind)
            #expect(IPLink.fallsBackToGetObject(after: CameraLinkFailure(kind, detail: "")) == expected, "\(kind)")
        }
        let invalidHandle = IPFailureMapping.failure(.invalidObjectHandle, during: .download, cardRemoved: false)
        #expect(IPLink.fallsBackToGetObject(after: invalidHandle))
        let cardGone = IPFailureMapping.failure(.invalidObjectHandle, during: .download, cardRemoved: true)
        #expect(!IPLink.fallsBackToGetObject(after: cardGone))
    }
}
