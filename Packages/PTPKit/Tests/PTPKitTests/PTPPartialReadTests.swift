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

    @Test("Sony four-parameter GetPartialObject splits the offset low/high and keeps code 0x101B")
    func sony64Builder() {
        let h = PTPObjectHandle(rawValue: 0x400010A3)
        let c = PTPCommand.getPartialObjectSony(h, offset: 0x2_0000_0010, length: 4 * Self.mib, tx: 9)
        #expect(c.operationCode == .getPartialObject)
        #expect(c.code == 0x101B)
        #expect(c.transactionID == 9)
        #expect(c.parameters == [0x400010A3, 0x10, 0x2, 4 * Self.mib])
        #expect(PTPCommand.getPartialObjectSony(h, offset: 0, length: 0, tx: 1).parameters == [0x400010A3, 0, 0, 0])
        #expect(PTPCommand.getPartialObjectSony(h, offset: .max, length: .max, tx: 1).parameters == [0x400010A3, .max, .max, .max])
        #expect(c.encode().count == 28)
    }

    @Test("Sony large-object builder widens the length to u64 and builds with any code")
    func sonyLargeBuilder() {
        let h = PTPObjectHandle(rawValue: 0x400010A3)
        let c = PTPCommand.sonyGetPartialLargeObject(code: 0x9211, h, offset: 0x1_0000_0020, length: 0x3_0000_0040, tx: 5)
        #expect(c.operationCode == .sonySDIOGetPartialLargeObject)
        #expect(c.code == 0x9211)
        #expect(c.transactionID == 5)
        #expect(c.parameters == [0x400010A3, 0x20, 0x1, 0x40, 0x3])
        #expect(PTPCommand.sonyGetPartialLargeObject(code: 0x9219, h, offset: 0, length: 16, tx: 6).parameters == [0x400010A3, 0, 0, 16, 0])
        #expect(PTPCommand.sonyGetPartialLargeObject(code: 0x9219, h, offset: .max, length: .max, tx: 6).parameters == [0x400010A3, .max, .max, .max, .max])
        #expect(PTPCommand.sonyGetPartialLargeObject(code: 0x9219, h, offset: 0, length: 0, tx: 6).operationCode == .sonySDIO0x9219)
        // Precondition-free: an unrelated code still builds.
        let odd = PTPCommand.sonyGetPartialLargeObject(code: 0x0000, h, offset: 1, length: 2, tx: 7)
        #expect(odd.code == 0)
        #expect(odd.parameters == [0x400010A3, 1, 0, 2, 0])
        #expect(c.encode().count == 32)
    }

    @Test("0x9219 is named as unverified")
    func code9219() {
        #expect(PTPOperationCode.sonySDIO0x9219.rawValue == 0x9219)
        #expect(PTPOperationCode.sonySDIO0x9219.description == "Sony 0x9219 (unverified)")
    }

    @Test("Variant raw values are stable strings")
    func variantRawValues() {
        #expect(PTPPartialRead.Variant.sony64.rawValue == "sony64")
        #expect(PTPPartialRead.Variant.sonyLarge9211.rawValue == "sonyLarge9211")
        #expect(PTPPartialRead.Variant.sonyLarge9219.rawValue == "sonyLarge9219")
        #expect(PTPPartialRead.Variant(rawValue: "sonyLarge9219") == .sonyLarge9219)
    }

    @Test("command() maps the Sony variants with no 32-bit limit")
    func sonyVariantCommands() throws {
        let h = PTPObjectHandle(rawValue: 0x400010A3)
        let far = PTPPartialRead.Chunk(offset: 0x1_0000_0010, length: 16)

        let s64 = try PTPPartialRead.command(h, chunk: far, variant: .sony64, tx: 11)
        #expect(s64.code == 0x101B)
        #expect(s64.parameters == [0x400010A3, 0x10, 0x1, 16])
        #expect(s64.transactionID == 11)

        let l11 = try PTPPartialRead.command(h, chunk: far, variant: .sonyLarge9211, tx: 12)
        #expect(l11.code == 0x9211)
        #expect(l11.parameters == [0x400010A3, 0x10, 0x1, 16, 0])

        let l19 = try PTPPartialRead.command(h, chunk: far, variant: .sonyLarge9219, tx: 13)
        #expect(l19.code == 0x9219)
        #expect(l19.parameters == [0x400010A3, 0x10, 0x1, 16, 0])

        // Offsets above 4 GiB and a chunk ending past UInt32.max are fine for all three.
        let huge = PTPPartialRead.Chunk(offset: 5 * (1 << 32) + 7, length: .max)
        for variant in [PTPPartialRead.Variant.sony64, .sonyLarge9211, .sonyLarge9219] {
            let c = try PTPPartialRead.command(h, chunk: huge, variant: variant, tx: 14)
            #expect(Array(c.parameters.prefix(3)) == [0x400010A3, 7, 5])
            #expect(c.parameters[3] == .max)
        }
    }

    @Test("probeOrder starts with the standard form; operationCode(for:) names what each sends")
    func probing() {
        #expect(PTPPartialRead.probeOrder == [.standard32, .sony64, .sonyLarge9211, .sonyLarge9219])
        #expect(PTPPartialRead.operationCode(for: .standard32) == .getPartialObject)
        #expect(PTPPartialRead.operationCode(for: .sony64) == .getPartialObject)
        #expect(PTPPartialRead.operationCode(for: .extended64) == .getPartialObject64)
        #expect(PTPPartialRead.operationCode(for: .sonyLarge9211).rawValue == 0x9211)
        #expect(PTPPartialRead.operationCode(for: .sonyLarge9219).rawValue == 0x9219)

        // Each variant's command carries the code operationCode(for:) reports.
        let h = PTPObjectHandle(rawValue: 1)
        for variant in PTPPartialRead.probeOrder + [.extended64] {
            let c = try? PTPPartialRead.command(h, chunk: .init(offset: 0, length: 1), variant: variant, tx: 1)
            #expect(c?.operationCode == PTPPartialRead.operationCode(for: variant))
        }

        // DeviceInfo support check, as the spike does it.
        var info = PTPDatasetTests.syntheticSonyDeviceInfo
        info.operationsSupported.removeAll { $0 == 0x9211 || $0 == 0x9219 }
        #expect(!info.supports(PTPPartialRead.operationCode(for: .sonyLarge9211)))
        info.operationsSupported.append(0x9219)
        #expect(info.supports(PTPPartialRead.operationCode(for: .sonyLarge9219)))
        // variant(objectSize:device:) still picks only the standard ones.
        #expect(PTPPartialRead.variant(objectSize: 5_000_000_000, device: info) == nil)
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
