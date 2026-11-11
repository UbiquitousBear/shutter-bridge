import Foundation
import Testing
@testable import PhotosBridge

@Suite("Photos access decides the destination")
struct PhotosAccessTests {
    @Test func deniedIsStagedAndLimitedGoesToPhotos() {
        #expect(PhotosAuthorisation.notDetermined.destination == nil)
        #expect(PhotosAuthorisation.denied.destination == .staging)
        #expect(PhotosAuthorisation.restricted.destination == .staging)
        #expect(PhotosAuthorisation.limited.destination == .photos)
        #expect(PhotosAuthorisation.authorised.destination == .photos)
    }

    /// The rule with the choice agrees with the access-only rule: on Stage it never offers the Settings link
    /// whatever the access; on Import to Photos it gives the same destination wherever the access alone has an answer.
    @Test func destinationFollowsTheChoiceAndAccess() {
        for access in PhotosAuthorisation.allCases {
            let staged = DestinationDecision.resolve(choice: .staging, authorisation: access, staging: .iCloudDrive)
            #expect(staged == .staging(.chosen, .iCloudDrive))
            #expect(staged.stagingReason?.offersSettingsLink == false)
            #expect(DestinationDecision.resolve(choice: .photos, authorisation: access, staging: .iCloudDrive).kind
                == access.destination)
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
    nonisolated let kind: DestinationKind = .staging
    private(set) var committed: [CommitUnit] = []
    var failNext: ImportDestinationFailure?

    func commit(_ unit: CommitUnit) throws(ImportDestinationFailure) -> ImportResult {
        if let failure = failNext {
            failNext = nil
            throw failure
        }
        committed.append(unit)
        return .staged(place: .iCloudDrive, unit.files.map { FileLocation(relativePath: "Staging/" + $0.filename) })
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

    @Test func stagingKeepsBothFilesOfAPair() async throws {
        let d = RecordingDestination()
        let dest: any ImportDestination = d
        let result = try await dest.commit(.pair(raw: raw, processed: jpg))
        #expect(result == .staged(place: .iCloudDrive, [FileLocation(relativePath: "Staging/DSC00001.ARW"),
                                                        FileLocation(relativePath: "Staging/DSC00001.JPG")]))
        #expect(dest.kind == .staging)
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
