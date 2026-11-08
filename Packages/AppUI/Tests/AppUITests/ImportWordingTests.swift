import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

@Suite("Import, Settings and Browse wording")
struct ImportWordingTests {
    /// Every full sentence the new screens can show.
    var sentences: [String] {
        var lines = [
            SettingsWording.destinationFooter, ImportWording.screenOnNote, ImportWording.couldNotStart,
            ImportWording.couldNotAdd, BrowseWording.lastKnownDetail, BrowseWording.noMatchesDetail,
            AppWording.catalogueFailedDetail,
        ]
        lines += PauseReason.allCases.map { ImportWording.paused($0) }
        lines.append(ImportWording.paused(.stalled, stallWaitsForPerson: true))
        lines += [JobOutcome.completed, .cancelled, .catalogueUnavailable].map(ImportWording.finished)
        lines += CameraLinkFailure.Kind.allCases.map { ImportWording.finished(.stopped($0)) }
        lines += FilesReason.allCases.map(ImportWording.filesReason)
        lines += [ImportRequestOutcome.started(2), .appended(1), .nothingNew, .busyWithAnotherCamera, .stillStarting]
            .compactMap(BrowseWording.importRequested)
        lines += [BrowseModel.SelectionBlock.imported, .noCaptureDate, .cardNotRead].map(BrowseWording.notSelectable)
        lines += [ImportWording.destination(.photos, folder: nil, finished: false, imported: 0)!,
                  ImportWording.destination(.files(.chosen), folder: "Untitled", finished: true, imported: 1)!]
        lines += USBMode.allCases.map { ImportWording.paused(.cameraRemoved, mode: $0) }
        return lines
    }

    @Test func finishedSentencesInBritishEnglishWithoutMakerMarks() {
        for line in sentences {
            #expect(line.hasSuffix("."), "\(line)")
            let lower = line.lowercased()
            #expect(!lower.contains("sony"), "\(line)")
            for american in ["color", "behavior", "catalog ", "catalog.", "canceled", "favorite", "license "] {
                #expect(!lower.contains(american), "\(line)")
            }
        }
    }

    @Test func sizesRatesAndTimes() {
        #expect(ByteWording.size(0) == "0 bytes")
        #expect(ByteWording.size(1) == "1 byte")
        #expect(ByteWording.size(999) == "999 bytes")
        #expect(ByteWording.size(1_500) == "2 KB")
        #expect(ByteWording.size(42_349_999) == "42.3 MB")
        #expect(ByteWording.size(41_000_000) == "41.0 MB")
        #expect(ByteWording.size(1_240_000_000) == "1.24 GB")
        #expect(ByteWording.size(839_000_000) == "839.0 MB")
        #expect(ByteWording.progress(1_200_000_000, of: 4_500_000_000) == "1.20 GB of 4.50 GB")
        #expect(ByteWording.rate(megabytesPerSecond: 41.83) == "41.8 MB/s")
        #expect(ByteWording.timeLeft(.seconds(0.2)) == "About 1 s left")
        #expect(ByteWording.timeLeft(.seconds(40)) == "About 40 s left")
        #expect(ByteWording.timeLeft(.seconds(150)) == "About 3 min left")
        #expect(ByteWording.timeLeft(.seconds(3_900)) == "About 1 h 5 min left")
        #expect(ByteWording.files(1) == "1 file")
        #expect(ByteWording.files(0) == "0 files")
    }

    @Test func statusAndCounts() {
        var p = ImportProgress(filesDone: 3, filesTotal: 40, bytesDone: 0, bytesTotal: 1, state: .running)
        #expect(ImportWording.status(p) == "3 of 40 files done")
        p.filesTotal = 0
        #expect(ImportWording.status(p) == "Reading the card…")
        let done = ImportProgress(filesDone: 41, filesTotal: 41, bytesDone: 1, bytesTotal: 1,
                                  state: .finished(.completed), filesSkipped: 2, filesFailed: 1)
        #expect(ImportWording.counts(done) == "38 files imported, 2 skipped, 1 failed.")
        #expect(ImportWording.status(done) == "Import finished.")
        #expect(ImportWording.finished(.stopped(.phoneStorageFull)) == "Import stopped: this iPhone is out of space.")
    }

    @Test func destinationNamesTheFolder() {
        #expect(ImportWording.destination(.files(.photosDenied), folder: "ILCE-7CM2", finished: false, imported: 0)
            == "Importing to Files: On My iPhone › Shutter Bridge › ILCE-7CM2.")
        #expect(ImportWording.destination(.photos, folder: "x", finished: true, imported: 2) == "Imported to Photos.")
        // A finished job that imported nothing (cancelled at once, stopped, all skipped) doesn't claim it did.
        #expect(ImportWording.destination(.photos, folder: "x", finished: true, imported: 0) == nil)
        #expect(ImportWording.destination(.files(.chosen), folder: "x", finished: true, imported: 0) == nil)
        #expect(ImportWording.destination(nil, folder: nil, finished: false, imported: 0) == nil)
        #expect(ImportWording.destination(.askForPhotosAccess, folder: nil, finished: false, imported: 0) == nil)
    }

    @Test func rowWords() {
        let raw = item("DSC00001.ARW", size: 45_600_000)
        let video = item("C0001.MP4")
        #expect(ImportWording.row(.committing, item: raw, going: .photos) == "Saving to Photos")
        #expect(ImportWording.row(.committing, item: raw, going: .filesFolder) == "Moving to Files")
        #expect(ImportWording.row(.skipped(.notAStill), item: video, going: .photos) == "Skipped: video (from 1.1)")
        #expect(ImportWording.row(.skipped(.link(.itemNotFound)), item: raw, going: nil)
            == "Skipped: no longer on the card")
        #expect(ImportWording.row(.failed(.destination(.notEnoughSpace)), item: raw, going: nil)
            == "Failed: this iPhone is out of space")
        let notImported = ImportRow(ImportFileStatus(id: .undated(2), item: raw, phase: .notImported, bytesDone: 0),
                                    going: .photos)
        #expect(notImported.stateText == "Not imported: still on the card")
        #expect(!notImported.isInFlight && !notImported.isProblem)
        #expect(notImported.sizeText == "45.6 MB")
        let copying = ImportFileStatus(id: .undated(0), item: raw, phase: .downloading, bytesDone: 12_300_000)
        #expect(ImportWording.rowSize(copying) == "12.3 MB of 45.6 MB")
        let row = ImportRow(copying, going: .photos)
        #expect(row.accessibilityLabel == "DSC00001.ARW, Copying from the camera, 12.3 MB of 45.6 MB, 26 percent")
        #expect(row.isInFlight && !row.isProblem)
        let failed = ImportRow(ImportFileStatus(id: .undated(1), item: raw, phase: .failed(.sizeMismatch(
            expected: 2, actual: 1)), bytesDone: raw.size), going: .photos)
        #expect(failed.isProblem)
        #expect(failed.sizeText == "45.6 MB")
    }
}
