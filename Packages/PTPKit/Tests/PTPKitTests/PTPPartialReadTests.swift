import Testing
import Foundation
@testable import PTPKit

@Suite("Partial reads and resume")
struct PTPPartialReadTests {
    static let mib: UInt32 = 1024 * 1024

    @Test("Chunks tile the object exactly, last one short")
    func tiling() throws {
        let size: UInt64 = 36_412_928 // a lossless-compressed 33 MP ARW
        let chunks = try PTPPartialRead.chunks(objectSize: size, chunkSize: 4 * Self.mib)
        #expect(chunks.count == 9)
        #expect(chunks.first == PTPPartialRead.Chunk(offset: 0, length: 4 * Self.mib))
        #expect(chunks.last?.end == size)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(a.end == b.offset) }
        #expect(chunks.reduce(UInt64(0)) { $0 + UInt64($1.length) } == size)
    }

    @Test("Resuming mid-object starts at the saved offset; a complete object has no next chunk")
    func resumeFromOffset() throws {
        let chunks = try PTPPartialRead.chunks(objectSize: 10, chunkSize: 4, from: 6)
        #expect(chunks == [.init(offset: 6, length: 4)])
        #expect(PTPPartialRead.nextChunk(at: 10, objectSize: 10) == nil)
        #expect(PTPPartialRead.nextChunk(at: 0, objectSize: 0) == nil)
        #expect(PTPPartialRead.nextChunk(at: 3, objectSize: 10, chunkSize: 0) == nil)
        #expect(throws: PTPPartialRead.PlanError.zeroChunkSize) { try PTPPartialRead.chunks(objectSize: 10, chunkSize: 0) }
    }

    @Test("A short read just moves the offset by what arrived")
    func shortRead() {
        var offset: UInt64 = 0
        var requests = 0
        while let c = PTPPartialRead.nextChunk(at: offset, objectSize: 10, chunkSize: 4) {
            requests += 1
            offset += UInt64(min(c.length, 3)) // camera returns at most 3 bytes
        }
        #expect(offset == 10)
        #expect(requests == 4)
    }

    @Test("32-bit GetPartialObject for objects under 4 GiB; 64-bit variant beyond")
    func variantChoice() {
        var info = PTPDatasetTests.syntheticSonyDeviceInfo
        #expect(PTPPartialRead.variant(objectSize: 50_000_000, device: info) == .standard32)
        #expect(PTPPartialRead.variant(objectSize: 5_000_000_000, device: info) == nil)
        info.operationsSupported.append(PTPOperationCode.getPartialObject64.rawValue)
        #expect(PTPPartialRead.variant(objectSize: 5_000_000_000, device: info) == .extended64)
        info.operationsSupported.removeAll { $0 == PTPOperationCode.getPartialObject.rawValue }
        #expect(PTPPartialRead.variant(objectSize: 50_000_000, device: info) == .extended64)
    }

    @Test("Commands carry the chunk; 32-bit refuses offsets it cannot address")
    func commands() throws {
        let h = PTPObjectHandle(rawValue: 0x1234)
        let c32 = try PTPPartialRead.command(h, chunk: .init(offset: 8 * UInt64(Self.mib), length: Self.mib), variant: .standard32, tx: 3)
        #expect(c32.operationCode == .getPartialObject)
        #expect(c32.parameters == [0x1234, 8 * Self.mib, Self.mib])

        let far = PTPPartialRead.Chunk(offset: 0x1_0000_0010, length: 16)
        #expect(throws: PTPPartialRead.PlanError.beyond32BitOffset(far)) {
            try PTPPartialRead.command(h, chunk: far, variant: .standard32, tx: 4)
        }
        let c64 = try PTPPartialRead.command(h, chunk: far, variant: .extended64, tx: 4)
        #expect(c64.operationCode == .getPartialObject64)
        #expect(c64.parameters == [0x1234, 0x10, 0x1, 16])

        // The last addressable byte is UInt32.max; a chunk ending exactly there is fine.
        let edge = PTPPartialRead.Chunk(offset: UInt64(UInt32.max) - 3, length: 4)
        #expect(throws: Never.self) { try PTPPartialRead.command(h, chunk: edge, variant: .standard32, tx: 5) }
        let zero = PTPPartialRead.Chunk(offset: 0, length: 0)
        #expect(throws: Never.self) { try PTPPartialRead.command(h, chunk: zero, variant: .standard32, tx: 6) }
    }

    @Test("Resume only when the object is the same one")
    func resumeRule() {
        let saved = PTPObjectIdentity(cameraSerial: "123", filename: "DSC04512.ARW", captureDateRaw: "20261031T211412", size: 36_412_928)
        #expect(PTPPartialRead.resumeOffset(savedOffset: 16_777_216, saved: saved, current: saved) == 16_777_216)

        var swapped = saved
        swapped.captureDateRaw = "20261101T090000" // card swapped, counter reused the name
        #expect(PTPPartialRead.resumeOffset(savedOffset: 16_777_216, saved: saved, current: swapped) == 0)

        var resized = saved
        resized.size = 1000
        #expect(PTPPartialRead.resumeOffset(savedOffset: 16_777_216, saved: saved, current: resized) == 0)

        #expect(PTPPartialRead.resumeOffset(savedOffset: saved.size + 1, saved: saved, current: saved) == 0)
    }

    @Test("Checkpoints every 16 MiB, not every chunk")
    func checkpoints() {
        let m = UInt64(Self.mib)
        #expect(!PTPPartialRead.crossesCheckpoint(from: 0, to: 4 * m))
        #expect(!PTPPartialRead.crossesCheckpoint(from: 12 * m, to: 16 * m - 1))
        #expect(PTPPartialRead.crossesCheckpoint(from: 12 * m, to: 16 * m))
        #expect(PTPPartialRead.crossesCheckpoint(from: 15 * m, to: 33 * m))
        #expect(!PTPPartialRead.crossesCheckpoint(from: 20 * m, to: 20 * m))
        #expect(!PTPPartialRead.crossesCheckpoint(from: 0, to: 100, interval: 0))
    }
}
