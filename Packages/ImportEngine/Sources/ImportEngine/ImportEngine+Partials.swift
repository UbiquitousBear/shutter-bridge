import CameraTransport
import Catalogue
import Foundation

// Partial files between launches (backlog section 2, I13). Resumable partial files live in the work folder's
// `Partials/<uuid>/<camera file name>` (the `<uuid>` folder marks a partial; the serial never goes in a path), and a
// `.partial` row keeps that path relative to the work folder, so a container moved by an app update still resolves it.
// The app's work folder is in Caches (`cachesWorkFolder`), which iOS doesn't empty while the app is suspended, as it may
// empty `tmp`; it can still empty Caches under storage pressure, and the 7-day prune deletes old partials, so every
// launch, and every job before its diff, sends a row whose file is gone back to offset 0 (`reconcilePartials()`).
extension ImportEngine {
    /// The app's work folder: `Library/Caches/Imports`. Downloads are written here before a destination takes them,
    /// and resumable partial files are kept in its `Partials` folder. The engine's default, `tmp/Imports`, is for tests
    /// and previews: iOS may empty `tmp` while the app is suspended, taking a partial with it.
    public static var cachesWorkFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Imports", isDirectory: true)
    }

    /// Moves the partial files of an earlier work folder (`tmp/Imports`, before I13) into `workFolder`, so the rows
    /// that point to them (relative to the work folder) resolve in the new one, then removes the earlier `Partials`
    /// folder. A partial already in the new folder under the same name is kept and the earlier one dropped. Call it
    /// before making the engine with `workFolder`, which prunes old partials and empties the rest of the folder.
    public static func movePartials(from earlier: URL, to workFolder: URL) {
        let fm = FileManager.default
        let from = earlier.appendingPathComponent(partialsFolderName, isDirectory: true)
        guard from.standardizedFileURL.pathComponents
            != workFolder.appendingPathComponent(partialsFolderName).standardizedFileURL.pathComponents,
            let folders = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else { return }
        let to = workFolder.appendingPathComponent(partialsFolderName, isDirectory: true)
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for folder in folders {
            let target = to.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            guard !fm.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            try? fm.moveItem(at: folder, to: target)
        }
        try? fm.removeItem(at: from)
    }

    /// Sends every `.partial` row whose file is missing, or shorter than its resume offset, back to offset 0 with no
    /// temporary file (`CatalogueStore.resetPartial(_:ifTempURL:)`, which keeps it `.partial`), and deletes what is
    /// left of that file's folder; the next job copies the file from its start, reporting no failure. A row whose
    /// file lies outside the work folder's `Partials` folder is reset too (no job would continue it) and its file
    /// left alone. Returns how many rows were reset.
    ///
    /// The launch pass (section 2): the app calls it once the catalogue is open and the engine made, which is after
    /// the engine's prune, so a partial pruned by age resets its row (one 7-day rule for both), and each job runs it
    /// before its diff, after the commits of ended jobs have settled. One pass at a time: a caller arriving during a
    /// pass awaits it. A partial the current job holds is never touched, and a row is reset only while it still points
    /// to the file found missing, so a checkpoint written meanwhile stands. A catalogue that can't list its partial
    /// rows (or refuses a reset) leaves them as they are: a job still checks a partial file before it continues one.
    @discardableResult
    public func reconcilePartials() async -> Int {
        if let pass = partialPass { return await pass.value }
        let pass = Task { await self.resetMissingPartials() }
        partialPass = pass
        let reset = await pass.value
        if partialPass == pass { partialPass = nil }
        return reset
    }

    /// One pass of `reconcilePartials()`.
    func resetMissingPartials() async -> Int {
        guard let rows = try? await catalogue.partialRecords() else { return 0 }
        var reset = 0
        for row in rows {
            guard let tempURL = row.tempURL, case let .reset(folder) = check(row) else { continue }
            guard (try? await catalogue.resetPartial(row.identity, ifTempURL: tempURL)) == true else { continue }
            if let folder, !isHeld(folder) { try? FileManager.default.removeItem(at: folder) }
            reset += 1
            trace(.partialReset(row.identity.filename))
        }
        return reset
    }

    /// What the pass does with a `.partial` row.
    enum PartialCheck: Equatable {
        case keep
        /// Back to offset 0; the folder (inside `Partials`) to delete, if any.
        case reset(folder: URL?)
    }

    /// Keeps a row whose file is a regular file holding at least its offset, or that the current job holds; resets
    /// the rest.
    func check(_ row: CatalogueRecord) -> PartialCheck {
        guard let file = row.partialFile(in: stagingDirectory)?.standardizedFileURL else { return .keep }
        let folder = file.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().pathComponents == partialsDirectory.standardizedFileURL.pathComponents
        else { return .reset(folder: nil) }
        if isHeld(folder) { return .keep }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false), isDirectory: &isDirectory),
           !isDirectory.boolValue, Self.fileSize(at: file) >= row.resumeOffset {
            return .keep
        }
        return .reset(folder: folder)
    }

    /// Whether a file of the current job keeps its partial copy in `folder`.
    func isHeld(_ folder: URL) -> Bool {
        let components = folder.standardizedFileURL.pathComponents
        return job?.entries.values.contains {
            $0.resumable?.folder.standardizedFileURL.pathComponents == components
        } ?? false
    }
}
