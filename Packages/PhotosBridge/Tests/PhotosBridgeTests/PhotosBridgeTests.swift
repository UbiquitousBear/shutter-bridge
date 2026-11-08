import Foundation
import Testing
@testable import PhotosBridge

@Suite("Photos access decides the destination")
struct PhotosAccessTests {
    @Test func deniedGoesToFilesAndLimitedToPhotos() {
        #expect(PhotosAuthorisation.notDetermined.destination == nil)
        #expect(PhotosAuthorisation.denied.destination == .filesFolder)
        #expect(PhotosAuthorisation.restricted.destination == .filesFolder)
        #expect(PhotosAuthorisation.limited.destination == .photos)
        #expect(PhotosAuthorisation.authorised.destination == .photos)
    }

    @Test func destinationFollowsTheSettingAndAccess() {
        let files = DestinationDecision(kind: .filesFolder, reason: .chosen)
        let photos = DestinationDecision(kind: .photos, reason: .chosen)
        #expect(PhotosAuthorisation.notDetermined.destination(setting: .photos) == nil)
        #expect(PhotosAuthorisation.restricted.destination(setting: .photos)
            == DestinationDecision(kind: .filesFolder, reason: .photosRestricted))
        #expect(PhotosAuthorisation.denied.destination(setting: .photos)
            == DestinationDecision(kind: .filesFolder, reason: .photosDenied))
        #expect(PhotosAuthorisation.limited.destination(setting: .photos) == photos)
        #expect(PhotosAuthorisation.authorised.destination(setting: .photos) == photos)
        // A chosen Files folder is the person's choice whatever the access, so it never offers the Settings link.
        for access in PhotosAuthorisation.allCases {
            #expect(access.destination(setting: .filesFolder) == files)
        }
        // The setting on Photos agrees with the access-only rule wherever that rule has an answer.
        for access in PhotosAuthorisation.allCases {
            #expect(access.destination(setting: .photos)?.kind == access.destination)
        }
    }

    @Test func onlyADenialOffersTheSettingsLink() {
        #expect(DestinationDecision(kind: .filesFolder, reason: .photosDenied).offersSettingsLink)
        #expect(!DestinationDecision(kind: .filesFolder, reason: .photosRestricted).offersSettingsLink)
        #expect(!DestinationDecision(kind: .filesFolder, reason: .chosen).offersSettingsLink)
        #expect(!DestinationDecision(kind: .photos, reason: .chosen).offersSettingsLink)
    }

    @Test func defaultsAreShamilsFirstOfNovember() {
        let o = PhotosImportOptions()
        #expect(o.albums == .perCamera)
        #expect(o.pairOriginal == .raw)
    }
}

/// A destination that records what it was given, to show the protocol can be met without Photos.
actor RecordingDestination: ImportDestination {
    nonisolated let kind: DestinationKind = .filesFolder
    private(set) var committed: [CommitUnit] = []
    var failNext: ImportDestinationFailure?

    func commit(_ unit: CommitUnit) throws(ImportDestinationFailure) -> ImportResult {
        if let failure = failNext {
            failNext = nil
            throw failure
        }
        committed.append(unit)
        return .files(unit.files.map { FileLocation(relativePath: "Imports/" + $0.filename) })
    }

    func setFailNext(_ f: ImportDestinationFailure) { failNext = f }
}

@Suite("Import destinations")
struct ImportDestinationTests {
    let raw = StagedFile(url: URL(fileURLWithPath: "/tmp/a.part"), filename: "DSC00001.ARW", captureDate: nil)
    let jpg = StagedFile(url: URL(fileURLWithPath: "/tmp/b.part"), filename: "DSC00001.JPG", captureDate: nil)

    @Test func pairListsRawFirst() {
        #expect(CommitUnit.pair(raw: raw, processed: jpg).files == [raw, jpg])
        #expect(CommitUnit.single(jpg).files == [jpg])
    }

    @Test func filesKeepBothFilesOfAPair() async throws {
        let d = RecordingDestination()
        let dest: any ImportDestination = d
        let result = try await dest.commit(.pair(raw: raw, processed: jpg))
        #expect(result == .files([FileLocation(relativePath: "Imports/DSC00001.ARW"),
                                  FileLocation(relativePath: "Imports/DSC00001.JPG")]))
        #expect(dest.kind == .filesFolder)
    }

    @Test func failuresAreTyped() async {
        let d = RecordingDestination()
        await d.setFailNext(.photosAccessDenied)
        await #expect(throws: ImportDestinationFailure.photosAccessDenied) {
            try await d.commit(.single(raw))
        }
        #expect(await d.committed.isEmpty)
    }
}
