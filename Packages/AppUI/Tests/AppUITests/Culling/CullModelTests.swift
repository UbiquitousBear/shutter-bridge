import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import Testing
@testable import AppUI

/// A staged file for the Staging screen's tests: a row with a staged copy, and the copy itself written under the root's
/// Documents folder at "Staging/<cameraFolder>/<YYYY-MM-DD>/<name>" (unless `write` is false).
private struct Staged {
    var record: CatalogueRecord
    var identity: ObjectIdentity { record.identity }
    var key: ObjectIdentity.ContentKey { record.identity.contentKey }
}

private func makeFolder() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CullModelTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func stage(_ name: String, at date: String = "20261105T140000", size: Int = 64, camera: String = "cam-a",
                   cameraFolder: String = "ILCE-7CM2", root: StagingRoot = .onThisIPhone, in documents: URL,
                   path: String? = nil, write: Bool = true, writtenSize: Int? = nil) -> Staged {
    let identity = ObjectIdentity(camera: CameraKey(rawValue: camera), folder: "100MSDCF", filename: name,
                                  captureDate: CaptureDate(rawValue: date)!, size: UInt64(size))
    let day = String(date.prefix(4)) + "-" + String(date.dropFirst(4).prefix(2)) + "-" + String(date.dropFirst(6).prefix(2))
    let relative = path ?? "Staging/\(cameraFolder)/\(day)/\(name)"
    let location = StagedLocation(root: root, relativePath: relative)
    if write, let url = location.fileURL(in: documents) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data(count: writtenSize ?? size))
    }
    return Staged(record: CatalogueRecord(identity: identity, format: CameraItemFormat.of(name), state: .new,
                                          staged: location))
}

/// The media kind a file name implies, as the catalogue stores it.
private enum CameraItemFormat {
    static func of(_ name: String) -> PTPMediaKind {
        switch name.split(separator: ".").last?.uppercased() {
        case "ARW": .raw
        case "JPG": .jpeg
        case "HIF": .heif
        default: .other
        }
    }
}

@MainActor
private final class Rig {
    let documents = makeFolder()
    let iCloud = makeFolder()
    let catalogue: InMemoryCatalogue
    let locator: FakeStagingLocator
    let loader = FakeLoader()
    let clock = WiFiTestClock()
    let log = RecordingLog()
    let exifReads = ExifReads()
    let model: CullModel<String>

    init(_ staged: (Rig.Folders) -> [Staged], iCloudAvailable: Bool = false,
         files: any StagedFileAvailability = AlwaysLocalFiles(),
         catalogue makeCatalogue: (([CatalogueRecord]) -> any CatalogueStore)? = nil) {
        let folders = Folders(documents: documents, iCloud: iCloud)
        let records = staged(folders).map(\.record)
        let store = InMemoryCatalogue(records: records)
        self.catalogue = store
        locator = FakeStagingLocator(iCloudAvailable ? .iCloudDrive(documents: iCloud) : .unavailable(.containerUnavailable))
        loader.autoRelease = true
        let reads = exifReads
        model = CullModel(catalogue: makeCatalogue?(records) ?? store, onThisIPhone: documents, locator: locator,
                          loader: loader, files: files, exif: { url in reads.read(url) }, clock: clock, log: log)
    }

    struct Folders {
        var documents: URL
        var iCloud: URL
    }

    var onlyRow: CullDayRow { model.rows[0] }

    func marks(_ staged: [Staged]) async -> [ObjectIdentity.ContentKey: MarkRecord] {
        await catalogue.marks(of: staged.map(\.key))
    }
}

/// The EXIF reader's calls; each answers an ISO taken from the file's number, so a test can tell whose line it is.
final class ExifReads: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var read: [String] { lock.withLock { names } }

    func read(_ url: URL) -> EXIFSummary? {
        let name = url.lastPathComponent
        lock.withLock { names.append(name) }
        let digits = name.filter(\.isNumber)
        return EXIFSummary(iso: Int(digits).map { $0 * 100 })
    }
}

@MainActor
@Suite("Staging screen: the cull model over the catalogue")
struct CullModelTests {
    @Test func listsStagedFilesByCameraAndDayNewestFirstWithCountsFromTheMarks() async throws {
        var files: [String: Staged] = [:]
        let rig = Rig { f in
            let list = [
                stage("DSC00001.JPG", at: "20261105T100000", in: f.documents),
                stage("DSC00002.ARW", at: "20261105T100100", in: f.documents),
                stage("DSC00002.JPG", at: "20261105T100100", in: f.documents),
                stage("DSC00003.JPG", at: "20261105T100200", in: f.documents),
                stage("DSC00010.JPG", at: "20261106T090000", in: f.documents),
                stage("DSC09000.JPG", at: "20261105T120000", camera: "cam-b", cameraFolder: "ZV-E1", in: f.documents),
            ]
            for s in list { files[s.identity.filename] = s }
            return list
        }
        // A mark on the pair's JPG half reads as the pair's (D4); one single kept.
        try await rig.catalogue.setMark(.reject, rating: 0, for: [files["DSC00002.JPG"]!.key], at: Date())
        try await rig.catalogue.setMark(.keep, rating: 2, for: [files["DSC00001.JPG"]!.key], at: Date())

        await rig.model.load()

        #expect(rig.model.phase == .loaded)
        #expect(rig.model.sections.map(\.name) == ["ILCE-7CM2", "ZV-E1"])
        #expect(rig.model.sections[0].days.map(\.day) == ["20261106", "20261105"])
        let day = rig.model.sections[0].days[1]
        #expect(day.units.count == 3)
        #expect(day.units[1].isPair)
        let counts = rig.model.counts(of: day)
        #expect(counts.units == 3 && counts.files == 4 && counts.kept == 1 && counts.rejected == 1)
        #expect(CullWording.countsLine(counts) == "3 staged, 1 kept, 1 rejected")
        #expect(rig.model.unavailable.total == 0)
        #expect(rig.model.mark(of: day.units[0]) == CullMark(decision: .keep, rating: 2))
        // Each file's URL is its staged copy, resolved under the root's Documents folder.
        let url = try #require(day.units[0].files.first?.url)
        #expect(url.path.hasPrefix(rig.documents.path) && url.path.hasSuffix("Staging/ILCE-7CM2/2026-11-05/DSC00001.JPG"))
    }

    @Test func oneCameraStagedUnderTwoKeysIsOneCameraAndOneDay() async {
        // Image Transfer and MTP give one body two keys; Staging files them under its one display name (D11).
        let rig = Rig { f in
            [
                stage("DSC00002.JPG", at: "20261105T100100", camera: "msc-key", in: f.documents),
                stage("DSC00001.JPG", at: "20261105T100000", camera: "mtp-key", in: f.documents),
                stage("DSC00003.JPG", at: "20261105T100200", camera: "mtp-key", in: f.documents),
            ]
        }
        await rig.model.load()
        #expect(rig.model.sections.count == 1)
        #expect(rig.model.rows.count == 1)
        #expect(rig.onlyRow.units.map { $0.files[0].identity.filename } == ["DSC00001.JPG", "DSC00002.JPG", "DSC00003.JPG"])
    }

    @Test func twoStagedCopiesOfOneFileAreOneUnit() async {
        let rig = Rig { f in
            [
                stage("DSC00001.JPG", camera: "msc-key", in: f.documents),
                stage("dsc00001.jpg", camera: "mtp-key", cameraFolder: "ILCE-7CM2", in: f.documents,
                      path: "Staging/ILCE-7CM2/2026-11-05/dsc00001 2.jpg"),
            ]
        }
        await rig.model.load()
        #expect(rig.model.rows.flatMap(\.units).count == 1)
    }

    @Test func filesThatCantBeShownAreCountedWithWhyAndNeverResolvedOutsideStaging() async {
        let rig = Rig { f in
            [
                stage("DSC00001.JPG", in: f.documents),
                // Staged, but the destination didn't say where: never resolved.
                stage("DSC00002.JPG", in: f.documents, path: "", write: false),
                // A path that would leave Staging: refused by the resolver.
                stage("DSC00003.JPG", in: f.documents, path: "Staging/../DSC00003.JPG", write: false),
                // In iCloud Drive, which isn't available.
                stage("DSC00004.JPG", root: .iCloudDrive, in: f.iCloud),
                // Removed from Staging in Files, and replaced with another size.
                stage("DSC00005.JPG", in: f.documents, write: false),
                stage("DSC00006.JPG", size: 64, in: f.documents, writtenSize: 10),
            ]
        }
        await rig.model.load()
        #expect(rig.model.rows.flatMap(\.units).map { $0.files[0].identity.filename } == ["DSC00001.JPG"])
        #expect(rig.model.unavailable == StagedUnavailable(inICloudDrive: 1, gone: 2, unknownPlace: 2))
        #expect(CullWording.unavailableLines(rig.model.unavailable) == [
            "1 staged file is in iCloud Drive, which isn't available to Shutter Bridge now.",
            "2 staged files are no longer in Staging as they were staged.",
            "2 staged files can't be shown: Shutter Bridge doesn't know where their copies are.",
        ])

        // iCloud Drive comes back: the next load finds that copy in the container's Documents folder.
        await rig.locator.set(.iCloudDrive(documents: rig.iCloud))
        await rig.model.load()
        #expect(rig.model.rows.flatMap(\.units).count == 2)
        #expect(rig.model.unavailable.inICloudDrive == 0)
    }

    @Test func emptyStagingIsEmpty() async {
        let rig = Rig { _ in [] }
        await rig.model.load()
        #expect(rig.model.phase == .loaded && rig.model.isEmpty && rig.model.unavailable.total == 0)
    }

    @Test func aStoreThatCantListStagedFilesFailsAndTryAgainRecovers() async throws {
        var failing: SwitchableCatalogue?
        let rig = Rig({ f in [stage("DSC00001.JPG", in: f.documents)] }, catalogue: { records in
            let store = SwitchableCatalogue(records: records)
            failing = store
            return store
        })
        let store = try #require(failing)
        await store.setFailsListing(true)
        await rig.model.load()
        #expect(rig.model.phase == .failed)
        #expect(rig.log.lines.contains("cull: couldn't read the staged files (CatalogueFailure)"))

        await store.setFailsListing(false)
        await rig.model.load()
        #expect(rig.model.phase == .loaded && rig.model.rows.count == 1)
    }

    // MARK: Marks

    @Test func marksSaveAtOnceUnderBothHalvesOfAPairAndTheCountsFollow() async throws {
        var pair: [Staged] = []
        var single: Staged?
        let rig = Rig { f in
            pair = [stage("DSC00001.ARW", in: f.documents), stage("DSC00001.JPG", in: f.documents)]
            single = stage("DSC00002.JPG", at: "20261105T140001", in: f.documents)
            return pair + [single!]
        }
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        let loupe = try #require(rig.model.loupe)
        #expect(loupe.session.index == 0 && loupe.current?.isPair == true)

        loupe.keep()
        await loupe.settled()
        let stored = await rig.marks(pair)
        #expect(stored.count == 2)
        #expect(stored.values.allSatisfy { $0.decision == .keep && $0.rating == 0 })
        // The day's counts follow the open loupe.
        #expect(rig.model.counts(of: rig.onlyRow).kept == 1)
        // Kept moved on to the next unit, and said so.
        #expect(loupe.session.index == 1)
        #expect(loupe.announcement?.announcement.text == "Kept. 2 of 2.")

        loupe.setRating(4)
        loupe.reject()
        await loupe.settled()
        let second = try #require(await rig.marks([single!])[single!.key])
        #expect(second.decision == .reject && second.rating == 4)
        // The last unit: a mark doesn't move past it.
        #expect(loupe.session.index == 1)
        #expect(loupe.announcement?.announcement.text == "Rejected.")

        loupe.clearDecision()
        await loupe.settled()
        let cleared = try #require(await rig.marks([single!])[single!.key])
        #expect(cleared.decision == nil && cleared.rating == 4)
        loupe.setRating(0)
        await loupe.settled()
        #expect(await rig.marks([single!]).isEmpty)
    }

    @Test func undoRevertsTheMarkInTheCatalogueAndGoesBackToItsUnit() async throws {
        var files: [Staged] = []
        let rig = Rig { f in
            files = (1 ... 3).map { stage(String(format: "DSC%05d.JPG", $0), at: "20261105T14000\($0)", in: f.documents) }
            return files
        }
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        let loupe = try #require(rig.model.loupe)
        loupe.reject()
        #expect(loupe.session.index == 1)
        loupe.undo()
        await loupe.settled()
        #expect(loupe.session.index == 0)
        #expect(await rig.marks(files).isEmpty)
        #expect(loupe.announcement?.announcement.text == "Mark undone. 1 of 3, No mark.")
        loupe.undo()
        #expect(loupe.announcement?.announcement.text == "Nothing to undo.")
    }

    @Test func aRejectIsRememberedAfterTheLoupeClosesAfterReloadAndAfterItsCopyLeavesStaging() async throws {
        // D3: nothing here forgets a reject; only the person changes it.
        var file: Staged?
        let rig = Rig { f in
            file = stage("DSC00001.JPG", in: f.documents)
            return [file!, stage("DSC00002.JPG", at: "20261105T140001", in: f.documents)]
        }
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        rig.model.loupe?.reject()
        await rig.model.closeLoupe()
        #expect(rig.model.loupe == nil)
        #expect(rig.model.counts(of: rig.onlyRow).rejected == 1)

        await rig.model.load()
        #expect(rig.model.counts(of: rig.onlyRow).rejected == 1)

        // Its staged copy removed (I12's removal clears the staged fact): no longer listed, the reject still kept.
        await rig.catalogue.clearStaged(file!.identity)
        await rig.model.load()
        #expect(rig.model.rows.flatMap(\.units).count == 1)
        #expect(await rig.marks([file!])[file!.key]?.decision == .reject)
    }

    @Test func dismissingTheLoupeClosesItAtOnceAndOnlyThatOne() async throws {
        // The cover over the tab view is bound to `loupe`: a dismissal must leave it nil before returning, or the
        // cover would be put up again, and a stale dismissal must leave a loupe opened since alone.
        var files: [Staged] = []
        let rig = Rig { f in
            files = [stage("DSC00001.JPG", in: f.documents),
                     stage("DSC00002.JPG", at: "20261105T140001", in: f.documents)]
            return files
        }
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        let first = try #require(rig.model.loupe)
        first.keep()
        rig.model.dismissLoupe(first)
        #expect(rig.model.loupe == nil)
        #expect(rig.model.counts(of: rig.onlyRow).kept == 1, "its mark counted when the cover goes")
        await first.settled()
        #expect(await eventually { await rig.marks(files).count == 1 }, "and saved")

        rig.model.openLoupe(rig.onlyRow.id)
        let second = try #require(rig.model.loupe)
        rig.model.dismissLoupe(first)
        #expect(rig.model.loupe === second, "a dismissal of the first loupe leaves the one opened since")
        rig.model.dismissLoupe(second)
        #expect(rig.model.loupe == nil)
    }

    @Test func aMarkThatCantBeSavedIsShownPutBackAndLoggedWithoutNames() async throws {
        var failing: SwitchableCatalogue?
        let rig = Rig({ f in [stage("DSC00001.JPG", in: f.documents)] }, catalogue: { records in
            let store = SwitchableCatalogue(records: records)
            failing = store
            return store
        })
        let store = try #require(failing)
        await rig.model.load()
        await store.setFailsMarks(true)
        rig.model.openLoupe(rig.onlyRow.id)
        let loupe = try #require(rig.model.loupe)
        loupe.keep()
        await loupe.settled()
        #expect(loupe.currentMark == .unmarked)
        #expect(loupe.writeFailureNotice?.text == CullWording.writeFailed)
        #expect(loupe.writeFailureNotice?.tone == .problem)
        loupe.dismissWriteFailure()
        #expect(loupe.writeFailureNotice == nil)
        await rig.model.closeLoupe()
        #expect(rig.log.lines.contains("cull: a mark couldn't be saved (Refused)"))
        #expect(!rig.log.lines.joined().contains("DSC"))
        #expect(!rig.log.lines.joined().contains("ILCE"))
    }

    // MARK: The loupe

    @Test func opensAtTheFirstUnitWithNoDecisionAndSaysWhereTheEndsAre() async throws {
        var files: [Staged] = []
        let rig = Rig { f in
            files = (1 ... 4).map { stage(String(format: "DSC%05d.JPG", $0), at: "20261105T14000\($0)", in: f.documents) }
            return files
        }
        try await rig.catalogue.setMark(.keep, rating: 0, for: [files[0].key], at: Date())
        // A rating alone isn't a decision.
        try await rig.catalogue.setMark(nil, rating: 3, for: [files[1].key], at: Date())
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        var loupe = try #require(rig.model.loupe)
        #expect(loupe.session.index == 1)
        #expect(loupe.position == "2 of 4")
        #expect(loupe.accessibilityLabel == "DSC00002.JPG")
        #expect(loupe.accessibilityValue == "2 of 4, No mark, 3 stars")

        rig.model.openLoupe(rig.onlyRow.id, at: 3)
        loupe = try #require(rig.model.loupe)
        loupe.next()
        #expect(loupe.session.index == 3 && loupe.announcement?.announcement.text == "Last photo of the day.")
        rig.model.openLoupe(rig.onlyRow.id, at: 0)
        loupe = try #require(rig.model.loupe)
        loupe.previous()
        #expect(loupe.session.index == 0 && loupe.announcement?.announcement.text == "First photo of the day.")
        let first = loupe.announcement?.id
        loupe.previous()
        // The same words again are a new announcement, so VoiceOver says them again.
        #expect(loupe.announcement?.id != first)
    }

    @Test func thePreviewFollowsTheLoupeAndAPairIsShownByItsJPG() async throws {
        let rig = Rig { f in
            [
                stage("DSC00001.ARW", in: f.documents),
                stage("DSC00001.JPG", in: f.documents),
                stage("DSC00002.ARW", at: "20261105T140005", in: f.documents),
            ]
        }
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id, maxPixelSize: 1_200)
        let loupe = try #require(rig.model.loupe)
        #expect(await waitUntilOnMain { loupe.preview != nil })
        #expect(loupe.preview?.image == "DSC00001.JPG")
        #expect(CullWording.pairBadge(try #require(loupe.current)) == "RAW+JPEG")
        #expect(loupe.accessibilityLabel == "DSC00001.JPG and its RAW")

        loupe.next()
        #expect(await waitUntilOnMain { loupe.preview?.image == "DSC00002.ARW" })
        #expect(CullWording.pairBadge(try #require(loupe.current)) == nil)
        #expect(!rig.loader.started.contains("DSC00001.ARW"))

        await rig.model.closeLoupe()
        #expect(loupe.prefetcher.heldCount == 0)
    }

    @Test func theEXIFLineIsTheUnitOnScreens() async throws {
        let rig = Rig { f in
            [stage("DSC00001.JPG", in: f.documents), stage("DSC00002.JPG", at: "20261105T140001", in: f.documents)]
        }
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        let loupe = try #require(rig.model.loupe)
        #expect(await waitUntilOnMain { loupe.exif?.iso == 100 })
        loupe.next()
        #expect(loupe.exif == nil || loupe.exif?.iso == 200)
        #expect(await waitUntilOnMain { loupe.exif?.iso == 200 })
        #expect(rig.exifReads.read == ["DSC00001.JPG", "DSC00002.JPG"])
    }

    @Test func anEvictedFilesEXIFLineIsReadOnceItsDownloadHasFinished() async throws {
        // Reading it before would block on the download (a dataless file) and never be read again once it arrived.
        let files = FakeAvailability(evicted: ["DSC00001.JPG"])
        let rig = Rig({ f in
            [stage("DSC00001.JPG", in: f.documents), stage("DSC00002.JPG", at: "20261105T140001", in: f.documents)]
        }, files: files)
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        let loupe = try #require(rig.model.loupe)
        #expect(await waitUntilOnMain { files.started.contains("DSC00001.JPG") })
        await loupe.settled()
        #expect(rig.exifReads.read.isEmpty)
        #expect(loupe.exif == nil)

        files.finish("DSC00001.JPG")
        #expect(await waitUntilOnMain { loupe.exif?.iso == 100 })
        #expect(rig.exifReads.read == ["DSC00001.JPG"])
        await rig.model.closeLoupe()
    }

    @Test func zoomedInPastThePreviewTheRegionOnScreenIsDecodedFromTheOriginal() async throws {
        let rig = Rig { f in
            [stage("DSC00001.JPG", in: f.documents), stage("DSC00002.JPG", at: "20261105T140001", in: f.documents)]
        }
        rig.loader.fullPixelSize = PixelSize(width: 7_008, height: 4_672)
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        let loupe = try #require(rig.model.loupe)
        #expect(await waitUntilOnMain { loupe.preview?.fullPixelSize != nil })
        // Its 100 % is the original's, not the 10-pixel preview's.
        let maximum = LoupeZoom.maximumScale(for: loupe.preview, fittingWidth: 393, fittingHeight: 700,
                                             displayScale: 3)
        #expect(abs(maximum - 7_008.0 / 1_179.0) < 0.001)

        let region = try #require(LoupeZoom.detailRegion(for: loupe.preview, scale: maximum, offsetX: 0, offsetY: 0,
                                                         fittingWidth: 393, fittingHeight: 700, displayScale: 3))
        loupe.showDetail(region, maxPixelSize: 2_100)
        #expect(await waitUntilOnMain { loupe.detail != nil })
        #expect(loupe.detail?.preview.image == "DSC00001.JPG@detail")
        #expect(loupe.detail?.region == region)
        #expect(loupe.detail?.unit == loupe.current?.id)
        // The same region again isn't decoded again.
        loupe.showDetail(region, maxPixelSize: 2_100)
        await loupe.settled()
        #expect(rig.loader.detailRequests == [.init(name: "DSC00001.JPG", region: region, maxPixelSize: 2_100)])

        // Another unit drops it, and so does fitting the screen again.
        loupe.next()
        #expect(loupe.detail == nil)
        #expect(await waitUntilOnMain { loupe.preview?.fullPixelSize != nil })
        loupe.showDetail(region, maxPixelSize: 2_100)
        #expect(await waitUntilOnMain { loupe.detail?.preview.image == "DSC00002.JPG@detail" })
        loupe.clearDetail()
        #expect(loupe.detail == nil)
        await rig.model.closeLoupe()
    }

    @Test func aPreviewWithNoOriginalToDecodeZoomsOnlyAsFarAsItsOwnPixels() async throws {
        // A RAW shown by its embedded preview: there are no more pixels to decode.
        let rig = Rig { f in [stage("DSC00001.JPG", in: f.documents)] }
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        let loupe = try #require(rig.model.loupe)
        #expect(await waitUntilOnMain { loupe.preview != nil })
        #expect(LoupeZoom.detailRegion(for: loupe.preview, scale: 8, offsetX: 0, offsetY: 0, fittingWidth: 393,
                                       fittingHeight: 700, displayScale: 3) == nil)
        loupe.showDetail(.whole, maxPixelSize: 2_100)
        await loupe.settled()
        #expect(rig.loader.detailRequests.isEmpty && loupe.detail == nil)
        await rig.model.closeLoupe()
    }

    @Test func closingALoupeThatIsNoLongerOpenLeavesTheOpenOneAlone() async throws {
        let rig = Rig { f in
            [stage("DSC00001.JPG", in: f.documents), stage("DSC00002.JPG", at: "20261105T140001", in: f.documents)]
        }
        await rig.model.load()
        rig.model.openLoupe(rig.onlyRow.id)
        let first = try #require(rig.model.loupe)
        rig.model.openLoupe(rig.onlyRow.id, at: 1)
        let second = try #require(rig.model.loupe)
        await rig.model.closeLoupe(first)
        #expect(rig.model.loupe === second)
        second.keep()
        await rig.model.closeLoupe(second)
        #expect(rig.model.loupe == nil)
        #expect(rig.model.counts(of: rig.onlyRow).kept == 1)
    }

    @Test func aRefreshThatFailsOverAListAlreadyShownSaysSoUntilClosed() async throws {
        var failing: SwitchableCatalogue?
        let rig = Rig({ f in [stage("DSC00001.JPG", in: f.documents)] }, catalogue: { records in
            let store = SwitchableCatalogue(records: records)
            failing = store
            return store
        })
        let store = try #require(failing)
        await rig.model.load()
        #expect(rig.model.loadFailureNotice == nil)

        await store.setFailsListing(true)
        await rig.model.load()
        // The list stays as it was, and a strip says it may be out of date.
        #expect(rig.model.rows.count == 1)
        let notice = try #require(rig.model.loadFailureNotice)
        #expect(notice.text == CullWording.refreshFailed && notice.tone == .problem && !notice.dismissesItself)
        rig.model.dismissLoadFailure()
        #expect(rig.model.loadFailureNotice == nil)
        // A second failure says so again; a refresh that works clears it.
        await rig.model.load()
        #expect(rig.model.loadFailureNotice != nil)
        await store.setFailsListing(false)
        await rig.model.load()
        #expect(rig.model.loadFailureNotice == nil && rig.model.phase == .loaded)
    }

    @Test func aFirstLoadThatFailsHasNoStripTheScreenSaysItInstead() async throws {
        var failing: SwitchableCatalogue?
        let rig = Rig({ f in [stage("DSC00001.JPG", in: f.documents)] }, catalogue: { records in
            let store = SwitchableCatalogue(records: records)
            failing = store
            return store
        })
        try await #require(failing).setFailsListing(true)
        await rig.model.load()
        #expect(rig.model.phase == .failed && rig.model.isEmpty)
        #expect(rig.model.loadFailureNotice == nil)
    }

    @Test func theLogSaysHowManyWithNoNamesOrPaths() async {
        let rig = Rig { f in
            [stage("DSC00001.JPG", in: f.documents), stage("DSC00002.JPG", in: f.documents, path: "", write: false)]
        }
        await rig.model.load()
        #expect(rig.log.lines == ["cull: listed staged files=1 days=1 notShown=1"])
    }

    @Test func theAppMakesTheStagingModelOverItsCatalogueAndLocator() async {
        let documents = makeFolder()
        let file = stage("DSC00001.JPG", in: documents)
        let catalogue = InMemoryCatalogue(records: [file.record])
        let app = AppModel(discovery: FakeDiscovery(link: FakeLink(items: [])), services: services(),
                           catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                           destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
        let loader = FakeLoader()
        let model = app.stagingModel(documents: documents, loader: loader)
        await model.load()
        #expect(model.rows.flatMap(\.units).map { $0.files[0].identity.filename } == ["DSC00001.JPG"])
    }
}

/// A small catalogue whose staged listing and mark writes can be made to fail. Only what the Staging screen uses is kept.
actor SwitchableCatalogue: CatalogueStore {
    struct Refused: Error {}

    private var rows: [ObjectIdentity: CatalogueRecord] = [:]
    private var stored: [ObjectIdentity.ContentKey: MarkRecord] = [:]
    private var failsListing = false
    private var failsMarks = false

    init(records: [CatalogueRecord]) {
        for record in records { rows[record.identity] = record }
    }

    func setFailsListing(_ fails: Bool) { failsListing = fails }
    func setFailsMarks(_ fails: Bool) { failsMarks = fails }

    func record(for identity: ObjectIdentity) -> CatalogueRecord? { rows[identity] }
    func states(of identities: [ObjectIdentity]) -> [ObjectIdentity: ObjectState] {
        Dictionary(identities.map { ($0, rows[$0]?.state ?? .new) }, uniquingKeysWith: { a, _ in a })
    }
    func upsert(_ record: CatalogueRecord) { rows[record.identity] = record }
    func saveListing(_ listing: CardListing) {}
    func lastListing(for camera: CameraKey) -> CardListing? { nil }
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) {}
    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) {
        var row = rows[identity] ?? CatalogueRecord(identity: identity, format: format, state: .new)
        row.staged = location
        rows[identity] = row
    }
    func clearStaged(_ identity: ObjectIdentity) { rows[identity]?.staged = nil }
    func stagedStates(of identities: [ObjectIdentity]) -> Set<ObjectIdentity> {
        Set(identities.filter { rows[$0]?.staged != nil })
    }
    func camera(_ key: CameraKey) -> CameraRecord? { nil }
    func cameras() -> [CameraRecord] { [] }
    func upsertCamera(_ record: CameraRecord) {}
    func setMark(_ decision: MarkRecord.Decision?, rating: Int, for keys: [ObjectIdentity.ContentKey],
                 at date: Date) throws {
        if failsMarks { throw Refused() }
        for key in keys { stored[key] = MarkRecord(decision: decision, rating: rating, markedAt: date) }
    }
    func marks(of keys: [ObjectIdentity.ContentKey]) -> [ObjectIdentity.ContentKey: MarkRecord] {
        stored.filter { keys.contains($0.key) }
    }
    func clearMarks(of keys: [ObjectIdentity.ContentKey]) throws {
        if failsMarks { throw Refused() }
        for key in keys { stored[key] = nil }
    }
    func stagedRecords(camera: CameraKey?) throws -> [CatalogueRecord] {
        if failsListing { throw CatalogueFailure.notSupported }
        return rows.values.filter { $0.staged != nil }.sorted { $0.identity.filename < $1.identity.filename }
    }
}
