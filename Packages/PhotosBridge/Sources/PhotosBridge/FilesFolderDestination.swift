import Foundation

/// The Files destination (decision 9; backlog section 5, *Files import path*): a folder per camera in the app's
/// Documents folder, which Files shows under On My iPhone › the app (the app's Info.plist sets
/// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`).
///
/// - Each staged file is **moved** into the camera's folder, never copied (on one volume, a rename: about 0.01 s in
///   the spike's Wi-Fi copies).
/// - A name already in the folder is **never overwritten**: the file gets "NAME (2).EXT", "NAME (3).EXT" and so on,
///   compared case-insensitively, and the name used is what the returned `FileLocation` records.
/// - Both files of a RAW+JPEG pair are kept, under their own names; when either clashes, both take the same number,
///   so the pair still sorts together ("DSC00001 (2).ARW" and "DSC00001 (2).JPG").
/// - The file's modification date is set to the capture date, so Files sorts by it; the bytes stay the camera's.
/// - It returns each file's path relative to Documents, because the container's absolute path changes between
///   installs and updates.
///
/// No album, no pairing into one asset and no original choice apply here. Pure Foundation, tested on Linux with
/// temporary directories; the real Documents folder is in the hardware plan.
public actor FilesFolderDestination: ImportDestination {
    public nonisolated let kind: DestinationKind = .filesFolder

    /// The app's Documents folder (on iOS, `URL.documentsDirectory`).
    public nonisolated let documentsDirectory: URL
    /// The camera's folder name, already made safe (`FilesFolderNaming.folderName(forCamera:)`).
    public nonisolated let folderName: String
    /// Documents/`folderName`.
    public nonisolated let folderURL: URL

    /// - Parameters:
    ///   - documentsDirectory: the app's Documents folder; tests pass a temporary directory.
    ///   - cameraName: the camera's name, for example its model name; made into a safe folder name.
    public init(documentsDirectory: URL, cameraName: String) {
        self.documentsDirectory = documentsDirectory
        folderName = FilesFolderNaming.folderName(forCamera: cameraName)
        folderURL = documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    public func commit(_ unit: CommitUnit) throws(ImportDestinationFailure) -> ImportResult {
        let fm = FileManager.default
        let files = unit.files
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
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            throw Self.failure(error)
        }

        // Date first, on the staged file: a failure here leaves nothing placed. The rename keeps it.
        for file in files {
            guard let date = file.captureDate else { continue }
            do {
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.url.path)
            } catch {
                throw Self.failure(error)
            }
        }

        var placed: [(staged: URL, target: URL)] = []
        // A clash can appear between choosing a name and moving (another writer in the folder): try a few numbers.
        var attempt = 0
        while true {
            let names = try freeNames(for: files.map(\.filename), startingAfter: attempt)
            do {
                for (file, name) in zip(files, names) {
                    let target = folderURL.appendingPathComponent(name, isDirectory: false)
                    try fm.moveItem(at: file.url, to: target)
                    placed.append((file.url, target))
                }
                break
            } catch {
                // Put back what this attempt placed, so a failed pair leaves both files staged for a retry.
                for p in placed.reversed() { try? fm.moveItem(at: p.target, to: p.staged) }
                placed.removeAll()
                attempt += 1
                if Self.isExists(error), attempt < 5 { continue }
                throw Self.failure(error)
            }
        }

        for (file, p) in zip(files, placed) {
            // Some file systems reset the date on a move to another volume; best effort, the file is in place.
            if let date = file.captureDate {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: p.target.path)
            }
        }
        return .files(placed.map { FileLocation(relativePath: folderName + "/" + $0.target.lastPathComponent) })
    }

    /// Names for `filenames` (made safe) that nothing in the folder has, case-insensitively. A group of names with the
    /// same stem (a pair) takes one number for all, so the pair keeps one stem. `startingAfter` skips that many
    /// free choices, after a clash found at move time. Gives up past `maximumNumber` rather than search for ever.
    private func freeNames(for filenames: [String], startingAfter skip: Int) throws(ImportDestinationFailure) -> [String] {
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []).map { $0.lowercased() })
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

    /// The highest number tried in "NAME (n).EXT" before a commit is rejected.
    static let maximumNumber = 10_000

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
        if ns.domain == NSCocoaErrorDomain,
           [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(ns.code) {
            return .stagedFileMissing
        }
        return .rejected(detail: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }
}

/// Safe names for the Files folder: no path separators, no hidden names, no control characters.
public enum FilesFolderNaming {
    /// The longest folder name kept, in characters; a camera's name is far shorter.
    public static let maximumFolderNameLength = 64

    /// A folder name for the camera: the name with "/", ":", "\" and control characters replaced by "_", surrounding
    /// spaces and leading dots removed, at most 64 characters; "Camera" if nothing is left. "Inbox" becomes
    /// "Inbox camera", because iOS keeps Documents/Inbox for files other apps hand over.
    public static func folderName(forCamera name: String) -> String {
        var out = cleaned(name).trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > maximumFolderNameLength {
            out = String(out.prefix(maximumFolderNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.isEmpty { return "Camera" }
        if out.lowercased() == "inbox" { return out + " camera" }
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

extension FileLocation {
    /// The file's URL, given the app's Documents folder as it is now.
    public func url(inDocuments documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent(relativePath, isDirectory: false)
    }
}
