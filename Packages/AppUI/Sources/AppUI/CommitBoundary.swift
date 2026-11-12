import Foundation
import ImportEngine
import PhotosBridge

// The commit boundary in the app (backlog section 3.1, I15): the launch pass the engine owns (pending commits resolved,
// then partial rows reconciled), Browse's badges read again when it wrote rows, the possible-duplicate line in the
// Import outcome, and the bench check's Debug-only launch argument. The production lookup is composed in `LiveRoot`
// (`LibraryCommitLookup` over `SystemPhotoLibrary` and `UbiquityStagingLocator`).

extension AppModel {
    /// The launch pass (`ImportEngine.launchPass()`): pending commits left by an earlier launch resolved, then partial
    /// rows whose file is gone reset. The app calls it once the catalogue is open and the engine made; the first job's
    /// pass waits for it. When it wrote rows (a commit found in Photos or Staging), every open Browse reads its badges
    /// again, since a file it showed as new may now be imported or staged. Called again, it returns the first report.
    @discardableResult
    public func runLaunchPass() async -> PendingCommitReport {
        let report = await importer.engine.launchPass()
        if report.changedRows { await cameras.refreshBrowseBadges() }
        return report
    }
}

extension ImportModel {
    /// Photos an interrupted import may have saved twice (a pending commit not found under Limited Access, resolved
    /// before this job's diff; I15): "1 photo from an interrupted import may now be in Photos twice."; nil for none.
    public var possibleDuplicatesLine: String? {
        guard camera != nil else { return nil }
        return ImportWording.possibleDuplicates(progress.possibleDuplicates)
    }
}

/// The commit-boundary bench check (docs/iteration-2-bench.md, I15): a launch argument that ends the app right after a
/// destination returns and before the commit's catalogue write (`finishCommit`), so the next launch has a pending
/// commit to resolve. Debug builds only: `install` doesn't exist in a Release build.
public enum CommitBoundaryBench {
    /// The launch argument (Xcode's scheme, *Arguments Passed On Launch*).
    public static let argument = "-EndBeforeFinishCommit"

    #if DEBUG
    /// When `arguments` holds `argument`, makes `engine` call `end` (the app passes `exit(0)`) right after a
    /// destination returns and before that commit's `finishCommit`, with a log line before each. Returns whether it
    /// did.
    @discardableResult
    public static func install(on engine: ImportEngine, arguments: [String], log: any BenchLog,
                               end: @escaping @Sendable () -> Void) async -> Bool {
        guard arguments.contains(argument) else { return false }
        log.note("bench: this launch ends the app after the first commit, before its catalogue write")
        await engine.setBeforeFinishCommit {
            log.note("bench: ending the app between a commit and its catalogue write")
            end()
        }
        return true
    }
    #endif
}
