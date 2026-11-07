// A reproducible generator and value builders for the seeded round-trip tests (PTPRoundTripTests.swift).
//
// Determinism rules, so a failing "seed 0x… iteration N" replays identically on every machine and toolchain:
//   - No Foundation or system randomness, and no `random(in:using:)`: the standard library may change how it
//     maps a generator's output onto a range. Every value here is built from `SplitMix64.next()` with integer
//     arithmetic only.
//   - Never derive a generated value from iterating a Set or Dictionary: Swift seeds hashing per process.
//   - Always pass an explicit time zone to anything that parses a date.
//   - Every base seed is a literal constant in the test that uses it.

import Foundation
@testable import PTPKit

/// SplitMix64 (Steele, Lea, Flood 2014; Vigna's reference). Pure integer arithmetic, so the same seed gives the
/// same values on every platform and toolchain. It deliberately does NOT conform to RandomNumberGenerator, so a
/// stray `Int.random(in:using:)` (whose mapping the standard library may change) or Foundation randomness won't compile.
struct SplitMix64 {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// The generator for iteration `i` of a test with base seed `base`. The index is hashed first: seeding with
    /// base + i·gamma would only shift one stream, so iterations would overlap.
    static func iteration(_ i: Int, of base: UInt64) -> SplitMix64 {
        var s = SplitMix64(seed: base &+ UInt64(i))
        return SplitMix64(seed: s.next())
    }

    /// Uniform in 0..<n (Lemire's multiply-high, without rejection; the bias is below n/2^64). n == 0 returns 0.
    mutating func below(_ n: UInt64) -> UInt64 {
        n == 0 ? 0 : next().multipliedFullWidth(by: n).high
    }

    mutating func int(_ r: ClosedRange<Int>) -> Int {
        r.lowerBound + Int(below(UInt64(r.upperBound - r.lowerBound) + 1))
    }

    mutating func chance(_ oneIn: UInt64) -> Bool { below(oneIn) == 0 }

    mutating func element<T>(_ a: [T]) -> T { a[int(0 ... a.count - 1)] }

    /// `n` bytes from successive `next()` values, low byte first.
    mutating func bytes(_ n: Int) -> Data {
        var out = Data()
        out.reserveCapacity(n)
        var word: UInt64 = 0
        for i in 0 ..< n {
            if i % 8 == 0 { word = next() }
            out.append(UInt8(truncatingIfNeeded: word >> UInt64((i % 8) * 8)))
        }
        return out
    }

    // MARK: Edge-biased integers: one draw in 8 comes from the edge table, otherwise the low bits of next().

    mutating func u8() -> UInt8 {
        chance(8) ? element([0, 1, 0x7F, 0x80, 0xFE, 0xFF]) : UInt8(truncatingIfNeeded: next())
    }

    mutating func u16() -> UInt16 {
        chance(8) ? element([0, 1, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]) : UInt16(truncatingIfNeeded: next())
    }

    mutating func u32() -> UInt32 {
        chance(8) ? element([0, 1, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF]) : UInt32(truncatingIfNeeded: next())
    }

    mutating func u64() -> UInt64 {
        chance(8)
            ? element([0, 1, 0xFFFF_FFFF, 0x1_0000_0000, UInt64(Int64.max), UInt64.max - 1, UInt64.max])
            : next()
    }

    /// A length in 0...max: one draw in 8 gives 0, one in 8 gives `max`, the rest are uniform.
    mutating func length(_ max: Int) -> Int {
        switch below(8) {
        case 0: 0
        case 1: max
        default: int(0 ... max)
        }
    }
}

/// Two-digit-style decimal padding by integer arithmetic (no String(format:), whose output the tests shouldn't depend on).
func padded(_ value: Int, width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

/// Howard Hinnant's days_from_civil: days since 1970-01-01 in the proleptic Gregorian calendar.
func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
}

// MARK: - Value builders

extension SplitMix64 {
    /// One Unicode scalar from a pool chosen uniformly: ASCII, Latin-1 to Cyrillic, combining marks, CJK or
    /// astral (two UTF-16 units). Never U+0000, never a surrogate.
    mutating func scalar(bmpOnly: Bool = false) -> Unicode.Scalar {
        let pools: [ClosedRange<UInt32>] = [0x20 ... 0x7E, 0x00A0 ... 0x04FF, 0x0300 ... 0x036F, 0x4E00 ... 0x9FFF, 0x1F300 ... 0x1FAFF]
        let pool = bmpOnly ? pools[Int(below(4))] : pools[Int(below(5))]
        return Unicode.Scalar(pool.lowerBound + UInt32(below(UInt64(pool.upperBound - pool.lowerBound) + 1)))!
    }

    /// A PTP string of at most `maxUnits` UTF-16 units (default: the longest that round-trips with its NUL).
    mutating func ptpString(maxUnits: Int = 254) -> String {
        let target = length(maxUnits)
        var out = String.UnicodeScalarView()
        var units = 0
        while true {
            let s = scalar()
            let n = s.utf16.count
            if units + n > target { break }
            out.append(s)
            units += n
        }
        return String(out)
    }

    /// A string of at least `units` UTF-16 units (an astral scalar can overshoot by one), for the over-length tests.
    mutating func longString(atLeastUnits units: Int, bmpOnly: Bool) -> String {
        var out = String.UnicodeScalarView()
        var count = 0
        while count < units {
            let s = scalar(bmpOnly: bmpOnly)
            out.append(s)
            count += s.utf16.count
        }
        return String(out)
    }

    /// The name in a PTP/IP handshake packet: UTF-16 with a NUL terminator and no length limit, so no U+0000 inside.
    mutating func utf16zName(maxScalars: Int = 64) -> String {
        var out = String.UnicodeScalarView()
        for _ in 0 ..< int(0 ... maxScalars) { out.append(scalar()) }
        return String(out)
    }

    /// A PTP DateTime string and the instant it names, computed by an independent arithmetic oracle.
    mutating func ptpDateTimeString() -> (text: String, expectedEpoch: Double) {
        let year = int(1980 ... 2099)
        let month = int(1 ... 12)
        let day = int(1 ... daysIn(month: month, year: year))
        let hour = int(0 ... 23)
        let minute = int(0 ... 59)
        let second = int(0 ... 59)
        var text = padded(year, width: 4) + padded(month, width: 2) + padded(day, width: 2) + "T"
            + padded(hour, width: 2) + padded(minute, width: 2) + padded(second, width: 2)
        var epoch = Double(daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second)
        if chance(2) {
            let tenths = int(0 ... 9)
            text += "." + String(tenths)
            epoch += Double(tenths) / 10
        }
        switch below(3) {
        case 0: break
        case 1: text += "Z"
        default:
            let east = chance(2)
            let hh = int(0 ... 14)
            let mm = element([0, 15, 30, 45])
            text += (east ? "+" : "-") + padded(hh, width: 2) + padded(mm, width: 2)
            epoch -= Double((east ? 1 : -1) * (hh * 3600 + mm * 60))
        }
        return (text, epoch)
    }

    // MARK: Containers and datasets

    mutating func parameters(_ range: ClosedRange<Int>) -> [UInt32] {
        (0 ..< int(range)).map { _ in u32() }
    }

    mutating func commandContainer() -> (container: PTPContainer, parameters: [UInt32]) {
        let code = u16()
        let tx = u32()
        let params = parameters(0 ... 5)
        return (PTPContainer(type: .command, code: code, transactionID: tx, parameters: params), params)
    }

    /// A container of any type; `parameters` is nil for a data container, whose payload is raw bytes.
    mutating func container() -> (container: PTPContainer, parameters: [UInt32]?) {
        let type = element([PTPContainerType.command, .data, .response, .event])
        let code = u16()
        let tx = u32()
        if type == .data {
            return (PTPContainer(type: type, code: code, transactionID: tx, payload: bytes(length(2048))), nil)
        }
        let params = parameters(0 ... 5)
        return (PTPContainer(type: type, code: code, transactionID: tx, parameters: params), params)
    }

    mutating func deviceInfo() -> PTPDeviceInfo {
        let standardVersion = u16()
        let vendorExtensionID = element([0x11, 0xFFFF_FFFF, 0x6, u32()])
        let vendorExtensionVersion = u16()
        let vendorExtensionDescription = ptpString()
        let functionalMode = u16()
        func codes(_ g: inout SplitMix64) -> [UInt16] { (0 ..< g.length(64)).map { _ in g.u16() } }
        let ops = codes(&self), events = codes(&self), props = codes(&self), capture = codes(&self), images = codes(&self)
        return PTPDeviceInfo(
            standardVersion: standardVersion, vendorExtensionID: vendorExtensionID,
            vendorExtensionVersion: vendorExtensionVersion, vendorExtensionDescription: vendorExtensionDescription,
            functionalMode: functionalMode, operationsSupported: ops, eventsSupported: events,
            devicePropertiesSupported: props, captureFormats: capture, imageFormats: images,
            manufacturer: ptpString(), model: ptpString(), deviceVersion: ptpString(), serialNumber: ptpString())
    }

    mutating func storageInfo() -> PTPStorageInfo {
        PTPStorageInfo(
            storageType: u16(), filesystemType: u16(), accessCapability: u16(),
            maxCapacity: u64(), freeSpaceInBytes: u64(), freeSpaceInImages: u32(),
            storageDescription: ptpString(), volumeLabel: ptpString())
    }

    mutating func objectInfo() -> PTPObjectInfo {
        let storageID = PTPStorageID(rawValue: u32())
        let objectFormat = PTPObjectFormat(rawValue: u16())
        let protectionStatus = u16()
        let objectCompressedSize = u32()
        let thumbFormat = PTPObjectFormat(rawValue: u16())
        let thumbCompressedSize = u32()
        let thumbPixWidth = u32(), thumbPixHeight = u32()
        let imagePixWidth = u32(), imagePixHeight = u32(), imageBitDepth = u32()
        let parentObject = PTPObjectHandle(rawValue: u32())
        let associationType = u16()
        let associationDescription = u32()
        let sequenceNumber = u32()
        let filename: String
        if chance(2) {
            filename = "DSC" + padded(int(0 ... 99_999), width: 5) + "." + element(["ARW", "JPG", "HIF", "MP4"])
        } else {
            filename = ptpString()
        }
        let captureDateRaw = chance(2) ? ptpDateTimeString().text : ptpString()
        let modificationDateRaw = chance(2) ? ptpDateTimeString().text : ptpString()
        return PTPObjectInfo(
            storageID: storageID, objectFormat: objectFormat, protectionStatus: protectionStatus,
            objectCompressedSize: objectCompressedSize, thumbFormat: thumbFormat,
            thumbCompressedSize: thumbCompressedSize, thumbPixWidth: thumbPixWidth, thumbPixHeight: thumbPixHeight,
            imagePixWidth: imagePixWidth, imagePixHeight: imagePixHeight, imageBitDepth: imageBitDepth,
            parentObject: parentObject, associationType: associationType,
            associationDescription: associationDescription, sequenceNumber: sequenceNumber,
            filename: filename, captureDateRaw: captureDateRaw, modificationDateRaw: modificationDateRaw,
            keywords: ptpString())
    }

    mutating func uuid() -> UUID {
        let b = [UInt8](bytes(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // MARK: MTP

    /// One of the 21 valid datatypes: the ten integer scalars, their ten arrays, and STR. Never an unknown type,
    /// because decode throws `unknownDataType` on one by design.
    mutating func mtpType() -> MTPDataType {
        let codes: [UInt16] = Array(0x0001 ... 0x000A) + Array(0x4001 ... 0x400A) + [0xFFFF]
        return MTPDataType(rawValue: element(codes))
    }

    /// A value that encodes and decodes to itself for `type`.
    mutating func wellTypedValue(for type: MTPDataType) -> MTPValue {
        if type == .string { return .string(ptpString()) }
        if type.isArray {
            let base = MTPDataType(rawValue: type.rawValue & 0x3FFF)
            return .array((0 ..< int(0 ... 16)).map { _ in wellTypedValue(for: base) })
        }
        switch type.rawValue {
        case 0x0001: return .int(Int64(Int8(bitPattern: u8())))
        case 0x0002: return .uint(UInt64(u8()))
        case 0x0003: return .int(Int64(Int16(bitPattern: u16())))
        case 0x0004: return .uint(UInt64(u16()))
        case 0x0005: return .int(Int64(Int32(bitPattern: u32())))
        case 0x0006: return .uint(UInt64(u32()))
        case 0x0007: return .int(Int64(bitPattern: u64()))
        case 0x0008: return .uint(u64())
        case 0x0009: return .int128(bytes(16))
        default: return .uint128(bytes(16))
        }
    }

    /// Any MTPValue, including kinds that don't match any particular datatype, short and long 128-bit data,
    /// nested arrays and strings past the 254-unit limit. For the "normalises in one pass" test.
    mutating func anyValue(depth: Int = 0) -> MTPValue {
        switch below(depth < 2 ? 6 : 5) {
        case 0: return .int(Int64(bitPattern: u64()))
        case 1: return .uint(u64())
        case 2: return .int128(bytes(int(0 ... 20)))
        case 3: return .uint128(bytes(int(0 ... 20)))
        case 4: return .string(ptpString(maxUnits: 400))
        default: return .array((0 ..< int(0 ... 8)).map { _ in anyValue(depth: depth + 1) })
        }
    }
}
