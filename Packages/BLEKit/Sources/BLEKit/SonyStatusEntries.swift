// The entry list that CC09 (status) uses on the α7C II, and that CCAB and CCA1 showed too.
//
// Measured layout (spike build 12 and later; spike-findings.md, *BLE advertisement*, third run): a list of entries, each
//
//     [length: 1 byte, counting the tag and the value][tag: 2 bytes, big-endian][value: length - 2 bytes]
//
// A read of CC09 carries every tag (ten tags, 43 bytes on the α7C II); a notification carries one entry, for example
// `04 00 01 02 00` (tag 0x0001, value 02 00: Wi-Fi status 2). The tag is big-endian although PTP is little-endian
// everywhere: this is Bluetooth. CCAB read `04 00 00 02 03` and a CCA1 notification `04 00 00 02 01`: one entry each,
// tag 0x0000.

import Foundation

/// A 2-byte tag of a status entry. Unknown tags are values too: the camera sends tags 0x0004 and 0x0006 whose meaning
/// nobody knows, and the decoder keeps them.
public struct SonyStatusTag: RawRepresentable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// 0x0001: the Wi-Fi status; the first value byte is 0 terminated, 1 launching, 2 launched, 3 terminating (see `WiFiStatus`).
    /// Measured: all four seen on the α7C II; the value is two bytes (`02 00`), and what the second byte means is unknown.
    public static let wifiStatus = SonyStatusTag(rawValue: 0x0001)
    /// 0x0002: image transfer available (unverified: the notes). Value 1 (one byte) with the Wi-Fi off.
    public static let imageTransferAvailable = SonyStatusTag(rawValue: 0x0002)
    /// 0x0003: remote control available (unverified: the notes). One byte, 0 or 1 (both seen). It read 0 at 5 Nov 01:18,
    /// 2.8 s after the camera reappeared following a restart (1 again by 01:21), and before the CC08 write of the failed
    /// 4 Nov 12:34 join; 1 in every other read. Whether 0 belongs to the first seconds after the camera is switched on is
    /// unverified, and so is whether a join fails while it reads 0.
    public static let remoteControlAvailable = SonyStatusTag(rawValue: 0x0003)
    /// 0x0005: time set (unverified: the notes). Value 1 with the Wi-Fi off.
    public static let timeSet = SonyStatusTag(rawValue: 0x0005)
    /// 0x0007: live streaming (unverified: the notes). Value 0.
    public static let liveStreaming = SonyStatusTag(rawValue: 0x0007)
    /// 0x0008: movie recording (unverified: the notes). Value 0.
    public static let movieRecording = SonyStatusTag(rawValue: 0x0008)
    /// 0x0009: streaming mode (unverified: the notes). Value 0.
    public static let streamingMode = SonyStatusTag(rawValue: 0x0009)
    /// 0x000A: background transfer available (unverified: the notes). Value 1 with the Wi-Fi off.
    public static let backgroundTransferAvailable = SonyStatusTag(rawValue: 0x000A)

    /// The notes' name for a tag; nil for 0x0004 (three bytes, `00 00 00`, meaning unknown), 0x0006 (one byte, 0, meaning
    /// unknown) and any other tag.
    public var name: String? {
        switch self {
        case .wifiStatus: "Wi-Fi status"
        case .imageTransferAvailable: "image transfer available"
        case .remoteControlAvailable: "remote control available"
        case .timeSet: "time set"
        case .liveStreaming: "live streaming"
        case .movieRecording: "movie recording"
        case .streamingMode: "streaming mode"
        case .backgroundTransferAvailable: "background transfer available"
        default: nil
        }
    }

    /// "0x0001 (Wi-Fi status)" or "0x0004".
    public var description: String {
        let hex = String(rawValue, radix: 16, uppercase: true)
        let text = "0x" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        return name.map { "\(text) (\($0))" } ?? text
    }

    public static func < (a: SonyStatusTag, b: SonyStatusTag) -> Bool { a.rawValue < b.rawValue }
}

/// One entry of a status value: a tag and its value bytes (empty when the entry's length is 2).
public struct SonyStatusEntry: Hashable, Sendable, CustomStringConvertible {
    public let tag: SonyStatusTag
    public let value: [UInt8]

    public init(tag: SonyStatusTag, value: [UInt8]) {
        self.tag = tag
        self.value = value
    }

    /// The tag, then the value masked (`SonyMasking`): "0x0001 (Wi-Fi status) = 02 00". Safe to log: the values of unknown
    /// tags could hold anything.
    public var description: String {
        "\(tag) = \(SonyMasking.maskedHex(value))"
    }
}

/// Why a status value didn't decode. Offsets are byte offsets of the entry's length byte.
public enum SonyStatusError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No bytes at all.
    case empty
    /// A length below 2: it counts the 2-byte tag, so 0 and 1 leave no room for one. A zero byte where an entry should
    /// start (padding, or bytes after the last entry) ends up here.
    case lengthTooShort(offset: Int, length: Int)
    /// The entry's length runs past the end of the value.
    case truncated(offset: Int, length: Int, available: Int)

    public var description: String {
        switch self {
        case .empty:
            "status value is empty"
        case .lengthTooShort(let offset, let length):
            "status entry at byte \(offset) has length \(length), below the 2 its tag needs"
        case .truncated(let offset, let length, let available):
            "status entry at byte \(offset) has length \(length) but only \(available) byte(s) follow its length byte"
        }
    }
}

public enum SonyStatusEntries {
    /// Decodes a value into its entries, in order, using every byte.
    ///
    /// Strict, as the spike's parser was (`alpha7CIIEntries`, build 13): a value whose bytes don't all belong to complete
    /// entries is refused whole, never partly decoded. That covers trailing bytes (a partial entry, or a zero byte, after
    /// the last good one) and zero or one lengths. A length of 2 is an entry with an empty value and decodes. Duplicate tags
    /// stay duplicates here; `SonyStatus.merge` lets the later one win, as the spike did.
    ///
    /// The evidence: every read (43 bytes) and notification the α7C II sent parsed this way with no byte left over.
    /// Whether the camera ever pads or appends bytes is unknown (unverified), so a refusal is the safe answer.
    public static func decode(_ data: Data) throws -> [SonyStatusEntry] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { throw SonyStatusError.empty }
        var entries: [SonyStatusEntry] = []
        var offset = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            guard length >= 2 else { throw SonyStatusError.lengthTooShort(offset: offset, length: length) }
            let available = bytes.count - offset - 1
            guard length <= available else {
                throw SonyStatusError.truncated(offset: offset, length: length, available: available)
            }
            let tag = UInt16(bytes[offset + 1]) << 8 | UInt16(bytes[offset + 2])
            let value = Array(bytes[(offset + 3) ..< (offset + 1 + length)])
            entries.append(SonyStatusEntry(tag: SonyStatusTag(rawValue: tag), value: value))
            offset += 1 + length
        }
        return entries
    }
}
