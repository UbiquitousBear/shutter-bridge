// Little-endian reader/writer for PTP datasets. PTP is little-endian everywhere (ISO 15740 §5.2).

import Foundation

public enum PTPDecodingError: Error, Equatable, Sendable {
    case truncated(needed: Int, available: Int)
    case badContainerLength(UInt32)
    case unknownContainerType(UInt16)
    case badString
    case badDateTime(String)
    case badPacketType(UInt32)
}

public struct PTPReader: Sendable {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    public var remaining: Int { data.count - offset }
    public var isAtEnd: Bool { remaining <= 0 }

    public mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    public mutating func u16() throws -> UInt16 {
        try need(2)
        defer { offset += 2 }
        return UInt16(byte(0)) | UInt16(byte(1)) << 8
    }

    public mutating func u32() throws -> UInt32 {
        try need(4)
        defer { offset += 4 }
        return UInt32(byte(0)) | UInt32(byte(1)) << 8 | UInt32(byte(2)) << 16 | UInt32(byte(3)) << 24
    }

    public mutating func u64() throws -> UInt64 {
        let lo = try u32()
        let hi = try u32()
        return UInt64(hi) << 32 | UInt64(lo)
    }

    public mutating func bytes(_ count: Int) throws -> Data {
        try need(count)
        defer { offset += count }
        let start = data.startIndex + offset
        return data.subdata(in: start ..< start + count)
    }

    public mutating func rest() -> Data {
        let start = data.startIndex + offset
        offset = data.count
        return data.subdata(in: start ..< data.endIndex)
    }

    /// PTP string: one byte count of UTF-16 code units (including the terminating NUL), then the units.
    /// A count of 0 is the empty string with no terminator.
    public mutating func string() throws -> String {
        let count = Int(try u8())
        if count == 0 { return "" }
        let raw = try bytes(count * 2)
        var units = [UInt16](repeating: 0, count: count)
        for i in 0 ..< count {
            units[i] = UInt16(raw[raw.startIndex + i * 2]) | UInt16(raw[raw.startIndex + i * 2 + 1]) << 8
        }
        if units.last == 0 { units.removeLast() }
        return String(utf16CodeUnits: units, count: units.count)
    }

    public mutating func u16Array() throws -> [UInt16] {
        let n = Int(try u32())
        try need(n * 2)
        var out = [UInt16](); out.reserveCapacity(n)
        for _ in 0 ..< n { out.append(try u16()) }
        return out
    }

    public mutating func u32Array() throws -> [UInt32] {
        let n = Int(try u32())
        try need(n * 4)
        var out = [UInt32](); out.reserveCapacity(n)
        for _ in 0 ..< n { out.append(try u32()) }
        return out
    }

    private func byte(_ i: Int) -> UInt8 { data[data.startIndex + offset + i] }

    private func need(_ n: Int) throws {
        if remaining < n { throw PTPDecodingError.truncated(needed: n, available: remaining) }
    }
}

public struct PTPWriter: Sendable {
    public private(set) var data = Data()
    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    public mutating func u32(_ v: UInt32) {
        data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
    public mutating func u64(_ v: UInt64) { u32(UInt32(v & 0xFFFF_FFFF)); u32(UInt32(v >> 32)) }
    public mutating func bytes(_ d: Data) { data.append(d) }

    public mutating func string(_ s: String) {
        if s.isEmpty { u8(0); return }
        let units = Array(s.utf16) + [0]
        u8(UInt8(min(units.count, 255)))
        for u in units.prefix(255) { u16(u) }
    }

    public mutating func u16Array(_ a: [UInt16]) { u32(UInt32(a.count)); for v in a { u16(v) } }
    public mutating func u32Array(_ a: [UInt32]) { u32(UInt32(a.count)); for v in a { u32(v) } }
}
