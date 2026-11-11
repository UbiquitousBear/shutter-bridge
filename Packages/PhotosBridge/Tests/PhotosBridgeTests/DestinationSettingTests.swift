import Foundation
import Testing
@testable import PhotosBridge

/// The remembered choice and the rule that picks the destination (Shamil, 11 Nov: *Import to Photos* or *Stage* at
/// each import; staging replaced the Files folder). Was the 8 Nov Photos-or-Files setting's tests: where Files was
/// chosen or forced, the decision is now staging, in the place passed in.
@Suite("Remembered choice and the rule that picks the destination")
struct DestinationSettingTests {
    let iCloud = StagingPlace.iCloudDrive
    let local = StagingPlace.onThisIPhone(.iCloudDriveOff)

    @Test func defaultIsPhotos() {
        #expect(DestinationSetting().preferred == .photos)
        #expect(DestinationSetting.default == DestinationSetting(preferred: .photos))
    }

    @Test("Import to Photos: full and limited go to Photos; not determined asks; denied and restricted are staged")
    func choosingPhotos() {
        for place in [iCloud, local] {
            #expect(DestinationDecision.resolve(choice: .photos, authorisation: .authorised, staging: place) == .photos)
            #expect(DestinationDecision.resolve(choice: .photos, authorisation: .limited, staging: place) == .photos)
            #expect(DestinationDecision.resolve(choice: .photos, authorisation: .notDetermined, staging: place)
                == .askForPhotosAccess)
            #expect(DestinationDecision.resolve(choice: .photos, authorisation: .denied, staging: place)
                == .staging(.photosDenied, place))
            #expect(DestinationDecision.resolve(choice: .photos, authorisation: .restricted, staging: place)
                == .staging(.photosRestricted, place))
        }
    }

    @Test("Stage: chosen, in the place passed in, whatever the access; never asks for Photos, never links Settings")
    func choosingStage() {
        for place in [iCloud, local, .onThisIPhone(.containerUnavailable)] {
            for access in PhotosAuthorisation.allCases {
                let decision = DestinationDecision.resolve(choice: .staging, authorisation: access, staging: place)
                #expect(decision == .staging(.chosen, place))
                #expect(decision != .askForPhotosAccess)
                #expect(decision.stagingReason?.offersSettingsLink == false)
                #expect(decision.stagingPlace == place)
            }
        }
    }

    @Test("Only a denial links to Settings; restricted and chosen don't")
    func settingsLink() {
        #expect(StagingReason.photosDenied.offersSettingsLink)
        #expect(!StagingReason.photosRestricted.offersSettingsLink)
        #expect(!StagingReason.chosen.offersSettingsLink)
        #expect(!StagingReason.chosen.isForced && StagingReason.photosDenied.isForced
            && StagingReason.photosRestricted.isForced)
        for reason in StagingReason.allCases { #expect(!reason.explanation.isEmpty) }
        for reason in StagingFallbackReason.allCases { #expect(!reason.explanation.isEmpty) }
    }

    @Test("A denied save stages the rest, in the place passed in; restricted keeps its own reason")
    func afterDeniedSave() {
        #expect(DestinationDecision.afterDeniedSave(authorisation: .denied, staging: iCloud)
            == .staging(.photosDenied, iCloud))
        #expect(DestinationDecision.afterDeniedSave(authorisation: .authorised, staging: local)
            == .staging(.photosDenied, local))
        #expect(DestinationDecision.afterDeniedSave(authorisation: .restricted, staging: iCloud)
            == .staging(.photosRestricted, iCloud))
    }

    @Test func kinds() {
        #expect(DestinationDecision.photos.kind == .photos)
        #expect(DestinationDecision.staging(.chosen, iCloud).kind == .staging)
        #expect(DestinationDecision.askForPhotosAccess.kind == nil)
        #expect(DestinationDecision.staging(.photosDenied, local).stagingReason == .photosDenied)
        #expect(DestinationDecision.photos.stagingReason == nil)
        #expect(DestinationDecision.photos.stagingPlace == nil)
    }

    @Test("iCloud Drive lost mid-job: the same reason, staged on this iPhone; Photos is left as it is")
    func stagedElsewhere() {
        let lost = StagingPlace.onThisIPhone(.lostDuringImport)
        #expect(DestinationDecision.staging(.chosen, iCloud).staged(in: lost) == .staging(.chosen, lost))
        #expect(DestinationDecision.staging(.photosDenied, iCloud).staged(in: lost) == .staging(.photosDenied, lost))
        #expect(DestinationDecision.photos.staged(in: lost) == .photos)
    }

    @Test("Where staging goes, as Files names it")
    func places() {
        #expect(StagingPlace.iCloudDrive.folderPath == "iCloud Drive › Shutter Bridge › Staging")
        #expect(StagingPlace.onThisIPhone(.iCloudDriveOff).folderPath == "On My iPhone › Shutter Bridge › Staging")
        #expect(StagingPlace.iCloudDrive.fallbackReason == nil)
        #expect(StagingPlace.onThisIPhone(.containerUnavailable).fallbackReason == .containerUnavailable)
        let documents = URL(fileURLWithPath: "/container/Documents", isDirectory: true)
        #expect(StagingAvailability.iCloudDrive(documents: documents).place == .iCloudDrive)
        #expect(StagingAvailability.iCloudDrive(documents: documents).iCloudDocuments == documents)
        #expect(StagingAvailability.unavailable(.iCloudDriveOff).place == .onThisIPhone(.iCloudDriveOff))
        #expect(StagingAvailability.unavailable(.iCloudDriveOff).iCloudDocuments == nil)
    }

    @Test("Codable round trip; Files stored by an earlier build reads as Stage; anything unknown reads as Photos")
    func codable() throws {
        let stage = DestinationSetting(preferred: .staging)
        let data = try JSONEncoder().encode(stage)
        #expect(String(decoding: data, as: UTF8.self) == #"{"preferred":"staging"}"#)
        #expect(try JSONDecoder().decode(DestinationSetting.self, from: data) == stage)
        #expect(try JSONDecoder().decode(DestinationSetting.self, from: Data(#"{"preferred":"filesFolder"}"#.utf8))
            == stage)
        #expect(try JSONDecoder().decode(DestinationSetting.self, from: Data(#"{"preferred":"photos"}"#.utf8))
            == .default)
        #expect(try JSONDecoder().decode(DestinationSetting.self, from: Data(#"{"preferred":"cloud"}"#.utf8)) == .default)
        #expect(try JSONDecoder().decode(DestinationSetting.self, from: Data("{}".utf8)) == .default)
    }

    @Test("The old raw value never fails: filesFolder is staging; the raw values written are photos and staging")
    func rawValues() {
        #expect(DestinationKind(rawValue: "filesFolder") == .staging)
        #expect(DestinationKind(rawValue: "staging") == .staging)
        #expect(DestinationKind(rawValue: "photos") == .photos)
        #expect(DestinationKind(rawValue: "cloud") == nil)
        #expect(DestinationKind.allCases.map(\.rawValue) == ["photos", "staging"])
    }
}

@Suite("Photos access gate")
struct PhotosAccessGateTests {
    let place = StagingPlace.iCloudDrive

    @Test("Asks once, only when not determined and the choice is Import to Photos")
    func asksOnce() async {
        let library = FakePhotoLibrary(authorisation: .notDetermined, answer: .limited)
        let gate = PhotosAccessGate(library: library)
        #expect(await gate.decision(for: .photos, staging: place) == .photos)
        #expect(await library.requests == 1)
        #expect(await gate.decision(for: .photos, staging: place) == .photos)
        #expect(await library.requests == 1)
    }

    @Test("Stage never asks for Photos access, whatever the authorisation")
    func doesNotAskWhenStageIsChosen() async {
        for access in PhotosAuthorisation.allCases {
            let library = FakePhotoLibrary(authorisation: access, answer: .authorised)
            #expect(await PhotosAccessGate(library: library).decision(for: .staging, staging: place)
                == .staging(.chosen, place))
            #expect(await library.requests == 0)
        }
    }

    @Test("Declined at the prompt: staged, with the Settings link")
    func declined() async {
        let library = FakePhotoLibrary(authorisation: .notDetermined, answer: .denied)
        let local = StagingPlace.onThisIPhone(.containerUnavailable)
        #expect(await PhotosAccessGate(library: library).decision(for: .photos, staging: local)
            == .staging(.photosDenied, local))
    }

    @Test("Before a continue, access withdrawn in Settings stages the rest")
    func continueAfterChange() async {
        let library = FakePhotoLibrary(authorisation: .authorised)
        let gate = PhotosAccessGate(library: library)
        #expect(await gate.decision(for: .photos, staging: place) == .photos)
        await library.setAuthorisation(.denied)
        #expect(await gate.decision(for: .photos, staging: place) == .staging(.photosDenied, place))
        await library.setAuthorisation(.restricted)
        #expect(await gate.decisionAfterDeniedSave(staging: place) == .staging(.photosRestricted, place))
        #expect(await library.requests == 0)
    }
}

@Suite("Staging locator fake")
struct FakeStagingLocatorTests {
    @Test func answersWhatItWasGiven() async {
        let documents = URL(fileURLWithPath: "/container/Documents", isDirectory: true)
        let locator = FakeStagingLocator(.iCloudDrive(documents: documents))
        #expect(await locator.locate() == .iCloudDrive(documents: documents))
        await locator.set(.unavailable(.iCloudDriveOff))
        #expect(await locator.locate().place == .onThisIPhone(.iCloudDriveOff))
        #expect(await locator.locateCount == 2)
    }
}
