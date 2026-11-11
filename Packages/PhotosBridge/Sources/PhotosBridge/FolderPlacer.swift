import Foundation

/// Moves a downloaded file into a folder and back. `PlainFileMover` everywhere (Linux, tests, staging on this
/// iPhone); `UbiquitousFileMover` on iOS, for the app's iCloud Drive folder.
public protocol StagedFileMover: Sendable {
    /// Moves the staged file at `staged` to `target`, which doesn't exist yet. Throws if `target` exists (the
    /// placer then tries the next free name).
    func place(_ staged: URL, at target: URL) throws
    /// Moves a file `place(_:at:)` put at `target` back to `staged`, when the next file of its unit couldn't be
    /// placed.
    func takeBack(_ target: URL, to staged: URL) throws
    /// Whether the placer sets the capture date on the placed file again after the move (best effort, for a move to
    /// another volume that resets it). False where an uncoordinated write to the placed file is unwelcome (iCloud
    /// Drive); the date set on the staged file before the move travels with it either way.
    var setsDateAfterPlacing: Bool { get }
}

/// A plain rename with `FileManager.moveItem`: on one volume, about 0.01 s whatever the size (the spike's Wi-Fi
/// copies).
public struct PlainFileMover: StagedFileMover {
    public init() {}

    public func place(_ staged: URL, at target: URL) throws {
        try FileManager.default.moveItem(at: staged, to: target)
    }

    public func takeBack(_ target: URL, to staged: URL) throws {
        try FileManager.default.moveItem(at: target, to: staged)
    }

    public var setsDateAfterPlacing: Bool { true }
}

/// The placement core every folder destination shares (it was the Files folder's, 8 Nov; staging's since 11 Nov):
///
/// - Each staged file is **moved** into `folder`, never copied.
/// - A name already in the folder is **never overwritten**: the file gets "NAME (2).EXT", "NAME (3).EXT" and so on,
///   compared case-insensitively. An iCloud placeholder ".NAME.icloud" (a file iOS has evicted) counts as "NAME"
///   taken.
/// - Both files of a RAW+JPEG pair are kept, under their own names; when either clashes, both take the same number,
///   so the pair still sorts together ("DSC00001 (2).ARW" and "DSC00001 (2).JPG").
/// - A clash that appears between choosing a name and moving (another writer in the folder) is retried with the
///   next free number, a few times.
/// - If the second file of a pair can't be placed, the first is moved back to staging, so a failed unit leaves both
///   files staged for a retry.
/// - The file's modification date is set to the capture date, so Files sorts by it; the bytes stay the camera's.
///
/// Pure Foundation, tested on Linux with temporary directories.
struct FolderPlacer: Sendable {
    /// Where the files go; created if missing.
    let folder: URL
    let mover: any StagedFileMover

    /// Places the files, in order, and returns where each went.
    func place(_ files: [StagedFile]) throws(ImportDestinationFailure) -> [URL] {
        let fm = FileManager.default
        for file in files where !fm.fileExists(atPath: file.url.path) {
            throw .stagedFileMissing
        }
        // Two files of one unit under one name (ignoring case, as the folder does) can never both be placed under a
        // shared number: refuse the unit before anything is touched. The pairing rule never builds one (the roles
        // differ by extension), but `CommitUnit.pair` is public.
        let safeNames = files.map { FilesFolderNaming.fileName(forCameraFile: $0.filename).lowercased() }
        if Set(safeNames).count != safeNames.count {
            throw .rejected(detail: "two files of one unit share a name")
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Self.failure(error)
        }

        // Date first, on the staged file: a failure here leaves nothing placed. The move keeps it.
        for file in files {
            guard let date = file.captureDate else { continue }
            do {
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.url.path)
            } catch {
                throw Self.failure(error)
            }
        }

        var placed: [(staged: URL, target: URL)] = []
        var attempt = 0
        while true {
            let names = try freeNames(for: files.map(\.filename), startingAfter: attempt)
            do {
                for (file, name) in zip(files, names) {
                    let target = folder.appendingPathComponent(name, isDirectory: false)
                    try mover.place(file.url, at: target)
                    placed.append((file.url, target))
                }
                break
            } catch {
                // Put back what this attempt placed, so a failed pair leaves both files staged for a retry.
                for p in placed.reversed() { try? mover.takeBack(p.target, to: p.staged) }
                placed.removeAll()
                attempt += 1
                if Self.isExists(error), attempt < 5 { continue }
                throw Self.failure(error)
            }
        }

        if mover.setsDateAfterPlacing {
            for (file, p) in zip(files, placed) {
                // Some file systems reset the date on a move to another volume; best effort, the file is in place.
                if let date = file.captureDate {
                    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: p.target.path)
                }
            }
        }
        return placed.map(\.target)
    }

    /// Names for `filenames` (made safe) that nothing in the folder has, case-insensitively. A group of names with the
    /// same stem (a pair) takes one number for all, so the pair keeps one stem. `startingAfter` skips that many
    /// free choices, after a clash found at move time. Gives up past `maximumNumber` rather than search for ever.
    private func freeNames(for filenames: [String], startingAfter skip: Int) throws(ImportDestinationFailure) -> [String] {
        let existing = Self.takenNames(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []))
        let safe = filenames.map(FilesFolderNaming.fileName(forCameraFile:))
        var skipped = 0
        var n = 1
        while n <= Self.maximumNumber {
            let candidates = safe.map { n == 1 ? $0 : FilesFolderNaming.numbered($0, n) }
            let lowered = candidates.map { $0.lowercased() }
            let free = lowered.allSatisfy { !existing.contains($0) } && Set(lowered).count == lowered.count
            if free {
                if skipped == skip { return candidates }
                skipped += 1
            }
            n += 1
        }
        throw .rejected(detail: "no free name up to (\(Self.maximumNumber)) for \(safe.joined(separator: ", "))")
    }

    /// The names a folder's entries take, lower-cased: each entry's own name, and for an iCloud placeholder
    /// ".NAME.icloud" (a file iOS evicted from the phone after uploading it) also "NAME", which is the file's real
    /// name in iCloud Drive.
    static func takenNames(_ entries: [String]) -> Set<String> {
        var taken: Set<String> = []
        for entry in entries {
            let lowered = entry.lowercased()
            taken.insert(lowered)
            let suffix = ".icloud"
            if lowered.hasPrefix("."), lowered.hasSuffix(suffix), lowered.count > 1 + suffix.count {
                taken.insert(String(lowered.dropFirst().dropLast(suffix.count)))
            }
        }
        return taken
    }

    /// The highest number tried in "NAME (n).EXT" before a commit is rejected.
    static let maximumNumber = 10_000

    /// `NSUbiquitousFileUnavailableError`: the iCloud container isn't available (signed out, or iCloud Drive off).
    /// The number, rather than `CocoaError.Code.ubiquitousFileUnavailable`, so the mapping is the same everywhere.
    ///
    /// Unverified: that a container that goes away mid-job fails `setUbiquitous` or `createDirectory` with this code
    /// (directly or as the underlying error) is from Apple's documentation, not the device. If it fails with "no such
    /// file" (4 or 260) instead, the file maps to `.stagedFileMissing` and is downloaded again; with any other code,
    /// to `.rejected`. Either way the job doesn't switch to this iPhone, though nothing is lost, and the next import
    /// finds iCloud Drive unavailable (the locator asks again each time). Bench check S11 confirms it.
    static let ubiquitousFileUnavailable = 4353

    private static func isExists(_ error: any Error) -> Bool {
        if let e = error as? CocoaError, e.code == .fileWriteFileExists { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileWriteFileExists.rawValue { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EEXIST) { return true }
        return false
    }

    static func failure(_ error: any Error) -> ImportDestinationFailure {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileWriteOutOfSpace.rawValue { return .notEnoughSpace }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return .notEnoughSpace }
        if let underlying, underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) { return .notEnoughSpace }
        if ns.domain == NSCocoaErrorDomain, ns.code == ubiquitousFileUnavailable { return .stagingUnavailable }
        if let underlying, underlying.domain == NSCocoaErrorDomain, underlying.code == ubiquitousFileUnavailable {
            return .stagingUnavailable
        }
        if ns.domain == NSCocoaErrorDomain,
           [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(ns.code) {
            return .stagedFileMissing
        }
        return .rejected(detail: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }
}

/// Safe names for folders and files the app writes: no path separators, no hidden names, no control characters.
public enum FilesFolderNaming {
    /// The longest folder name kept, in characters; a camera's name is far shorter.
    public static let maximumFolderNameLength = 64

    /// A folder name for the camera: the name with "/", ":", "\" and control characters replaced by "_", surrounding
    /// spaces and leading dots removed, at most 64 characters; "Camera" if nothing is left. "Inbox" becomes
    /// "Inbox camera", because iOS keeps Documents/Inbox for files other apps hand over, and "Staging" becomes
    /// "Staging camera", so no camera folder this build makes is the staging folder (Documents/Staging). It doesn't
    /// rule the case out: builds before 11 Nov had no such rule, so a camera named "Staging" imported to Files then
    /// already has Documents/Staging holding imported originals, and staging on this iPhone nests its camera folders
    /// inside it. Nothing is overwritten (a name already taken is numbered), but Documents/Staging may hold files that
    /// aren't staged copies: anything that removes staged files acts only on the paths the catalogue recorded
    /// (`StagedLocation.fileURL(in:)`), never on everything under Staging.
    public static func folderName(forCamera name: String) -> String {
        var out = cleaned(name).trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > maximumFolderNameLength {
            out = String(out.prefix(maximumFolderNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.isEmpty { return "Camera" }
        if ["inbox", "staging"].contains(out.lowercased()) { return out + " camera" }
        return out
    }

    /// The camera's file name made safe to write: separators and control characters replaced, not hidden.
    public static func fileName(forCameraFile name: String) -> String {
        var out = cleaned(name)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "unnamed" : out
    }

    /// "NAME (n).EXT", or "NAME (n)" without an extension.
    public static func numbered(_ name: String, _ n: Int) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "\(name) (\(n))" }
        return "\(name[..<dot]) (\(n))\(name[dot...])"
    }

    private static func cleaned(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            if scalar == "/" || scalar == ":" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) {
                return "_"
            }
            return scalar
        }))
    }
}
