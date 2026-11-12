import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Synchronization
import Testing
@testable import AppUI

// Staging's hardening (staging PR 7): the reconcile step for staged files deleted in Files (bench S3), the free-space
// check before each job (S4) and the iCloud upload status with the quota error (S10).

// MARK: - Helpers

/// A Documents folder in a fresh temporary folder, with staged files in it and their rows in a catalogue.
private struct StagingTree {
    let documents: URL
    let key = CameraKey(rawValue: "upkeep-camera")
    static let day = "2026-11-01"
    static let camera = "ILCE-7CM2"

    init() throws {
        documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUITests-upkeep-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    func identity(_ name: String, at seconds: TimeInterval) -> ObjectIdentity {
        item(name, at: seconds).identity(camera: key, timeZone: .current)!
    }

    static func path(_ name: String, camera: String = camera, day: String = day) -> String {
        "Staging/\(camera)/\(day)/\(name)"
    }

    func url(_ relativePath: String) -> URL {
        documents.appendingPathComponent(relativePath, isDirectory: false)
    }

    /// Writes the file (unless `onDisk` is false) and records it staged at `relativePath` under `root`.
    @discardableResult
    func stage(_ name: String, at seconds: TimeInterval, root: StagingRoot = .onThisIPhone,
               relativePath: String? = nil, onDisk: Bool = true, stagedAt: Date = Date(timeIntervalSince1970: 1),
               in catalogue: InMemoryCatalogue) async throws -> (ObjectIdentity, StagedLocation) {
        let path = relativePath ?? Self.path(name)
        let identity = identity(name, at: seconds)
        let location = StagedLocation(root: root, relativePath: path, stagedAt: stagedAt)
        if onDisk {
            let file = url(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(name.utf8).write(to: file)
        }
        await catalogue.markStaged(identity, format: item(name).format, at: location)
        return (identity, location)
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: documents.appendingPathComponent(relativePath))
    }
}

/// Answers each `locate()` from a script, then the last answer for ever.
private actor ScriptedLocator: StagingLocator {
    private var answers: [StagingAvailability]
    private(set) var locateCount = 0

    init(_ answers: StagingAvailability...) {
        self.answers = answers
    }

    func locate() -> StagingAvailability {
        locateCount += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

/// The plain listing, counting each folder it lists, with a hook before each listing and a folder made unreadable.
private final class InstrumentedListing: StagingFolderListing, Sendable {
    private let counts = Mutex<[String: Int]>([:])
    let unreadable: Set<String>
    let before: @Sendable (URL) -> Void

    init(unreadable: Set<String> = [], before: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.unreadable = unreadable
        self.before = before
    }

    var listed: [String: Int] { counts.withLock { $0 } }

    func entries(of folder: URL) -> [String]? {
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        counts.withLock { $0[path, default: 0] += 1 }
        before(folder)
        if unreadable.contains(folder.lastPathComponent) { return nil }
        return PlainStagingFolderListing().entries(of: folder)
    }
}

/// Runs `work` (async) to its end from a synchronous caller off the cooperative pool (the listing's GCD thread).
private func blockingRun(_ work: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await work()
        done.signal()
    }
    done.wait()
}

/// An iCloud account a test switches between passes, or during one from the listing's hook.
private final class SettableIdentity: UbiquityIdentityReading, Sendable {
    private let value: Mutex<Data?>
    init(_ account: String?) { value = Mutex(account.map { Data($0.utf8) }) }
    func set(_ account: String?) { value.withLock { $0 = account.map { Data($0.utf8) } } }
    func currentIdentity() -> Data? { value.withLock { $0 } }
}

private struct FixedFreeSpace: FreeSpaceReading {
    let bytes: UInt64?
    func availableBytes() async -> UInt64? { bytes }
}

private final class ChangingFreeSpace: FreeSpaceReading, Sendable {
    private let value = Mutex<UInt64?>(nil)
    func set(_ bytes: UInt64?) { value.withLock { $0 = bytes } }
    func availableBytes() async -> UInt64? { value.withLock { $0 } }
}

/// The quota error as Apple's headers describe it (bench S10 settles what iOS 27 reports).
private let quotaError = StagedUploadState.failed(.quotaFull(seen: UploadErrorSeen(domain: NSCocoaErrorDomain,
                                                                                  code: 4354)))

/// Answers from a table by file name, counting each read.
private final class TableUploadReader: StagedUploadReading, Sendable {
    private let table: [String: StagedUploadState]
    private let fallback: StagedUploadState
    private let reads = Mutex<[URL]>([])

    init(_ table: [String: StagedUploadState] = [:], otherwise fallback: StagedUploadState = .uploaded) {
        self.table = table
        self.fallback = fallback
    }

    var urls: [URL] { reads.withLock { $0 } }
    var count: Int { urls.count }

    func uploadState(of url: URL) -> StagedUploadState {
        reads.withLock { $0.append(url) }
        return table[url.lastPathComponent] ?? fallback
    }
}

// MARK: - The reconcile step

@Suite("Staging upkeep: reconciling staged files deleted in Files")
struct StagedCopyReconcilerTests {
    private func reconciler(_ tree: StagingTree, _ catalogue: any CatalogueStore,
                            locator: any StagingLocator = FakeStagingLocator(.unavailable(.iCloudDriveOff)),
                            onThisIPhone: URL? = nil, listing: any StagingFolderListing = PlainStagingFolderListing(),
                            identity: any UbiquityIdentityReading = NoUbiquityIdentityReading(),
                            log: any BenchLog = SilentBenchLog()) -> StagedCopyReconciler {
        StagedCopyReconciler(catalogue: catalogue, onThisIPhone: onThisIPhone ?? tree.documents, locator: locator,
                             listing: listing, identity: identity, log: log)
    }

    @Test func deletedFilesAreClearedAndTheRestKept() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        var staged: [(ObjectIdentity, StagedLocation)] = []
        for i in 1...5 {
            staged.append(try await tree.stage("DSC0000\(i).ARW", at: Double(i), in: catalogue))
        }
        // An imported file staged too: clearing keeps its state and location.
        let imported = CatalogueRecord(identity: staged[0].0, format: .raw, state: .imported,
                                       location: .photosAsset(localIdentifier: "A/L0/001"))
        await catalogue.upsert(imported)
        for (_, location) in staged.prefix(3) { try tree.remove(location.relativePath) }

        let report = await reconciler(tree, catalogue).reconcile()
        #expect(report.looked == 5)
        #expect(report.cleared == 3)
        #expect(report.present == 2)
        #expect(report.notChecked == 0)
        #expect(report.changedRows)
        let all = staged.map(\.0)
        #expect(await catalogue.stagedStates(of: all) == Set(all.suffix(2)))
        let first = try #require(await catalogue.record(for: staged[0].0))
        #expect(first.state == .imported)
        #expect(first.location == .photosAsset(localIdentifier: "A/L0/001"))
        #expect(first.staged == nil)
        #expect(await catalogue.record(for: staged[1].0)?.state == .new)

        // A second pass has nothing left to clear.
        let again = await reconciler(tree, catalogue).reconcile()
        #expect(again == StagedReconcileReport(looked: 2, present: 2))
        #expect(!again.changedRows)
    }

    @Test func aDeletedDayOrCameraFolderOnThisIPhoneClearsItsRows() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let a = try await tree.stage("DSC00001.ARW", at: 1, in: catalogue)
        let b = try await tree.stage("DSC00002.ARW", at: 2, in: catalogue)
        let other = try await tree.stage("DSC00003.ARW", at: 3,
                                         relativePath: StagingTree.path("DSC00003.ARW", day: "2026-11-02"),
                                         in: catalogue)
        try tree.remove("Staging/\(StagingTree.camera)/\(StagingTree.day)")
        let report = await reconciler(tree, catalogue).reconcile()
        #expect(report.cleared == 2)
        #expect(report.present == 1)
        #expect(await catalogue.stagedStates(of: [a.0, b.0, other.0]) == [other.0])

        // The whole Staging folder deleted on this iPhone, where Documents is local: every row under it goes.
        try tree.remove("Staging")
        let all = await reconciler(tree, catalogue).reconcile()
        #expect(all.cleared == 1)
        #expect(await catalogue.stagedStates(of: [other.0]).isEmpty)
    }

    @Test func aMissingDayOrCameraFolderInICloudDriveIsNotAnAnswer() async throws {
        let local = try StagingTree()
        let iCloud = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let inDay = try await iCloud.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, in: catalogue)
        let otherCamera = try await iCloud.stage("DSC00002.ARW", at: 2, root: .iCloudDrive,
                                                 relativePath: StagingTree.path("DSC00002.ARW", camera: "ZV-E1"),
                                                 in: catalogue)
        let keptDay = try await iCloud.stage("DSC00003.ARW", at: 3, root: .iCloudDrive,
                                             relativePath: StagingTree.path("DSC00003.ARW", day: "2026-11-02"),
                                             in: catalogue)
        // A day folder and a camera folder missing from iCloud Drive (deleted, or not synced yet), and a file missing
        // from a day folder that is listed.
        try iCloud.remove("Staging/\(StagingTree.camera)/\(StagingTree.day)")
        try iCloud.remove("Staging/ZV-E1")
        let gone = try await iCloud.stage("DSC00004.ARW", at: 4, root: .iCloudDrive,
                                          relativePath: StagingTree.path("DSC00004.ARW", day: "2026-11-02"),
                                          onDisk: false, in: catalogue)
        let report = await reconciler(local, catalogue,
                                      locator: FakeStagingLocator(.iCloudDrive(documents: iCloud.documents)))
            .reconcile()
        #expect(report.unreadable == 2)
        #expect(report.present == 1)
        #expect(report.cleared == 1)
        #expect(await catalogue.stagedStates(of: [inDay.0, otherCamera.0, keptDay.0, gone.0])
            == [inDay.0, otherCamera.0, keptDay.0])
    }

    @Test func anEvictedICloudFileCountsAsPresent() async throws {
        let local = try StagingTree()
        let iCloud = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let (identity, location) = try await iCloud.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, in: catalogue)
        let file = iCloud.url(location.relativePath)
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent()
            .appendingPathComponent(".DSC00001.ARW.icloud"))
        let report = await reconciler(local, catalogue,
                                      locator: FakeStagingLocator(.iCloudDrive(documents: iCloud.documents)))
            .reconcile()
        #expect(report == StagedReconcileReport(looked: 1, present: 1))
        #expect(await catalogue.stagedStates(of: [identity]) == [identity])
    }

    @Test func aNameInAnotherCaseCountsAsPresent() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let (identity, location) = try await tree.stage("DSC00001.ARW", at: 1, in: catalogue)
        let file = tree.url(location.relativePath)
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent()
            .appendingPathComponent("dsc00001.arw"))
        // The camera's folder renamed in case too: the walk goes down into the folder as it is named on disk.
        let cameraFolder = tree.documents.appendingPathComponent("Staging/\(StagingTree.camera)")
        try FileManager.default.moveItem(at: cameraFolder, to: cameraFolder.deletingLastPathComponent()
            .appendingPathComponent(StagingTree.camera.lowercased()))
        let report = await reconciler(tree, catalogue).reconcile()
        #expect(report == StagedReconcileReport(looked: 1, present: 1))
        #expect(await catalogue.stagedStates(of: [identity]) == [identity])
    }

    @Test func nothingInICloudDriveIsClearedWhileItIsUnavailable() async throws {
        let local = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let a = try await local.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, onDisk: false, in: catalogue)
        let b = try await local.stage("DSC00002.ARW", at: 2, root: .iCloudDrive, onDisk: false, in: catalogue)
        let onPhone = try await local.stage("DSC00003.ARW", at: 3, onDisk: false, in: catalogue)
        let report = await reconciler(local, catalogue, locator: FakeStagingLocator(.unavailable(.iCloudDriveOff)))
            .reconcile()
        #expect(report.inICloudDriveUnavailable == 2)
        #expect(report.cleared == 1, "the row on this iPhone is still reconciled")
        #expect(await catalogue.stagedStates(of: [a.0, b.0, onPhone.0]) == [a.0, b.0])
    }

    @Test func aMissingStagingFolderInICloudDriveIsNotAnAnswer() async throws {
        let local = try StagingTree()
        let iCloud = try StagingTree()   // its Documents folder has no Staging folder
        let catalogue = InMemoryCatalogue()
        let a = try await iCloud.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, onDisk: false, in: catalogue)
        let report = await reconciler(local, catalogue,
                                      locator: FakeStagingLocator(.iCloudDrive(documents: iCloud.documents)))
            .reconcile()
        #expect(report == StagedReconcileReport(looked: 1, unreadable: 1))
        #expect(await catalogue.stagedStates(of: [a.0]) == [a.0])
    }

    @Test func iCloudDriveGoingAwayDuringThePassClearsNothingThere() async throws {
        let local = try StagingTree()
        let iCloud = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let kept = try await iCloud.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, in: catalogue)
        let deleted = try await iCloud.stage("DSC00002.ARW", at: 2, root: .iCloudDrive, in: catalogue)
        let onPhone = try await local.stage("DSC00003.ARW", at: 3, onDisk: false, in: catalogue)
        try iCloud.remove(deleted.1.relativePath)
        let locator = ScriptedLocator(.iCloudDrive(documents: iCloud.documents), .unavailable(.iCloudDriveOff))
        let report = await reconciler(local, catalogue, locator: locator).reconcile()
        #expect(report.iCloudDriveUnsettled == 1)
        #expect(report.present == 1)
        #expect(report.cleared == 1, "only the row on this iPhone")
        #expect(await locator.locateCount == 2)
        #expect(await catalogue.stagedStates(of: [kept.0, deleted.0, onPhone.0]) == [kept.0, deleted.0])

        // Another spelling of the same folder isn't a change.
        let respelled = iCloud.documents.appendingPathComponent("Staging/..", isDirectory: true)
        let same = ScriptedLocator(.iCloudDrive(documents: iCloud.documents), .iCloudDrive(documents: respelled))
        let next = await reconciler(local, catalogue, locator: same).reconcile()
        #expect(next.cleared == 1)
        #expect(await catalogue.stagedStates(of: [deleted.0]).isEmpty)
    }

    @Test func theFirstPassAfterICloudDriveCameBackClearsNothingThere() async throws {
        let local = try StagingTree()
        let iCloud = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let deleted = try await iCloud.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, in: catalogue)
        try await iCloud.stage("DSC00002.ARW", at: 2, root: .iCloudDrive, in: catalogue)
        try iCloud.remove(deleted.1.relativePath)
        let locator = FakeStagingLocator(.unavailable(.iCloudDriveOff))
        let reconciler = reconciler(local, catalogue, locator: locator)
        #expect(await reconciler.reconcile().inICloudDriveUnavailable == 2)
        // Signed in again: the first pass that finds it available may list folders still coming down.
        await locator.set(.iCloudDrive(documents: iCloud.documents))
        let first = await reconciler.reconcile()
        #expect(first.iCloudDriveUnsettled == 1)
        #expect(first.cleared == 0)
        #expect(await catalogue.stagedStates(of: [deleted.0]) == [deleted.0])
        // The next one clears it.
        #expect(await reconciler.reconcile().cleared == 1)
        #expect(await catalogue.stagedStates(of: [deleted.0]).isEmpty)
    }

    /// Bench S3's sign-in row when the app returned once while signed out, but its pass ended as iCloud Drive went
    /// away or moved: the next pass that finds it may list folders still coming down, so it clears nothing there.
    @Test func iCloudDriveFoundGoneOrMovedAtThePassEndMakesTheNextPassJustBack() async throws {
        let local = try StagingTree()
        let elsewhere = try StagingTree()
        for second in [StagingAvailability.unavailable(.iCloudDriveOff), .iCloudDrive(documents: elsewhere.documents)] {
            let iCloud = try StagingTree()
            let catalogue = InMemoryCatalogue()
            let deleted = try await iCloud.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, in: catalogue)
            try await iCloud.stage("DSC00002.ARW", at: 2, root: .iCloudDrive, in: catalogue)
            try iCloud.remove(deleted.1.relativePath)
            let here = StagingAvailability.iCloudDrive(documents: iCloud.documents)
            let locator = ScriptedLocator(here, second, here)
            let reconciler = reconciler(local, catalogue, locator: locator)
            #expect(await reconciler.reconcile().iCloudDriveUnsettled == 1, "went away or moved during the pass")
            let next = await reconciler.reconcile()
            #expect(next.iCloudDriveUnsettled == 1, "the first pass after it came back")
            #expect(next.cleared == 0)
            #expect(await locator.locateCount == 3, "a just-back pass doesn't ask again")
            #expect(await catalogue.stagedStates(of: [deleted.0]) == [deleted.0])
            #expect(await reconciler.reconcile().cleared == 1)
            #expect(await catalogue.stagedStates(of: [deleted.0]).isEmpty)
        }
    }

    /// Bench S3's other sign-in row: signing out and in, or into another Apple ID, while the app stays away. No pass
    /// sees iCloud Drive unavailable, so the account read at each pass is what tells.
    @Test func anICloudAccountChangeWhileAwayMakesTheNextPassJustBack() async throws {
        let local = try StagingTree()
        let iCloud = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let deleted = try await iCloud.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, in: catalogue)
        try await iCloud.stage("DSC00002.ARW", at: 2, root: .iCloudDrive, in: catalogue)
        let identity = SettableIdentity("first account")
        let reconciler = reconciler(local, catalogue,
                                    locator: FakeStagingLocator(.iCloudDrive(documents: iCloud.documents)),
                                    identity: identity)
        #expect(await reconciler.reconcile() == StagedReconcileReport(looked: 2, present: 2))
        // Away: the file is deleted and the account changes; iCloud Drive is available at every pass.
        try iCloud.remove(deleted.1.relativePath)
        identity.set("second account")
        let first = await reconciler.reconcile()
        #expect(first.iCloudDriveUnsettled == 1)
        #expect(first.cleared == 0)
        #expect(await catalogue.stagedStates(of: [deleted.0]) == [deleted.0])
        // The same account at the next pass: cleared.
        #expect(await reconciler.reconcile().cleared == 1)
        #expect(await catalogue.stagedStates(of: [deleted.0]).isEmpty)
    }

    /// The account changing during a pass is the same as iCloud Drive moving: nothing there is cleared, nor in the
    /// pass after.
    @Test func anICloudAccountChangeDuringThePassClearsNothingThere() async throws {
        let local = try StagingTree()
        let iCloud = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let deleted = try await iCloud.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, in: catalogue)
        try iCloud.remove(deleted.1.relativePath)
        let identity = SettableIdentity("first account")
        let listing = InstrumentedListing(before: { _ in identity.set("second account") })
        let reconciler = reconciler(local, catalogue,
                                    locator: FakeStagingLocator(.iCloudDrive(documents: iCloud.documents)),
                                    listing: listing, identity: identity)
        #expect(await reconciler.reconcile().iCloudDriveUnsettled == 1)
        #expect(await reconciler.reconcile().iCloudDriveUnsettled == 1)
        #expect(await reconciler.reconcile().cleared == 1)
    }

    @Test func anUnreadableFolderClearsNothingUnderIt() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let a = try await tree.stage("DSC00001.ARW", at: 1, onDisk: false, in: catalogue)
        let b = try await tree.stage("DSC00002.ARW", at: 2, in: catalogue)
        try tree.remove(b.1.relativePath)
        // The day folder is in its parent's listing but can't be listed itself.
        let listing = InstrumentedListing(unreadable: [StagingTree.day])
        let report = await reconciler(tree, catalogue, listing: listing).reconcile()
        #expect(report == StagedReconcileReport(looked: 2, unreadable: 2))
        #expect(await catalogue.stagedStates(of: [a.0, b.0]) == [a.0, b.0])

        // Documents itself unreadable on this iPhone: nothing is cleared either.
        let nowhere = tree.documents.appendingPathComponent("not-a-folder")
        try Data().write(to: nowhere)
        let none = await reconciler(tree, catalogue, onThisIPhone: nowhere).reconcile()
        #expect(none.unreadable == 2)
        #expect(none.cleared == 0)
    }

    @Test func unknownAndOutOfStagingPathsAreNeverResolved() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let unknown = try await tree.stage("DSC00001.ARW", at: 1, relativePath: "", onDisk: false, in: catalogue)
        let outside = try await tree.stage("DSC00002.ARW", at: 2, relativePath: "Camera/DSC00002.ARW", onDisk: false,
                                           in: catalogue)
        let climbing = try await tree.stage("DSC00003.ARW", at: 3, relativePath: "Staging/../DSC00003.ARW",
                                            onDisk: false, in: catalogue)
        let listing = InstrumentedListing()
        let report = await reconciler(tree, catalogue, listing: listing).reconcile()
        #expect(report == StagedReconcileReport(looked: 3, unknownPath: 3))
        #expect(listing.listed.isEmpty)
        #expect(await catalogue.stagedStates(of: [unknown.0, outside.0, climbing.0])
            == [unknown.0, outside.0, climbing.0])
    }

    @Test func aThousandFilesListEachFolderOnce() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        for i in 0..<1000 {
            let day = "2026-11-0\(1 + i % 4)"
            let name = String(format: "DSC%05d.ARW", i)
            try await tree.stage(name, at: Double(i), relativePath: StagingTree.path(name, day: day), in: catalogue)
        }
        let listing = InstrumentedListing()
        let locator = FakeStagingLocator(.unavailable(.iCloudDriveOff))
        let report = await reconciler(tree, catalogue, locator: locator, listing: listing).reconcile()
        #expect(report == StagedReconcileReport(looked: 1000, present: 1000))
        // Documents, Staging, the camera's folder and 4 day folders, once each.
        #expect(listing.listed.count == 7)
        #expect(listing.listed.values.allSatisfy { $0 == 1 })
        #expect(await locator.locateCount == 1, "asked again only when an iCloud Drive row is gone")
    }

    @Test func aCatalogueThatCantListStagedRowsChangesNothing() async throws {
        let tree = try StagingTree()
        let log = LeveledLog()
        let report = await reconciler(tree, BrokenCatalogue(), log: log).reconcile()
        #expect(report == StagedReconcileReport())
        #expect(log.entries.contains { entry in
            entry.line.hasPrefix("staging: reconcile skipped: catalogue error") && entry.level == .error
        })
    }

    @Test func theLogLineHasCountsOnly() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let a = try await tree.stage("DSC00001.ARW", at: 1, in: catalogue)
        try await tree.stage("DSC00002.ARW", at: 2, in: catalogue)
        try await tree.stage("DSC00003.ARW", at: 3, root: .iCloudDrive, onDisk: false, in: catalogue)
        try tree.remove(a.1.relativePath)
        let log = RecordingLog()
        _ = await reconciler(tree, catalogue, log: log).reconcile()
        let line = try #require(log.lines.first { $0.hasPrefix("staging: reconciled ") })
        #expect(line.hasPrefix("staging: reconciled 3 staged file(s) in "))
        #expect(line.contains("1 gone and cleared, 1 still there, 1 not checked (1 in iCloud Drive while it isn't "
            + "available, 0 in iCloud Drive just after it came back or while it went away, 0 with no known path, 0 "
            + "where a folder couldn't be read or is missing from iCloud Drive), 0 staged again meanwhile, 0 not "
            + "cleared for a catalogue error"))
        for secret in ["DSC0000", StagingTree.camera, StagingTree.day, "Staging/", tree.documents.lastPathComponent] {
            #expect(!line.contains(secret))
        }
    }

    /// The race the conditional clear closes: a file staged again while the pass runs, after the rows were read, keeps
    /// its row. A reconciler that cleared with plain `clearStaged(_:)` would clear both.
    @Test func aFileStagedAgainDuringThePassKeepsItsRow() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        let samePath = try await tree.stage("DSC00001.ARW", at: 1, in: catalogue)
        let elsewhere = try await tree.stage("DSC00002.ARW", at: 2, in: catalogue)
        try tree.remove(samePath.1.relativePath)
        try tree.remove(elsewhere.1.relativePath)
        let again = StagedLocation(root: .onThisIPhone, relativePath: samePath.1.relativePath,
                                   stagedAt: Date(timeIntervalSince1970: 2))
        let moved = StagedLocation(root: .onThisIPhone, relativePath: StagingTree.path("DSC00002 (2).ARW"),
                                   stagedAt: Date(timeIntervalSince1970: 2))
        // When the day folder is listed, a job stages both files again: one to the same path, one beside it. The
        // listing still answers without the old names.
        let restaged = Mutex(false)
        let listing = InstrumentedListing(before: { folder in
            guard folder.lastPathComponent == StagingTree.day, !restaged.withLock({ $0 }) else { return }
            restaged.withLock { $0 = true }
            blockingRun {
                await catalogue.markStaged(samePath.0, format: .raw, at: again)
                await catalogue.markStaged(elsewhere.0, format: .raw, at: moved)
            }
        })
        let report = await reconciler(tree, catalogue, listing: listing).reconcile()
        #expect(restaged.withLock { $0 })
        #expect(report.cleared == 0)
        #expect(report.stagedAgain == 2)
        #expect(!report.changedRows)
        #expect(await catalogue.record(for: samePath.0)?.staged == again)
        #expect(await catalogue.record(for: elsewhere.0)?.staged == moved)
    }

    @Test func theRuleWalksThePathAndNeverGuesses() {
        let documents = URL(fileURLWithPath: "/D", isDirectory: true)
        let folders: [String: [String]] = [
            "/D": ["Staging", "Other"],
            "/D/Staging": ["Cam"],
            "/D/Staging/Cam": ["2026-11-01"],
            "/D/Staging/Cam/2026-11-01": ["A.ARW", ".B.ARW.icloud"],
        ]
        func list(_ url: URL) -> [String]? {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return folders[path]
        }
        func answer(_ root: StagingRoot, _ path: String) -> StagedPresenceRule.Answer {
            StagedPresenceRule.answer(for: StagedLocation(root: root, relativePath: path), documents: documents,
                                      list: list)
        }
        for root in StagingRoot.allCases {
            #expect(answer(root, "Staging/Cam/2026-11-01/A.ARW") == .present)
            #expect(answer(root, "Staging/Cam/2026-11-01/b.arw") == .present)
            #expect(answer(root, "Staging/Cam/2026-11-01/C.ARW") == .gone)
            #expect(answer(root, "") == .cannotTell)
            #expect(answer(root, "Other/A.ARW") == .cannotTell)
        }
        // A folder missing from a listing: gone on this iPhone, no answer in iCloud Drive.
        #expect(answer(.onThisIPhone, "Staging/Cam/2026-11-02/A.ARW") == .gone)
        #expect(answer(.iCloudDrive, "Staging/Cam/2026-11-02/A.ARW") == .cannotTell)
        #expect(answer(.onThisIPhone, "Staging/Other/2026-11-01/A.ARW") == .gone)
        #expect(answer(.iCloudDrive, "Staging/Other/2026-11-01/A.ARW") == .cannotTell)
        // A folder listed in its parent but not listable: no answer on either root.
        let unlistable = StagedLocation(root: .onThisIPhone, relativePath: "Staging/Cam/2026-11-01/A.ARW")
        #expect(StagedPresenceRule.answer(for: unlistable, documents: documents, list: { url in
            url.lastPathComponent == "Cam" ? nil : list(url)
        }) == .cannotTell)
    }
}

// MARK: - When it runs

@MainActor
@Suite("Staging upkeep: when it runs")
struct StagingUpkeepAppTests {
    private func appModel(discovery: FakeDiscovery, catalogue: InMemoryCatalogue, documents: URL?,
                          listing: any StagingFolderListing = PlainStagingFolderListing(),
                          log: RecordingLog = RecordingLog(), uploadReader: (any StagedUploadReading)? = nil,
                          staging: StagingAvailability = .unavailable(.containerUnavailable)) -> AppModel {
        AppModel(discovery: discovery, services: services(log: log), catalogue: catalogue,
                 engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                 settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                 destinations: FakeDestinations(staging: staging), cameraKey: CameraKeys.fromDescriptor,
                 stagingDocuments: documents, folderListing: listing, uploadReader: uploadReader)
    }

    private func stageOnDisk(_ file: CameraItem, of link: FakeLink, under documents: URL,
                             in catalogue: InMemoryCatalogue) async throws -> (ObjectIdentity, URL) {
        let key = CameraKeys.key(for: link.descriptor, material: nil)
        let identity = try #require(file.identity(camera: key, timeZone: .current))
        let path = StagingTree.path(file.name)
        let url = documents.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        await catalogue.markStaged(identity, format: file.format,
                                   at: StagedLocation(root: .onThisIPhone, relativePath: path, stagedAt: Date()))
        return (identity, url)
    }

    private func reconciledLines(_ log: RecordingLog) -> Int {
        log.lines.filter { $0.hasPrefix("staging: reconciled ") }.count
    }

    /// A new, unmarked file: once its staged copy is deleted, *Select All New* picks it again (an imported or rejected
    /// one would stay out, D3).
    @Test func comingToTheFrontReconcilesAndBrowseOffersTheFilesAgain() async throws {
        let stagedFile = item("DSC00001.JPG")
        let other = item("DSC00002.JPG", at: 5)
        let link = FakeLink(items: [stagedFile, other])
        let catalogue = InMemoryCatalogue()
        let tree = try StagingTree()
        let (identity, url) = try await stageOnDisk(stagedFile, of: link, under: tree.documents, in: catalogue)
        let log = RecordingLog()
        let app = appModel(discovery: FakeDiscovery(link: link), catalogue: catalogue, documents: tree.documents,
                           log: log)
        let browse = app.browseModel(for: link.descriptor)
        let run = Task { await browse.run() }
        #expect(await eventually { browse.phase == .listed })
        #expect(await eventually { browse.staged == [stagedFile.id] })
        #expect(browse.liveNewPhotoCount == 1)

        try FileManager.default.removeItem(at: url)
        await app.scenePhaseChanged(.active)
        await app.stagingUpkeepSettled()
        #expect(reconciledLines(log) == 1)
        #expect(browse.staged.isEmpty)
        #expect(browse.liveNewPhotoCount == 2)
        browse.selectAllNew()
        #expect(browse.selection == [stagedFile.id, other.id])
        #expect(await catalogue.record(for: identity)?.staged == nil)
        run.cancel()
        await run.value
    }

    @Test func withoutStagingDocumentsNothingIsReconciled() async throws {
        let file = item("DSC00001.JPG")
        let link = FakeLink(items: [file])
        let catalogue = InMemoryCatalogue()
        let tree = try StagingTree()
        let (identity, url) = try await stageOnDisk(file, of: link, under: tree.documents, in: catalogue)
        try FileManager.default.removeItem(at: url)
        let log = RecordingLog()
        let app = appModel(discovery: FakeDiscovery(link: link), catalogue: catalogue, documents: nil, log: log)
        #expect(await app.reconcileStagedCopies() == nil)
        #expect(app.uploads == nil)
        await app.scenePhaseChanged(.active)
        await app.stagingUpkeepSettled()
        #expect(reconciledLines(log) == 0)
        #expect(await catalogue.record(for: identity)?.staged != nil)
    }

    /// Pulling Control Centre down, Face ID or a permission prompt makes the app inactive and then active again: no
    /// pass. Only the first activation and a return from the background reconcile.
    @Test func anInactiveFlickDoesntReconcile() async throws {
        let link = FakeLink(items: [item("DSC00001.JPG")])
        let tree = try StagingTree()
        let log = RecordingLog()
        let app = appModel(discovery: FakeDiscovery(link: link), catalogue: InMemoryCatalogue(),
                           documents: tree.documents, log: log)
        await app.scenePhaseChanged(.active)
        await app.stagingUpkeepSettled()
        #expect(reconciledLines(log) == 1)
        await app.scenePhaseChanged(.inactive)
        await app.scenePhaseChanged(.active)
        await app.stagingUpkeepSettled()
        #expect(reconciledLines(log) == 1)
        await app.scenePhaseChanged(.inactive)
        await app.scenePhaseChanged(.background)
        await app.scenePhaseChanged(.inactive)
        await app.scenePhaseChanged(.active)
        await app.stagingUpkeepSettled()
        #expect(reconciledLines(log) == 2)
    }

    /// Returns from the background while a pass runs share one follow-up pass, rather than queueing one each; the
    /// follow-up's clears still reach Browse.
    @Test func overlappingReturnsShareOneFollowUpPassThatStillRefreshesBrowse() async throws {
        let stagedFile = item("DSC00001.JPG")
        let link = FakeLink(items: [stagedFile])
        let catalogue = InMemoryCatalogue()
        let tree = try StagingTree()
        let (identity, url) = try await stageOnDisk(stagedFile, of: link, under: tree.documents, in: catalogue)
        // The first pass lists the day folder (the file is there), then waits until the test lets it go.
        let gate = DispatchSemaphore(value: 0)
        let listedDay = Mutex(0)
        let listing = InstrumentedListing(before: { folder in
            guard folder.lastPathComponent == StagingTree.day else { return }
            if listedDay.withLock({ $0 += 1; return $0 }) == 1 { gate.wait() }
        })
        let log = RecordingLog()
        let app = appModel(discovery: FakeDiscovery(link: link), catalogue: catalogue, documents: tree.documents,
                           listing: listing, log: log)
        let browse = app.browseModel(for: link.descriptor)
        let run = Task { await browse.run() }
        #expect(await eventually { browse.phase == .listed })
        #expect(await eventually { browse.staged == [stagedFile.id] })

        await app.scenePhaseChanged(.active)
        #expect(await eventually { listedDay.withLock { $0 } == 1 })
        // Deleted while the first pass waits, after the day folder was looked at; two returns meanwhile.
        try FileManager.default.removeItem(at: url)
        for _ in 0..<2 {
            await app.scenePhaseChanged(.background)
            await app.scenePhaseChanged(.active)
        }
        gate.signal()
        await app.stagingUpkeepSettled()
        #expect(reconciledLines(log) == 2, "the first pass and one follow-up")
        #expect(await catalogue.record(for: identity)?.staged == nil)
        #expect(browse.staged.isEmpty)
        run.cancel()
        await run.value
    }

    @Test func theUploadStatusIsReadAfterTheReconcileAndSharedWithTheScreens() async throws {
        let iCloud = try StagingTree()
        let catalogue = InMemoryCatalogue()
        try await iCloud.stage("DSC00001.ARW", at: 1, root: .iCloudDrive, in: catalogue)
        let reader = TableUploadReader(["DSC00001.ARW": quotaError])
        let app = appModel(discovery: FakeDiscovery(link: FakeLink(items: [])), catalogue: catalogue,
                           documents: try StagingTree().documents, uploadReader: reader,
                           staging: .iCloudDrive(documents: iCloud.documents))
        #expect(app.importer.uploads === app.uploads)
        await app.scenePhaseChanged(.active)
        await app.stagingUpkeepSettled()
        #expect(reader.count == 1)
        #expect(app.settings.uploadProblemLine == StagingWording.uploadQuotaFull(1))
    }
}

// MARK: - Free space before a job

@Suite("Staging upkeep: free space before a job")
struct FreeSpaceCheckTests {
    @Test func theVerdictComparesTheJobPlusTheSpare() {
        #expect(FreeSpaceCheck.verdict(jobBytes: 9_000, available: 1_000_009_000)
            == .fits(available: 1_000_009_000, needed: 1_000_009_000))
        #expect(FreeSpaceCheck.verdict(jobBytes: 9_000, available: 1_000_008_999)
            == .tooLittle(available: 1_000_008_999, needed: 1_000_009_000))
        #expect(FreeSpaceCheck.verdict(jobBytes: 9_000, available: nil) == .unknown)
        #expect(FreeSpaceCheck.verdict(jobBytes: .max, available: .max) == .fits(available: .max, needed: .max))
        #expect(FreeSpaceCheck.verdict(jobBytes: .max, available: 5) == .tooLittle(available: 5, needed: .max))
    }

    @Test func jobBytesCountDatedStillsOnly() {
        let key = CameraKey(rawValue: "free-space")
        let items = [
            item("DSC00001.ARW", at: 1, size: 4_000),
            item("DSC00002.JPG", at: nil, size: 2_000),
            item("C0001.MP4", at: 2, size: 5_000),
        ]
        #expect(FreeSpaceCheck.jobBytes(items, camera: key, timeZone: .current) == 4_000)
        #expect(FreeSpaceCheck.jobBytes([item("A.ARW", size: .max), item("B.ARW", at: 1, size: 2)], camera: key,
                                        timeZone: .current) == .max)
    }

    @Test func volumeFreeSpaceReadsTheVolume() async {
        let bytes = await VolumeFreeSpace(url: FileManager.default.temporaryDirectory).availableBytes()
        #expect((bytes ?? 0) > 0)
        #expect(await UnknownFreeSpace().availableBytes() == nil)
    }

    @Test func theShortfallIsRoundedUpToWhatIsShown() {
        #expect(FreeSpaceCheck.shortfall(available: 10, needed: 5) == 0)
        #expect(FreeSpaceCheck.shortfall(available: 0, needed: 1) == 1_000)
        #expect(FreeSpaceCheck.shortfall(available: 0, needed: 1_000_001) == 1_100_000)
        #expect(FreeSpaceCheck.shortfall(available: 1_000_000_000, needed: 2_000_000_001) == 1_010_000_000)
        #expect(FreeSpaceCheck.shortfall(available: 0, needed: .max) == .max)
    }
}

extension ImportModelTests {
    @Test func aStageJobThatCantFitIsStoppedBeforeItStarts() async {
        let log = RecordingLog()
        let h = await harness(setting: .photos, log: log, freeSpace: FixedFreeSpace(bytes: 1_000_008_999))
        let outcome = await h.model.importItems(card, from: h.camera, link: h.link, as: .staging, newOnly: false)
        let text = ImportWording.notEnoughSpace(free: 1_000_008_999, needed: 9_000, spare: 1_000_000_000, staging: true)
        #expect(outcome == .failed(text))
        #expect(await !h.engine.state.isActive)
        #expect(await h.destinations.files.names.isEmpty)
        #expect(h.model.camera == nil)
        #expect(h.model.message == text)
        #expect(h.model.importChoice == .photos, "a refused job isn't remembered as the choice")
        #expect(log.lines.contains(
            "import: free space 1000008999 bytes; the job needs 9000 bytes plus 1000000000 spare: not started"))
        #expect(!log.lines.contains { $0.hasPrefix("import: started") })
    }

    @Test func aJobThatFitsExactlyStarts() async {
        let log = RecordingLog()
        let h = await harness(setting: .staging, log: log, freeSpace: FixedFreeSpace(bytes: 1_000_009_000))
        #expect(await h.importAll(card) == .started(3))
        #expect(await h.finished())
        #expect(await h.destinations.files.names.count == 3)
        #expect(log.lines.contains(
            "import: free space 1000009000 bytes; the job needs 9000 bytes plus 1000000000 spare: it fits"))
    }

    @Test func unknownFreeSpaceNeverStopsAJob() async {
        let log = RecordingLog()
        let h = await harness(setting: .staging, log: log, freeSpace: FixedFreeSpace(bytes: nil))
        #expect(await h.importAll(card) == .started(3))
        #expect(await h.finished())
        #expect(log.lines.contains("import: free space unknown; not checked"))
    }

    @Test func onlyTheFilesTheJobWouldCopyAreCounted() async throws {
        let h = await harness(setting: .staging, freeSpace: FixedFreeSpace(bytes: 1_000_005_000))
        let raw = try #require(card[0].identity(camera: h.camera.key, timeZone: .current))
        await h.catalogue.markStaged(raw, format: .raw,
                                     at: StagedLocation(root: .onThisIPhone, relativePath: "Staging/C/D/DSC00001.ARW"))
        // The two JPEGs (5 000 bytes) plus the spare fit exactly; the staged RAW isn't counted.
        #expect(await h.importAll(card) == .started(2))
        #expect(await h.finished())
    }

    @Test func anImportToPhotosIsCheckedTooAndKeepsTheJobShownBefore() async {
        let freeSpace = ChangingFreeSpace()
        let h = await harness(setting: .photos, freeSpace: freeSpace)
        #expect(await h.importAll(Array(card.prefix(2))) == .started(2))
        #expect(await h.finished())
        let rows = h.model.rows
        let snapshot = h.model.snapshot
        #expect(rows.count == 2)
        freeSpace.set(1_000_002_999)
        let outcome = await h.importAll([card[2]])
        let text = ImportWording.notEnoughSpace(free: 1_000_002_999, needed: 3_000, spare: 1_000_000_000,
                                                staging: false)
        #expect(outcome == .failed(text))
        #expect(text.contains("Importing these files needs"))
        #expect(text.contains("so nothing was imported"))
        #expect(await h.destinations.photos.names.count == 2)
        #expect(h.model.camera == h.camera)
        #expect(h.model.rows == rows)
        #expect(h.model.snapshot == snapshot)
    }

    @Test func theUploadLineFollowsAStageJobIntoICloudDrive() async throws {
        let iCloud = try StagingTree()
        let catalogue = InMemoryCatalogue()
        try await iCloud.stage("DSC00009.ARW", at: 9, root: .iCloudDrive, in: catalogue)
        let monitor = StagedUploadMonitor(catalogue: catalogue,
                                          locator: FakeStagingLocator(.iCloudDrive(documents: iCloud.documents)),
                                          reader: TableUploadReader(otherwise: quotaError))
        await monitor.refresh()
        let inICloud = await harness(setting: .staging, staging: .iCloudDrive(documents: iCloud.documents))
        inICloud.model.uploads = monitor
        #expect(inICloud.model.uploadLine == nil, "no job shown")
        #expect(await inICloud.importAll(card) == .started(3))
        #expect(await inICloud.finished())
        #expect(inICloud.model.uploadLine == StagingWording.uploadQuotaFull(1))

        let onPhone = await harness(setting: .staging)
        onPhone.model.uploads = monitor
        #expect(await onPhone.importAll(card) == .started(3))
        #expect(await onPhone.finished())
        #expect(onPhone.model.uploadLine == nil)
    }
}

// MARK: - The iCloud upload status

@MainActor
@Suite("Staging upkeep: iCloud upload status")
struct StagedUploadMonitorTests {
    private func iCloudRows(_ count: Int, in tree: StagingTree, catalogue: InMemoryCatalogue) async throws {
        for i in 0..<count {
            let name = String(format: "DSC%05d.ARW", i)
            try await tree.stage(name, at: Double(i), root: .iCloudDrive, onDisk: false,
                                 stagedAt: Date(timeIntervalSince1970: Double(i)), in: catalogue)
        }
    }

    @Test func aFullQuotaIsSaidInSettingsAndOnTheImportScreen() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        try await iCloudRows(3, in: tree, catalogue: catalogue)
        let reader = TableUploadReader(["DSC00000.ARW": quotaError, "DSC00001.ARW": quotaError],
                                       otherwise: .uploaded)
        let log = RecordingLog()
        let monitor = StagedUploadMonitor(catalogue: catalogue,
                                          locator: FakeStagingLocator(.iCloudDrive(documents: tree.documents)),
                                          reader: reader, log: log)
        await monitor.refresh()
        #expect(monitor.summary == StagedUploadSummary(read: 3, uploaded: 1, quotaFull: 2,
                                                       firstQuota: UploadErrorSeen(domain: NSCocoaErrorDomain,
                                                                                   code: 4354)))
        let settings = SettingsModel(uploads: monitor)
        #expect(settings.uploadProblemLine == "Your iCloud storage is full, so 2 staged files haven't uploaded to "
            + "iCloud Drive. They stay on this iPhone; free up iCloud storage and they'll upload.")
        #expect(settings.uploadWaitingLine == nil)
        let line = try #require(log.lines.first { $0.hasPrefix("staging: upload status of ") })
        #expect(line.hasSuffix("1 uploaded, 0 waiting, 2 over the iCloud quota (NSCocoaErrorDomain 4354), "
            + "0 other problems (none), 0 not read"))
        #expect(!line.contains("DSC"))
        // Without a monitor, Settings says nothing about uploads.
        #expect(SettingsModel().uploadProblemLine == nil)
    }

    @Test func nothingIsReadWhileICloudDriveIsUnavailable() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        try await iCloudRows(2, in: tree, catalogue: catalogue)
        let reader = TableUploadReader(otherwise: quotaError)
        let locator = FakeStagingLocator(.iCloudDrive(documents: tree.documents))
        let monitor = StagedUploadMonitor(catalogue: catalogue, locator: locator, reader: reader)
        await monitor.refresh()
        #expect(monitor.problemLine != nil)
        await locator.set(.unavailable(.iCloudDriveOff))
        let readsBefore = reader.count
        await monitor.refresh()
        #expect(monitor.summary == nil)
        #expect(reader.count == readsBefore)
        #expect(monitor.problemLine == nil)
        #expect(monitor.waitingLine == nil)
    }

    @Test func onlyICloudDriveCopiesWithAKnownPathAreRead() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        try await tree.stage("DSC00001.ARW", at: 1, onDisk: false, in: catalogue)
        try await tree.stage("DSC00002.ARW", at: 2, root: .iCloudDrive, relativePath: "", onDisk: false, in: catalogue)
        let reader = TableUploadReader()
        let monitor = StagedUploadMonitor(catalogue: catalogue,
                                          locator: FakeStagingLocator(.iCloudDrive(documents: tree.documents)),
                                          reader: reader)
        await monitor.refresh()
        #expect(reader.count == 0)
        #expect(monitor.summary == nil, "nothing to read in iCloud Drive")
        try await tree.stage("DSC00003.ARW", at: 3, root: .iCloudDrive, onDisk: false, in: catalogue)
        await monitor.refresh()
        #expect(reader.urls.map(\.lastPathComponent) == ["DSC00003.ARW"])
        #expect(reader.urls.first == tree.url(StagingTree.path("DSC00003.ARW")))
    }

    @Test func atMostTheNewestThousandAreRead() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        try await iCloudRows(1200, in: tree, catalogue: catalogue)
        let records = await catalogue.stagedRecords(camera: nil)
        let (urls, notRead) = StagedUploadMonitor.filesToRead(records, in: tree.documents, limit: 1000)
        #expect(urls.count == 1000)
        #expect(notRead == 200)
        #expect(urls.first?.lastPathComponent == "DSC01199.ARW")
        #expect(urls.last?.lastPathComponent == "DSC00200.ARW")
        let reader = TableUploadReader()
        let monitor = StagedUploadMonitor(catalogue: catalogue,
                                          locator: FakeStagingLocator(.iCloudDrive(documents: tree.documents)),
                                          reader: reader)
        await monitor.refresh()
        #expect(reader.count == 1000)
        #expect(monitor.summary?.notRead == 200)
    }

    @Test func serverUnavailableCountsAsWaitingNotAsAProblem() {
        let summary = StagedUploadSummary.tally([.failed(.serverUnavailable), .uploading, .waiting, .notInICloud,
                                                 .unreadable], notRead: 0)
        #expect(summary == StagedUploadSummary(read: 5, waiting: 3))
        let other = StagedUploadSummary.tally([.failed(.other(domain: "D", code: 1)),
                                               .failed(.other(domain: "E", code: 2))], notRead: 0)
        #expect(other.otherProblems == 2)
        #expect(other.firstOther == .other(domain: "D", code: 1))
        // The first quota error is kept as iOS reported it, the error under it included, and logged that way.
        let under = UploadErrorSeen(domain: "BRCloudDocsErrorDomain", code: 35, underlyingDomain: NSCocoaErrorDomain,
                                    underlyingCode: 4354)
        let quota = StagedUploadSummary.tally([.uploaded, .failed(.quotaFull(seen: under)), quotaError], notRead: 0)
        #expect(quota == StagedUploadSummary(read: 3, uploaded: 1, quotaFull: 2, firstQuota: under))
        #expect(StagedUploadMonitor.line(quota, seconds: 0).contains(
            "2 over the iCloud quota (BRCloudDocsErrorDomain 35 over NSCocoaErrorDomain 4354), 0 other problems (none)"))
        #expect(StagedUploadMonitor.line(StagedUploadSummary(read: 1, uploaded: 1), seconds: 0)
            .contains("0 over the iCloud quota (none), "))
    }

    @Test func theLinesSayTheProblemFirstThenTheWaiting() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        try await iCloudRows(4, in: tree, catalogue: catalogue)
        let waiting = StagedUploadMonitor(catalogue: catalogue,
                                          locator: FakeStagingLocator(.iCloudDrive(documents: tree.documents)),
                                          reader: TableUploadReader(["DSC00000.ARW": .failed(.serverUnavailable),
                                                                     "DSC00001.ARW": .uploading,
                                                                     "DSC00002.ARW": .waiting]))
        await waiting.refresh()
        #expect(waiting.problemLine == nil)
        #expect(waiting.waitingLine == "3 staged files are waiting to upload to iCloud Drive.")
        let failing = StagedUploadMonitor(catalogue: catalogue,
                                          locator: FakeStagingLocator(.iCloudDrive(documents: tree.documents)),
                                          reader: TableUploadReader(["DSC00000.ARW": .waiting],
                                                                    otherwise: .failed(.other(domain: "D", code: 9))))
        await failing.refresh()
        #expect(failing.problemLine == StagingWording.uploadFailed(3))
        #expect(failing.waitingLine == nil)
    }

    /// Reads asked for while one runs share one more read after it; each caller returns once a read that started after
    /// its call has finished.
    @Test func readsAskedForWhileOneRunsShareOneFollowUp() async throws {
        let tree = try StagingTree()
        let catalogue = InMemoryCatalogue()
        try await iCloudRows(1, in: tree, catalogue: catalogue)
        final class GatedReader: StagedUploadReading, Sendable {
            let gate = DispatchSemaphore(value: 0)
            let reads = Mutex(0)
            func uploadState(of url: URL) -> StagedUploadState {
                if reads.withLock({ $0 += 1; return $0 }) == 1 { gate.wait() }
                return .uploaded
            }
        }
        let reader = GatedReader()
        let monitor = StagedUploadMonitor(catalogue: catalogue,
                                          locator: FakeStagingLocator(.iCloudDrive(documents: tree.documents)),
                                          reader: reader)
        let first = Task { await monitor.refresh() }
        #expect(await eventually { reader.reads.withLock { $0 } == 1 })
        let second = Task { await monitor.refresh() }
        let third = Task { await monitor.refresh() }
        monitor.refreshSoon()
        // Every caller has asked while the first read waits.
        #expect(await eventually { monitor.refreshCalls == 4 })
        reader.gate.signal()
        await first.value
        await second.value
        await third.value
        await monitor.settled()
        #expect(reader.reads.withLock { $0 } == 2)
        #expect(monitor.summary == StagedUploadSummary(read: 1, uploaded: 1))
    }

    @Test func theWordingHasBothPluralForms() {
        #expect(StagingWording.uploadQuotaFull(1) == "Your iCloud storage is full, so 1 staged file hasn't uploaded "
            + "to iCloud Drive. It stays on this iPhone; free up iCloud storage and it will upload.")
        #expect(StagingWording.uploadQuotaFull(2) == "Your iCloud storage is full, so 2 staged files haven't "
            + "uploaded to iCloud Drive. They stay on this iPhone; free up iCloud storage and they'll upload.")
        #expect(StagingWording.uploadFailed(1) == "1 staged file couldn't upload to iCloud Drive yet. It stays on "
            + "this iPhone, and iCloud Drive will try again.")
        #expect(StagingWording.uploadFailed(4) == "4 staged files couldn't upload to iCloud Drive yet. They stay on "
            + "this iPhone, and iCloud Drive will try again.")
        #expect(StagingWording.uploadWaiting(1) == "1 staged file is waiting to upload to iCloud Drive.")
        #expect(StagingWording.uploadWaiting(3) == "3 staged files are waiting to upload to iCloud Drive.")
        let british = Locale(identifier: "en_GB")
        #expect(ImportWording.notEnoughSpace(free: 1_800_000_000, needed: 7_200_000_000, spare: 1_000_000_000,
                                             staging: true, locale: british)
            == "This iPhone has 1.8 GB free. Staging these files needs 7.2 GB, plus 1 GB kept spare, so nothing was "
            + "staged. Free at least 6.4 GB more, then try again.")
        #expect(ImportWording.notEnoughSpace(free: 1_800_000_000, needed: 7_200_000_000, spare: 1_000_000_000,
                                             staging: false, locale: british)
            == "This iPhone has 1.8 GB free. Importing these files needs 7.2 GB, plus 1 GB kept spare, so nothing "
            + "was imported. Free at least 6.4 GB more, then try again.")
    }
}
