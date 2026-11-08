// Byte-range reads for resumable downloads: chunk planning, the choice between ISO 15740 GetPartialObject
// (32-bit offset) and the 64-bit variant, and the resume rule from the proposal (§ Import engine design):
// resume from the saved offset only if the object is still the same one, otherwise start again from zero.

import Foundation

public enum PTPPartialRead {
    public static let defaultChunkSize: UInt32 = 4 * 1024 * 1024

    public struct Chunk: Equatable, Sendable, CustomStringConvertible {
        public let offset: UInt64
        public let length: UInt32
        public init(offset: UInt64, length: UInt32) { self.offset = offset; self.length = length }
        /// One past the last byte. Saturates at `UInt64.max` rather than trapping when a caller builds a chunk at the
        /// very top of the address space (the chunk planners never do, but `description` and error values carry chunks).
        public var end: UInt64 {
            let (sum, overflow) = offset.addingReportingOverflow(UInt64(length))
            return overflow ? UInt64.max : sum
        }
        public var description: String { "[\(offset), \(end))" }
    }

    /// Which command a chunk is read with.
    public enum Variant: String, Sendable, Equatable {
        /// ISO 15740 GetPartialObject 0x101B: u32 offset, u32 length. Covers objects up to 4 GiB − 1.
        case standard32
        /// GetPartialObject64 0x95C1: u64 offset (low, high), u32 length.
        case extended64
        /// 0x101B with four parameters: handle, offset low, offset high, length. Source: mvpzac/Imagedge, field-tested
        /// on a ZV-E10. `unverified` on the α7C II (the three-parameter form answered InvalidObjectHandle there).
        case sony64
        /// 0x9211 (libgphoto2's SDIO_GetPartialLargeObject): handle, offset low, offset high, length low, length high.
        /// The layout is a guess from mvpzac/Imagedge's description of the large-object command. 0x9211 is listed in the
        /// α7C II's PTP/IP DeviceInfo; the layout is `unverified` in tests (the spike's log: it read byte ranges that
        /// matched a GetObject download by SHA-256, and resumed after Wi-Fi off and on).
        case sonyLarge9211
        /// 0x9219 (what mvpzac/Imagedge calls SDIO_GetPartialLargeObject; unnamed in libgphoto2): the same
        /// five-parameter layout as `sonyLarge9211`. 0x9219 is listed in the α7C II's PTP/IP DeviceInfo; `unverified`
        /// otherwise (the spike's log: it answered InvalidObjectHandle in a contents-transfer session).
        case sonyLarge9219
    }

    /// The variants to try, in order, when the standard form fails. Check `operationCode(for:)` against the
    /// DeviceInfo's operations before sending each one. All `unverified` on the α7C II except `standard32`'s
    /// failure, which is known.
    public static let probeOrder: [Variant] = [.standard32, .sony64, .sonyLarge9211, .sonyLarge9219]

    /// The operation code a variant sends, for checking `PTPDeviceInfo.supports(_:)`.
    public static func operationCode(for variant: Variant) -> PTPOperationCode {
        switch variant {
        case .standard32, .sony64: .getPartialObject
        case .extended64: .getPartialObject64
        case .sonyLarge9211: .sonySDIOGetPartialLargeObject
        case .sonyLarge9219: .sonySDIO0x9219
        }
    }

    public enum PlanError: Error, Equatable, Sendable {
        case zeroChunkSize
        /// The chunk starts or ends beyond what a 32-bit offset can address and the 64-bit variant wasn't chosen.
        case beyond32BitOffset(Chunk)
    }

    /// The next chunk to request when `offset` bytes are already on disk, or nil when the object is complete.
    /// Loop on this (rather than precomputing chunks) so a short read from the camera simply moves the offset
    /// by what actually arrived.
    public static func nextChunk(at offset: UInt64, objectSize: UInt64, chunkSize: UInt32 = defaultChunkSize) -> Chunk? {
        guard chunkSize > 0, offset < objectSize else { return nil }
        return Chunk(offset: offset, length: UInt32(min(UInt64(chunkSize), objectSize - offset)))
    }

    /// Every chunk from `start` to the end, for planning and tests.
    public static func chunks(objectSize: UInt64, chunkSize: UInt32 = defaultChunkSize, from start: UInt64 = 0) throws -> [Chunk] {
        guard chunkSize > 0 else { throw PlanError.zeroChunkSize }
        var out: [Chunk] = []
        var offset = start
        while let c = nextChunk(at: offset, objectSize: objectSize, chunkSize: chunkSize) {
            out.append(c)
            offset = c.end
        }
        return out
    }

    /// The variant to use for an object of `objectSize` bytes on a device, or nil if the device supports neither
    /// (then fall back to whole-file GetObject and per-file resume, the spike's "otherwise" branch).
    public static func variant(objectSize: UInt64, device: PTPDeviceInfo) -> Variant? {
        let fits32 = objectSize <= UInt64(UInt32.max)
        if fits32, device.supports(.getPartialObject) { return .standard32 }
        if device.supports(.getPartialObject64) { return .extended64 }
        return nil
    }

    /// The command container for one chunk.
    public static func command(_ handle: PTPObjectHandle, chunk: Chunk, variant: Variant, tx: UInt32) throws -> PTPContainer {
        switch variant {
        case .standard32:
            // The last byte read is at end − 1, so an object of exactly 4 GiB − 1 bytes is still addressable.
            guard chunk.offset <= UInt64(UInt32.max), chunk.length == 0 || chunk.end - 1 <= UInt64(UInt32.max) else {
                throw PlanError.beyond32BitOffset(chunk)
            }
            return PTPCommand.getPartialObject(handle, offset: UInt32(chunk.offset), length: chunk.length, tx: tx)
        case .extended64:
            return PTPCommand.getPartialObject64(handle, offset: chunk.offset, length: chunk.length, tx: tx)
        case .sony64:
            return PTPCommand.getPartialObjectSony(handle, offset: chunk.offset, length: chunk.length, tx: tx)
        case .sonyLarge9211, .sonyLarge9219:
            return PTPCommand.sonyGetPartialLargeObject(code: operationCode(for: variant).rawValue, handle, offset: chunk.offset,
                                                        length: UInt64(chunk.length), tx: tx)
        }
    }

    /// The resume rule. A saved partial download continues from `savedOffset` only if the object found now has the
    /// same identity (filename, capture date, size, camera) and the offset is within it; otherwise it restarts
    /// from zero (card swapped, file replaced, counter wrapped).
    public static func resumeOffset(savedOffset: UInt64, saved: PTPObjectIdentity, current: PTPObjectIdentity) -> UInt64 {
        guard saved == current, savedOffset <= current.size else { return 0 }
        return savedOffset
    }

    /// True when advancing from `previous` to `current` bytes crosses a multiple of `interval`: the moments the
    /// engine persists its resume offset (every 16 MiB in the proposal) without writing on every chunk.
    public static func crossesCheckpoint(from previous: UInt64, to current: UInt64, interval: UInt64 = 16 * 1024 * 1024) -> Bool {
        guard interval > 0, current > previous else { return false }
        return previous / interval != current / interval
    }
}
