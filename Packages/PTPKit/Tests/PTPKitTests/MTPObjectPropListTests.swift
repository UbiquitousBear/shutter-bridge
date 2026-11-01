import Testing
import Foundation
@testable import PTPKit

@Suite("MTP GetObjectPropList")
struct MTPObjectPropListTests {

    static func element(_ handle: UInt32, _ prop: MTPObjectPropertyCode, _ type: MTPDataType, _ value: MTPValue) -> MTPObjectPropElement {
        MTPObjectPropElement(handle: PTPObjectHandle(rawValue: handle), property: prop, dataType: type, value: value)
    }

    /// Two files and a folder, five properties each, in the order a device sends them (grouped by object).
    static let listing: MTPObjectPropList = {
        func file(_ h: UInt32, _ name: String, _ size: UInt64, _ format: PTPObjectFormat, _ parent: UInt32, _ date: String) -> [MTPObjectPropElement] {
            [
                element(h, .storageID, .uint32, .uint(0x0001_0001)),
                element(h, .objectFormat, .uint16, .uint(UInt64(format.rawValue))),
                element(h, .parentObject, .uint32, .uint(UInt64(parent))),
                element(h, .objectSize, .uint64, .uint(size)),
                element(h, .objectFileName, .string, .string(name)),
                element(h, .dateCreated, .string, .string(date)),
                element(h, .dateModified, .string, .string(date)),
            ]
        }
        return MTPObjectPropList(elements:
            file(1, "DCIM", 0, .association, 0, "20261103T091500")
            + file(2, "DSC00001.ARW", 52_428_800, .sonyARW, 1, "20261103T091512")
            + file(3, "DSC00002.JPG", 6_543_210, .exifJPEG, 1, "20261103T091512.5+0100"))
    }()

    // MARK: Decoding

    @Test("A listing survives encode → decode")
    func roundTrip() throws {
        let decoded = try MTPObjectPropList.decode(Self.listing.encode())
        #expect(decoded == Self.listing)
        #expect(decoded.elements.count == 21)
    }

    @Test("Decodes hand-built bytes, not just our own encoder's")
    func handBuilt() throws {
        var w = PTPWriter()
        w.u32(2)
        w.u32(0x0000_0007); w.u16(0xDC04); w.u16(0x0008); w.u64(0x1_0000_0001)       // ObjectSize UINT64 > 4 GiB
        w.u32(0x0000_0007); w.u16(0xDC07); w.u16(0xFFFF); w.string("A.ARW")          // ObjectFileName STR
        let list = try MTPObjectPropList.decode(w.data)
        #expect(list.elements == [
            Self.element(7, .objectSize, .uint64, .uint(0x1_0000_0001)),
            Self.element(7, .objectFileName, .string, .string("A.ARW")),
        ])
    }

    @Test("Signed integers sign-extend; unsigned zero-extend")
    func integerWidths() throws {
        var w = PTPWriter()
        w.u32(5)
        w.u32(1); w.u16(0xD001); w.u16(0x0001); w.u8(0xFE)                           // INT8 -2
        w.u32(1); w.u16(0xD002); w.u16(0x0003); w.u16(0x8000)                        // INT16 -32768
        w.u32(1); w.u16(0xD003); w.u16(0x0005); w.u32(0xFFFF_FFFF)                   // INT32 -1
        w.u32(1); w.u16(0xD004); w.u16(0x0007); w.u64(UInt64(bitPattern: Int64.min)) // INT64 min
        w.u32(1); w.u16(0xD005); w.u16(0x0002); w.u8(0xFE)                           // UINT8 254
        let values = try MTPObjectPropList.decode(w.data).elements.map(\.value)
        #expect(values == [.int(-2), .int(-32768), .int(-1), .int(Int64.min), .uint(254)])
    }

    @Test("Arrays carry a count and fixed-width elements")
    func arrays() throws {
        var w = PTPWriter()
        w.u32(3)
        w.u32(9); w.u16(0xDC0E); w.u16(0x4006); w.u32(2); w.u32(10); w.u32(11)      // AUINT32
        w.u32(9); w.u16(0xDC0F); w.u16(0x4003); w.u32(2); w.u16(0xFFFF); w.u16(1)    // AINT16: -1, 1
        w.u32(9); w.u16(0xDC10); w.u16(0x4004); w.u32(0)                             // empty AUINT16
        let values = try MTPObjectPropList.decode(w.data).elements.map(\.value)
        #expect(values == [.array([.uint(10), .uint(11)]), .array([.int(-1), .int(1)]), .array([])])
    }

    @Test("128-bit values keep their 16 little-endian bytes, alone or in an array")
    func int128() throws {
        let uid = Data((1 ... 16).map { UInt8($0) })
        let negative = Data(repeating: 0xFF, count: 16)
        var w = PTPWriter()
        w.u32(3)
        w.u32(4); w.u16(0xDC41); w.u16(0x000A); w.bytes(uid)                         // UINT128
        w.u32(4); w.u16(0xD006); w.u16(0x0009); w.bytes(negative)                    // INT128
        w.u32(4); w.u16(0xD007); w.u16(0x400A); w.u32(2); w.bytes(uid); w.bytes(uid) // AUINT128
        let list = try MTPObjectPropList.decode(w.data)
        #expect(list.elements.map(\.value) == [.uint128(uid), .int128(negative), .array([.uint128(uid), .uint128(uid)])])
        #expect(list.elements[0].property == .persistentUniqueObjectIdentifier)
        #expect(try MTPObjectPropList.decode(list.encode()) == list)
    }

    @Test("An empty list is valid")
    func empty() throws {
        let list = try MTPObjectPropList.decode(Data([0, 0, 0, 0]))
        #expect(list.elements.isEmpty)
        #expect(list.summaries().isEmpty)
        #expect(MTPObjectPropList().encode() == Data([0, 0, 0, 0]))
    }

    @Test("Empty and non-empty strings both decode")
    func strings() throws {
        let list = MTPObjectPropList(elements: [
            Self.element(1, .name, .string, .string("")),
            Self.element(1, .objectFileName, .string, .string("IMG_é日本.JPG")),
        ])
        #expect(try MTPObjectPropList.decode(list.encode()) == list)
    }

    @Test("Trailing bytes after the last element are tolerated")
    func trailingBytes() throws {
        let decoded = try MTPObjectPropList.decode(Self.listing.encode() + Data([0, 0, 0]))
        #expect(decoded == Self.listing)
    }

    @Test("Truncating a valid dataset at every byte boundary throws and never traps")
    func truncation() throws {
        var rich = Self.listing
        rich.elements += [
            Self.element(4, .persistentUniqueObjectIdentifier, .uint128, .uint128(Data(repeating: 7, count: 16))),
            Self.element(4, MTPObjectPropertyCode(rawValue: 0xDC0E), .uint32.array, .array([.uint(1), .uint(2)])),
            Self.element(4, MTPObjectPropertyCode(rawValue: 0xD001), .int8, .int(-3)),
        ]
        let full = rich.encode()
        #expect(try MTPObjectPropList.decode(full) == rich)
        for cut in 0 ..< full.count {
            #expect(throws: PTPDecodingError.self, "cut at \(cut) of \(full.count)") {
                try MTPObjectPropList.decode(full.prefix(cut))
            }
        }
    }

    @Test("Corrupting bytes of a valid dataset throws or decodes, never traps")
    func mutation() {
        let valid = Self.listing.encode()
        var rng = SeededGenerator(seed: 0x9805)
        for _ in 0 ..< 3_000 {
            var bytes = valid
            for _ in 0 ..< Int.random(in: 1 ... 4, using: &rng) {
                bytes[Int.random(in: 0 ..< bytes.count, using: &rng)] = UInt8.random(in: 0 ... 255, using: &rng)
            }
            _ = try? MTPObjectPropList.decode(bytes).summaries()
        }
    }

    @Test("Truncation works on a Data slice with a non-zero start index")
    func slice() throws {
        let full = Data([0xAA, 0xBB]) + Self.listing.encode()
        #expect(try MTPObjectPropList.decode(full.dropFirst(2)) == Self.listing)
        #expect(throws: PTPDecodingError.self) { try MTPObjectPropList.decode(full.dropFirst(2).dropLast()) }
    }

    @Test("An absurd element count throws before anything is allocated for it")
    func absurdElementCount() {
        var w = PTPWriter()
        w.u32(0xFFFF_FFFF)
        w.u32(1); w.u16(0xDC04); w.u16(0x0008); w.u64(5)
        #expect(throws: PTPDecodingError.self) { try MTPObjectPropList.decode(w.data) }
        // Just over what the bytes can hold: one element's worth of bytes, two claimed.
        var w2 = PTPWriter()
        w2.u32(2)
        w2.u32(1); w2.u16(0xDC04); w2.u16(0x0008); w2.u64(5)
        #expect(throws: PTPDecodingError.self) { try MTPObjectPropList.decode(w2.data) }
    }

    @Test("An absurd array count throws, including 128-bit arrays whose byte size would overflow 32 bits")
    func absurdArrayCount() {
        for type: UInt16 in [0x4002, 0x4008, 0x400A] {
            var w = PTPWriter()
            w.u32(1)
            w.u32(1); w.u16(0xDC0E); w.u16(type); w.u32(0xFFFF_FFFF); w.u32(0)
            #expect(throws: PTPDecodingError.self) { try MTPObjectPropList.decode(w.data) }
        }
    }

    @Test("An unknown datatype throws unknownDataType")
    func unknownDataType() {
        for type: UInt16 in [0x0000, 0x000B, 0x0100, 0x4000, 0x400B, 0x4FFF, 0x8001, 0xFFFE] {
            var w = PTPWriter()
            w.u32(1)
            w.u32(1); w.u16(0xDC04); w.u16(type); w.u64(0); w.u64(0)
            #expect(throws: PTPDecodingError.unknownDataType(type), "datatype \(type)") {
                try MTPObjectPropList.decode(w.data)
            }
        }
    }

    @Test("Datatype descriptions and array helpers")
    func dataTypes() {
        #expect(MTPDataType.uint16.array.rawValue == 0x4004)
        #expect(MTPDataType.uint16.array.isArray)
        #expect(!MTPDataType.string.isArray)
        #expect(MTPDataType.uint128.array.description == "AUINT128")
        #expect(MTPDataType.string.description == "STR")
        #expect(MTPDataType(rawValue: 0x1234).description == "Datatype(0x1234)")
    }

    // MARK: Summaries

    @Test("Elements fold into one summary per object")
    func summaries() throws {
        let s = try MTPObjectPropList.decode(Self.listing.encode()).summaries()
        #expect(s.count == 3)

        let folder = try #require(s[PTPObjectHandle(rawValue: 1)])
        #expect(folder.isFolder)
        #expect(folder.filename == "DCIM")
        #expect(folder.parent == PTPObjectHandle(rawValue: 0))

        let arw = try #require(s[PTPObjectHandle(rawValue: 2)])
        #expect(arw.filename == "DSC00001.ARW")
        #expect(arw.size == 52_428_800)
        #expect(arw.format == .sonyARW)
        #expect(arw.parent == PTPObjectHandle(rawValue: 1))
        #expect(arw.storage == PTPStorageID(rawValue: 0x0001_0001))
        #expect(arw.dateCreatedRaw == "20261103T091512")
        #expect(arw.dateModifiedRaw == "20261103T091512")
        #expect(arw.name == nil)
        #expect(!arw.isFolder)

        let jpg = try #require(s[PTPObjectHandle(rawValue: 3)])
        #expect(jpg.format == .exifJPEG)
        #expect(jpg.size == 6_543_210)
        // 09:15:12.5 at +01:00 is 08:15:12.5 UTC on 3 Nov 2026; the fractional part is dropped to tenths.
        let expected = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0),
                                      year: 2026, month: 11, day: 3, hour: 8, minute: 15, second: 12, nanosecond: 500_000_000).date
        #expect(jpg.dateCreated == expected)
    }

    @Test("Size accepts any unsigned width; wrong shapes, negatives and out-of-range values stay nil")
    func summaryTolerance() {
        let list = MTPObjectPropList(elements: [
            Self.element(1, .objectSize, .uint32, .uint(1234)),
            Self.element(1, .objectFormat, .uint32, .uint(0x1_0000)),       // does not fit a format code
            Self.element(1, .objectFileName, .uint8, .uint(65)),            // not a string
            Self.element(1, .storageID, .int32, .int(-1)),                   // negative
            Self.element(1, .name, .string, .string("first")),
            Self.element(1, .name, .string, .string("last")),               // repeated: last wins
            Self.element(2, MTPObjectPropertyCode(rawValue: 0xD400), .uint8, .uint(1)),   // unknown property ignored
        ])
        let s = list.summaries()
        #expect(s[PTPObjectHandle(rawValue: 1)] == MTPObjectSummary(size: 1234, name: "last"))
        #expect(s[PTPObjectHandle(rawValue: 2)] == MTPObjectSummary())
    }

    // MARK: Codes and command

    @Test("Operation and property codes carry the MTP values and readable names")
    func codes() {
        #expect(PTPOperationCode.getObjectPropsSupported.rawValue == 0x9801)
        #expect(PTPOperationCode.getObjectPropDesc.rawValue == 0x9802)
        #expect(PTPOperationCode.getObjectPropValue.rawValue == 0x9803)
        #expect(PTPOperationCode.getObjectPropList.rawValue == 0x9805)
        #expect(PTPOperationCode.getObjectPropList.description == "GetObjectPropList (MTP)")

        let props: [(MTPObjectPropertyCode, UInt16, String)] = [
            (.storageID, 0xDC01, "StorageID"), (.objectFormat, 0xDC02, "ObjectFormat"),
            (.protectionStatus, 0xDC03, "ProtectionStatus"), (.objectSize, 0xDC04, "ObjectSize"),
            (.objectFileName, 0xDC07, "ObjectFileName"), (.dateCreated, 0xDC08, "DateCreated"),
            (.dateModified, 0xDC09, "DateModified"), (.parentObject, 0xDC0B, "ParentObject"),
            (.persistentUniqueObjectIdentifier, 0xDC41, "PersistentUniqueObjectIdentifier"), (.name, 0xDC44, "Name"),
        ]
        for (code, raw, name) in props {
            #expect(code.rawValue == raw)
            #expect(code.description == name)
        }
        #expect(MTPObjectPropertyCode(rawValue: 0xDCFF).description == "ObjectProp(0xDCFF)")
    }

    @Test("getAllObjectProps is a 32-byte command: all objects, all formats, all properties, no group, all depths")
    func allObjectsCommandBytes() {
        let c = PTPCommand.getAllObjectProps(tx: 9)
        let expected: [UInt8] = [
            0x20, 0, 0, 0,                  // length 32
            0x01, 0x00,                     // command
            0x05, 0x98,                     // 0x9805
            0x09, 0, 0, 0,                  // tx 9
            0xFF, 0xFF, 0xFF, 0xFF,         // handle: every object
            0x00, 0x00, 0x00, 0x00,         // format: all
            0xFF, 0xFF, 0xFF, 0xFF,         // property: all
            0x00, 0x00, 0x00, 0x00,         // group: none
            0xFF, 0xFF, 0xFF, 0xFF,         // depth: all (libmtp)
        ]
        #expect(Array(c.encode()) == expected)
        #expect(c.operationCode == .getObjectPropList)
    }

    @Test("getObjectPropList puts its five parameters in MTP's order")
    func commandParameterOrder() {
        let c = PTPCommand.getObjectPropList(handle: PTPObjectHandle(rawValue: 0x11), format: .exifJPEG,
                                             property: .objectSize, group: 0x22, depth: 1, tx: 3)
        #expect(c.parameters == [0x11, 0x3801, 0xDC04, 0x22, 1])
        #expect(c.encode().count == 32)
        #expect(PTPCommand.getAllObjectProps(tx: 3) == PTPCommand.getObjectPropList(tx: 3))
    }
}
