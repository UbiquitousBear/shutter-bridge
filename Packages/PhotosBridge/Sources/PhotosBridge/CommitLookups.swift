import Foundation

// Finding a commit whose catalogue write was lost (backlog section 3.1, I15). The engine writes a pending-commit marker
// before each commit; one left behind (the app killed between the save and the row, or a store failing every try) is
// resolved by looking for what the commit would have left: the asset in Photos (`PhotoLibraryClient.findAsset(_:)`,
// `SystemPhotoLibrary` behind `#if canImport(Photos)`, CI only) or the file in its Staging day folder
// (`StagedCopyFinder`, pure Foundation). Every doubtful answer is "not found": a duplicate can be undone by the person,
// a file wrongly marked done can't.

/// What to look for in the Photos library: the date the asset was given and its original resources, role for role,
/// as the save made them.
public struct AssetQuery: Sendable, Hashable {
    /// The exact date the asset was given (`PHAssetCreationRequest.creationDate`): the camera's whole second.
    public var creationDate: Date
    /// The unit's resources as `AssetCreation(unit:options:)` lays them out: roles and original file names only; the
    /// file URLs are not used.
    public var resources: [AssetCreation.Resource]

    /// The window either side of `creationDate` the fetch covers: that Photos keeps the date as set and to the second
    /// is `unverified`.
    public static let dateTolerance: TimeInterval = 1

    public init(creationDate: Date, resources: [AssetCreation.Resource]) {
        self.creationDate = creationDate
        self.resources = resources
    }

    /// The query for an asset as the save would create it (built from `AssetCreation(unit:options:)`, so the roles
    /// match the save's); nil for one given no date, which no fetch by date can find.
    public init?(_ asset: AssetCreation) {
        guard let date = asset.creationDate else { return nil }
        self.init(creationDate: date, resources: asset.resources)
    }

    /// The fetch's date range: `creationDate` ± `dateTolerance`.
    public var dateRange: ClosedRange<Date> {
        creationDate.addingTimeInterval(-Self.dateTolerance) ... creationDate.addingTimeInterval(Self.dateTolerance)
    }

    /// One original resource of a candidate asset (`PHAssetResource` of type `.photo` or `.alternatePhoto`).
    public struct Original: Sendable, Hashable {
        public var role: AssetCreation.Role
        public var originalFilename: String

        public init(role: AssetCreation.Role, originalFilename: String) {
            self.role = role
            self.originalFilename = originalFilename
        }
    }

    /// Whether a candidate's original resources are exactly the unit's, role for role, by original file name with
    /// ASCII case folded (D13). A lone ARW doesn't match a pair's asset, nor the other way round; size can't be
    /// compared (no public size on `PHAssetResource`), so the role stands in for it.
    public func matches(_ originals: [Original]) -> Bool {
        func key(_ role: AssetCreation.Role, _ name: String) -> String { role.rawValue + "/" + ASCIIFold.fold(name) }
        let wanted = resources.map { key($0.role, $0.originalFilename) }.sorted()
        let found = originals.map { key($0.role, $0.originalFilename) }.sorted()
        return !wanted.isEmpty && wanted == found
    }
}

/// What a search of the Photos library found.
public enum AssetSearch: Sendable, Hashable {
    /// At least one asset matches; the first one's `localIdentifier`.
    case found(localIdentifier: String)
    /// None matches. `underLimitedAccess`: the app has Limited Access, so an asset it saved may be outside what it
    /// can see (`unverified` on iOS 27): counted apart and said as a possible duplicate.
    case notFound(underLimitedAccess: Bool)
    /// The library can't be read (access not determined, denied or restricted; or no library here): the marker
    /// waits for a later pass.
    case cannotSearch
}

extension PhotoLibraryClient {
    /// No search: markers wait. `SystemPhotoLibrary` searches; test fakes answer what they are told.
    public func findAsset(_ query: AssetQuery) async -> AssetSearch { .cannotSearch }
}

/// Finds a stage commit's files in its Staging day folder (backlog section 3.1): the final name isn't known when the
/// marker is written, since `FolderPlacer` gives a clashing file "NAME (2).EXT" and a pair one shared number, so the
/// folder is listed for each file's name, made safe as the placer makes it (`FilesFolderNaming.fileName(forCameraFile:)`),
/// or its numbered form, ASCII case folded, with the file's size. Pure Foundation, tested on Linux over temporary
/// folders.
///
/// - A pair matches only with both files under the same number. Where several numbers match, the highest wins (the
///   newest placement): an older copy with the same name and size is the same file's bytes, so picking it marks the
///   file staged correctly and leaves only a spare copy, never a loss.
/// - Within one number (two entries differing only in case, on a case-sensitive volume), the one whose modification
///   date is the wanted date breaks the tie when it is readable; it is never required (whether it survives an iCloud
///   upload and eviction is `unverified`).
/// - Only regular files whose size can be read count: an evicted iCloud file (".NAME.icloud") is not a match (whether
///   its size can be read without downloading it is `unverified`).
public struct StagedCopyFinder: Sendable {
    public struct Wanted: Sendable, Hashable {
        /// The camera's name, as the marker keeps it.
        public var filename: String
        public var size: UInt64
        /// The marker's `assetDate`; a tie-breaker only.
        public var modificationDate: Date?

        public init(filename: String, size: UInt64, modificationDate: Date? = nil) {
            self.filename = filename
            self.size = size
            self.modificationDate = modificationDate
        }
    }

    public init() {}

    /// Each file's path relative to `root`, in the unit's order; nil unless every file is found (a pair under one
    /// number), or when `folder` isn't a plain relative path (empty, absolute, or with "." or ".." in it).
    public func find(_ wanted: [Wanted], in folder: String, under root: URL) -> [FileLocation]? {
        guard !wanted.isEmpty, let components = Self.components(of: folder) else { return nil }
        var url = root
        for component in components { url = url.appendingPathComponent(component, isDirectory: true) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        else { return nil }

        // For each wanted file, its candidates by number: (name, modification date).
        var byNumber: [[Int: [(name: String, date: Date?)]]] = Array(repeating: [:], count: wanted.count)
        for entry in entries {
            let name = entry.lastPathComponent
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, size >= 0 else { continue }
            for (i, file) in wanted.enumerated() where UInt64(size) == file.size {
                guard let n = Self.number(of: name, for: FilesFolderNaming.fileName(forCameraFile: file.filename))
                else { continue }
                byNumber[i][n, default: []].append((name, values.contentModificationDate))
            }
        }
        let shared = byNumber.dropFirst().reduce(Set(byNumber[0].keys)) { $0.intersection($1.keys) }
        guard let n = shared.max() else { return nil }
        let prefix = components.joined(separator: "/") + "/"
        return wanted.indices.map { i in
            let candidates = byNumber[i][n]!.sorted { $0.name < $1.name }
            let chosen = candidates.first { Self.sameSecond($0.date, wanted[i].modificationDate) } ?? candidates[0]
            return FileLocation(relativePath: prefix + chosen.name)
        }
    }

    /// The number `entry` carries for `name`: 1 for the name itself, n for "NAME (n).EXT" (n ≥ 2, no leading zero),
    /// ASCII case folded; nil for anything else.
    static func number(of entry: String, for name: String) -> Int? {
        let entry = ASCIIFold.fold(entry)
        let name = ASCIIFold.fold(name)
        if entry == name { return 1 }
        let stem: String
        let ext: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            ext = String(name[dot...])
        } else {
            stem = name
            ext = ""
        }
        let head = stem + " ("
        let tail = ")" + ext
        guard entry.count > head.count + tail.count, entry.hasPrefix(head), entry.hasSuffix(tail) else { return nil }
        let digits = entry.dropFirst(head.count).dropLast(tail.count)
        guard let first = digits.first, first != "0", digits.allSatisfy({ ("0" ... "9").contains($0) }),
              digits.count <= 9, let n = Int(digits), n >= 2 else { return nil }
        return n
    }

    /// A folder relative to the root as its components; nil unless every component is a plain name.
    static func components(of folder: String) -> [String]? {
        guard !folder.isEmpty, !folder.hasPrefix("/") else { return nil }
        let parts = folder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }

    private static func sameSecond(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) < 1
    }
}

/// ASCII case folding (D13): "A"–"Z" to "a"–"z", nothing else, so the comparison doesn't depend on the locale.
enum ASCIIFold {
    static func fold(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
            (65 ... 90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
    }
}
