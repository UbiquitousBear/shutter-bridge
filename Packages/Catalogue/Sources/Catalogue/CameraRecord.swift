import Foundation
import PTPKit

/// What the catalogue keeps about one camera body: the `Camera` row (backlog section 0, "Catalogue fields"; plan
/// W4). Written with `CatalogueStore.upsertCamera(_:)` and read with `camera(_:)` and `cameras()`.
///
/// **The network password is never stored** (backlog section 0, adopted in the wireless plan, decision 7 there): it
/// is read over Bluetooth for each join and dropped when the join ends. There is no field for it, and none may be
/// added. The network name is kept only so the app can remove the hotspot configuration when it leaves.
///
/// Every field but the key is private to the person (a Bluetooth identifier, a network name, an address on a
/// network, a GUID), so `description` and `customMirror` say only which fields are set, never their values, and the
/// record can go into a log or a test failure message as it is.
public struct CameraRecord: Sendable, Hashable, Codable, CustomStringConvertible, CustomReflectable {
    /// How the phone reaches the camera, as the catalogue stores it. CameraTransport's `CameraCarrier` has the same
    /// cases and raw values; it isn't used here because Catalogue doesn't depend on CameraTransport (and W11's
    /// `WirelessSession` may make CameraTransport depend on Catalogue).
    public enum Carrier: String, Sendable, Hashable, Codable, CaseIterable {
        case usb
        case wifi
    }

    /// The camera's key. Stored in the `Camera` row's `serial` column, which has held the key since build 17.1: a
    /// serial is hashed before it becomes a key (`CameraKey`), so no raw serial is kept here either.
    public var key: CameraKey
    /// The camera's model name from DeviceInfo ("ILCE-7CM2"); empty until a link has read it.
    public var model: String
    /// The name to show for the camera; empty until one is known.
    public var friendlyName: String
    /// When the camera was last connected or listed. Never moves backwards: `upsertCamera(_:)` and
    /// `saveListing(_:)` keep the later of the stored date and theirs. `Date.distantPast` when never seen.
    public var lastSeen: Date
    /// The carrier the camera was last set up for. The stored column has said "usb" for every row since build 17.1,
    /// so a camera nobody chose a carrier for reads `.usb`, as does a value a later version adds.
    public var preferredCarrier: Carrier
    /// Auto-import on connect (backlog section 14, not in this round): stored, not acted on.
    public var autoImport: Bool
    /// The camera's network name (SSID), kept only to remove the app's hotspot configuration on leaving. Never the
    /// password (see the type's documentation).
    public var wifiSSID: String?
    /// The address the camera last answered on, for a typed or remembered address (the camera's own network is
    /// always 192.168.122.1, so this matters for the home network, which is later).
    public var lastIP: String?
    /// The initiator GUID this app sends this camera in `Init_Command_Request`. Kept per camera so it stays the same
    /// across connections: the same GUID reconnected after a power cycle with no prompt (2 Nov). PTPKit's
    /// `PTPIP.initCommandRequest(guid:friendlyName:)` takes it as a `UUID`, and the V1 column is a `UUID`.
    public var ptpipGUID: UUID?
    /// The camera's Core Bluetooth peripheral identifier, stored at onboarding (backlog section 6) and used to
    /// reconnect without a scan and to confirm a proximity report (section 11). The same across reconnects and
    /// camera restarts on 5 Nov; iOS gives a different identifier to each phone, so it is meaningless elsewhere.
    public var bluetoothPeripheralID: UUID?

    public init(key: CameraKey, model: String = "", friendlyName: String = "", lastSeen: Date = .distantPast,
                preferredCarrier: Carrier = .usb, autoImport: Bool = false, wifiSSID: String? = nil,
                lastIP: String? = nil, ptpipGUID: UUID? = nil, bluetoothPeripheralID: UUID? = nil) {
        self.key = key
        self.model = model
        self.friendlyName = friendlyName
        self.lastSeen = lastSeen
        self.preferredCarrier = preferredCarrier
        self.autoImport = autoImport
        self.wifiSSID = wifiSSID
        self.lastIP = lastIP
        self.ptpipGUID = ptpipGUID
        self.bluetoothPeripheralID = bluetoothPeripheralID
    }

    /// Safe for logs: the key by its length, the model, the carrier, and which private fields are set.
    public var description: String {
        var parts = ["\(key)", model.isEmpty ? "no model" : model, preferredCarrier.rawValue]
        if !friendlyName.isEmpty { parts.append("named") }
        if autoImport { parts.append("auto-import") }
        if wifiSSID != nil { parts.append("ssid") }
        if lastIP != nil { parts.append("ip") }
        if ptpipGUID != nil { parts.append("guid") }
        if bluetoothPeripheralID != nil { parts.append("peripheral") }
        return "CameraRecord(\(parts.joined(separator: ", ")))"
    }

    /// `dump` and the debugger's summary show the same redacted text as `description`, not the stored values.
    public var customMirror: Mirror {
        Mirror(self, children: ["summary": description], displayStyle: .struct)
    }

    /// This record as an upsert leaves it over `stored`: every field from `self`, except `lastSeen`, which keeps the
    /// later of the two, so a write built from an older read never moves it backwards.
    func written(over stored: CameraRecord?) -> CameraRecord {
        var out = self
        if let stored, stored.lastSeen > out.lastSeen { out.lastSeen = stored.lastSeen }
        return out
    }
}

/// Why a store refused a write.
public enum CatalogueFailure: Error, Sendable, Hashable {
    /// `markPartial` was given an offset past the end of the file: more bytes than the file has.
    case resumeOffsetPastEnd(offset: UInt64, size: UInt64)
    /// `markPartial` was given an absolute URL for the partial file. It must be relative to the engine's staging
    /// folder (`CatalogueRecord.tempURL`), because the app's container moves when the app is updated.
    case partialFileNotRelative
    /// `setMark` was given a rating outside 0...5 (`MarkRecord.ratings`).
    case ratingOutOfRange(Int)
    /// `beginCommit` was given a commit with no files.
    case emptyCommit
    /// The store doesn't keep what the call needs (a test double written before Catalogue V4).
    case notSupported
}

/// The partial-file rule, for both stores (plan W4; the engine writes a checkpoint every 16 MiB in W7).
enum PartialMark {
    /// The row a checkpoint leaves for `identity`, given the row the store holds for it (if any); nil when the row is
    /// to stay as it is because the file is already imported (a checkpoint flushed after the commit must not undo
    /// it). Otherwise the row reads `.partial` with the offset and temporary file (its relative part, `stored(_:)`),
    /// keeping any location and staged copy it had. Throws `CatalogueFailure.resumeOffsetPastEnd` when `offset` is
    /// past the file's size, and `.partialFileNotRelative` when `tempURL` is absolute.
    static func record(for identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64,
                       existing: CatalogueRecord?) throws(CatalogueFailure) -> CatalogueRecord? {
        guard offset <= identity.size else {
            throw .resumeOffsetPastEnd(offset: offset, size: identity.size)
        }
        let stored = try stored(tempURL)
        if existing?.state == .imported { return nil }
        return CatalogueRecord(identity: identity, format: format, state: .partial, location: existing?.location,
                               resumeOffset: offset, tempURL: stored, staged: existing?.staged)
    }

    /// The row `resetPartial(_:ifTempURL:offset:)` leaves: `existing` at offset 0 with no temporary file, still
    /// `.partial`, location and staged copy kept; nil (nothing to write) unless `existing` is `.partial` with `tempURL`
    /// as its file, compared by relative path (`stored(_:)`), and `offset` as its resume offset.
    static func reset(_ existing: CatalogueRecord?, ifTempURL tempURL: URL, offset: UInt64) -> CatalogueRecord? {
        guard var record = existing, record.state == .partial, record.resumeOffset == offset,
              let file = record.tempURL, let expected = try? stored(tempURL),
              file.relativePath == expected.relativePath else { return nil }
        record.resumeOffset = 0
        record.tempURL = nil
        return record
    }

    /// The row `forgetPartial(_:ifTempURL:offset:)` leaves: `existing` back to `.new` with no offset and no temporary
    /// file, location and staged copy kept; nil under the same conditions as `reset(_:ifTempURL:offset:)`.
    static func forget(_ existing: CatalogueRecord?, ifTempURL tempURL: URL, offset: UInt64) -> CatalogueRecord? {
        guard var record = reset(existing, ifTempURL: tempURL, offset: offset) else { return nil }
        record.state = .new
        return record
    }

    /// The form of a partial file's URL the catalogue keeps: its part relative to the staging folder, with no base
    /// URL, so nothing of the container's current path is stored. A URL with a base (relative to the staging folder,
    /// or to the working directory, as `URL(fileURLWithPath:)` makes a relative path on Apple platforms) keeps its
    /// relative part; a URL with neither a base nor a scheme is relative already; any other URL is absolute.
    static func stored(_ url: URL) throws(CatalogueFailure) -> URL {
        guard url.baseURL != nil || url.scheme == nil, let relative = URL(string: url.relativeString),
              relative.scheme == nil, !url.relativePath.isEmpty, !url.relativePath.hasPrefix("/") else {
            throw .partialFileNotRelative
        }
        return relative
    }
}

/// The staging rules, for both stores (Shamil, 11 Nov): what `markStaged` leaves, and what `upsert` keeps.
enum StagedMark {
    /// The row `markStaged` leaves for `identity`, given the row the store holds for it (if any): a new `.new` row
    /// when there is none; otherwise the same row, state and location kept, with the staged copy at `location`. A
    /// `.partial` row goes back to `.new` with its offset and temporary file cleared: the partial file was the
    /// staging commit's. An imported row stays imported.
    static func record(for identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation,
                       existing: CatalogueRecord?) -> CatalogueRecord {
        guard var record = existing else {
            return CatalogueRecord(identity: identity, format: format, state: .new, staged: location)
        }
        if record.state == .partial {
            record.state = .new
            record.resumeOffset = 0
            record.tempURL = nil
        }
        record.format = format
        record.staged = location
        return record
    }

    /// What `upsert` writes for `record` over the row the store holds (if any): the record, with the stored row's
    /// staged copy rather than its own, because only `markStaged` and `clearStaged` change it. A row it inserts
    /// takes the record's.
    static func upserting(_ record: CatalogueRecord, over existing: CatalogueRecord?) -> CatalogueRecord {
        guard let existing else { return record }
        var kept = record
        kept.staged = existing.staged
        return kept
    }

    /// The row a write for one identity builds on, given the row the store keeps (`kept`, the furthest along when it
    /// holds several) and the staged copies of all of the identity's rows, in the store's order (`kept`'s own among
    /// them). The others are deleted by the write, so when `kept` has no staged copy it takes the first one another
    /// row has: healing duplicates never forgets a staged copy, which would leave the file in Staging with no row.
    /// `upsert` and `markPartial` read the stored row through this in both stores (`markStaged` writes its own copy).
    static func healed(_ kept: CatalogueRecord?, among staged: [StagedLocation?]) -> CatalogueRecord? {
        guard var kept, kept.staged == nil, let first = staged.lazy.compactMap(\.self).first else { return kept }
        kept.staged = first
        return kept
    }
}
