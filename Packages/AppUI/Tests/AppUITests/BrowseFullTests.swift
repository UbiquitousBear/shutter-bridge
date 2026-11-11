import CameraTransport
import Catalogue
import Foundation
import PTPKit
import Testing
@testable import AppUI

@MainActor
@Suite("Browse: selection, filters, the badge and the last-known card")
struct BrowseFullTests {
    let card = [
        item("DSC00001.ARW", at: 10, size: 40_000_000),
        item("DSC00001.JPG", at: 10, size: 20_000_000),
        item("DSC00002.ARW", at: 20, size: 41_000_000),
        item("DSC00003.JPG", at: 86_400 + 30, size: 22_000_000),   // the next day
        item("DSC00004.HIF", at: 86_400 + 40, size: 9_000_000),
        item("C0001.MP4", at: 86_400 + 50, size: 300_000_000),
        item("DSC00005.JPG", at: nil, size: 1_000_000),   // no capture date
    ]
    let zone = TimeZone(identifier: "UTC")!

    struct Harness {
        let model: BrowseModel
        let link: FakeLink
        let catalogue: InMemoryCatalogue
        let importer: FakeImporter
        let leases: LinkLeases
        let log: RecordingLog
        let run: Task<Void, Never>

        func stop() async {
            run.cancel()
            await run.value
        }
    }

    func key(_ descriptor: CameraDescriptor) -> CameraKey { CameraKeys.key(for: descriptor, material: nil) }

    func start(catalogue: InMemoryCatalogue = InMemoryCatalogue(), items: [CameraItem]? = nil,
               leases: LinkLeases = LinkLeases(), listFailure: CameraLinkFailure? = nil,
               listHangs: Bool = false) async -> Harness {
        let link = FakeLink(items: items ?? card)
        await link.set(listFailure: listFailure)
        await link.set(listHangs: listHangs)
        let importer = FakeImporter()
        let log = RecordingLog()
        let model = BrowseModel(
            camera: link.descriptor,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in link },
            services: services(log: log),
            onGone: { _ in },
            catalogue: BrowseCatalogue(store: catalogue, cameraKey: CameraKeys.fromDescriptor),
            importer: importer,
            leases: leases
        )
        let run = Task { await model.run() }
        return Harness(model: model, link: link, catalogue: catalogue, importer: importer, leases: leases, log: log,
                       run: run)
    }

    func named(_ name: String) -> CameraItem { card.first { $0.name == name }! }

    func identity(_ item: CameraItem, camera: CameraDescriptor) -> ObjectIdentity {
        item.identity(camera: key(camera), timeZone: .current)!
    }

    func importedRow(_ name: String, camera: CameraDescriptor) -> CatalogueRecord {
        let item = named(name)
        return CatalogueRecord(identity: identity(item, camera: camera), format: item.format, state: .imported)
    }

    var descriptor: CameraDescriptor { FakeLink(items: []).descriptor }

    // MARK: - Badge and listing

    @Test func importedFilesAreBadgedByTheEnginesIdentity() async {
        let catalogue = InMemoryCatalogue(records: [importedRow("DSC00002.ARW", camera: descriptor)])
        let h = await start(catalogue: catalogue)
        #expect(await eventually { h.model.phase == .listed && !h.model.imported.isEmpty })
        #expect(h.model.isImported(named("DSC00002.ARW")))
        #expect(!h.model.isImported(named("DSC00001.ARW")))
        // It can still be picked, to stage it (Shamil, 11 Nov).
        #expect(h.model.selectionBlock(for: named("DSC00002.ARW")) == nil)
        await h.stop()
    }

    @Test func theLiveListingIsSavedAsTheLastKnownCard() async throws {
        let h = await start()
        #expect(await eventually { h.model.phase == .listed })
        #expect(await eventually { await h.catalogue.lastListing(for: key(h.link.descriptor)) != nil })
        let saved = try #require(await h.catalogue.lastListing(for: key(h.link.descriptor)))
        // Every file with a capture date, by identity; the undated one has none.
        #expect(saved.entries.count == card.count - 1)
        #expect(Set(saved.entries.map(\.identity.filename)) == Set(card.dropLast().map(\.name)))
        #expect(h.model.lastKnownListedAt == nil)
        await h.stop()
    }

    @Test func theLastKnownCardShowsAtOnceThenTheLiveCardReplacesIt() async throws {
        let camera = descriptor
        let listedAt = Date(timeIntervalSince1970: 1_792_000_000)
        let old = [item("DSC09999.ARW", at: 5, size: 42), item("DSC00001.ARW", at: 10, size: 40_000_000)]
        let listing = CardListing(camera: key(camera), listedAt: listedAt, entries: old.map {
            CardListing.Entry(identity: $0.identity(camera: key(camera), timeZone: .current)!, format: $0.format)
        })
        let catalogue = InMemoryCatalogue(records: [
            CatalogueRecord(identity: old[1].identity(camera: key(camera), timeZone: .current)!, format: .raw,
                            state: .imported),
        ])
        await catalogue.saveListing(listing)
        let h = await start(catalogue: catalogue, listFailure: CameraLinkFailure(.noAnswer))   // no live card yet
        #expect(await eventually { h.model.lastKnownListedAt == listedAt })
        let shown = h.model.sections.flatMap(\.items)
        #expect(shown.map(\.name) == ["DSC00001.ARW", "DSC09999.ARW"])
        #expect(shown.first?.captureDate == old[1].captureDate)
        #expect(await eventually { h.model.isImported(shown[0]) })   // the badge works on the last-known card
        // Nothing can be picked, copied or imported from it: the link can't fetch those files by handle.
        #expect(h.model.selectionBlock(for: shown[1]) == .cardNotRead)
        #expect(!h.model.offersJPEGActions(shown[1]))
        #expect(!h.model.canImport)
        await h.stop()

        // With the live card, the last-known one goes and the new listing is saved.
        let live = await start(catalogue: catalogue)
        #expect(await eventually { live.model.phase == .listed })
        #expect(live.model.lastKnownListedAt == nil)
        #expect(live.model.sections.flatMap(\.items).count == card.count)
        // Saved after the catalogue is read again, so it can lag the phase.
        #expect(await eventually {
            await catalogue.lastListing(for: key(camera))?.entries.contains { $0.identity.filename == "DSC09999.ARW" }
                == false
        })
        #expect(live.log.lines.contains("browse: showing the last-known card (2 files)"))
        await live.stop()
    }

    /// The live card keeps the last-known card's Imported badges until the catalogue answers for it, so the badge
    /// doesn't flicker, New Only doesn't flash imported files and Select All New doesn't pick them. The catalogue
    /// here answers for the last-known card and fails for the live one, which leaves what the swap carried over.
    @Test func theBadgeCarriesOverToTheLiveCardUntilTheCatalogueAnswers() async {
        let camera = descriptor
        let k = key(camera)
        let catalogue = StatesFailAfterCatalogue(InMemoryCatalogue(), answering: 1)
        await catalogue.markImported(identity(named("DSC00002.ARW"), camera: camera))
        await catalogue.saveListing(CardListing(camera: k, listedAt: Date(timeIntervalSince1970: 1_792_000_000),
                                                entries: card.compactMap { item in
            item.identity(camera: k, timeZone: .current).map { CardListing.Entry(identity: $0, format: item.format) }
        }))
        let link = FakeLink(items: card)
        let model = BrowseModel(
            camera: link.descriptor,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in link },
            services: services(log: RecordingLog()), onGone: { _ in },
            catalogue: BrowseCatalogue(store: catalogue, cameraKey: CameraKeys.fromDescriptor)
        )
        model.filter.newOnly = true
        let run = Task { await model.run() }
        #expect(await eventually { model.phase == .listed })
        #expect(await eventually { await catalogue.failedCalls == 1 })   // the live card's read
        let imported = named("DSC00002.ARW")
        #expect(model.isImported(imported))
        #expect(model.selectionBlock(for: imported) == nil) // can be picked, to stage it
        #expect(!model.sections.flatMap(\.items).contains { $0.id == imported.id })
        model.selectAllNew()
        #expect(!model.isSelected(imported))
        #expect(!model.selection.isEmpty)
        run.cancel()
        await run.value
    }

    @Test func aCatalogueThatCantBeReadOnlyLosesTheBadge() async {
        let link = FakeLink(items: card)
        let log = RecordingLog()
        let model = BrowseModel(
            camera: link.descriptor,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in link },
            services: services(log: log), onGone: { _ in },
            catalogue: BrowseCatalogue(store: BrokenCatalogue(), cameraKey: CameraKeys.fromDescriptor)
        )
        let run = Task { await model.run() }
        #expect(await eventually { model.phase == .listed })
        #expect(model.imported.isEmpty)
        #expect(await eventually { log.lines.contains { $0.hasPrefix("browse: the listing couldn't be saved") } })
        run.cancel()
        await run.value
    }

    // MARK: - Selection and the sticky bar

    @Test func selectAllNewSkipsVideoImportedAndUndatedFiles() async {
        let catalogue = InMemoryCatalogue(records: [importedRow("DSC00002.ARW", camera: descriptor)])
        let h = await start(catalogue: catalogue)
        #expect(await eventually { h.model.phase == .listed && !h.model.imported.isEmpty })
        h.model.selectAllNew()
        #expect(h.model.isSelecting)
        #expect(Set(h.model.selectedItems.map(\.name))
            == ["DSC00001.ARW", "DSC00001.JPG", "DSC00003.JPG", "DSC00004.HIF"])
        // Newest first, as the card shows them.
        #expect(h.model.selectedItems.map(\.name) == ["DSC00004.HIF", "DSC00003.JPG", "DSC00001.ARW", "DSC00001.JPG"])
        #expect(h.model.selectionSummary == SelectionSummary(count: 4, bytes: 91_000_000))
        #expect(BrowseWording.selectionSummary(h.model.selectionSummary) == "4 files · \(ByteWording.size(91_000_000))")
        #expect(h.model.selectionBlock(for: named("C0001.MP4")) == .video)
        #expect(h.model.selectionBlock(for: named("DSC00005.JPG")) == .noCaptureDate)
        await h.stop()
    }

    @Test func togglingSelectsOnlyWhatCanBeImported() async {
        let h = await start()
        #expect(await eventually { h.model.phase == .listed })
        h.model.toggleSelection(named("C0001.MP4"))
        h.model.toggleSelection(named("DSC00005.JPG"))
        #expect(h.model.selection.isEmpty)
        h.model.toggleSelection(named("DSC00003.JPG"))
        #expect(h.model.isSelected(named("DSC00003.JPG")))
        #expect(BrowseWording.selectionSummary(h.model.selectionSummary) == "1 file · \(ByteWording.size(22_000_000))")
        h.model.toggleSelection(named("DSC00003.JPG"))
        #expect(h.model.selection.isEmpty)
        #expect(BrowseWording.selectionSummary(h.model.selectionSummary) == BrowseWording.noSelection)
        h.model.toggleSelection(named("DSC00003.JPG"))
        h.model.isSelecting = false   // leaving the mode clears it
        #expect(h.model.selection.isEmpty)
        await h.stop()
    }

    @Test func selectAllNewTakesWhatTheFiltersShow() async {
        let h = await start()
        #expect(await eventually { h.model.phase == .listed })
        h.model.filter.types = [.raw]
        h.model.selectAllNew()
        #expect(Set(h.model.selectedItems.map(\.name)) == ["DSC00001.ARW", "DSC00002.ARW"])
        // Hidden by a filter, still selected.
        h.model.filter = .none
        #expect(h.model.selectionSummary.count == 2)
        await h.stop()
    }

    // MARK: - Filters

    @Test func filtersForNewOnlyTypeAndDate() async {
        let catalogue = InMemoryCatalogue(records: [importedRow("DSC00002.ARW", camera: descriptor)])
        let h = await start(catalogue: catalogue)
        #expect(await eventually { h.model.phase == .listed && !h.model.imported.isEmpty })
        func shown() -> [String] { h.model.sections.flatMap(\.items).map(\.name) }
        #expect(shown().count == card.count)

        h.model.filter.newOnly = true
        #expect(!shown().contains("DSC00002.ARW"))
        #expect(shown().count == card.count - 1)
        #expect(h.model.filter.isActive)

        h.model.filter = BrowseFilter(types: [.heif, .video])
        #expect(shown() == ["C0001.MP4", "DSC00004.HIF"])

        let base = Date(timeIntervalSince1970: 1_793_000_000)
        h.model.filter = BrowseFilter(dateRange: base ... base.addingTimeInterval(15))
        #expect(shown() == ["DSC00001.ARW", "DSC00001.JPG"])   // the undated file is left out while a range is set

        h.model.filter.toggle(.jpeg)
        #expect(shown() == ["DSC00001.ARW"])
        h.model.filter = .none
        #expect(!h.model.filter.isActive)
        #expect(shown().count == card.count)
        #expect(h.model.hasFiles)
        #expect(h.model.dateBounds == base.addingTimeInterval(10) ... base.addingTimeInterval(86_400 + 50))
        await h.stop()
    }

    @Test func theDatePickersNarrowTheCardByWholeDays() async {
        let h = await start()
        #expect(await eventually { h.model.phase == .listed })
        func shown() -> Set<String> { Set(h.model.sections.flatMap(\.items).map(\.name)) }
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(!h.model.limitsDates)
        #expect(h.model.dayBounds?.contains(base.addingTimeInterval(10)) == true)

        h.model.limitsDates = true
        #expect(shown().count == card.count - 1)   // only the undated file goes
        h.model.lastDay = base.addingTimeInterval(10)
        #expect(shown() == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.ARW"])
        h.model.firstDay = base.addingTimeInterval(86_400 + 40)   // past the last day, which follows
        #expect(shown() == ["DSC00003.JPG", "DSC00004.HIF", "C0001.MP4"])
        #expect(h.model.firstDay <= h.model.lastDay)

        h.model.limitsDates = false
        #expect(h.model.filter.dateRange == nil)
        #expect(shown().count == card.count)
        await h.stop()
    }

    @Test func noDatedFilesMeansNoDateFilter() async {
        let h = await start(items: [item("DSC00009.JPG", at: nil)])
        #expect(await eventually { h.model.phase == .listed })
        #expect(h.model.dayBounds == nil)
        h.model.limitsDates = true
        #expect(!h.model.limitsDates)
        await h.stop()
    }

    @Test func fileTypes() {
        #expect(BrowseFileType.of(item("A.ARW")) == .raw)
        #expect(BrowseFileType.of(item("A.JPG")) == .jpeg)
        #expect(BrowseFileType.of(item("A.HIF")) == .heif)
        #expect(BrowseFileType.of(item("A.MP4")) == .video)
        #expect(BrowseFileType.of(item("A.XML")) == .other)
        #expect(BrowseFileType.allCases.map(BrowseWording.typeLabel) == ["RAW", "JPEG", "HEIF", "Video", "Other"])
    }

    // MARK: - Import

    @Test func importHandsTheSelectionOverAndClearsIt() async throws {
        let h = await start()
        #expect(await eventually { h.model.phase == .listed })
        h.model.toggleSelection(named("DSC00001.ARW"))
        h.model.toggleSelection(named("DSC00003.JPG"))
        #expect(h.model.canImport)
        let outcome = await h.model.importSelected()
        #expect(outcome == .started(2))
        let call = try #require(h.importer.calls.first)
        #expect(call.items.map(\.name) == ["DSC00003.JPG", "DSC00001.ARW"])
        #expect(call.camera.key == key(h.link.descriptor))
        #expect(call.camera.descriptor == h.link.descriptor)
        #expect(h.model.selection.isEmpty)
        #expect(!h.model.isSelecting)
        #expect(h.model.importNotice == "Importing 2 files.")
        #expect(h.model.importStatus?.tone == .info)
        #expect(h.model.importStatus?.dismissesItself == true)
        h.model.dismissImportNotice()
        #expect(h.model.importNotice == nil)
        #expect(h.model.importStatus == nil)
        await h.stop()
    }

    @Test func aRefusedImportKeepsTheSelection() async throws {
        let h = await start()
        #expect(await eventually { h.model.phase == .listed })
        h.importer.outcome = .busyWithAnotherCamera
        h.model.toggleSelection(named("DSC00003.JPG"))
        #expect(await h.model.importSelected() == .busyWithAnotherCamera)
        #expect(h.model.selectionSummary.count == 1)
        #expect(h.model.importNotice == BrowseWording.importRequested(.busyWithAnotherCamera))
        // A refusal is kept until it is closed, with the warning symbol, and VoiceOver hears it urgently.
        let first = try #require(h.model.importStatus)
        #expect(first.tone == .problem && !first.dismissesItself)
        #expect(first.systemImage == "exclamationmark.triangle")
        #expect(first.announcement.priority == .high)
        // The same refusal again is a new notice, so it is announced again.
        #expect(await h.model.importSelected() == .busyWithAnotherCamera)
        let second = try #require(h.model.importStatus)
        #expect(second.text == first.text && second != first)
        await h.stop()
    }

    @Test func filesImportedMeanwhileLeaveTheSelectionAndGetTheBadge() async {
        let catalogue = InMemoryCatalogue()
        let h = await start(catalogue: catalogue)
        #expect(await eventually { h.model.phase == .listed })
        h.model.selectAllNew()
        #expect(h.model.isSelected(named("DSC00003.JPG")))
        await catalogue.upsert(importedRow("DSC00003.JPG", camera: h.link.descriptor))
        await h.model.refreshImportedStates()
        #expect(h.model.isImported(named("DSC00003.JPG")))
        #expect(!h.model.isSelected(named("DSC00003.JPG")))
        await h.stop()
    }

    /// An explicit pick stays picked when it is imported meanwhile: it can still be staged (Shamil, 11 Nov).
    @Test func anExplicitPickImportedMeanwhileStaysSelected() async {
        let catalogue = InMemoryCatalogue()
        let h = await start(catalogue: catalogue)
        #expect(await eventually { h.model.phase == .listed })
        h.model.tap(named("DSC00003.JPG"))
        await catalogue.upsert(importedRow("DSC00003.JPG", camera: h.link.descriptor))
        await h.model.refreshImportedStates()
        #expect(h.model.isImported(named("DSC00003.JPG")))
        #expect(h.model.isSelected(named("DSC00003.JPG")))
        await h.stop()
    }

    /// The 17.1 bench run's MTP failure: Browse refreshes its badges itself when the import says more files were
    /// imported (nothing in SwiftUI has to ask), and stops following the import when it goes.
    @Test func browseRefreshesWhenTheImporterSaysMoreFilesWereImported() async {
        let catalogue = InMemoryCatalogue()
        let h = await start(catalogue: catalogue)
        #expect(await eventually { h.model.phase == .listed })
        #expect(await eventually { h.importer.updateReaders == 1 })
        h.model.selectAllNew()
        #expect(h.model.isSelected(named("DSC00003.JPG")))
        await catalogue.upsert(importedRow("DSC00003.JPG", camera: h.link.descriptor))
        h.importer.announceImported()
        #expect(await eventually { h.model.isImported(named("DSC00003.JPG")) })
        #expect(!h.model.isSelected(named("DSC00003.JPG")))
        #expect(h.log.lines.contains { $0.hasPrefix("browse: badges refreshed after import (rev 1): 7 shown, 6 dated, "
            + "1 imported, 0 staged, key k") })
        await h.stop()
        #expect(await eventually { h.importer.updateReaders == 0 })
    }

    /// Shamil's rule of 8 Nov in Browse: a file imported under another camera key and folder (MSC's, say) is badged.
    @Test func aFileImportedUnderAnotherKeyAndFolderIsBadged() async {
        let source = named("DSC00002.ARW")
        var identity = identity(source, camera: descriptor)
        identity.camera = CameraKey(rawValue: "usb-msc-name:hashed-volume-name")
        identity.folder = ""
        let row = CatalogueRecord(identity: identity, format: .raw, state: .imported)
        let catalogue = InMemoryCatalogue(records: [row])
        let h = await start(catalogue: catalogue)
        #expect(await eventually { h.model.phase == .listed && !h.model.imported.isEmpty })
        #expect(h.model.isImported(source))
        #expect(h.model.selectionBlock(for: source) == nil) // can be picked, to stage it
        await h.stop()
    }

    // MARK: - The link and accessibility

    @Test func leavingBrowseKeepsALinkAnImportHolds() async {
        let leases = LinkLeases()
        let h = await start(leases: leases)
        #expect(await eventually { h.model.phase == .listed })
        leases.acquire(h.link)   // as the import does when its job uses the link
        await h.stop()
        #expect(await !h.link.closed)
        await leases.release(h.link)
        #expect(await h.link.closed)
    }

    /// The label names the cell; whether it is selected is the `.isSelected` trait (never "Selected" in words as
    /// well, and no "Not selected" on every other cell), and why it can't be picked is the value, not a hint.
    @Test func cellLabelsSayNameDateTypeAndImportedAndTheValueSaysWhyNot() async {
        let catalogue = InMemoryCatalogue(records: [importedRow("DSC00002.ARW", camera: descriptor)])
        let h = await start(catalogue: catalogue)
        #expect(await eventually { h.model.phase == .listed && !h.model.imported.isEmpty })
        #expect(h.model.accessibilityLabel(for: named("DSC00002.ARW"), date: "8 Nov 2026 at 10:00")
            == "DSC00002.ARW, 8 Nov 2026 at 10:00, RAW, Imported")
        h.model.isSelecting = true
        h.model.toggleSelection(named("DSC00003.JPG"))
        #expect(h.model.accessibilityLabel(for: named("DSC00003.JPG"), date: "9 Nov") == "DSC00003.JPG, 9 Nov, JPEG, New")
        #expect(h.model.accessibilityLabel(for: named("DSC00001.JPG"), date: "8 Nov") == "DSC00001.JPG, 8 Nov, JPEG, New")
        #expect(h.model.accessibilityLabel(for: named("C0001.MP4"), date: "9 Nov") == "C0001.MP4, 9 Nov, Video")
        #expect(h.model.accessibilityLabel(for: named("DSC00005.JPG"), date: nil) == "DSC00005.JPG, No Date, JPEG, New")
        // The value: the reason, unless the label says it already.
        #expect(h.model.accessibilityValue(for: named("DSC00003.JPG")) == nil)
        #expect(h.model.accessibilityValue(for: named("DSC00001.JPG")) == nil)
        #expect(h.model.accessibilityValue(for: named("DSC00002.ARW")) == nil)   // it can be picked, to stage it
        #expect(h.model.accessibilityValue(for: named("C0001.MP4")) == "Videos can't be imported yet.")
        #expect(h.model.accessibilityValue(for: named("DSC00005.JPG"))
            == "No capture date, so it can't be imported yet.")
        // The same outside the selecting mode, where a tap now selects too.
        h.model.isSelecting = false
        #expect(h.model.accessibilityValue(for: named("C0001.MP4")) == "Videos can't be imported yet.")
        await h.stop()
    }
}

/// A catalogue whose `states(of:)` answers the first `answering` calls and throws after that, so a test sees what
/// the model shows before the catalogue's answer for a new card (a failed read leaves the badges as they are).
actor StatesFailAfterCatalogue: CatalogueStore {
    struct Unreadable: Error {}
    private let inner: InMemoryCatalogue
    private var answersLeft: Int
    private(set) var failedCalls = 0

    init(_ inner: InMemoryCatalogue, answering: Int) {
        self.inner = inner
        answersLeft = answering
    }

    func record(for identity: ObjectIdentity) throws -> CatalogueRecord? { throw Unreadable() }

    func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] {
        guard answersLeft > 0 else {
            failedCalls += 1
            throw Unreadable()
        }
        answersLeft -= 1
        var out: [ObjectIdentity: ObjectState] = [:]
        for identity in identities where importedIdentities.contains(identity) { out[identity] = .imported }
        return out
    }

    private var importedIdentities: Set<ObjectIdentity> = []
    func markImported(_ identity: ObjectIdentity) { importedIdentities.insert(identity) }

    private var listings: [CameraKey: CardListing] = [:]
    func upsert(_ record: CatalogueRecord) throws { throw Unreadable() }
    func saveListing(_ listing: CardListing) { listings[listing.camera] = listing }
    func lastListing(for camera: CameraKey) -> CardListing? { listings[camera] }
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) throws {
        throw Unreadable()
    }
    func markStaged(_ identity: ObjectIdentity, format: PTPMediaKind, at location: StagedLocation) throws {
        throw Unreadable()
    }
    func clearStaged(_ identity: ObjectIdentity) throws { throw Unreadable() }
    func stagedStates(of identities: [ObjectIdentity]) throws -> Set<ObjectIdentity> { throw Unreadable() }
    func camera(_ key: CameraKey) throws -> CameraRecord? { throw Unreadable() }
    func cameras() throws -> [CameraRecord] { throw Unreadable() }
    func upsertCamera(_ record: CameraRecord) throws { throw Unreadable() }
}
