// CC09's merged state: what the camera has reported so far over one link.

import Foundation

/// The camera's Wi-Fi status, tag 0x0001's first value byte.
///
/// Values 0 to 3 are the notes' (CameraSync, BLE_STATE_MONITORING.md); measured on the α7C II: all four seen. CC08 = 0x01
/// took the status 0 → 1 → 2 (with Sony's five notifications on), and 2 → 3 → 0 when the Wi-Fi went off by itself (about 50 s
/// after a switch-on nobody joined) or after Creators' App left (spike-findings.md, *BLE advertisement*, 3 to 5 Nov). The
/// camera's screen shows nothing at any of them.
public enum WiFiStatus: Hashable, Sendable, CustomStringConvertible {
    case terminated
    case launching
    case launched
    case terminating
    /// A value outside 0 to 3: never seen, kept so a firmware change shows up instead of being guessed at.
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .terminated
        case 1: self = .launching
        case 2: self = .launched
        case 3: self = .terminating
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .terminated: 0
        case .launching: 1
        case .launched: 2
        case .terminating: 3
        case .unknown(let value): value
        }
    }

    public var description: String {
        switch self {
        case .terminated: "terminated"
        case .launching: "launching"
        case .launched: "launched"
        case .terminating: "terminating"
        case .unknown(let value): "unknown (\(SonyMasking.maskedByte(value)))"
        }
    }
}

/// One tag's change from a merge.
public struct SonyStatusChange: Hashable, Sendable, CustomStringConvertible {
    public let tag: SonyStatusTag
    /// The value before; nil when the tag is new to the state.
    public let old: [UInt8]?
    public let new: [UInt8]

    /// "0x0001 (Wi-Fi status) 00 00 → 01 00", or "= 02 00" for a new tag; values masked.
    public var description: String {
        let now = SonyMasking.maskedHex(new)
        guard let old else { return "\(tag) = \(now)" }
        return "\(tag) \(SonyMasking.maskedHex(old)) → \(now)"
    }
}

/// The entries of CC09 merged by tag across every read and notification on one link.
///
/// A read carries every tag and a notification one, so the state is the latest value of each tag seen, and the Wi-Fi status
/// is the state's tag 0x0001. Keep the state for the link's life, clear it (`removeAll()`) on the next connection: a state
/// from an earlier link says nothing about this one. The spike kept it after the camera dropped the link, so a run could
/// still report what came before the drop; that is the caller's choice. A status value is never a secret, but log it masked
/// (`description`), as the spike did.
public struct SonyStatus: Equatable, Sendable, CustomStringConvertible {
    public private(set) var values: [SonyStatusTag: [UInt8]] = [:]

    public init() {}

    /// A state holding one value's entries. Throws what `SonyStatusEntries.decode` throws.
    public init(decoding data: Data) throws {
        try merge(data)
    }

    public var isEmpty: Bool { values.isEmpty }

    public mutating func removeAll() { values = [:] }

    /// Merges a read or a notification. Atomic: when the bytes don't decode, nothing changes and the error is thrown.
    /// Returns what changed, tags ascending; a value equal to the one held changes nothing.
    @discardableResult
    public mutating func merge(_ data: Data) throws -> [SonyStatusChange] {
        merge(try SonyStatusEntries.decode(data))
    }

    /// Merges decoded entries, later entries of the same tag winning.
    @discardableResult
    public mutating func merge(_ entries: [SonyStatusEntry]) -> [SonyStatusChange] {
        let before = values
        for entry in entries { values[entry.tag] = entry.value }
        return values.keys.sorted().compactMap { tag in
            guard let new = values[tag], before[tag] != new else { return nil }
            return SonyStatusChange(tag: tag, old: before[tag], new: new)
        }
    }

    public func value(for tag: SonyStatusTag) -> [UInt8]? { values[tag] }

    /// The Wi-Fi status: tag 0x0001's first value byte. Nil when the state has no tag 0x0001 (a notification of another tag
    /// was the only thing seen) or its value is empty.
    public var wifiStatus: WiFiStatus? {
        values[.wifiStatus]?.first.map(WiFiStatus.init(rawValue:))
    }

    /// A one-byte flag tag as a Bool: 0 false, 1 true; nil when the tag is absent, its value isn't exactly one byte or the
    /// byte is neither 0 nor 1. The meaning of the tag is from the notes (unverified) except for 0x0001.
    public func flag(_ tag: SonyStatusTag) -> Bool? {
        guard let value = values[tag], value.count == 1 else { return nil }
        switch value[0] {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    /// Tag 0x0003, "remote control available" (the notes, unverified): 1 true, 0 false. The α7C II read 0 at 5 Nov 01:18, 2.8 s
    /// after the camera reappeared following a restart (1 again by 01:21), and before the CC08 write of the failed 4 Nov 12:34
    /// join; 1 in every other read. Whether 0 belongs to the first seconds after the camera is switched on is unverified, and
    /// so is whether a join fails while it reads 0. Nil when unknown.
    public var remoteControlAvailable: Bool? { flag(.remoteControlAvailable) }

    /// "Wi-Fi status launched; 0x0001 (Wi-Fi status) = 02 00, …": the status in words, then every tag masked, ascending.
    public var description: String {
        let body = values.keys.sorted().map { SonyStatusEntry(tag: $0, value: values[$0] ?? []).description }
        return "Wi-Fi status \(wifiStatus.map { "\($0)" } ?? "unknown"); " + (body.isEmpty ? "no entries" : body.joined(separator: ", "))
    }
}
