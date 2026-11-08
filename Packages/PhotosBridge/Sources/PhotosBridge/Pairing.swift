import Foundation

/// A file the pairing rule can look at: where it sits on the card, its name and when it was taken. The engine's
/// camera items conform to this (PhotosBridge can't see `CameraTransport`'s types: the packages are siblings).
public protocol PairableFile {
    /// The folder on the card, e.g. "100MSDCF" (MSC) or the parent's name or handle (MTP). Compared exactly.
    var pairingFolder: String { get }
    /// The camera's file name, e.g. "DSC00001.ARW".
    var pairingFilename: String { get }
    /// When the photo was taken; nil when the listing gave no date.
    var pairingCaptureDate: Date? { get }
}

/// One thing to commit, before download: a lone file, or a RAW file with its JPEG or HEIF.
public enum PairingUnit<File>: CustomStringConvertible {
    case single(File)
    case pair(raw: File, processed: File)

    /// The unit's files, the RAW first for a pair (the same order as `CommitUnit.files`).
    public var files: [File] {
        switch self {
        case let .single(f): [f]
        case let .pair(raw, processed): [raw, processed]
        }
    }

    /// The same unit with each file transformed, for example from a camera item to its `StagedFile` once both files
    /// are downloaded.
    public func map<T>(_ transform: (File) throws -> T) rethrows -> PairingUnit<T> {
        switch self {
        case let .single(f): .single(try transform(f))
        case let .pair(raw, processed): .pair(raw: try transform(raw), processed: try transform(processed))
        }
    }

    public var description: String {
        switch self {
        case let .single(f): "single(\(f))"
        case let .pair(raw, processed): "pair(raw: \(raw), processed: \(processed))"
        }
    }
}

extension PairingUnit: Sendable where File: Sendable {}
extension PairingUnit: Equatable where File: Equatable {}
extension PairingUnit: Hashable where File: Hashable {}

extension PairingUnit where File == StagedFile {
    /// The commit for this unit, once its files are staged.
    public var commitUnit: CommitUnit {
        switch self {
        case let .single(f): .single(f)
        case let .pair(raw, processed): .pair(raw: raw, processed: processed)
        }
    }
}

/// The RAW+JPEG pairing rule (backlog section 5, the default rule, kept by Shamil when the pairing test was dropped):
/// an `.ARW` and a `.JPG` or `.HIF` in the same folder, with the same stem, taken within 1 s of each other, become one
/// unit, which Photos saves as one asset. Every other file is its own unit; a lone ARW is common (the card on 5 Nov
/// held 539 ARW and 286 JPG).
///
/// Pure and deterministic. **Unverified against the camera's own card:** the rule has been run on fixtures and
/// synthetic listings only; week 1 runs it against the 5 Nov card (Photos' own Import listed 539 items there, so
/// 286 pairs and 253 lone ARW are the expected result, if every JPG has its ARW).
public struct RawPairingRule: Sendable, Hashable {
    /// RAW extensions, upper-cased. The α7C II writes ARW only.
    public static let rawExtensions: Set<String> = ["ARW"]
    /// Processed extensions, upper-cased: the camera writes JPG and HIF; JPEG, HEIF and HEIC are accepted for files
    /// renamed elsewhere (unverified that the camera ever writes them).
    public static let processedExtensions: Set<String> = ["JPG", "JPEG", "HIF", "HEIF", "HEIC"]

    /// How far apart the two capture times may be. The RAW and JPEG of one frame carry the same second; 1 s allows
    /// for a frame written across a second boundary.
    public var tolerance: TimeInterval

    public init(tolerance: TimeInterval = 1) {
        self.tolerance = tolerance
    }

    /// The kind of file by its extension, case-insensitively.
    public enum FileRole: Sendable, Hashable {
        case raw
        case processed
        case other
    }

    public static func role(ofFilename name: String) -> FileRole {
        let ext = Self.split(name).ext.uppercased()
        if rawExtensions.contains(ext) { return .raw }
        if processedExtensions.contains(ext) { return .processed }
        return .other
    }

    /// The name without its last extension, as the catalogue's `pairStem` stores it: "DSC00001.ARW" → "DSC00001".
    /// A name with no extension, or one that starts with its only dot, is its own stem.
    public static func stem(ofFilename name: String) -> String {
        String(split(name).stem)
    }

    /// Whether two files pair under this rule, in either order of arguments.
    public func pairs<F: PairableFile>(_ a: F, _ b: F) -> Bool {
        let (ra, rb) = (Self.role(ofFilename: a.pairingFilename), Self.role(ofFilename: b.pairingFilename))
        guard (ra == .raw && rb == .processed) || (ra == .processed && rb == .raw) else { return false }
        guard a.pairingFolder == b.pairingFolder else { return false }
        guard Self.stem(ofFilename: a.pairingFilename).uppercased() == Self.stem(ofFilename: b.pairingFilename).uppercased()
        else { return false }
        return Self.gap(a, b).map { $0 <= tolerance } ?? false
    }

    /// Groups `files` into units. Each file is in exactly one unit. Units come out in the order of their first file
    /// in `files`. A file without a capture date never pairs: a wrong pair hides a photo inside another asset, while
    /// a missed pair only makes two assets.
    ///
    /// When a RAW has more than one processed candidate (a JPG and a HIF of the same stem, which the camera doesn't
    /// write), the one closest in time wins, then JPEG before HEIF, then the earlier in `files`; the other stays
    /// single. When a processed file has more than one RAW candidate, the same applies the other way round.
    public func units<F: PairableFile>(_ files: [F]) -> [PairingUnit<F>] {
        // Candidates share folder and stem; only those groups need comparing.
        var groups: [GroupKey: [Int]] = [:]
        for (i, f) in files.enumerated() where Self.role(ofFilename: f.pairingFilename) != .other {
            groups[GroupKey(folder: f.pairingFolder, stem: Self.stem(ofFilename: f.pairingFilename).uppercased()), default: []].append(i)
        }
        // partner[i] == j when i and j pair.
        var partner: [Int: Int] = [:]
        for indices in groups.values where indices.count > 1 {
            let raws = indices.filter { Self.role(ofFilename: files[$0].pairingFilename) == .raw }
            let processed = indices.filter { Self.role(ofFilename: files[$0].pairingFilename) == .processed }
            // Every allowed pair, best first; take greedily.
            var candidates: [(raw: Int, processed: Int, gap: TimeInterval)] = []
            for r in raws {
                for p in processed {
                    if let gap = Self.gap(files[r], files[p]), gap <= tolerance { candidates.append((r, p, gap)) }
                }
            }
            candidates.sort { a, b in
                if a.gap != b.gap { return a.gap < b.gap }
                let (ja, jb) = (Self.isJPEG(files[a.processed].pairingFilename), Self.isJPEG(files[b.processed].pairingFilename))
                if ja != jb { return ja }
                if a.raw != b.raw { return a.raw < b.raw }
                return a.processed < b.processed
            }
            for c in candidates where partner[c.raw] == nil && partner[c.processed] == nil {
                partner[c.raw] = c.processed
                partner[c.processed] = c.raw
            }
        }
        var units: [PairingUnit<F>] = []
        units.reserveCapacity(files.count - partner.count / 2)
        for (i, f) in files.enumerated() {
            guard let j = partner[i] else {
                units.append(.single(f))
                continue
            }
            guard i < j else { continue } // emitted with its partner
            if Self.role(ofFilename: f.pairingFilename) == .raw {
                units.append(.pair(raw: f, processed: files[j]))
            } else {
                units.append(.pair(raw: files[j], processed: f))
            }
        }
        return units
    }

    private struct GroupKey: Hashable {
        let folder: String
        let stem: String
    }

    private static func gap<F: PairableFile>(_ a: F, _ b: F) -> TimeInterval? {
        guard let da = a.pairingCaptureDate, let db = b.pairingCaptureDate else { return nil }
        return abs(da.timeIntervalSince(db))
    }

    private static func isJPEG(_ name: String) -> Bool {
        let ext = split(name).ext.uppercased()
        return ext == "JPG" || ext == "JPEG"
    }

    private static func split(_ name: String) -> (stem: Substring, ext: Substring) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (Substring(name), "") }
        return (name[..<dot], name[name.index(after: dot)...])
    }
}
