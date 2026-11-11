import Catalogue
import Foundation
import PhotosBridge

/// One staged file as the cull screen sees it: its identity (from the catalogue's staged record) and where the staged
/// copy sits. The caller makes these from `stagedRecords`; nothing here reads the file.
public struct CullFile: Sendable, Hashable {
    public var identity: ObjectIdentity
    /// The staged copy.
    public var url: URL

    public init(identity: ObjectIdentity, url: URL) {
        self.identity = identity
        self.url = url
    }

    /// What a mark on this file is keyed by.
    public var contentKey: ObjectIdentity.ContentKey { identity.contentKey }

    /// RAW, a processed still (JPG, HIF…) or anything else (video, sidecars), by extension, as the pairing rule reads it.
    public var role: RawPairingRule.FileRole { RawPairingRule.role(ofFilename: identity.filename) }
}

extension CullFile: PairableFile {
    public var pairingFolder: String { identity.folder }
    public var pairingFilename: String { identity.filename }

    /// The capture time read as UTC wall-clock time: only the gaps between files matter to the pairing rule, so any
    /// fixed zone does.
    public var pairingCaptureDate: Date? { identity.captureDate.date(in: Self.utc) }

    private static let utc = TimeZone(secondsFromGMT: 0) ?? .gmt
}

/// What one swipe in the loupe shows (D4's recommendation): a lone file, or a RAW with its JPG or HEIF as **one unit,
/// with one mark and one rating**, shown by the processed file. Pairing is `RawPairingRule`, the rule Import uses.
public struct CullUnit: Sendable, Hashable, Identifiable {
    /// The unit is named by its first file's content key (the RAW's, for a pair), which a mark is keyed by.
    public typealias ID = ObjectIdentity.ContentKey

    public let pairing: PairingUnit<CullFile>

    public init(_ pairing: PairingUnit<CullFile>) {
        self.pairing = pairing
    }

    /// The unit's files, the RAW first for a pair.
    public var files: [CullFile] { pairing.files }

    /// The content keys a mark on this unit is written under: both halves of a pair.
    public var keys: [ObjectIdentity.ContentKey] { files.map(\.contentKey) }

    public var id: ID { files[0].contentKey }
    public var camera: CameraKey { files[0].identity.camera }
    public var captureDate: CaptureDate { files[0].identity.captureDate }
    public var isPair: Bool {
        if case .pair = pairing { true } else { false }
    }

    /// `YYYYMMDD` of the capture time (the camera's wall clock), which the cull screen groups by.
    public var day: String { String(captureDate.rawValue.prefix(8)) }

    /// Where the preview comes from: the pair's processed file, else the lone file.
    public var previewSource: PreviewSource {
        switch pairing {
        case let .pair(_, processed):
            .image(processed, pairedWithRAW: true)
        case let .single(file):
            switch file.role {
            case .raw: .raw(file)
            case .processed: .image(file, pairedWithRAW: false)
            case .other: PreviewSource.none
            }
        }
    }
}

/// The units of one camera on one capture day, in shooting order. The cull screen lists these, newest day first.
public struct CullDay: Sendable, Hashable, Identifiable {
    public struct ID: Sendable, Hashable {
        public var camera: CameraKey
        /// `YYYYMMDD`.
        public var day: String
    }

    public var camera: CameraKey
    public var day: String
    public var units: [CullUnit]

    public var id: ID { ID(camera: camera, day: day) }

    /// The units' counts under `marks` (keyed by content key).
    public func counts(marks: [ObjectIdentity.ContentKey: CullMark]) -> CullCounts {
        CullCounts(units: units, marks: marks)
    }

    /// Groups staged files into days: by camera (in the order of the camera key's raw value, only so the order is
    /// stable), then newest day first, each day's units in shooting order (capture second, then file name).
    ///
    /// - Pairs are made per camera, by `rule`.
    /// - A file whose content key was already seen is dropped, so two staged copies of one file are one unit: a mark
    ///   is keyed by content key and couldn't tell them apart.
    public static func days(of files: [CullFile], rule: RawPairingRule = RawPairingRule()) -> [CullDay] {
        var seen = Set<ObjectIdentity.ContentKey>()
        var byCamera: [CameraKey: [CullFile]] = [:]
        for file in files where seen.insert(file.contentKey).inserted {
            byCamera[file.identity.camera, default: []].append(file)
        }
        var days: [CullDay] = []
        for camera in byCamera.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let ordered = byCamera[camera, default: []].sorted(by: shootingOrder)
            var byDay: [String: [CullUnit]] = [:]
            for pairing in rule.units(ordered) {
                let unit = CullUnit(pairing)
                byDay[unit.day, default: []].append(unit)
            }
            for day in byDay.keys.sorted(by: >) {
                days.append(CullDay(camera: camera, day: day, units: byDay[day, default: []]))
            }
        }
        return days
    }

    private static func shootingOrder(_ a: CullFile, _ b: CullFile) -> Bool {
        if a.identity.captureDate != b.identity.captureDate { return a.identity.captureDate < b.identity.captureDate }
        let (na, nb) = (a.identity.filename.uppercased(), b.identity.filename.uppercased())
        if na != nb { return na < nb }
        return a.identity.folder < b.identity.folder
    }
}

/// "120 staged, 34 kept, 60 rejected", counted in units: a pair is one.
public struct CullCounts: Sendable, Hashable {
    public var units = 0
    /// Every file in the units (a pair is two).
    public var files = 0
    public var kept = 0
    public var rejected = 0

    public var unmarked: Int { units - kept - rejected }

    public init(units: [CullUnit], marks: [ObjectIdentity.ContentKey: CullMark]) {
        for unit in units {
            self.units += 1
            files += unit.files.count
            switch CullMark.of(unit, in: marks).decision {
            case .keep?: kept += 1
            case .reject?: rejected += 1
            case nil: break
            }
        }
    }
}
