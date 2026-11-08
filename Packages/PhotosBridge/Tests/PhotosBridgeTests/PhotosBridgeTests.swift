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

    /// The rule with the setting agrees with the access-only rule: on Files it never offers the Settings link
    /// whatever the access; on Photos it gives the same destination wherever the access alone has an answer.
    @Test func destinationFollowsTheSettingAndAccess() {
        for access in PhotosAuthorisation.allCases {
            let files = DestinationDecision.resolve(setting: DestinationSetting(preferred: .filesFolder),
                                                    authorisation: access)
            #expect(files == .files(.chosen))
            #expect(files.filesReason?.offersSettingsLink == false)
            #expect(DestinationDecision.resolve(setting: .default, authorisation: access).kind == access.destination)
        }
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
