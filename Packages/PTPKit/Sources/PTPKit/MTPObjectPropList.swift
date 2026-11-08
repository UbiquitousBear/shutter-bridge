// MTP ObjectPropList (MTP 1.1, the data phase of GetObjectPropList, operation 0x9805): the answer to "give me
// these properties for these objects" in one transaction. Layout, all little-endian:
//
//   u32 element count
//   per element:  u32 ObjectHandle, u16 PropertyCode, u16 Datatype, value
//
// The value's encoding follows the datatype: fixed-width integers (0x0001–0x000A: INT8, UINT8, INT16, UINT16,
// INT32, UINT32, INT64, UINT64, INT128, UINT128), arrays of those (0x4001–0x400A: u32 count, then elements),
// or STR (0xFFFF: PTP string). Decoding follows libmtp's `ptp_unpack_OPL` (ptp-pack.c), except that a list cut
// short throws here, where libmtp returns the elements it managed to read. `unverified` on the α7C II: no real reply
// is committed (an MTP property list's object IDs may carry the camera's serial, so the repository keeps them out).

import Foundation

/// One property value. Integers are widened to 64 bits; 128-bit values stay as their 16 little-endian bytes.
public enum MTPValue: Equatable, Sendable {
    case int(Int64)
    case uint(UInt64)
    /// 16 bytes, little-endian, as on the wire.
    case int128(Data)
    /// 16 bytes, little-endian, as on the wire.
    case uint128(Data)
    case array([MTPValue])
    case string(String)

    /// The value as an unsigned integer, if it is one (or a non-negative signed one).
    public var unsignedValue: UInt64? {
        switch self {
        case .uint(let v): v
        case .int(let v): v >= 0 ? UInt64(v) : nil
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { s } else { nil }
    }
}

/// MTP datatype codes (the subset that can appear in an ObjectPropList value).
public struct MTPDataType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let int8    = MTPDataType(rawValue: 0x0001)
    public static let uint8   = MTPDataType(rawValue: 0x0002)
    public static let int16   = MTPDataType(rawValue: 0x0003)
    public static let uint16  = MTPDataType(rawValue: 0x0004)
    public static let int32   = MTPDataType(rawValue: 0x0005)
    public static let uint32  = MTPDataType(rawValue: 0x0006)
    public static let int64   = MTPDataType(rawValue: 0x0007)
    public static let uint64  = MTPDataType(rawValue: 0x0008)
    public static let int128  = MTPDataType(rawValue: 0x0009)
    public static let uint128 = MTPDataType(rawValue: 0x000A)
    public static let string  = MTPDataType(rawValue: 0xFFFF)

    /// The array type of a scalar type (0x4000 | scalar), e.g. `MTPDataType.uint16.array` is AUINT16 (0x4004).
    public var array: MTPDataType { MTPDataType(rawValue: rawValue | 0x4000) }

    /// True for 0x4001–0x400A.
    public var isArray: Bool { rawValue & 0xC000 == 0x4000 && (1 ... 10).contains(rawValue & 0x3FFF) }

    /// The scalar code (1...10) for an integer or integer-array type, else nil.
    private var scalarCode: UInt16? {
        let base = rawValue & 0xC000 == 0x4000 ? rawValue & 0x3FFF : rawValue
        return (1 ... 10).contains(base) ? base : nil
    }

    /// Bytes per fixed-width element, or nil for STR and unknown types.
    var elementSize: Int? {
        guard let code = scalarCode else { return nil }
        return [1, 1, 2, 2, 4, 4, 8, 8, 16, 16][Int(code) - 1]
    }

    /// The codes alternate INT, UINT: odd codes are signed.
    var isSigned: Bool { (scalarCode ?? 0) % 2 == 1 }

    public var description: String {
        if isArray { return "A" + MTPDataType(rawValue: rawValue & 0x3FFF).description }
        switch self {
        case .int8: return "INT8"
        case .uint8: return "UINT8"
        case .int16: return "INT16"
        case .uint16: return "UINT16"
        case .int32: return "INT32"
        case .uint32: return "UINT32"
        case .int64: return "INT64"
        case .uint64: return "UINT64"
        case .int128: return "INT128"
        case .uint128: return "UINT128"
        case .string: return "STR"
        default: return String(format: "Datatype(0x%04X)", rawValue)
        }
    }
}

/// One (object, property, value) triple of an ObjectPropList.
public struct MTPObjectPropElement: Equatable, Sendable {
    public var handle: PTPObjectHandle
    public var property: MTPObjectPropertyCode
    public var dataType: MTPDataType
    public var value: MTPValue

    public init(handle: PTPObjectHandle, property: MTPObjectPropertyCode, dataType: MTPDataType, value: MTPValue) {
        self.handle = handle
        self.property = property
        self.dataType = dataType
        self.value = value
    }
}

/// What a listing needs to know about one object, folded from its ObjectPropList elements. A property the
/// device didn't send, or sent with an unexpected datatype, is nil.
public struct MTPObjectSummary: Equatable, Sendable {
    public var storage: PTPStorageID?
    public var format: PTPObjectFormat?
    /// ParentObject as sent: 0 is the storage root in MTP (not ObjectInfo's 0xFFFFFFFF).
    public var parent: PTPObjectHandle?
    public var filename: String?
    /// ObjectSize, UINT64 in MTP.
    public var size: UInt64?
    /// PTP DateTime strings as sent; `dateCreated` / `dateModified` parse them with `PTPDateTime`.
    public var dateCreatedRaw: String?
    public var dateModifiedRaw: String?
    /// The Name property (display name), when sent.
    public var name: String?

    public init(storage: PTPStorageID? = nil, format: PTPObjectFormat? = nil, parent: PTPObjectHandle? = nil,
                filename: String? = nil, size: UInt64? = nil, dateCreatedRaw: String? = nil,
                dateModifiedRaw: String? = nil, name: String? = nil) {
        self.storage = storage
        self.format = format
        self.parent = parent
        self.filename = filename
        self.size = size
        self.dateCreatedRaw = dateCreatedRaw
        self.dateModifiedRaw = dateModifiedRaw
        self.name = name
    }

    public var dateCreated: Date? { dateCreatedRaw.flatMap { PTPDateTime.parse($0) } }
    public var dateModified: Date? { dateModifiedRaw.flatMap { PTPDateTime.parse($0) } }
    public var isFolder: Bool { format == .association }
}

public struct MTPObjectPropList: Equatable, Sendable {
    /// GetObjectPropList's Depth parameter meaning "all descendants" (what libmtp sends).
    public static let allDepths: UInt32 = 0xFFFF_FFFF
    /// Every element is at least handle (4) + property (2) + datatype (2) + a value of at least one byte
    /// (UINT8, or an empty STR's count byte).
    private static let minimumElementLength: UInt64 = 9

    public var elements: [MTPObjectPropElement]

    public init(elements: [MTPObjectPropElement] = []) { self.elements = elements }

    public static func decode(_ data: Data) throws -> MTPObjectPropList {
        var r = PTPReader(data)
        let count = UInt64(try r.u32())
        // Never let the count size an allocation: a count the remaining bytes can't hold is truncation.
        try requireRoom(&r, count: count, each: minimumElementLength)
        var elements: [MTPObjectPropElement] = []
        elements.reserveCapacity(Int(count))
        for _ in 0 ..< count {
            let handle = PTPObjectHandle(rawValue: try r.u32())
            let property = MTPObjectPropertyCode(rawValue: try r.u16())
            let type = MTPDataType(rawValue: try r.u16())
            elements.append(MTPObjectPropElement(handle: handle, property: property, dataType: type,
                                                 value: try readValue(&r, type)))
        }
        return MTPObjectPropList(elements: elements)
    }

    private static func requireRoom(_ r: inout PTPReader, count: UInt64, each: UInt64) throws {
        let (needed, overflow) = count.multipliedReportingOverflow(by: each)
        if overflow || needed > UInt64(r.remaining) {
            throw PTPDecodingError.truncated(needed: Int(clamping: needed), available: r.remaining)
        }
    }

    private static func readValue(_ r: inout PTPReader, _ type: MTPDataType) throws -> MTPValue {
        if type == .string { return .string(try r.string()) }
        guard let size = type.elementSize else { throw PTPDecodingError.unknownDataType(type.rawValue) }
        guard type.isArray else { return try readScalar(&r, size: size, signed: type.isSigned) }
        let n = UInt64(try r.u32())
        try requireRoom(&r, count: n, each: UInt64(size))
        var out: [MTPValue] = []
        out.reserveCapacity(Int(n))
        for _ in 0 ..< n { out.append(try readScalar(&r, size: size, signed: type.isSigned)) }
        return .array(out)
    }

    private static func readScalar(_ r: inout PTPReader, size: Int, signed: Bool) throws -> MTPValue {
        switch (size, signed) {
        case (1, false): return .uint(UInt64(try r.u8()))
        case (1, true): return .int(Int64(Int8(bitPattern: try r.u8())))
        case (2, false): return .uint(UInt64(try r.u16()))
        case (2, true): return .int(Int64(Int16(bitPattern: try r.u16())))
        case (4, false): return .uint(UInt64(try r.u32()))
        case (4, true): return .int(Int64(Int32(bitPattern: try r.u32())))
        case (8, false): return .uint(try r.u64())
        case (8, true): return .int(Int64(bitPattern: try r.u64()))
        default: return signed ? .int128(try r.bytes(16)) : .uint128(try r.bytes(16))
        }
    }

    /// Folds the elements into one summary per object. When a device repeats a property for an object the
    /// last one wins. Properties with a value of an unexpected shape (say, a string ObjectSize) stay nil.
    public func summaries() -> [PTPObjectHandle: MTPObjectSummary] {
        var out: [PTPObjectHandle: MTPObjectSummary] = [:]
        for e in elements {
            var s = out[e.handle] ?? MTPObjectSummary()
            switch e.property {
            case .storageID:
                s.storage = e.value.unsignedValue.flatMap { UInt32(exactly: $0) }.map(PTPStorageID.init(rawValue:))
            case .objectFormat:
                s.format = e.value.unsignedValue.flatMap { UInt16(exactly: $0) }.map(PTPObjectFormat.init(rawValue:))
            case .parentObject:
                s.parent = e.value.unsignedValue.flatMap { UInt32(exactly: $0) }.map(PTPObjectHandle.init(rawValue:))
            case .objectSize:
                s.size = e.value.unsignedValue
            case .objectFileName:
                s.filename = e.value.stringValue
            case .dateCreated:
                s.dateCreatedRaw = e.value.stringValue
            case .dateModified:
                s.dateModifiedRaw = e.value.stringValue
            case .name:
                s.name = e.value.stringValue
            default:
                break
            }
            out[e.handle] = s
        }
        return out
    }

    /// Wire encoding, for a responder test double and for tests. Each value is written as its element's
    /// `dataType` says, truncating integers to that width; a value that doesn't fit the type is written as
    /// zero (or an empty string / array).
    public func encode() -> Data {
        var w = PTPWriter()
        w.u32(UInt32(elements.count))
        for e in elements {
            w.u32(e.handle.rawValue)
            w.u16(e.property.rawValue)
            w.u16(e.dataType.rawValue)
            Self.write(&w, e.value, as: e.dataType)
        }
        return w.data
    }

    private static func write(_ w: inout PTPWriter, _ value: MTPValue, as type: MTPDataType) {
        let size = type.elementSize ?? 1
        if type == .string {
            w.string(value.stringValue ?? "")
        } else if type.isArray {
            guard case .array(let items) = value else { w.u32(0); return }
            w.u32(UInt32(items.count))
            for item in items { writeScalar(&w, item, size: size) }
        } else {
            writeScalar(&w, value, size: size)
        }
    }

    private static func writeScalar(_ w: inout PTPWriter, _ value: MTPValue, size: Int) {
        var bits: UInt64 = 0
        var high: UInt64 = 0   // upper half of a 128-bit value
        switch value {
        case .uint(let v): bits = v
        case .int(let v): bits = UInt64(bitPattern: v); high = v < 0 ? UInt64.max : 0
        case .int128(let d), .uint128(let d):
            var padded = Data(d.prefix(16))
            padded.append(Data(repeating: 0, count: 16 - padded.count))
            if size == 16 { w.bytes(padded) } else { w.bytes(Data(repeating: 0, count: size)) }
            return
        default: break
        }
        switch size {
        case 1: w.u8(UInt8(truncatingIfNeeded: bits))
        case 2: w.u16(UInt16(truncatingIfNeeded: bits))
        case 4: w.u32(UInt32(truncatingIfNeeded: bits))
        case 8: w.u64(bits)
        default: w.u64(bits); w.u64(high)
        }
    }
}
