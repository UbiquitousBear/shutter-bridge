import Foundation
@testable import ImportEngine
import PhotosBridge
import Synchronization

/// A destination that records what it was given. As Photos it notes each file's size and leaves the file for the
/// engine to delete; as a staging folder it moves each file into its folder, never overwriting, and says it staged it
/// in `place`. It can fail a given commit, deny Photos access from a given commit on, or lose iCloud Drive from a
/// given commit on.
actor FakeDestination: ImportDestination {
    nonisolated let kind: DestinationKind
    let folder: URL
    /// Where it stages (staging only).
    let place: StagingPlace

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
    /// From this attempt number on, every commit fails with `.stagingUnavailable` (iCloud Drive gone).
    private var unavailableFrom: Int?
    /// The album its saves go into (Photos only), named once a commit has succeeded, as the real destination does.
    private var album: String?

    init(kind: DestinationKind, folder: URL, place: StagingPlace = Harness.onThisIPhone) {
        self.kind = kind
        self.folder = folder
        self.place = place
    }

    func fail(attempt: Int, with failure: ImportDestinationFailure) { failures[attempt] = failure }
    func deny(from attempt: Int) { deniesFrom = attempt }
    func becomeUnavailable(from attempt: Int) { unavailableFrom = attempt }
    func fileInto(album: String?) { self.album = album }

    func filedAlbumIdentifier() async -> String? { kind == .photos && !commits.isEmpty ? album : nil }

    var committedNames: [String] { commits.flatMap { $0.files.map(\.filename) } }

    /// The library, or the folder every file goes to ("Untitled", as its locations say), in `place`.
    nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget {
        switch kind {
        case .photos: .photosLibrary
        case .staging: .stagingFolder(place: place, folderPath: "Untitled")
        }
    }

    func commit(_ unit: CommitUnit) throws(ImportDestinationFailure) -> ImportResult {
        attempts += 1
        if let d = deniesFrom, attempts >= d { throw .photosAccessDenied }
        if let u = unavailableFrom, attempts >= u { throw .stagingUnavailable }
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
        case .staging:
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
            return .staged(place: place, locations)
        }
    }
}

/// The Photos authorisation as a route reads it after a refused save: settable by the test, and counting reads.
final class FakePhotosAccess: Sendable {
    private let state: Mutex<(authorisation: PhotosAuthorisation, reads: Int)>

    init(_ authorisation: PhotosAuthorisation = .authorised) { state = Mutex((authorisation, 0)) }

    func set(_ authorisation: PhotosAuthorisation) { state.withLock { $0.authorisation = authorisation } }
    var reads: Int { state.withLock { $0.reads } }

    /// What `ImportRoute.photos(_:filesFolder:authorisation:)` takes.
    var read: @Sendable () async -> PhotosAuthorisation {
        { [self] in
            state.withLock { s in
                s.reads += 1
                return s.authorisation
            }
        }
    }
}

/// Photos access that holds each read until `n` have arrived, then answers them in arrival order from `answers`
/// (the last answer repeats): two in-flight refusals read access at once and get different answers, so a second
/// switch would show as a second `destinationChanged`.
actor HeldPhotosAccess {
    let n: Int
    let answers: [PhotosAuthorisation]
    private(set) var reads = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(n: Int, answers: [PhotosAuthorisation]) {
        self.n = n
        self.answers = answers
    }

    func read() async -> PhotosAuthorisation {
        let i = reads
        reads += 1
        await withCheckedContinuation { c in
            waiting.append(c)
            if waiting.count == n {
                for w in waiting { w.resume() }
                waiting = []
            }
        }
        return answers[min(i, answers.count - 1)]
    }
}

extension DestinationDecision {
    /// Staged on this iPhone for `reason`, in the harness's place (`Harness.onThisIPhone`). Was `.files(reason)`
    /// before staging replaced the Files folder.
    static func stagedHere(_ reason: StagingReason) -> DestinationDecision {
        .staging(reason, Harness.onThisIPhone)
    }
}
