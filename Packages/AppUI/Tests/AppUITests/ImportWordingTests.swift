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
            SettingsWording.stagingFooter, ImportWording.screenOnNote, ImportWording.couldNotStart,
            ImportWording.couldNotAdd, BrowseWording.lastKnownLine("8 Nov 2026 at 14:05"),
            BrowseWording.noMatchesDetail, AppWording.catalogueFailedDetail, BrowseWording.importStripHint,
        ]
        lines += StagingReason.allCases.compactMap(SettingsWording.forcedStaging)
        let places = [StagingPlace.iCloudDrive] + StagingFallbackReason.allCases.map(StagingPlace.onThisIPhone)
        lines += places.compactMap(SettingsWording.stagingFallback)
        lines += StagingFallbackReason.allCases.map(ImportWording.stagingFallback)
        lines += [NotificationWording.importPaused, NotificationWording.stagingPaused]
        lines += PauseReason.allCases.map { ImportWording.paused($0) }
        lines.append(ImportWording.paused(.stalled, stallWaitsForPerson: true))
        lines += [JobOutcome.completed, .cancelled, .catalogueUnavailable].map(ImportWording.finished)
        lines += CameraLinkFailure.Kind.allCases.map { ImportWording.finished(.stopped($0)) }
        for reason in StagingReason.allCases {
            lines += places.map { ImportWording.stagingReason(reason, place: $0) }
        }
        let outcomes: [ImportRequestOutcome] = [.started(2), .appended(1), .nothingNew(staging: false),
                                                .nothingNew(staging: true), .busyWithAnotherCamera,
                                                .busyWithAnotherMode(.photos), .busyWithAnotherMode(.staging),
                                                .stillStarting]
        for choice in [DestinationKind.photos, .staging] {
            lines += outcomes.compactMap { BrowseWording.importRequested($0, choice: choice) }
        }
        lines += [BrowseModel.SelectionBlock.video, .notAPhoto, .noCaptureDate, .cardNotRead]
            .map(BrowseWording.notSelectable)
        lines += [ImportWording.destination(.photos, folder: nil, finished: false, imported: 0)!,
                  ImportWording.destination(.stagedHere(.chosen), folder: "Untitled", finished: true, imported: 1)!,
                  ImportWording.destination(.staging(.chosen, .iCloudDrive), folder: "Untitled", finished: false,
                                            imported: 0)!]
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

    @Test func countedFiles() {
        #expect(ByteWording.files(1) == "1 file")
        #expect(ByteWording.files(0) == "0 files")
        #expect(ByteWording.files(3) == "3 files")
    }

    @Test func statusAndCounts() {
        var p = ImportProgress(filesDone: 3, filesTotal: 40, bytesDone: 0, bytesTotal: 1, state: .running)
        #expect(ImportWording.status(p) == "3 of 40 files done")
        p.filesTotal = 0
        #expect(ImportWording.status(p) == "Reading the card…")
        let done = ImportProgress(filesDone: 41, filesTotal: 41, bytesDone: 1, bytesTotal: 1,
                                  state: .finished(.completed), filesSkipped: 2, filesFailed: 1)
        #expect(ImportWording.counts(done) == "38 files imported, 2 skipped, 1 failed.")
        var staged = done
        staged.filesStaged = 38
        #expect(ImportWording.counts(staged) == "38 files staged, 2 skipped, 1 failed.")
        // Photos refused a save part-way: the rest were staged.
        staged.filesStaged = 28
        #expect(ImportWording.counts(staged) == "10 files imported, 28 staged, 2 skipped, 1 failed.")
        #expect(ImportWording.status(done) == "Import finished.")
        #expect(ImportWording.finished(.stopped(.phoneStorageFull)) == "Import stopped: this iPhone is out of space.")
    }

    @Test func destinationNamesTheFolder() {
        #expect(ImportWording.destination(.stagedHere(.photosDenied), folder: "ILCE-7CM2", finished: false, imported: 0)
            == "Staging to On My iPhone › Shutter Bridge › Staging › ILCE-7CM2.")
        #expect(ImportWording.destination(.staging(.chosen, .iCloudDrive), folder: "ILCE-7CM2", finished: true,
                                          imported: 3)
            == "Staged in iCloud Drive › Shutter Bridge › Staging › ILCE-7CM2.")
        #expect(ImportWording.destination(.photos, folder: "x", finished: true, imported: 2) == "Imported to Photos.")
        // A finished job that imported nothing (cancelled at once, stopped, all skipped) doesn't claim it did.
        #expect(ImportWording.destination(.photos, folder: "x", finished: true, imported: 0) == nil)
        #expect(ImportWording.destination(.stagedHere(.chosen), folder: "x", finished: true, imported: 0) == nil)
        #expect(ImportWording.destination(nil, folder: nil, finished: false, imported: 0) == nil)
        #expect(ImportWording.destination(.askForPhotosAccess, folder: nil, finished: false, imported: 0) == nil)
    }

    @Test func rowWords() {
        let raw = item("DSC00001.ARW", size: 45_600_000)
        let video = item("C0001.MP4")
        #expect(ImportWording.row(.committing, item: raw, going: .photos) == "Saving to Photos")
        #expect(ImportWording.row(.committing, item: raw, going: .staging) == "Saving to Staging")
        #expect(ImportWording.row(.skipped(.notAStill), item: video, going: .photos)
            == "Skipped: videos can't be imported yet")
        #expect(ImportWording.row(.skipped(.link(.itemNotFound)), item: raw, going: nil)
            == "Skipped: no longer on the card")
        #expect(ImportWording.row(.failed(.destination(.notEnoughSpace)), item: raw, going: nil)
            == "Failed: this iPhone is out of space")
        let notImported = ImportRow(ImportFileStatus(id: .undated(2), item: raw, phase: .notImported, bytesDone: 0),
                                    going: .photos)
        #expect(notImported.stateText == "Not imported: still on the card")
        #expect(!notImported.isInFlight && !notImported.isProblem)
        let total = ByteWording.size(45_600_000)
        #expect(notImported.sizeText == total)
        let copying = ImportFileStatus(id: .undated(0), item: raw, phase: .downloading, bytesDone: 12_300_000)
        #expect(ImportWording.rowSize(copying) == "\(ByteWording.size(12_300_000)) of \(total)")
        let row = ImportRow(copying, going: .photos)
        #expect(row.accessibilityLabel
            == "DSC00001.ARW, Copying from the camera, \(ByteWording.size(12_300_000)) of \(total), 26 percent")
        #expect(row.isInFlight && !row.isProblem)
        let failed = ImportRow(ImportFileStatus(id: .undated(1), item: raw, phase: .failed(.sizeMismatch(
            expected: 2, actual: 1)), bytesDone: raw.size), going: .photos)
        #expect(failed.isProblem)
        #expect(failed.sizeText == total)
    }
}
