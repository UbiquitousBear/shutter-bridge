// Which Sony features a camera may be asked for, decided from its DeviceInfo alone. Pure values, no I/O.
//
// Every Sony value here is `unverified` on the α7C II until a fixture captures it. What the spike saw is in each
// doc comment (Spike/Sources/Views/WirelessView.swift; docs/spike-findings.md "Wireless browsing in 1.0" and
// "PTP/IP and join facts"; α7C II builds 0.1 (7.1) to 0.1 (14.1), 2–4 Nov 2026).

import Foundation

/// The kind of session the camera is in when a capability is asked about.
public enum SonySessionKind: String, Sendable, Equatable, CaseIterable {
    /// SDIO_OpenSession 0x9210 [1, 1] plus 0x9212 [2,0,0] → [2,1,0]: the whole card lists.
    case wholeCardContentsTransfer
    /// OpenSession 0x1002 (with or without the init sequence): over Wi-Fi in PC Remote it lists nothing
    /// (StoreNotAvailable); over USB in MTP it is the ordinary session.
    case plain
}

/// Which Sony features a camera may be asked for, from its DeviceInfo. A feature is offered only when
/// `PTPDeviceInfo.isSony` is true, because vendor codes mean nothing on another maker's body.
public struct SonyCapabilities: Equatable, Sendable, CustomStringConvertible {
    public let deviceInfo: PTPDeviceInfo

    public init(deviceInfo: PTPDeviceInfo) {
        self.deviceInfo = deviceInfo
    }

    public var isSony: Bool { deviceInfo.isSony }

    /// For logs, e.g. "Sony ILCE-7CM2 2.01: 0x9210 listed, 0x9212 not listed". Leaves out the serial number, so a
    /// failure that carries these capabilities is safe to log.
    public var description: String {
        func listed(_ code: PTPOperationCode) -> String {
            let hex = "0x" + String(code.rawValue, radix: 16, uppercase: true)
            return "\(hex) \(deviceInfo.supports(code) ? "listed" : "not listed")"
        }
        let name = "\(isSony ? "Sony" : "Not Sony") \(deviceInfo.model) \(deviceInfo.deviceVersion)"
        return "\(name): \(listed(.sonySDIOOpenSession)), \(listed(.sonySDIOSetContentsTransferMode))"
    }

    /// isSony && lists 0x9210 && lists 0x9212. Says only that the operations are listed; whole-card listing
    /// worked on the α7C II over Wi-Fi in PC Remote (unverified: spike 2–4 Nov). PC Remote over USB lists the
    /// same operations but that route is untested.
    public var wholeCardContentsTransfer: Bool {
        isSony && deviceInfo.supports(.sonySDIOOpenSession) && deviceInfo.supports(.sonySDIOSetContentsTransferMode)
    }

    /// isSony && lists 0x9201 (SDIO_Connect).
    public var sdioInitSequence: Bool { isSony && deviceInfo.supports(.sonySDIOConnect) }

    /// isSony && lists 0x9202 (SDIO_GetExtDeviceInfo).
    public var extDeviceInfo: Bool { isSony && deviceInfo.supports(.sonySDIOGetExtDeviceInfo) }

    /// isSony && lists 0x9211.
    public var largeObjectPartialRead: Bool { isSony && deviceInfo.supports(.sonySDIOGetPartialLargeObject) }

    /// isSony && emits 0xC201. Seen only on a plain PC Remote session after the init sequence, carrying
    /// 0xFFFFC001 (a buffer slot, not a card handle); not tested in a whole-card session; none over USB.
    public var sonyObjectAdded: Bool { isSony && deviceInfo.emits(.sonyObjectAdded) }

    /// The byte-range variant to use, or nil for whole-file GetObject (a resume then restarts the file).
    /// - wholeCardContentsTransfer: `.sonyLarge9211` when `largeObjectPartialRead`, at any size (64-bit offset and
    ///   length); otherwise nil. Never `.standard32`, `.sony64` or `.sonyLarge9219`, which answered
    ///   InvalidObjectHandle in this session on the α7C II even though 0x101B is listed (unverified: spike
    ///   2 Nov 23:10). Only 0x9211 read a byte range there; the reads matched a full download by SHA-256 and a
    ///   resume after Wi-Fi off/on worked (unverified: spike).
    /// - plain: `PTPPartialRead.variant(objectSize:device:)` (unverified: over USB in MTP the spike read 0x101B byte
    ///   ranges that matched a full download by SHA-256, 1 Nov).
    public func partialReadVariant(objectSize: UInt64, in session: SonySessionKind) -> PTPPartialRead.Variant? {
        switch session {
        case .wholeCardContentsTransfer:
            largeObjectPartialRead ? .sonyLarge9211 : nil
        case .plain:
            PTPPartialRead.variant(objectSize: objectSize, device: deviceInfo)
        }
    }

    /// True only when DeviceInfo lists the property. The whole-card session lists none and never answers
    /// GetDevicePropValue; a read there waits for the reply timeout and the session is lost (unverified: on
    /// build 9 a BatteryLevel read hit the 30 s idle timeout and killed the session).
    public func mayRead(_ property: PTPDevicePropCode) -> Bool {
        deviceInfo.devicePropertiesSupported.contains(property.rawValue)
    }
}
