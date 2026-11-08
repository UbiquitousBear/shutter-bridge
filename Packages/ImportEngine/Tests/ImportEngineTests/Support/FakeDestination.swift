import Foundation
import PhotosBridge

/// A destination that records what it was given. As Photos it notes each file's size and leaves the file for the
/// engine to delete; as the Files folder it moves each file into its folder, never overwriting. It can fail a given
/// commit, or deny Photos access from a given commit on.
actor FakeDestination: ImportDestination {
    nonisolated let kind: DestinationKind
    let folder: URL

    /// Successful commits, in order.
    private(set) var commits: [CommitUnit] = []
    /// The size on disk of each committed file, by name, when it was committed.
    private(set) var sizes: [String: UInt64] = [:]
    /// Every commit call, failed or not.
    private(set) var attempts = 0
    /// Failures by attempt number (1-based).
    private var failures: [Int: ImportDestinationFailure] = [:]
    /// From this attempt number on, every commit is refused with `.photosAccessDenied` (3311).
    private var deniesFrom: Int?

    init(kind: DestinationKind, folder: URL) {
        self.kind = kind
        self.folder = folder
    }

    func fail(attempt: Int, with failure: ImportDestinationFailure) { failures[attempt] = failure }
    func deny(from attempt: Int) { deniesFrom = attempt }

    var committedNames: [String] { commits.flatMap { $0.files.map(\.filename) } }

    func commit(_ unit: CommitUnit) throws(ImportDestinationFailure) -> ImportResult {
        attempts += 1
        if let d = deniesFrom, attempts >= d { throw .photosAccessDenied }
        if let f = failures[attempts] { throw f }
        let fm = FileManager.default
        for file in unit.files where !fm.fileExists(atPath: file.url.path(percentEncoded: false)) {
            throw .stagedFileMissing
        }
        for file in unit.files {
            let attributes = try? fm.attributesOfItem(atPath: file.url.path(percentEncoded: false))
            sizes[file.filename] = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        commits.append(unit)
        switch kind {
        case .photos:
            return .photosAsset(localIdentifier: "asset-\(commits.count)")
        case .filesFolder:
            var locations: [FileLocation] = []
            for file in unit.files {
                var name = file.filename
                var n = 1
                while fm.fileExists(atPath: folder.appendingPathComponent(name).path(percentEncoded: false)) {
                    n += 1
                    let url = URL(fileURLWithPath: file.filename)
                    name = "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)"
                }
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    try fm.moveItem(at: file.url, to: folder.appendingPathComponent(name))
                } catch {
                    throw .rejected(detail: "\(error)")
                }
                locations.append(FileLocation(relativePath: "Untitled/" + name))
            }
            return .files(locations)
        }
    }
}
