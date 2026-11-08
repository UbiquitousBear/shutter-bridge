import Foundation
import Testing
@testable import PhotosBridge

@Suite("Destination setting and the rule that picks the destination")
struct DestinationSettingTests {
    let photos = DestinationSetting(preferred: .photos)
    let files = DestinationSetting(preferred: .filesFolder)

    @Test func defaultIsPhotos() {
        #expect(DestinationSetting().preferred == .photos)
        #expect(DestinationSetting.default == photos)
    }

    @Test("Setting Photos: full and limited go to Photos; not determined asks; denied and restricted force Files")
    func settingPhotos() {
        #expect(DestinationDecision.resolve(setting: photos, authorisation: .authorised) == .photos)
        #expect(DestinationDecision.resolve(setting: photos, authorisation: .limited) == .photos)
        #expect(DestinationDecision.resolve(setting: photos, authorisation: .notDetermined) == .askForPhotosAccess)
        #expect(DestinationDecision.resolve(setting: photos, authorisation: .denied) == .files(.photosDenied))
        #expect(DestinationDecision.resolve(setting: photos, authorisation: .restricted) == .files(.photosRestricted))
    }

    @Test("Setting Files: chosen, and never asks for Photos; a denial still reports itself as forced")
    func settingFiles() {
        #expect(DestinationDecision.resolve(setting: files, authorisation: .authorised) == .files(.chosen))
        #expect(DestinationDecision.resolve(setting: files, authorisation: .limited) == .files(.chosen))
        #expect(DestinationDecision.resolve(setting: files, authorisation: .notDetermined) == .files(.chosen))
        // The person chose Files: it says so, with no Settings link, even when Photos access is off (*It says so*).
        #expect(DestinationDecision.resolve(setting: files, authorisation: .denied) == .files(.chosen))
        #expect(DestinationDecision.resolve(setting: files, authorisation: .restricted) == .files(.chosen))
        #expect(DestinationDecision.resolve(setting: files, authorisation: .denied).filesReason?.offersSettingsLink == false)
    }

    @Test("Only a denial links to Settings; restricted and chosen don't")
    func settingsLink() {
        #expect(FilesReason.photosDenied.offersSettingsLink)
        #expect(!FilesReason.photosRestricted.offersSettingsLink)
        #expect(!FilesReason.chosen.offersSettingsLink)
        #expect(!FilesReason.chosen.isForced && FilesReason.photosDenied.isForced && FilesReason.photosRestricted.isForced)
        for reason in FilesReason.allCases { #expect(!reason.explanation.isEmpty) }
    }

    @Test("A denied save forces Files whatever the setting; restricted keeps its own reason")
    func afterDeniedSave() {
        #expect(DestinationDecision.afterDeniedSave(authorisation: .denied) == .files(.photosDenied))
        #expect(DestinationDecision.afterDeniedSave(authorisation: .authorised) == .files(.photosDenied))
        #expect(DestinationDecision.afterDeniedSave(authorisation: .restricted) == .files(.photosRestricted))
    }

    @Test func kinds() {
        #expect(DestinationDecision.photos.kind == .photos)
        #expect(DestinationDecision.files(.chosen).kind == .filesFolder)
        #expect(DestinationDecision.askForPhotosAccess.kind == nil)
        #expect(DestinationDecision.files(.photosDenied).filesReason == .photosDenied)
        #expect(DestinationDecision.photos.filesReason == nil)
    }

    @Test("Codable round trip; an unknown stored value reads as the default")
    func codable() throws {
        let data = try JSONEncoder().encode(files)
        #expect(try JSONDecoder().decode(DestinationSetting.self, from: data) == files)
        #expect(try JSONDecoder().decode(DestinationSetting.self, from: Data(#"{"preferred":"cloud"}"#.utf8)) == .default)
        #expect(try JSONDecoder().decode(DestinationSetting.self, from: Data("{}".utf8)) == .default)
    }
}

@Suite("Photos access gate")
struct PhotosAccessGateTests {
    @Test("Asks once, only when not determined and the setting says Photos")
    func asksOnce() async {
        let library = FakePhotoLibrary(authorisation: .notDetermined, answer: .limited)
        let gate = PhotosAccessGate(library: library)
        #expect(await gate.decision(for: .default) == .photos)
        #expect(await library.requests == 1)
        #expect(await gate.decision(for: .default) == .photos)
        #expect(await library.requests == 1)
    }

    @Test func doesNotAskWhenFilesIsChosen() async {
        let library = FakePhotoLibrary(authorisation: .notDetermined, answer: .authorised)
        #expect(await PhotosAccessGate(library: library).decision(for: DestinationSetting(preferred: .filesFolder)) == .files(.chosen))
        #expect(await library.requests == 0)
    }

    @Test("Declined at the prompt: Files with the Settings link")
    func declined() async {
        let library = FakePhotoLibrary(authorisation: .notDetermined, answer: .denied)
        #expect(await PhotosAccessGate(library: library).decision(for: .default) == .files(.photosDenied))
    }

    @Test("Before a continue, access withdrawn in Settings sends the rest to Files")
    func continueAfterChange() async {
        let library = FakePhotoLibrary(authorisation: .authorised)
        let gate = PhotosAccessGate(library: library)
        #expect(await gate.decision(for: .default) == .photos)
        await library.setAuthorisation(.denied)
        #expect(await gate.decision(for: .default) == .files(.photosDenied))
        await library.setAuthorisation(.restricted)
        #expect(await gate.decisionAfterDeniedSave() == .files(.photosRestricted))
        #expect(await library.requests == 0)
    }
}
