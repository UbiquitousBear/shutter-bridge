import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

/// *Import keepers*' wording, and Staging's carrier at every switch site (backlog sections 7.2, 7.5 and 7.6; I12).
@Suite("Import keepers: wording and the Staging carrier")
struct KeepersWordingTests {
    @Test func theConfirmationSaysWhatGoesAndWhatStaysAsD2Has() {
        var plan = StagingRemovalPlan()
        plan.copies = (0 ..< 120).map { _ in
            StagedCopy(identity: ObjectIdentity(camera: CameraKey(rawValue: "k"), folder: "", filename: "A.JPG",
                                                captureDate: CaptureDate(rawValue: "20261105T140000")!, size: 1),
                       location: StagedLocation(root: .onThisIPhone, relativePath: "Staging/A/2026-11-05/A.JPG"))
        }
        plan.keepersInPhotos = 34
        plan.rejects = 86
        #expect(KeepersWording.confirmTitle(plan) == "Remove 120 Staged Files?")
        #expect(KeepersWording.confirmMessage(plan)
            == "34 keepers are in Photos; 86 rejects will be deleted from Staging. Unmarked files stay.")

        plan.keepersHeld = 2
        plan.rejectsHeld = 5
        #expect(KeepersWording.confirmMessage(plan)
            == "34 keepers are in Photos; 86 rejects will be deleted from Staging. 2 keepers aren't in Photos, so they "
            + "stay in Staging with their marks, and so do 5 rejects of the same days. Unmarked files stay.")

        var one = StagingRemovalPlan()
        one.copies = [plan.copies[0]]
        one.keepersInPhotos = 1
        one.keepersHeld = 1
        one.rejectsHeld = 1
        #expect(KeepersWording.confirmTitle(one) == "Remove 1 Staged File?")
        #expect(KeepersWording.confirmMessage(one)
            == "1 keeper is in Photos. 1 keeper isn't in Photos, so it stays in Staging with its mark, and so does 1 "
            + "reject of the same day. Unmarked files stay.")
    }

    @Test func theImportScreenSaysWhichJobRuns() {
        #expect(KeepersWording.sequence(KeepersSequence(index: 2, count: 3, cameraName: "ZV-E1"))
            == "Keepers, 2 of 3 cameras")
        #expect(KeepersWording.sequence(KeepersSequence(index: 1, count: 1, cameraName: "ZV-E1"))
            == "Importing keepers from Staging")
        #expect(KeepersWording.notImported == "Not imported: still in Staging")
        #expect(KeepersWording.downloading(done: 1, of: 3)
            == "Downloading 3 photos from iCloud Drive before the import (1 of 3)…")
    }

    @Test func aPhotosAccessStopSaysSoWithSettingsOnlyForADenial() {
        #expect(ImportWording.finished(.photosAccessNeeded(.denied)).hasPrefix("Photos access needed: "))
        #expect(ImportWording.finished(.photosAccessNeeded(.denied)).contains("Allow access in Settings"))
        #expect(ImportWording.finished(.photosAccessNeeded(.restricted)).hasPrefix("Photos access needed: "))
        #expect(!ImportWording.finished(.photosAccessNeeded(.restricted)).contains("Settings"))
        #expect(BrowseWording.importRequested(.busyWithKeepers)
            == "Keepers are being imported from Staging. Import these when it's done.")
    }

    @Test func theSummarySaysWhatHappened() {
        var run = KeepersRun(jobCount: 2)
        run.jobsStarted = 2
        run.filesImported = 3
        run.alreadyImported = 1
        run.filesFailed = 1
        var removal = StagingRemovalResult()
        removal.removed = 4
        removal.failed = 1
        let summary = KeepersSummary(run: run, plan: StagingRemovalPlan(), removal: removal)
        #expect(KeepersWording.finished(summary) == "3 files imported to Photos; 1 file already in Photos; "
            + "1 failed and stay in Staging; 4 files removed from Staging; 1 file couldn't be removed and stay staged; "
            + "try again from Staging.")
        #expect(KeepersWording.finished(KeepersSummary(run: run, plan: StagingRemovalPlan()))
            .hasSuffix("Nothing was removed from Staging."))
        #expect(KeepersWording.finished(KeepersSummary(problem: .couldNotRead))
            == "Couldn't read the marks, so nothing was imported or removed.")
    }

    /// The new carrier reaches every switch over it, with words of its own and capabilities that never delete.
    @Test func theStagingCarrierHasItsOwnWordsAtEverySwitchSite() {
        let staging = StagingFolderLink.descriptor(named: "ILCE-7CM2")
        #expect(staging.carrier == .staging)
        #expect(CamerasWording.badge(for: .staging) == "Staging")
        #expect(CamerasWording.modeLine(.staging) == "Staging")
        #expect(CamerasWording.detailLine(.staging) == "Staged files on this iPhone or in iCloud Drive")
        #expect(CamerasWording.rowHint(.staging) == "Opens the staged files.")
        #expect(BrowseWording.readingDetail(.staging) == "Reading the staged files.")
        #expect(CamerasWording.deviceStatus(carrier: .staging, batteryPercent: 50, freeBytes: 1).isEmpty)
        // The job's camera name is the staged camera's folder name (D11).
        #expect(CamerasWording.displayName(for: staging) == "ILCE-7CM2")
        #expect(ImportCamera(descriptor: staging, key: CameraKey(rawValue: "cam-a")).name == "ILCE-7CM2")
        // The descriptor never makes a camera's key.
        let key = CameraKeys.key(for: staging, material: nil)
        #expect(key.rawValue.hasPrefix("staging-name:"))
        for mode in [CameraMode.usb(.massStorage), .usb(.mtp), .wifi(.cameraNetwork)] {
            let camera = CameraDescriptor(id: staging.id, name: staging.name, mode: mode)
            #expect(CameraKeys.key(for: camera, material: nil) != key)
        }
        #expect(!CameraLinkCapabilities.defaults(for: .staging).deletes)
    }
}
