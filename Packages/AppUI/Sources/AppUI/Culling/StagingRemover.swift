import Catalogue
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Removing the staged copies after *Import keepers* (backlog section 7.6; D2, Shamil, 11 Nov). This deletes the person's
// photos from Staging, so every rule is conservative:
//
// - **Only recorded paths.** A copy is removed only through its row's `stagedRelativePath`, resolved with
//   `StagedLocation.fileURL(in:)`, never by walking a folder. An empty (unknown) path or one outside `Staging/` doesn't
//   resolve and is skipped, so the originals an older build imported to Files in a camera folder called "Staging"
//   (Documents/Staging, before 11 Nov), which have no staged row, are never touched.
// - **Only the recorded file.** A file at the path whose size isn't the recorded one is left alone; so is a folder.
// - **Only what is safe** (`StagingRemovalRule`): a keeper whose save succeeded, both halves of a pair; rejects only
//   when every keeper of their day is in Photos; never an unmarked file.
// - **Never the camera.** Nothing here has a camera link: `CameraLink` has no delete call, and Staging's link reports
//   `deletes: false`.
// - A removal that fails leaves the row staged (the cull screen offers it again); a removed copy's row is cleared with
//   `clearStaged`, which keeps its state and its mark (D3).

/// One staged copy: the file's identity and where the catalogue recorded its copy.
public struct StagedCopy: Sendable, Hashable {
    public var identity: ObjectIdentity
    public var location: StagedLocation

    public init(identity: ObjectIdentity, location: StagedLocation) {
        self.identity = identity
        self.location = location
    }
}

/// What the one confirmation after *Import keepers* offers to remove (D2), and what it holds back. Counts of keepers,
/// rejects and unmarked files are in units, as the cull screen counts them (a RAW+JPEG pair is one); `copies` are files.
public struct StagingRemovalPlan: Sendable, Hashable {
    /// The staged copies to remove, keepers' first, each day's in shooting order.
    public var copies: [StagedCopy] = []
    /// Keepers wholly in Photos, whose copies go.
    public var keepersInPhotos = 0
    /// Rejects whose copies go.
    public var rejects = 0
    /// Keepers not wholly in Photos (failed, skipped, or one half of a pair failed): they stay, with their mark.
    public var keepersHeld = 0
    /// Rejects that stay because a keeper of their day isn't in Photos.
    public var rejectsHeld = 0
    /// Unmarked units, which always stay.
    public var unmarked = 0

    public init() {}

    public var isEmpty: Bool { copies.isEmpty }
}

/// The removal rules (backlog section 7.6; D2), pure so every one is tested on Linux.
public enum StagingRemovalRule {
    /// What may be removed from `days`, given the marks (by content key, as the catalogue keeps them), the catalogue's
    /// states of the files (by content: a keeper imported before, separately, is in Photos too) and the staged copies
    /// recorded now.
    ///
    /// - A keeper's copies go only if every file of the unit is imported (both halves of a pair).
    /// - A day's rejects go only when every keeper of that day is in Photos. A keeper given up (its mark changed to
    ///   Reject, or cleared) is no longer a keeper, so it doesn't hold its day back.
    /// - Unmarked units always stay.
    /// - A file with no staged copy recorded now (its copy was removed meanwhile) has nothing to remove.
    public static func plan(days: [CullDayRow], marks: [ObjectIdentity.ContentKey: CullMark],
                            states: [ObjectIdentity: ObjectState],
                            staged: [ObjectIdentity: StagedLocation]) -> StagingRemovalPlan {
        var plan = StagingRemovalPlan()
        var keeperCopies: [StagedCopy] = []
        var rejectCopies: [StagedCopy] = []
        for day in days {
            var keepers: [CullUnit] = []
            var rejects: [CullUnit] = []
            for unit in day.units {
                switch CullMark.of(unit, in: marks).decision {
                case .keep?: keepers.append(unit)
                case .reject?: rejects.append(unit)
                case nil: plan.unmarked += 1
                }
            }
            var allIn = true
            for unit in keepers {
                if unit.files.allSatisfy({ states[$0.identity] == .imported }) {
                    plan.keepersInPhotos += 1
                    keeperCopies += copies(of: unit, staged: staged)
                } else {
                    plan.keepersHeld += 1
                    allIn = false
                }
            }
            if allIn {
                plan.rejects += rejects.count
                for unit in rejects { rejectCopies += copies(of: unit, staged: staged) }
            } else {
                plan.rejectsHeld += rejects.count
            }
        }
        plan.copies = keeperCopies + rejectCopies
        return plan
    }

    private static func copies(of unit: CullUnit, staged: [ObjectIdentity: StagedLocation]) -> [StagedCopy] {
        unit.files.compactMap { file in staged[file.identity].map { StagedCopy(identity: file.identity, location: $0) } }
    }
}

/// Why one staged copy wasn't removed.
public enum StagedRemovalFailure: Error, Sendable, Hashable {
    /// Nothing is at the recorded path (removed in Files, or an iCloud placeholder only): the row stays staged.
    case gone
    /// Something is at the path, but not the recorded file (another size, or a folder): left alone.
    case notTheStagedFile
    /// The removal itself failed (busy, an iCloud error); `detail` is the error's domain and code, for the log.
    case failed(detail: String)
}

/// Removes one staged copy, and a day folder left empty. `PlainStagedFileRemover` for On My iPhone and for Linux;
/// on iPhone, `CoordinatedStagedFileRemover` for iCloud Drive (`StagedFileRemovers.iCloudDrive`).
public protocol StagedFileRemoving: Sendable {
    /// Removes the regular file at `url` if its size is `expectedSize`; anything else is left as it is.
    func removeFile(at url: URL, expectedSize: UInt64) async throws(StagedRemovalFailure)
    /// Removes the folder at `url` only if it is empty (an `rmdir`, which refuses a folder with anything in it);
    /// whether it was removed.
    func removeFolderIfEmpty(at url: URL) async -> Bool
}

/// The removers a caller can choose between.
public enum StagedFileRemovers {
    /// For staged copies in iCloud Drive: coordinated on iPhone (`CoordinatedStagedFileRemover`), plain elsewhere.
    public static var iCloudDrive: any StagedFileRemoving {
        #if os(iOS)
        CoordinatedStagedFileRemover()
        #else
        PlainStagedFileRemover()
        #endif
    }
}

/// Removes with `FileManager` and `rmdir`, off the cooperative pool. Tested on Linux.
public struct PlainStagedFileRemover: StagedFileRemoving {
    public init() {}

    public func removeFile(at url: URL, expectedSize: UInt64) async throws(StagedRemovalFailure) {
        let outcome = await StagedRemoval.offThePool { StagedRemoval.removeFile(at: url, expectedSize: expectedSize) }
        if case let .failure(failure) = outcome { throw failure }
    }

    public func removeFolderIfEmpty(at url: URL) async -> Bool {
        await StagedRemoval.offThePool { StagedRemoval.removeFolderIfEmpty(at: url) }
    }
}

/// The synchronous steps both removers share.
enum StagedRemoval {
    /// The checks, then the removal: a regular file of the recorded size, and nothing else.
    static func removeFile(at url: URL, expectedSize: UInt64) -> Result<Void, StagedRemovalFailure> {
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return .failure(.gone) }
        guard !isDirectory.boolValue,
              let attributes = try? fm.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value == expectedSize
        else { return .failure(.notTheStagedFile) }
        do {
            try fm.removeItem(at: url)
            return .success(())
        } catch {
            let ns = error as NSError
            return .failure(.failed(detail: "\(ns.domain) \(ns.code)"))
        }
    }

    /// `rmdir`: removes the folder only if it is empty, atomically, so a file arriving meanwhile is never removed with
    /// it.
    static func removeFolderIfEmpty(at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return rmdir(path) == 0
        }
    }

    /// Runs blocking file work on a dispatch queue and waits without holding a cooperative thread.
    static func offThePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

#if os(iOS)
/// Removes a staged copy in iCloud Drive under `NSFileCoordinator`'s deleting coordination, so the iCloud daemon and
/// the Files app see the removal, and an evicted (dataless) file is removed without downloading it. Compiled only by
/// CI's Xcode 27 job; checked on the bench with iCloud Drive (I5). `unverified`: that a dataless file reports its
/// logical size, which the size check reads (if not, it is left alone as `notTheStagedFile`, which is safe).
public struct CoordinatedStagedFileRemover: StagedFileRemoving {
    public init() {}

    public func removeFile(at url: URL, expectedSize: UInt64) async throws(StagedRemovalFailure) {
        let outcome = await StagedRemoval.offThePool { () -> Result<Void, StagedRemovalFailure> in
            var coordinationError: NSError?
            var result: Result<Void, StagedRemovalFailure> = .failure(.failed(detail: "coordination didn't run"))
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url, options: .forDeleting, error: &coordinationError
            ) { coordinatedURL in
                result = StagedRemoval.removeFile(at: coordinatedURL, expectedSize: expectedSize)
            }
            if let coordinationError {
                let isMissing = coordinationError.domain == NSCocoaErrorDomain
                    && coordinationError.code == NSFileNoSuchFileError
                return .failure(isMissing ? .gone
                    : .failed(detail: "\(coordinationError.domain) \(coordinationError.code)"))
            }
            return result
        }
        if case let .failure(failure) = outcome { throw failure }
    }

    public func removeFolderIfEmpty(at url: URL) async -> Bool {
        await StagedRemoval.offThePool { () -> Bool in
            var coordinationError: NSError?
            var removed = false
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url, options: .forDeleting, error: &coordinationError
            ) { coordinatedURL in
                removed = StagedRemoval.removeFolderIfEmpty(at: coordinatedURL)
            }
            return coordinationError == nil && removed
        }
    }
}
#endif

/// What a removal did, in files.
public struct StagingRemovalResult: Sendable, Hashable {
    /// Removed, and their rows' staged copy cleared.
    public var removed = 0
    /// Not removed (gone, busy, an iCloud error, iCloud Drive unavailable, or not the recorded file): their rows stay
    /// staged, and the cull screen offers them again.
    public var failed = 0
    /// Never touched: the recorded path is unknown (empty) or outside Staging, which the resolver refuses.
    public var skipped = 0
    /// Day folders left empty and removed.
    public var foldersRemoved = 0

    public init() {}
}

/// Removes the staged copies a confirmed `StagingRemovalPlan` names (backlog section 7.6), each through its recorded
/// path only: plainly on this iPhone, under file coordination in iCloud Drive. A removed copy's row has its staged copy
/// cleared (`clearStaged`); a day folder a removed path named is removed when it is left empty, and nothing above it.
public struct StagingRemover: Sendable {
    private let catalogue: any CatalogueStore
    private let onThisIPhone: URL
    private let iCloud: URL?
    private let plain: any StagedFileRemoving
    private let coordinated: any StagedFileRemoving
    private let log: any BenchLog

    /// - Parameters:
    ///   - onThisIPhone: The app's Documents folder, the root of On My iPhone › Shutter Bridge › Staging.
    ///   - iCloud: The iCloud container's Documents folder, the root of iCloud Drive › Shutter Bridge › Staging; nil when
    ///     iCloud Drive isn't available (its copies then aren't removed, and stay staged).
    ///   - plain: Removes copies on this iPhone.
    ///   - coordinated: Removes copies in iCloud Drive (`StagedFileRemovers.iCloudDrive`).
    public init(catalogue: any CatalogueStore, onThisIPhone: URL, iCloud: URL?,
                plain: any StagedFileRemoving = PlainStagedFileRemover(),
                coordinated: any StagedFileRemoving = StagedFileRemovers.iCloudDrive,
                log: any BenchLog = SilentBenchLog()) {
        self.catalogue = catalogue
        self.onThisIPhone = onThisIPhone
        self.iCloud = iCloud
        self.plain = plain
        self.coordinated = coordinated
        self.log = log
    }

    public func remove(_ copies: [StagedCopy]) async -> StagingRemovalResult {
        var result = StagingRemovalResult()
        var dayFolders: [(folder: URL, remover: any StagedFileRemoving)] = []
        for copy in copies {
            let documents: URL
            let remover: any StagedFileRemoving
            switch copy.location.root {
            case .onThisIPhone:
                documents = onThisIPhone
                remover = plain
            case .iCloudDrive:
                guard let iCloud else {
                    result.failed += 1
                    continue
                }
                documents = iCloud
                remover = coordinated
            }
            // The only way a recorded copy becomes a file (`fileURL(in:)`): an unknown or out-of-Staging path is nil.
            guard let url = copy.location.fileURL(in: documents) else {
                result.skipped += 1
                continue
            }
            do throws(StagedRemovalFailure) {
                try await remover.removeFile(at: url, expectedSize: copy.identity.size)
            } catch {
                result.failed += 1
                log.note("staging: a staged copy wasn't removed (\(Self.word(error)))", level: .error)
                continue
            }
            result.removed += 1
            do {
                try await catalogue.clearStaged(copy.identity)
            } catch {
                // The file is gone; its row still says staged until the catalogue takes the change (the cull screen
                // counts it as gone meanwhile).
                log.note("staging: a removed copy's row couldn't be cleared (\(type(of: error)))", level: .error)
            }
            if let folder = Self.dayFolder(of: copy.location, at: url),
               !dayFolders.contains(where: { $0.folder == folder }) {
                dayFolders.append((folder, remover))
            }
        }
        for (folder, remover) in dayFolders where await remover.removeFolderIfEmpty(at: folder) {
            result.foldersRemoved += 1
        }
        // Counts only: never a name, a path or a camera's folder.
        log.note("staging: removed \(result.removed) staged file(s), \(result.failed) not removed, "
            + "\(result.skipped) skipped, \(result.foldersRemoved) day folder(s)")
        return result
    }

    /// The day folder a removed copy was in ("Staging/<camera>/<day>/<file>"): only for a path that deep, so Staging
    /// itself and a camera's folder are never removed.
    static func dayFolder(of location: StagedLocation, at url: URL) -> URL? {
        guard location.relativePath.split(separator: "/").count >= 4 else { return nil }
        return url.deletingLastPathComponent()
    }

    private static func word(_ failure: StagedRemovalFailure) -> String {
        switch failure {
        case .gone: "it is gone"
        case .notTheStagedFile: "the file there isn't the staged one"
        case let .failed(detail): detail
        }
    }
}
