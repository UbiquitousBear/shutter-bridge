import Foundation
import PhotosBridge

/// A Photos destination whose first commit waits until the test releases it. It notes whether the committing task
/// had been cancelled by then, and can refuse the save if so, as a destination or store that checks for
/// cancellation would; and whether the staged file was still there, and can fail the commit if not, as a real
/// destination does (`stagedFileMissing`). A test can also release the held commit with a failure of its choosing.
actor HoldingDestination: ImportDestination {
    nonisolated let kind: DestinationKind = .photos
    private let failsIfCancelled: Bool
    private let failsIfFileMissing: Bool
    /// Successful commits, by file name.
    private(set) var commits: [String] = []
    /// For the held commit: whether its task was cancelled when it was released.
    private(set) var cancelledAtCommit: [Bool] = []
    /// For the held commit: whether the staged file was still there when it was released.
    private(set) var stagedFileAtCommit: [Bool] = []
    private var holdFirst = true
    private var releaseFailure: ImportDestinationFailure?
    private var held: CheckedContinuation<Void, Never>?
    private var arrivedWaiter: CheckedContinuation<Void, Never>?

    init(failsIfCancelled: Bool = false, failsIfFileMissing: Bool = false) {
        self.failsIfCancelled = failsIfCancelled
        self.failsIfFileMissing = failsIfFileMissing
    }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        let name = unit.files[0].filename
        if holdFirst {
            holdFirst = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                held = c
                arrivedWaiter?.resume()
                arrivedWaiter = nil
            }
            cancelledAtCommit.append(Task.isCancelled)
            let fileThere = FileManager.default.fileExists(atPath: unit.files[0].url.path)
            stagedFileAtCommit.append(fileThere)
            if let releaseFailure { throw releaseFailure }
            if failsIfCancelled && Task.isCancelled { throw .rejected(detail: "cancelled mid-commit") }
            if failsIfFileMissing && !fileThere { throw .stagedFileMissing }
        }
        commits.append(name)
        return .photosAsset(localIdentifier: "held-\(commits.count)")
    }

    nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget { .photosLibrary }

    /// Returns once the first commit is being held.
    func waitArrived() async {
        if held != nil { return }
        await withCheckedContinuation { arrivedWaiter = $0 }
    }

    /// Lets the held commit go on: to save the file, or, given `failure`, to throw it.
    func release(throwing failure: ImportDestinationFailure? = nil) {
        releaseFailure = failure
        held?.resume()
        held = nil
    }
}

/// Photos that holds every commit until `n` have arrived, then refuses them all (3311), so `n` files in flight are
/// all refused by Photos, the second after the route has already switched.
actor DenyAllTogether: ImportDestination {
    nonisolated let kind: DestinationKind = .photos
    let n: Int
    private(set) var attempts = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(n: Int) { self.n = n }

    nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget { .photosLibrary }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        attempts += 1
        if attempts <= n {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiting.append(c)
                if waiting.count == n {
                    for w in waiting { w.resume() }
                    waiting = []
                }
            }
        }
        throw .photosAccessDenied
    }
}
