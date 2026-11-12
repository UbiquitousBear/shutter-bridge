import Catalogue
import Foundation
import PhotosBridge

// Staging's reconcile step (staging PR 7, bench S3): a staged file the person deleted in Files has its staged fact
// cleared, so Browse's Staged badge goes and the file is offered for staging again. Linux-tested over temporary folders
// and fakes; the app runs it each time it comes back to the front (`AppModel.scenePhaseChanged(_:)`).

/// Lists a Staging folder for the reconcile step.
public protocol StagingFolderListing: Sendable {
    /// The names in `folder`, hidden ones included (an evicted iCloud file's ".NAME.icloud" placeholder), or nil when
    /// it can't be listed (unreadable, or not a folder).
    func entries(of folder: URL) -> [String]?
}

/// Lists a folder with `FileManager`, for both staging roots.
///
/// `unverified` (bench S3, the sign-in row): that listing an iCloud Drive folder iOS hasn't synced yet waits for or
/// fails its sync rather than answering empty. The reconcile step never clears an iCloud Drive row because a folder is
/// missing, only because a file is missing from a day folder that was listed, so an empty answer for a folder still
/// coming down could clear only the rows of a day folder that exists and lists without them.
public struct PlainStagingFolderListing: StagingFolderListing {
    public init() {}

    public func entries(of folder: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
    }
}

/// Whether a staged copy is still where its row says, from folder listings alone: no file is opened, read for its size
/// or downloaded.
enum StagedPresenceRule {
    enum Answer: Sendable, Hashable {
        /// The file's name is listed in its folder (an evicted iCloud file's placeholder counts).
        case present
        /// Definitely gone: the file is missing from its folder's listing, or, on this iPhone, a folder on its path is
        /// missing from a listing that succeeded.
        case gone
        /// No answer: a folder couldn't be listed, or, in iCloud Drive, a folder on its path is missing.
        case cannotTell
    }

    /// The answer for `location` under `documents`, its root's Documents folder, walking the recorded path down from
    /// there one listing at a time. Names are compared ignoring case, through `StagingFolderNames.present(in:)`, as the
    /// placer compares them.
    ///
    /// **One rule for every missing folder in iCloud Drive** (Staging, the camera's folder or the day's): it can't be
    /// told apart from iCloud Drive not having synced it yet (just after signing in again, Documents is made on the
    /// phone before Staging and its folders come down), so it is `.cannotTell`. Only the file itself missing from its
    /// day folder's listing, with every folder above it listed, is `.gone` there. On this iPhone, where Documents is
    /// local, a missing folder is `.gone` too. A path that doesn't resolve (unknown, or outside Staging) is
    /// `.cannotTell`.
    static func answer(for location: StagedLocation, documents: URL, list: (URL) -> [String]?) -> Answer {
        guard location.isResolvable else { return .cannotTell }
        let components = location.relativePath.split(separator: "/").map(String.init)
        var folder = documents
        for (i, component) in components.enumerated() {
            guard let entries = list(folder) else { return .cannotTell }
            let wanted = component.lowercased()
            let isFile = i == components.count - 1
            guard StagingFolderNames.present(in: entries).contains(wanted) else {
                return isFile || location.root == .onThisIPhone ? .gone : .cannotTell
            }
            if isFile { return .present }
            // Down into the folder as it is named on disk, which may differ in case from the recorded path.
            let onDisk = entries.first { $0.lowercased() == wanted } ?? component
            folder = folder.appendingPathComponent(onDisk, isDirectory: true)
        }
        return .cannotTell
    }
}

/// What one reconcile pass found, in counts only (the bench line, `staging: reconciled …`).
public struct StagedReconcileReport: Sendable, Hashable {
    /// Rows with a staged copy.
    public var looked = 0
    /// Still listed where their row says.
    public var present = 0
    /// Gone, and their staged fact cleared.
    public var cleared = 0
    /// Gone, but the row recorded another copy by the time it was cleared (staged again meanwhile): left alone.
    public var stagedAgain = 0
    /// In iCloud Drive while it isn't available: not checked.
    public var inICloudDriveUnavailable = 0
    /// Gone from iCloud Drive while iCloud Drive had just come back (the previous pass found it unavailable) or went
    /// away or changed during the pass: not cleared this time.
    public var iCloudDriveUnsettled = 0
    /// With no known path, or one outside Staging: never resolved.
    public var unknownPath = 0
    /// Under a folder that couldn't be listed, or missing from iCloud Drive: not checked.
    public var unreadable = 0
    /// Gone, but the catalogue failed to clear it: left as it was.
    public var clearFailed = 0

    public init(looked: Int = 0, present: Int = 0, cleared: Int = 0, stagedAgain: Int = 0,
                inICloudDriveUnavailable: Int = 0, iCloudDriveUnsettled: Int = 0, unknownPath: Int = 0,
                unreadable: Int = 0, clearFailed: Int = 0) {
        self.looked = looked
        self.present = present
        self.cleared = cleared
        self.stagedAgain = stagedAgain
        self.inICloudDriveUnavailable = inICloudDriveUnavailable
        self.iCloudDriveUnsettled = iCloudDriveUnsettled
        self.unknownPath = unknownPath
        self.unreadable = unreadable
        self.clearFailed = clearFailed
    }

    /// Whether any row changed, so Browse reads its badges again.
    public var changedRows: Bool { cleared > 0 }

    /// The rows not checked at all.
    public var notChecked: Int { inICloudDriveUnavailable + iCloudDriveUnsettled + unknownPath + unreadable }
}

/// Clears the staged fact of rows whose staged copy is definitely gone from Staging: deleted in Files, on this iPhone
/// or in iCloud Drive (staging PR 7, bench S3). The app runs a pass on its first activation and each time it comes
/// back from the background (`AppModel`, which also keeps passes from overlapping).
///
/// A pass reads every staged row (`stagedRecords(camera: nil)`, one fetch), asks where iCloud Drive is (`locate()`),
/// then, off the cooperative pool, walks each row's recorded path down from its root's Documents folder, listing each
/// folder at most once per pass (`StagedPresenceRule`). A row is cleared only with `clearStaged(_:ifAt:)`, so a copy
/// staged again (to the same path or another) since the rows were read keeps its row.
///
/// Never cleared:
/// - a row whose path is unknown or outside Staging;
/// - an iCloud Drive row while iCloud Drive isn't available, in the first pass after it came back (the previous pass in
///   this run found it unavailable), or when `locate()`, asked again after the walk, finds it gone or elsewhere;
/// - any row under a folder that couldn't be listed, or under a folder missing from iCloud Drive (Staging, the camera's
///   or the day's): only a file missing from its listed day folder counts as gone there;
/// - a file whose name is still listed (its size isn't checked, so a replaced or still-downloading file stays).
public actor StagedCopyReconciler {
    private let catalogue: any CatalogueStore
    private let onThisIPhone: URL
    private let locator: any StagingLocator
    private let listing: any StagingFolderListing
    private let log: any BenchLog
    /// The last pass found iCloud Drive unavailable: the next one that finds it available doesn't clear iCloud rows.
    private var iCloudDriveWasUnavailable = false

    /// - Parameters:
    ///   - onThisIPhone: The app's Documents folder, the root of On My iPhone › Shutter Bridge › Staging.
    ///   - locator: Where iCloud Drive's staging root is, when it is available.
    public init(catalogue: any CatalogueStore, onThisIPhone: URL, locator: any StagingLocator,
                listing: any StagingFolderListing = PlainStagingFolderListing(), log: any BenchLog = SilentBenchLog()) {
        self.catalogue = catalogue
        self.onThisIPhone = onThisIPhone
        self.locator = locator
        self.listing = listing
        self.log = log
    }

    private struct Checked: Sendable {
        var identity: ObjectIdentity
        var location: StagedLocation
        var answer: StagedPresenceRule.Answer
    }

    private struct Walk: Sendable {
        var checked: [Checked] = []
        var inICloudDriveUnavailable = 0
        var unknownPath = 0
    }

    /// One pass. Returns its counts; an empty report when the catalogue can't list its staged rows.
    @discardableResult
    public func reconcile() async -> StagedReconcileReport {
        let started = ContinuousClock.now
        let records: [CatalogueRecord]
        do {
            records = try await catalogue.stagedRecords(camera: nil)
        } catch {
            log.note("staging: reconcile skipped: catalogue error (\(type(of: error)))", level: .error)
            return StagedReconcileReport()
        }
        let iCloud = await locator.locate().iCloudDocuments
        let justBack = iCloud != nil && iCloudDriveWasUnavailable
        iCloudDriveWasUnavailable = iCloud == nil

        let onThisIPhone = self.onThisIPhone
        let listing = self.listing
        let walk = await StagedRemoval.offThePool { () -> Walk in
            var cache: [String: [String]?] = [:]
            func list(_ folder: URL) -> [String]? {
                let key = folder.standardizedFileURL.path(percentEncoded: false)
                if let cached = cache[key] { return cached }
                let entries = listing.entries(of: folder)
                cache[key] = .some(entries)
                return entries
            }
            var walk = Walk()
            for record in records {
                guard let staged = record.staged else { continue }
                let documents: URL
                switch staged.root {
                case .onThisIPhone:
                    documents = onThisIPhone
                case .iCloudDrive:
                    guard let iCloud else {
                        walk.inICloudDriveUnavailable += 1
                        continue
                    }
                    documents = iCloud
                }
                guard staged.isResolvable else {
                    walk.unknownPath += 1
                    continue
                }
                walk.checked.append(Checked(identity: record.identity, location: staged,
                                            answer: StagedPresenceRule.answer(for: staged, documents: documents,
                                                                              list: list)))
            }
            return walk
        }

        var report = StagedReconcileReport(looked: records.filter { $0.staged != nil }.count,
                                           inICloudDriveUnavailable: walk.inICloudDriveUnavailable,
                                           unknownPath: walk.unknownPath)
        var gone: [Checked] = []
        for checked in walk.checked {
            switch checked.answer {
            case .present: report.present += 1
            case .cannotTell: report.unreadable += 1
            case .gone: gone.append(checked)
            }
        }
        // iCloud Drive must still be where it was when the folders were listed (a sign-out during the pass), and not
        // have only just come back.
        if gone.contains(where: { $0.location.root == .iCloudDrive }) {
            var settled = !justBack
            if settled {
                let after = await locator.locate().iCloudDocuments
                settled = after.map(Self.comparable) == iCloud.map(Self.comparable)
            }
            if !settled {
                report.iCloudDriveUnsettled = gone.filter { $0.location.root == .iCloudDrive }.count
                gone.removeAll { $0.location.root == .iCloudDrive }
            }
        }
        for checked in gone {
            do {
                if try await catalogue.clearStaged(checked.identity, ifAt: checked.location) {
                    report.cleared += 1
                } else {
                    report.stagedAgain += 1
                }
            } catch {
                report.clearFailed += 1
                log.note("staging: reconcile couldn't clear a staged file: catalogue error (\(type(of: error)))",
                         level: .error)
            }
        }
        log.note(Self.line(report, seconds: Self.seconds(since: started)))
        return report
    }

    /// The bench line: counts only, never a name or a path.
    static func line(_ report: StagedReconcileReport, seconds: Double) -> String {
        "staging: reconciled \(report.looked) staged file(s) in \(String(format: "%.2f", seconds)) s: "
            + "\(report.cleared) gone and cleared, \(report.present) still there, \(report.notChecked) not checked "
            + "(\(report.inICloudDriveUnavailable) in iCloud Drive while it isn't available, "
            + "\(report.iCloudDriveUnsettled) in iCloud Drive just after it came back or while it went away, "
            + "\(report.unknownPath) with no known path, \(report.unreadable) where a folder couldn't be read or is "
            + "missing from iCloud Drive), \(report.stagedAgain) staged again meanwhile, "
            + "\(report.clearFailed) not cleared for a catalogue error"
    }

    /// A Documents URL as compared between the two `locate()` calls: by its standardised path, so two spellings of
    /// one folder never read as a change.
    private static func comparable(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
