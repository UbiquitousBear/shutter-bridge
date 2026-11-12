import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import Testing
@testable import AppUI

// Rejects stay rejected (D3, Shamil, 11 Nov; backlog section 7.4, I21): Browse shows a Rejected badge for a file the
// catalogue holds a Reject mark for, even once its staged copy has been removed; *Select All New* and New Only leave
// it out; an explicit pick still hands it over; and a tap on the badge lifts it by clearing the mark (both halves of
// a pair, D4), so it is new again.

@MainActor
@Suite("Browse: the Rejected badge, what Select All New leaves out, and lifting a reject")
struct BrowseRejectTests {
    /// DSC00001 is a RAW+JPEG pair, both rejected, whose staged copies were removed; DSC00002.JPG is new;
    /// DSC00003.JPG is rejected and still staged; DSC00004.JPG is imported and rejected (imported elsewhere).
    let card = [
        item("DSC00001.ARW", at: 10, size: 40_000_000),
        item("DSC00001.JPG", at: 10, size: 20_000_000),
        item("DSC00002.JPG", at: 20, size: 21_000_000),
        item("DSC00003.JPG", at: 30, size: 22_000_000),
        item("DSC00004.JPG", at: 40, size: 23_000_000),
    ]

    struct Harness {
        let model: BrowseModel
        let catalogue: any CatalogueStore
        let importer: FakeImporter
        let log: RecordingLog
        let run: Task<Void, Never>

        func stop() async {
            run.cancel()
            await run.value
        }
    }

    var descriptor: CameraDescriptor { FakeLink(items: []).descriptor }

    func named(_ name: String) -> CameraItem { card.first { $0.name == name }! }

    func identity(_ name: String) -> ObjectIdentity {
        named(name).identity(camera: CameraKeys.key(for: descriptor, material: nil), timeZone: .current)!
    }

    func key(_ name: String) -> ObjectIdentity.ContentKey { identity(name).contentKey }

    /// The catalogue as described above: the pair was staged under another camera key, then removed from Staging
    /// (`clearStaged` leaves it new), with its Reject kept.
    func seeded() async throws -> InMemoryCatalogue {
        let catalogue = InMemoryCatalogue(records: [
            CatalogueRecord(identity: identity("DSC00004.JPG"), format: .jpeg, state: .imported),
        ])
        for name in ["DSC00001.ARW", "DSC00001.JPG"] {
            var other = identity(name)
            other.camera = CameraKey(rawValue: "usb-mtp-name:other")
            other.folder = "DCIM/101MSDCF"
            await catalogue.markStaged(other, format: name.hasSuffix("ARW") ? .raw : .jpeg,
                                       at: StagedLocation(root: .onThisIPhone, relativePath: "Staging/C/\(name)"))
            await catalogue.clearStaged(other)
        }
        await catalogue.markStaged(identity("DSC00003.JPG"), format: .jpeg,
                                   at: StagedLocation(root: .onThisIPhone, relativePath: "Staging/C/DSC00003.JPG"))
        try await catalogue.setMark(.reject, rating: 0, for: [key("DSC00001.ARW"), key("DSC00001.JPG")],
                                    at: Date(timeIntervalSince1970: 1_793_000_000))
        try await catalogue.setMark(.reject, rating: 2, for: [key("DSC00003.JPG")],
                                    at: Date(timeIntervalSince1970: 1_793_000_000))
        try await catalogue.setMark(.reject, rating: 0, for: [key("DSC00004.JPG")],
                                    at: Date(timeIntervalSince1970: 1_793_000_000))
        return catalogue
    }

    func start(_ catalogue: any CatalogueStore) async -> Harness {
        let link = FakeLink(items: card)
        let importer = FakeImporter()
        let log = RecordingLog()
        let model = BrowseModel(
            camera: link.descriptor,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in link },
            services: services(log: log),
            onGone: { _ in },
            catalogue: BrowseCatalogue(store: catalogue, cameraKey: CameraKeys.fromDescriptor),
            importer: importer
        )
        let run = Task { await model.run() }
        return Harness(model: model, catalogue: catalogue, importer: importer, log: log, run: run)
    }

    func listed(_ h: Harness) async -> Bool {
        await eventually { h.model.phase == .listed && !h.model.rejected.isEmpty }
    }

    // MARK: - The badge

    @Test func aRejectWhoseStagedCopyWasRemovedShowsRejected() async throws {
        let h = await start(try await seeded())
        #expect(await listed(h))
        #expect(h.model.rejected == Set(["DSC00001.ARW", "DSC00001.JPG", "DSC00003.JPG", "DSC00004.JPG"]
            .map { named($0).id }))
        #expect(!h.model.isStaged(named("DSC00001.ARW")) && !h.model.isImported(named("DSC00001.ARW")))
        // The badge shows unless the file is imported; it takes Staged's place.
        #expect(h.model.showsRejectedBadge(named("DSC00001.ARW")))
        #expect(h.model.showsRejectedBadge(named("DSC00003.JPG")))
        #expect(!h.model.showsRejectedBadge(named("DSC00004.JPG")))
        #expect(!h.model.showsRejectedBadge(named("DSC00002.JPG")))
        // VoiceOver says Rejected in place of New, and staged when it still is; Imported wins.
        #expect(h.model.accessibilityLabel(for: named("DSC00001.ARW"), date: "d") == "DSC00001.ARW, d, RAW, Rejected")
        #expect(h.model.accessibilityLabel(for: named("DSC00003.JPG"), date: "d")
            == "DSC00003.JPG, d, JPEG, Rejected, staged")
        #expect(h.model.accessibilityLabel(for: named("DSC00004.JPG"), date: "d") == "DSC00004.JPG, d, JPEG, Imported")
        #expect(h.model.accessibilityLabel(for: named("DSC00002.JPG"), date: "d") == "DSC00002.JPG, d, JPEG, New")
        #expect(h.log.lines.contains { $0.contains("staged, 4 rejected, key") })
        await h.stop()
    }

    // MARK: - Select All New, New Only and an explicit pick

    @Test func selectAllNewAndNewOnlyLeaveRejectsOut() async throws {
        let h = await start(try await seeded())
        #expect(await listed(h))
        h.model.selectAllNew()
        #expect(h.model.selectedItems.map(\.name) == ["DSC00002.JPG"])
        #expect(h.model.allNewSelected)
        #expect(await h.model.importSelected() == .started(1))
        #expect(h.importer.calls.last?.items.map(\.name) == ["DSC00002.JPG"])
        #expect(h.importer.asked.last?.newOnly == true)
        h.model.filter.newOnly = true
        #expect(h.model.sections.flatMap(\.items).map(\.name) == ["DSC00002.JPG"])
        await h.stop()
    }

    /// A rejected photo can still be picked, and an explicit pick hands it over to import.
    @Test func anExplicitPickOfARejectedPhotoIsHandedOver() async throws {
        let h = await start(try await seeded())
        #expect(await listed(h))
        #expect(h.model.selectionBlock(for: named("DSC00001.ARW")) == nil)
        h.model.tap(named("DSC00001.ARW"))
        h.model.toggleSelection(named("DSC00001.JPG"))
        #expect(await h.model.importSelected() == .started(2))
        #expect(h.importer.calls.last?.items.map(\.name).sorted() == ["DSC00001.ARW", "DSC00001.JPG"])
        #expect(h.importer.asked.last?.newOnly == false)
        await h.stop()
    }

    /// A photo *Select All New* picked that is rejected meanwhile drops out of the selection, as one imported
    /// meanwhile does.
    @Test func aNewPickRejectedMeanwhileDropsOut() async throws {
        let catalogue = try await seeded()
        let h = await start(catalogue)
        #expect(await listed(h))
        h.model.selectAllNew()
        #expect(h.model.selectedItems.map(\.name) == ["DSC00002.JPG"])
        try await catalogue.setMark(.reject, rating: 0, for: [key("DSC00002.JPG")],
                                    at: Date(timeIntervalSince1970: 1_793_000_100))
        h.importer.announceImported()
        #expect(await eventually { h.model.isRejected(named("DSC00002.JPG")) })
        #expect(h.model.selectedItems.isEmpty)
        await h.stop()
    }

    // MARK: - Lifting

    /// A tap on the badge clears the mark of both halves of the pair (D4): the pair is new again, *Select All New*
    /// picks it, and the catalogue no longer holds its marks. Others' marks stay.
    @Test func liftingARejectMakesThePairNewAgain() async throws {
        let catalogue = try await seeded()
        let h = await start(catalogue)
        #expect(await listed(h))
        #expect(await h.model.liftReject(named("DSC00001.JPG")))
        #expect(!h.model.isRejected(named("DSC00001.ARW")) && !h.model.isRejected(named("DSC00001.JPG")))
        #expect(h.model.accessibilityLabel(for: named("DSC00001.ARW"), date: "d") == "DSC00001.ARW, d, RAW, New")
        #expect(await catalogue.marks(of: [key("DSC00001.ARW"), key("DSC00001.JPG")]).isEmpty)
        #expect(await catalogue.marks(of: [key("DSC00003.JPG")])[key("DSC00003.JPG")]?.decision == .reject)
        #expect(h.log.lines.contains("browse: lifted a reject (2 files)"))
        h.model.selectAllNew()
        #expect(h.model.selectedItems.map(\.name).sorted() == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
        // A badge read after the lift agrees.
        await h.model.refreshImportedStates()
        #expect(!h.model.isRejected(named("DSC00001.ARW")))
        // Lifting a photo that isn't rejected does nothing.
        #expect(!(await h.model.liftReject(named("DSC00002.JPG"))))
        await h.stop()
    }

    /// Lifting a lone file's reject clears only its own mark, stars and all; under New Only it appears again.
    @Test func liftingALoneRejectShowsItUnderNewOnly() async throws {
        let catalogue = try await seeded()
        let h = await start(catalogue)
        #expect(await listed(h))
        h.model.filter.newOnly = true
        #expect(h.model.sections.flatMap(\.items).map(\.name) == ["DSC00002.JPG"])
        await catalogue.clearStaged(identity("DSC00003.JPG"))
        #expect(await h.model.liftReject(named("DSC00003.JPG")))
        #expect(await catalogue.marks(of: [key("DSC00003.JPG")]).isEmpty)
        #expect(await catalogue.marks(of: [key("DSC00001.ARW")])[key("DSC00001.ARW")]?.decision == .reject)
        await h.model.refreshImportedStates()
        #expect(Set(h.model.sections.flatMap(\.items).map(\.name)) == ["DSC00002.JPG", "DSC00003.JPG"])
        await h.stop()
    }

    /// When the catalogue refuses, the badge stays and the notice says so.
    @Test func aLiftTheCatalogueRefusesKeepsTheBadgeAndSaysSo() async throws {
        let refusing = MarksRefusedCatalogue(rejecting: [key("DSC00003.JPG")])
        let h = await start(refusing)
        #expect(await listed(h))
        #expect(!(await h.model.liftReject(named("DSC00003.JPG"))))
        #expect(h.model.isRejected(named("DSC00003.JPG")))
        #expect(h.model.importNotice == "The reject couldn't be lifted. Try again.")
        #expect(h.model.importStatus?.tone == .problem)
        #expect(h.log.lines.contains { $0.hasPrefix("browse: the reject wasn't lifted: catalogue error") })
        await h.stop()
    }

    // MARK: - Wording

    @Test func wording() {
        #expect(BrowseWording.rejectedBadge == "Rejected")
        #expect(BrowseWording.liftReject == "Lift Reject")
        #expect(BrowseWording.liftRejectHint == "Makes this photo new again, so Select All New picks it.")
        #expect(BrowseWording.cellAccessibility(name: "A.JPG", date: "d", kind: .photo(badge: nil), isImported: false,
                                                isStaged: false, isRejected: true) == "A.JPG, d, JPEG, Rejected")
        // Video and other files have no state words, rejected or not.
        #expect(BrowseWording.cellAccessibility(name: "C0001.MP4", date: "d", kind: .video, isImported: false,
                                                isRejected: true) == "C0001.MP4, d, Video")
        #expect(ImportWording.rejectsLeftOut(0) == nil)
        #expect(ImportWording.rejectsLeftOut(1) == "1 rejected file left out. Pick it in Browse to import it anyway.")
        #expect(ImportWording.rejectsLeftOut(3)
            == "3 rejected files left out. Pick them in Browse to import them anyway.")
    }
}

/// A catalogue that knows nothing but some Reject marks, and refuses to clear them.
actor MarksRefusedCatalogue: CatalogueStore {
    struct Refused: Error {}
    let rejected: Set<ObjectIdentity.ContentKey>
    init(rejecting keys: [ObjectIdentity.ContentKey]) { rejected = Set(keys) }

    func record(for identity: ObjectIdentity) -> CatalogueRecord? { nil }
    func states(of identities: [ObjectIdentity]) -> [ObjectIdentity: ObjectState] { [:] }
    func upsert(_ record: CatalogueRecord) {}
    func saveListing(_ listing: CardListing) {}
    func lastListing(for camera: CameraKey) -> CardListing? { nil }
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) {}
    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) {}
    func clearStaged(_ identity: ObjectIdentity) {}
    func stagedStates(of identities: [ObjectIdentity]) -> Set<ObjectIdentity> { [] }
    func camera(_ key: CameraKey) -> CameraRecord? { nil }
    func cameras() -> [CameraRecord] { [] }
    func upsertCamera(_ record: CameraRecord) {}
    func marks(of keys: [ObjectIdentity.ContentKey]) -> [ObjectIdentity.ContentKey: MarkRecord] {
        Dictionary(uniqueKeysWithValues: keys.filter(rejected.contains).map {
            ($0, MarkRecord(decision: .reject, markedAt: Date(timeIntervalSince1970: 1_793_000_000)))
        })
    }
    func clearMarks(of keys: [ObjectIdentity.ContentKey]) throws { throw Refused() }
}
