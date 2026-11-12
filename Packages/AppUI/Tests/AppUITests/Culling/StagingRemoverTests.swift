import Catalogue
import Foundation
import Testing
@testable import AppUI

/// A unit of one file, or a pair, on day `20261105` of camera `cam-a`, for the removal rules.
private func unit(_ names: String..., at time: String = "20261105T140000", camera: String = "cam-a") -> CullUnit {
    let files = names.map { cullFile($0, at: time, camera: camera) }
    return files.count == 2 ? CullUnit(.pair(raw: files[0], processed: files[1])) : CullUnit(.single(files[0]))
}

private func day(_ units: [CullUnit], day: String = "20261105", camera: String = "ILCE-7CM2") -> CullDayRow {
    CullDayRow(cameraName: camera, day: day, units: units)
}

/// Every file of `units` staged at "Staging/ILCE-7CM2/2026-11-05/<name>" on this iPhone.
private func stagedCopies(_ units: [CullUnit]) -> [ObjectIdentity: StagedLocation] {
    var staged: [ObjectIdentity: StagedLocation] = [:]
    for file in units.flatMap(\.files) {
        staged[file.identity] = StagedLocation(root: .onThisIPhone,
                                               relativePath: "Staging/ILCE-7CM2/2026-11-05/\(file.identity.filename)")
    }
    return staged
}

private func marks(_ pairs: [(CullUnit, CullDecision?)]) -> [ObjectIdentity.ContentKey: CullMark] {
    var marks: [ObjectIdentity.ContentKey: CullMark] = [:]
    for (unit, decision) in pairs {
        for key in unit.keys { marks[key] = CullMark(decision: decision) }
    }
    return marks
}

private func imported(_ files: [CullFile]) -> [ObjectIdentity: ObjectState] {
    Dictionary(uniqueKeysWithValues: files.map { ($0.identity, ObjectState.imported) })
}

/// The removal rules after *Import keepers* (backlog section 7.6; D2): only what is safe, and never an unmarked file.
@Suite("Removing staged copies: the rules")
struct StagingRemovalRuleTests {
    @Test func keepersInPhotosAndTheRejectsOfTheirDayGoAndUnmarkedFilesStay() {
        let keeper = unit("DSC00001.ARW", "DSC00001.JPG", at: "20261105T140001")
        let reject = unit("DSC00002.JPG", at: "20261105T140002")
        let unmarked = unit("DSC00003.JPG", at: "20261105T140003")
        let units = [keeper, reject, unmarked]
        let plan = StagingRemovalRule.plan(days: [day(units)], marks: marks([(keeper, .keep), (reject, .reject)]),
                                           states: imported(keeper.files), staged: stagedCopies(units))
        #expect(plan.keepersInPhotos == 1 && plan.rejects == 1 && plan.unmarked == 1)
        #expect(plan.keepersHeld == 0 && plan.rejectsHeld == 0)
        // Both halves of the pair, then the reject; never the unmarked file.
        #expect(plan.copies.map(\.identity.filename) == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
    }

    @Test func aFailedKeeperStaysWithItsMarkAndHoldsBackTheRejectsOfItsDay() {
        let inPhotos = unit("DSC00001.JPG", at: "20261105T140001")
        let failed = unit("DSC00002.JPG", at: "20261105T140002")
        let reject = unit("DSC00003.JPG", at: "20261105T140003")
        let otherDayReject = unit("DSC00004.JPG", at: "20261106T090000")
        let units = [inPhotos, failed, reject]
        let plan = StagingRemovalRule.plan(
            days: [day(units), day([otherDayReject], day: "20261106")],
            marks: marks([(inPhotos, .keep), (failed, .keep), (reject, .reject), (otherDayReject, .reject)]),
            states: imported(inPhotos.files), staged: stagedCopies(units + [otherDayReject]))
        #expect(plan.keepersInPhotos == 1 && plan.keepersHeld == 1)
        #expect(plan.rejectsHeld == 1 && plan.rejects == 1)
        // The failed keeper and its day's reject stay; the other day's reject goes.
        #expect(plan.copies.map(\.identity.filename) == ["DSC00001.JPG", "DSC00004.JPG"])
    }

    @Test func aPairWithOneHalfFailedStaysWholeAndHoldsItsDay() {
        let pair = unit("DSC00001.ARW", "DSC00001.JPG", at: "20261105T140001")
        let reject = unit("DSC00002.JPG", at: "20261105T140002")
        let units = [pair, reject]
        // The RAW reached Photos, the JPG didn't.
        let plan = StagingRemovalRule.plan(days: [day(units)], marks: marks([(pair, .keep), (reject, .reject)]),
                                           states: imported([pair.files[0]]), staged: stagedCopies(units))
        #expect(plan.isEmpty)
        #expect(plan.keepersHeld == 1 && plan.rejectsHeld == 1 && plan.keepersInPhotos == 0)
    }

    @Test func aFailedKeeperGivenUpNoLongerHoldsItsDayBack() {
        let inPhotos = unit("DSC00001.JPG", at: "20261105T140001")
        let failed = unit("DSC00002.JPG", at: "20261105T140002")
        let reject = unit("DSC00003.JPG", at: "20261105T140003")
        let units = [inPhotos, failed, reject]
        // Changed to Reject: it goes with the other rejects.
        let rejected = StagingRemovalRule.plan(
            days: [day(units)], marks: marks([(inPhotos, .keep), (failed, .reject), (reject, .reject)]),
            states: imported(inPhotos.files), staged: stagedCopies(units))
        #expect(rejected.copies.map(\.identity.filename) == ["DSC00001.JPG", "DSC00002.JPG", "DSC00003.JPG"])
        #expect(rejected.rejects == 2 && rejected.keepersHeld == 0)
        // Cleared: it stays (unmarked), and the reject goes.
        let cleared = StagingRemovalRule.plan(
            days: [day(units)], marks: marks([(inPhotos, .keep), (reject, .reject)]),
            states: imported(inPhotos.files), staged: stagedCopies(units))
        #expect(cleared.copies.map(\.identity.filename) == ["DSC00001.JPG", "DSC00003.JPG"])
        #expect(cleared.unmarked == 1 && cleared.keepersHeld == 0)
    }

    @Test func aDayOfRejectsOnlyIsRemovedAndAnUnmarkedDayIsLeftAlone() {
        let reject = unit("DSC00001.JPG")
        let unmarked = unit("DSC00002.JPG", at: "20261106T090000")
        let plan = StagingRemovalRule.plan(days: [day([reject]), day([unmarked], day: "20261106")],
                                           marks: marks([(reject, .reject)]), states: [:],
                                           staged: stagedCopies([reject, unmarked]))
        #expect(plan.copies.map(\.identity.filename) == ["DSC00001.JPG"])
        #expect(plan.unmarked == 1)
    }

    @Test func aFileWithNoCopyRecordedNowHasNothingToRemove() {
        let keeper = unit("DSC00001.ARW", "DSC00001.JPG")
        var staged = stagedCopies([keeper])
        staged[keeper.files[1].identity] = nil
        let plan = StagingRemovalRule.plan(days: [day([keeper])], marks: marks([(keeper, .keep)]),
                                           states: imported(keeper.files), staged: staged)
        #expect(plan.copies.map(\.identity.filename) == ["DSC00001.ARW"])
        #expect(plan.keepersInPhotos == 1)
    }
}

/// A temporary Documents folder for the plain remover, with staged rows in an `InMemoryCatalogue`.
private struct Folder {
    let documents = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagingRemoverTests-\(UUID().uuidString)", isDirectory: true)

    /// Writes `size` bytes at `relative` under Documents.
    @discardableResult
    func write(_ relative: String, size: Int) -> URL {
        let url = documents.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data(count: size))
        return url
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: documents.appendingPathComponent(relative).path)
    }

    func remove() { try? FileManager.default.removeItem(at: documents) }
}

private func identity(_ name: String, size: Int = 64, camera: String = "cam-a") -> ObjectIdentity {
    ObjectIdentity(camera: CameraKey(rawValue: camera), folder: "100MSDCF", filename: name,
                   captureDate: CaptureDate(rawValue: "20261105T140000")!, size: UInt64(size))
}

/// A staged row for `name` at `path`, and the copy written there unless `write` is false.
private func staged(_ name: String, path: String, size: Int = 64, root: StagingRoot = .onThisIPhone,
                    in folder: Folder, write: Bool = true, writtenSize: Int? = nil) -> (CatalogueRecord, StagedCopy) {
    let location = StagedLocation(root: root, relativePath: path)
    if write { folder.write(path, size: writtenSize ?? size) }
    let id = identity(name, size: size)
    return (CatalogueRecord(identity: id, format: .jpeg, state: .imported, staged: location),
            StagedCopy(identity: id, location: location))
}

/// Records every URL handed to it and removes nothing, so a test can say what the remover would have touched.
private final class SpyRemover: StagedFileRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL] = []
    private var folders: [URL] = []
    var removedFiles: [URL] { lock.withLock { files } }
    var removedFolders: [URL] { lock.withLock { folders } }

    func removeFile(at url: URL, expectedSize: UInt64) async throws(StagedRemovalFailure) {
        lock.withLock { files.append(url) }
    }

    func removeFolderIfEmpty(at url: URL) async -> Bool {
        lock.withLock { folders.append(url) }
        return false
    }
}

/// The plain remover over a temporary folder (backlog section 7.6): only recorded paths, only the recorded file, and
/// never the originals an older build imported to Files in a camera folder called "Staging".
@Suite("Removing staged copies: the plain remover")
struct StagingRemoverTests {
    @Test func removesTheRecordedCopiesClearsTheirRowsAndTheDayFolderLeftEmpty() async throws {
        let folder = Folder()
        defer { folder.remove() }
        let a = staged("DSC00001.JPG", path: "Staging/ILCE-7CM2/2026-11-05/DSC00001.JPG", in: folder)
        let b = staged("DSC00002.JPG", path: "Staging/ILCE-7CM2/2026-11-05/DSC00002.JPG", in: folder)
        let catalogue = InMemoryCatalogue(records: [a.0, b.0])
        let remover = StagingRemover(catalogue: catalogue, onThisIPhone: folder.documents, iCloud: nil)
        let result = await remover.remove([a.1, b.1])
        #expect(result.removed == 2 && result.failed == 0 && result.skipped == 0 && result.foldersRemoved == 1)
        #expect(!folder.exists("Staging/ILCE-7CM2/2026-11-05"))
        // The camera folder and Staging itself stay, even empty.
        #expect(folder.exists("Staging/ILCE-7CM2") && folder.exists("Staging"))
        // The rows keep their state, without the staged copy.
        for id in [a.0.identity, b.0.identity] {
            let row = try #require(await catalogue.record(for: id))
            #expect(row.staged == nil && row.state == .imported)
        }
    }

    /// A copy recorded directly in a camera's folder, or in Staging itself, is removed, but the folder it leaves empty
    /// stays: only a day folder ("Staging/<camera>/<day>/") is ever removed.
    @Test func aCameraFolderOrStagingLeftEmptyStays() async {
        let folder = Folder()
        defer { folder.remove() }
        let inCamera = staged("DSC00001.JPG", path: "Staging/ILCE-7CM2/DSC00001.JPG", in: folder)
        let inStaging = staged("DSC00002.JPG", path: "Staging/DSC00002.JPG", in: folder)
        let catalogue = InMemoryCatalogue(records: [inCamera.0, inStaging.0])
        let result = await StagingRemover(catalogue: catalogue, onThisIPhone: folder.documents, iCloud: nil)
            .remove([inCamera.1, inStaging.1])
        #expect(result.removed == 2 && result.foldersRemoved == 0)
        #expect(!folder.exists("Staging/ILCE-7CM2/DSC00001.JPG") && !folder.exists("Staging/DSC00002.JPG"))
        #expect(folder.exists("Staging/ILCE-7CM2") && folder.exists("Staging"))
    }

    @Test func aDayFolderWithAnythingElseInItStays() async {
        let folder = Folder()
        defer { folder.remove() }
        let a = staged("DSC00001.JPG", path: "Staging/ILCE-7CM2/2026-11-05/DSC00001.JPG", in: folder)
        folder.write("Staging/ILCE-7CM2/2026-11-05/DSC00009.JPG", size: 10) // unmarked, not in the plan
        let catalogue = InMemoryCatalogue(records: [a.0])
        let result = await StagingRemover(catalogue: catalogue, onThisIPhone: folder.documents, iCloud: nil)
            .remove([a.1])
        #expect(result.removed == 1 && result.foldersRemoved == 0)
        #expect(folder.exists("Staging/ILCE-7CM2/2026-11-05/DSC00009.JPG"))
    }

    /// Builds before 11 Nov imported to Files in Documents/<camera>, so a camera named "Staging" left originals in
    /// Documents/Staging with no staged row. None is removed, even beside a removed copy with the same name.
    @Test func anOlderFilesImportInACameraFolderNamedStagingIsNeverRemoved() async {
        let folder = Folder()
        defer { folder.remove() }
        folder.write("Staging/DSC00001.JPG", size: 64)
        folder.write("Staging/2026-11-05/DSC00001.JPG", size: 64)
        let a = staged("DSC00001.JPG", path: "Staging/ILCE-7CM2/2026-11-05/DSC00001.JPG", in: folder)
        let catalogue = InMemoryCatalogue(records: [a.0])
        let result = await StagingRemover(catalogue: catalogue, onThisIPhone: folder.documents, iCloud: nil)
            .remove([a.1])
        #expect(result.removed == 1)
        #expect(folder.exists("Staging/DSC00001.JPG"))
        #expect(folder.exists("Staging/2026-11-05/DSC00001.JPG"))
    }

    @Test func aRowWithAnEmptyOrOutOfStagingPathIsSkippedAndNothingIsTouched() async throws {
        let folder = Folder()
        defer { folder.remove() }
        folder.write("Staging/DSC00001.JPG", size: 64)
        folder.write("Other/DSC00002.JPG", size: 64)
        folder.write("DSC00003.JPG", size: 64)
        let unknown = staged("DSC00001.JPG", path: "", in: folder, write: false)
        let outside = staged("DSC00002.JPG", path: "Other/DSC00002.JPG", in: folder, write: false)
        let climbing = staged("DSC00003.JPG", path: "Staging/../DSC00003.JPG", in: folder, write: false)
        let bare = staged("DSC00004.JPG", path: "Staging", in: folder, write: false)
        let catalogue = InMemoryCatalogue(records: [unknown.0, outside.0, climbing.0, bare.0])
        let spy = SpyRemover()
        let result = await StagingRemover(catalogue: catalogue, onThisIPhone: folder.documents, iCloud: nil,
                                          plain: spy, coordinated: spy)
            .remove([unknown.1, outside.1, climbing.1, bare.1])
        #expect(result.skipped == 4 && result.removed == 0)
        #expect(spy.removedFiles.isEmpty && spy.removedFolders.isEmpty)
        #expect(folder.exists("Staging/DSC00001.JPG") && folder.exists("Other/DSC00002.JPG")
            && folder.exists("DSC00003.JPG"))
        // The rows stay staged as they were.
        for record in [unknown.0, outside.0, climbing.0, bare.0] {
            #expect(try #require(await catalogue.record(for: record.identity)).staged == record.staged)
        }
    }

    @Test func aFileThatIsntTheRecordedOneIsLeftAloneAndItsRowStaysStaged() async throws {
        let folder = Folder()
        defer { folder.remove() }
        let resized = staged("DSC00001.JPG", path: "Staging/ILCE-7CM2/2026-11-05/DSC00001.JPG", in: folder,
                             writtenSize: 65)
        let gone = staged("DSC00002.JPG", path: "Staging/ILCE-7CM2/2026-11-05/DSC00002.JPG", in: folder, write: false)
        let aFolder = staged("DSC00003.JPG", path: "Staging/ILCE-7CM2/2026-11-05/DSC00003.JPG", in: folder,
                             write: false)
        try FileManager.default.createDirectory(
            at: folder.documents.appendingPathComponent("Staging/ILCE-7CM2/2026-11-05/DSC00003.JPG"),
            withIntermediateDirectories: true)
        let catalogue = InMemoryCatalogue(records: [resized.0, gone.0, aFolder.0])
        let log = RecordingLog()
        let result = await StagingRemover(catalogue: catalogue, onThisIPhone: folder.documents, iCloud: nil, log: log)
            .remove([resized.1, gone.1, aFolder.1])
        #expect(result.failed == 3 && result.removed == 0 && result.foldersRemoved == 0)
        #expect(folder.exists("Staging/ILCE-7CM2/2026-11-05/DSC00001.JPG"))
        #expect(folder.exists("Staging/ILCE-7CM2/2026-11-05/DSC00003.JPG"))
        for record in [resized.0, gone.0, aFolder.0] {
            #expect(try #require(await catalogue.record(for: record.identity)).staged == record.staged)
        }
        // The log says how many, never a name or a path.
        #expect(log.lines.contains("staging: removed 0 staged file(s), 3 not removed, 0 skipped, 0 day folder(s)"))
        #expect(!log.lines.contains { $0.contains("DSC0000") || $0.contains("ILCE") })
    }

    @Test func aCopyInICloudDriveWhileItIsUnavailableIsNotRemoved() async throws {
        let folder = Folder()
        defer { folder.remove() }
        let copy = staged("DSC00001.JPG", path: "Staging/ILCE-7CM2/2026-11-05/DSC00001.JPG", root: .iCloudDrive,
                          in: folder)
        let catalogue = InMemoryCatalogue(records: [copy.0])
        let spy = SpyRemover()
        let result = await StagingRemover(catalogue: catalogue, onThisIPhone: folder.documents, iCloud: nil,
                                          plain: spy, coordinated: spy).remove([copy.1])
        #expect(result.failed == 1 && spy.removedFiles.isEmpty)
        #expect(try #require(await catalogue.record(for: copy.0.identity)).staged == copy.0.staged)
    }

    /// Copies on this iPhone go through the plain remover, copies in iCloud Drive through the coordinated one, each
    /// under its own root.
    @Test func eachRootHasItsOwnRemoverAndDocumentsFolder() async {
        let local = Folder()
        let iCloud = Folder()
        defer {
            local.remove()
            iCloud.remove()
        }
        let here = staged("DSC00001.JPG", path: "Staging/A/2026-11-05/DSC00001.JPG", in: local, write: false)
        let there = staged("DSC00002.JPG", path: "Staging/A/2026-11-05/DSC00002.JPG", root: .iCloudDrive, in: iCloud,
                           write: false)
        let plain = SpyRemover()
        let coordinated = SpyRemover()
        _ = await StagingRemover(catalogue: InMemoryCatalogue(records: [here.0, there.0]),
                                 onThisIPhone: local.documents, iCloud: iCloud.documents, plain: plain,
                                 coordinated: coordinated).remove([here.1, there.1])
        #expect(plain.removedFiles.map(\.standardizedFileURL)
            == [local.documents.appendingPathComponent("Staging/A/2026-11-05/DSC00001.JPG").standardizedFileURL])
        #expect(coordinated.removedFiles.map(\.standardizedFileURL)
            == [iCloud.documents.appendingPathComponent("Staging/A/2026-11-05/DSC00002.JPG").standardizedFileURL])
    }

    @Test func aFolderIsRemovedOnlyWhenEmpty() async throws {
        let folder = Folder()
        defer { folder.remove() }
        folder.write("Staging/A/2026-11-05/x.JPG", size: 1)
        let day = folder.documents.appendingPathComponent("Staging/A/2026-11-05")
        #expect(await PlainStagedFileRemover().removeFolderIfEmpty(at: day) == false)
        #expect(folder.exists("Staging/A/2026-11-05/x.JPG"))
        try FileManager.default.removeItem(at: day.appendingPathComponent("x.JPG"))
        #expect(await PlainStagedFileRemover().removeFolderIfEmpty(at: day))
        #expect(!folder.exists("Staging/A/2026-11-05"))
    }
}
